//
//  ControlServer.swift
//  SimulatorCamera (container app)
//
//  Lets simcamctl drive the app, so a source picked from the command line
//  feeds both the CMIO extension and iOS Simulator apps (SimulatorFeed) and
//  shows up in the UI, exactly as if it were clicked.
//
//  Loopback only (127.0.0.1:kSimCamControlPort). One JSON object per line:
//
//    {"command":"set-source","kind":"pattern"}
//    {"command":"set-source","kind":"camera"[,"device":"NAME or uniqueID"]}
//    {"command":"list-cameras"}
//    {"command":"set-source","kind":"qr","payload":"TEXT"}
//    {"command":"set-source","kind":"code128","payload":"TEXT"}
//    {"command":"set-source","kind":"ean13","payload":"123456789"}
//    {"command":"set-source","kind":"image","path":"/abs/file.png"}
//    {"command":"set-source","kind":"video","path":"/abs/file.mov"}
//    {"command":"set-orientation","orientation":"portrait"|"landscape"}
//    {"command":"status"}
//
//  Reply: {"ok":true, ...} or {"ok":false,"error":"..."}, then the
//  connection closes.
//

import Foundation
import Network
import OSLog

extension Notification.Name {
    /// Posted on the main queue when simcamctl changes SimulatorFeed.orientation.
    static let simulatorOrientationChanged = Notification.Name("SimulatorCamera.simulatorOrientationChanged")
}

@MainActor
final class ControlServer {

    static let shared = ControlServer()

    private let queue = DispatchQueue(label: "jp.co.bluecode.SimulatorCameraEx.control")
    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCameraEx", category: "control")
    private var listener: NWListener?
    private weak var sourceManager: SourceManager?

    func start(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: kSimCamControlPort)!)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log.error("control listener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connection

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLine(on: connection, buffer: Data())
    }

    nonisolated private func receiveLine(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                Task { @MainActor [weak self] in
                    let reply = await self?.handle(Data(line)) ?? ["ok": false, "error": "app is shutting down"]
                    Self.send(reply, on: connection)
                }
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self?.receiveLine(on: connection, buffer: buffer)
            }
        }
    }

    nonisolated private static func send(_ reply: [String: Any], on connection: NWConnection) {
        var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok":false}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Commands

    private func handle(_ line: Data) async -> [String: Any] {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let command = request["command"] as? String else {
            return ["ok": false, "error": "expected one JSON object with a \"command\""]
        }
        guard let sourceManager else { return ["ok": false, "error": "app is not ready"] }
        log.info("command \(command, privacy: .public)")

        switch command {
        case "status":
            return [
                "ok": true,
                "source": sourceManager.activeKind.label,
                "framesPushed": sourceManager.framesPushed,
                "simulatorApps": SimulatorFeed.shared.clientCount,
                "orientation": SimulatorFeed.shared.orientation.rawValue,
                "lastError": sourceManager.lastError ?? NSNull(),
            ]

        case "set-orientation":
            guard let raw = request["orientation"] as? String,
                  let orientation = SimulatorFeed.Orientation(rawValue: raw) else {
                return ["ok": false, "error": "orientation must be portrait or landscape"]
            }
            SimulatorFeed.shared.orientation = orientation
            NotificationCenter.default.post(name: .simulatorOrientationChanged, object: nil)
            return ["ok": true, "orientation": orientation.rawValue]

        case "set-source":
            return await setSource(request, sourceManager)

        case "list-cameras":
            let selected = sourceManager.selectedCameraID
            return ["ok": true, "cameras": MacCameraSource.cameraList().map {
                ["id": $0.id, "name": $0.name, "selected": $0.id == selected]
            }]

        default:
            return ["ok": false, "error": "unknown command \(command)"]
        }
    }

    private func setSource(_ request: [String: Any], _ sourceManager: SourceManager) async -> [String: Any] {
        let kind: SimCamSourceKind
        switch request["kind"] as? String {
        case "pattern":
            kind = .testPattern
        case "camera":
            if let query = request["device"] as? String, !query.isEmpty {
                guard let device = MacCameraSource.camera(matching: query) else {
                    let names = MacCameraSource.cameraList().map(\.name).joined(separator: ", ")
                    return ["ok": false, "error": "no camera matches \"\(query)\" (available: \(names))"]
                }
                sourceManager.selectedCameraID = device.uniqueID
            }
            kind = .macCamera
        case "qr":
            guard let payload = request["payload"] as? String, !payload.isEmpty else {
                return ["ok": false, "error": "qr needs a payload"]
            }
            sourceManager.qrPayload = payload
            kind = .qrCode
        case "code128":
            guard let payload = request["payload"] as? String, !payload.isEmpty else {
                return ["ok": false, "error": "code128 needs a payload"]
            }
            sourceManager.code128Payload = payload
            kind = .code128
        case "ean13":
            guard let payload = request["payload"] as? String, BarcodeRenderer.ean13(from: payload) != nil else {
                return ["ok": false, "error": "ean13 needs 1–12 digits (check digit added) or 13 digits with a valid check digit"]
            }
            sourceManager.ean13Payload = payload
            kind = .ean13
        case "image", "video":
            guard let path = request["path"] as? String else {
                return ["ok": false, "error": "\(request["kind"]!) needs a path"]
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                return ["ok": false, "error": "cannot read \(path)"]
            }
            if request["kind"] as? String == "image" {
                sourceManager.selectedImageURL = url
                kind = .image
            } else {
                sourceManager.selectedFileURL = url
                kind = .videoFile
            }
        default:
            return ["ok": false, "error": "kind must be pattern, camera, qr, code128, ean13, image or video"]
        }
        do {
            try await sourceManager.switchTo(kind)
            return ["ok": true, "source": kind.label, "simulatorApps": SimulatorFeed.shared.clientCount]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}
