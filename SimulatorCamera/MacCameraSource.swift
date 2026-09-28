//
//  MacCameraSource.swift
//  SimulatorCamera
//
//  AVCaptureSession against the Mac's built-in (or external) camera.
//  Captures BGRA frames and forwards them to the SourceManager → sink.
//
//  v1.0 picks default camera (Mac built-in webcam or first external).
//  v1.1 adds device picker, front/back equivalent, resolution control.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import OSLog

final class MacCameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {

    let kind: SimCamSourceKind = .macCamera
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFeedFrame: ((CVPixelBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "jp.co.bluecode.SimulatorCameraEx.maccamera.session")
    private let outputQueue = DispatchQueue(
        label: "jp.co.bluecode.SimulatorCameraEx.maccamera.output",
        qos: .userInteractive
    )
    private let normalizer = FrameNormalizer()
    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCameraEx", category: "mac-camera")

    /// uniqueID of the camera to open; nil (or unplugged) picks the default.
    private let deviceID: String?

    init(deviceID: String? = nil) {
        self.deviceID = deviceID
        super.init()
    }

    /// Cameras the source can open, in discovery order. Never includes our
    /// own virtual camera: that would feed the extension its own output.
    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.filter { $0.localizedName != kSimCamDeviceName }
    }

    /// (uniqueID, display name) for pickers and simcamctl; cameras sharing a
    /// name (e.g. two Studio Displays) get " (1)", " (2)" so they differ.
    static func cameraList() -> [(id: String, name: String)] {
        let cameras = availableCameras()
        var seen: [String: Int] = [:]
        let totals = Dictionary(grouping: cameras, by: displayName).mapValues(\.count)
        return cameras.map { camera in
            let name = displayName(camera)
            guard totals[name, default: 0] > 1 else { return (camera.uniqueID, name) }
            seen[name, default: 0] += 1
            return (camera.uniqueID, "\(name) (\(seen[name]!))")
        }
    }

    /// localizedName without invisible direction marks (Continuity Camera
    /// names start with U+200E) or surrounding spaces.
    private static func displayName(_ camera: AVCaptureDevice) -> String {
        camera.localizedName
            .filter { !["\u{200E}", "\u{200F}", "\u{202A}", "\u{202C}"].contains($0) }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Camera whose uniqueID equals `query`, else the first whose name
    /// contains it (case-insensitive). For simcamctl --camera NAME.
    static func camera(matching query: String) -> AVCaptureDevice? {
        let cameras = availableCameras()
        if let exact = cameras.first(where: { $0.uniqueID == query }) { return exact }
        // Match the display names from cameraList(), so "(2)" picks the second.
        guard let id = cameraList().first(where: { $0.name.localizedCaseInsensitiveContains(query) })?.id else { return nil }
        return cameras.first { $0.uniqueID == id }
    }

    /// Set by stop(). Checked after startRunning so a stop that races the
    /// (slow) session start still wins and the camera light goes off.
    private var isStopped = false
    private let stateLock = NSLock()

    func start() async throws {
        // Permission gate.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw FrameSourceError.permissionDenied }
        case .denied, .restricted:
            throw FrameSourceError.permissionDenied
        case .authorized:
            break
        @unknown default:
            throw FrameSourceError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureAndStart()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func configureAndStart() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        let candidates = Self.availableCameras()
        let chosen = deviceID.flatMap { id in candidates.first { $0.uniqueID == id } }
        guard let device = chosen
                ?? candidates.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? candidates.first else {
            throw FrameSourceError.noDevice
        }
        if deviceID != nil, chosen == nil {
            log.info("selected camera is not connected; using \(device.localizedName, privacy: .public)")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw FrameSourceError.invalidInput("Cannot add camera input")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw FrameSourceError.invalidInput("Cannot add video output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        stateLock.lock()
        let stopped = isStopped
        stateLock.unlock()
        guard !stopped else { return }

        session.startRunning()
        log.info("Mac camera capture started: \(device.localizedName, privacy: .public)")

        // If stop() landed while startRunning was blocking, honor it now.
        stateLock.lock()
        let stoppedDuringStart = isStopped
        stateLock.unlock()
        if stoppedDuringStart, session.isRunning {
            session.stopRunning()
        }
    }

    func stop() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()
        onFrame = nil
        onFeedFrame = nil
        sessionQueue.async { [session, log] in
            guard session.isRunning else { return }
            session.stopRunning()
            log.info("Mac camera capture stopped")
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = normalizer.canonicalize(pb) else { return }
        onFrame?(frame)
        // Portrait: crop the landscape webcam to the centre (fill) rather
        // than letterboxing it, the way an upright phone camera frames it.
        if let onFeedFrame, let feed = SimulatorFeed.shared.frame(from: frame, render: { size in
            normalizer.canonicalize(pb, size: size, fill: true)
        }) {
            onFeedFrame(feed)
        }
    }
}
