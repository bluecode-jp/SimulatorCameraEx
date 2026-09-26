//
//  SimulatorFeed.swift
//  SimulatorCamera (container app)
//
//  Serves the active source's frames to iOS Simulator apps that have
//  SimCamInject.dylib loaded. The Simulator has no capture stack, so the
//  CMIO extension alone never reaches it; the dylib fakes AVFoundation in
//  the app process and pulls frames from here over loopback TCP.
//
//  Wire format (little-endian), one message per frame:
//    "SCF1"  width u32  height u32  bytesPerRow u32  metaLength u32
//    pixels  (height * bytesPerRow bytes, BGRA)
//    meta    (metaLength bytes, UTF-8 JSON array of barcodes found in the
//             frame: type = AVMetadataObject.ObjectType raw value, value,
//             bounds [x,y,w,h] and corners [[x,y]…] normalized, top-left origin)
//
//  Each client gets the newest frame whenever its previous send finished,
//  so a slow client drops frames instead of queueing them.
//

import CoreGraphics
import CoreVideo
import Foundation
import Network
import OSLog
import Vision

final class SimulatorFeed: @unchecked Sendable {

    static let shared = SimulatorFeed()

    private let queue = DispatchQueue(label: "jp.co.bluecode.SimulatorCamera.feed")
    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCamera", category: "simulator-feed")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var latest: Data?
    private var sequence: UInt64 = 0

    // Barcode detection runs off the frame path, at most every 100 ms; each
    // frame carries the newest result so the simulator side needs no Vision.
    private let detectQueue = DispatchQueue(label: "jp.co.bluecode.SimulatorCamera.feed.detect", qos: .utility)
    private let metaLock = NSLock()
    private var latestMeta = Data("[]".utf8)
    private var detecting = false
    private var lastDetect = Date.distantPast

    private final class Client {
        let connection: NWConnection
        var sending = false
        var sentSequence: UInt64 = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// Number of simulator apps currently connected (read from any thread).
    var clientCount: Int { queue.sync { clients.count } }

    // MARK: - Orientation

    /// Shape of the frames sent to simulator apps. Portrait matches an iPhone
    /// held upright, so full-screen camera views are not cropped to a sliver
    /// of a landscape frame; the CMIO extension always gets landscape.
    enum Orientation: String, CaseIterable, Sendable {
        case portrait, landscape

        var frameSize: CGSize {
            self == .portrait ? FrameRaster.portraitSize : FrameRaster.canonicalSize
        }
    }

    static let orientationDefaultsKey = "simulatorFrameOrientation"
    private let orientationLock = NSLock()
    private var _orientation: Orientation =
        UserDefaults.standard.string(forKey: SimulatorFeed.orientationDefaultsKey)
            .flatMap(Orientation.init(rawValue:)) ?? .portrait

    var orientation: Orientation {
        get { orientationLock.lock(); defer { orientationLock.unlock() }; return _orientation }
        set {
            orientationLock.lock(); _orientation = newValue; orientationLock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.orientationDefaultsKey)
        }
    }

    /// The frame to send given a source's canonical one: the same buffer in
    /// landscape, otherwise `render(size)` (the source redraws from its
    /// original, so nothing is letterboxed twice). Nil when nobody listens.
    func frame(from canonical: CVPixelBuffer, render: (CGSize) -> CVPixelBuffer?) -> CVPixelBuffer? {
        guard clientCount > 0 else { return nil }
        let size = orientation.frameSize
        return size == FrameRaster.canonicalSize ? canonical : render(size)
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: kSimCamFeedPort)!)
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.log.info("listener \(String(describing: state), privacy: .public)")
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                log.error("listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Publish a frame. Called from the source's thread for every frame.
    func publish(_ pixelBuffer: CVPixelBuffer) {
        guard clientCount > 0 else { return }
        detectBarcodesIfDue(pixelBuffer)
        metaLock.lock()
        let meta = latestMeta
        metaLock.unlock()
        guard let message = Self.encode(pixelBuffer, meta: meta) else { return }
        queue.async { [self] in
            latest = message
            sequence &+= 1
            for client in clients.values { pump(client) }
        }
    }

    // MARK: - Barcodes

    /// Vision symbology → AVMetadataObject.ObjectType raw value.
    private static let metadataTypes: [VNBarcodeSymbology: String] = [
        .qr: "org.iso.QRCode", .ean13: "org.gs1.EAN-13", .ean8: "org.gs1.EAN-8", .upce: "org.gs1.UPC-E",
        .code128: "org.iso.Code128", .code39: "org.iso.Code39", .code39Checksum: "org.iso.Code39Mod43",
        .code93: "com.intermec.Code93", .itf14: "org.gs1.ITF14", .i2of5: "org.ansi.Interleaved2of5",
        .dataMatrix: "org.iso.DataMatrix", .pdf417: "org.iso.PDF417", .aztec: "org.iso.Aztec",
    ]

    private func detectBarcodesIfDue(_ pixelBuffer: CVPixelBuffer) {
        metaLock.lock()
        let due = !detecting && Date().timeIntervalSince(lastDetect) >= 0.1
        if due { detecting = true; lastDetect = Date() }
        metaLock.unlock()
        guard due else { return }
        detectQueue.async { [self] in
            let meta = Self.detectBarcodes(pixelBuffer)
            metaLock.lock()
            latestMeta = meta
            detecting = false
            metaLock.unlock()
        }
    }

    /// JSON array of {type, value, bounds:[x,y,w,h], corners:[[x,y]…]} in
    /// normalized image coordinates, origin top-left.
    private static func detectBarcodes(_ pixelBuffer: CVPixelBuffer) -> Data {
        let request = VNDetectBarcodesRequest()
        request.symbologies = Array(metadataTypes.keys)
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
        } catch {
            return Data("[]".utf8)
        }
        let codes: [[String: Any]] = (request.results ?? []).compactMap { obs in
            guard let type = metadataTypes[obs.symbology], let value = obs.payloadStringValue else { return nil }
            let flip = { (p: CGPoint) -> [Double] in [Double(p.x), Double(1 - p.y)] }
            let box = obs.boundingBox
            return [
                "type": type,
                "value": value,
                "bounds": [box.minX, 1 - box.maxY, box.width, box.height].map(Double.init),
                "corners": [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map(flip),
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: codes)) ?? Data("[]".utf8)
    }

    // MARK: - Private

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("simulator client connected")
            case .failed, .cancelled:
                self.clients[id] = nil
                self.log.info("simulator client gone")
            default:
                break
            }
        }
        clients[id] = client
        connection.start(queue: queue)
        pump(client)
    }

    private func pump(_ client: Client) {
        guard !client.sending, let message = latest, client.sentSequence != sequence else { return }
        client.sending = true
        client.sentSequence = sequence
        client.connection.send(content: message, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { return }
            client.sending = false
            if let error {
                self.log.error("send failed: \(error.localizedDescription, privacy: .public)")
                client.connection.cancel()
                return
            }
            self.pump(client)
        })
    }

    private static func encode(_ pixelBuffer: CVPixelBuffer, meta: Data) -> Data? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let height = UInt32(CVPixelBufferGetHeight(pixelBuffer))
        let bytesPerRow = UInt32(CVPixelBufferGetBytesPerRow(pixelBuffer))

        var data = Data(capacity: 20 + Int(height * bytesPerRow) + meta.count)
        data.append(contentsOf: Array("SCF1".utf8))
        for value in [width, height, bytesPerRow, UInt32(meta.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(base.assumingMemoryBound(to: UInt8.self), count: Int(height * bytesPerRow))
        data.append(meta)
        return data
    }
}
