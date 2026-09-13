//
//  MacCameraSource.swift
//  SimulatorCamera
//
//  AVCaptureSession against the Mac's built-in (or external) camera.
//  Captures BGRA frames and forwards them to the SourceManager → XPC.
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
    var onFrame: ((SimCamFrame) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.dautov.SimulatorCamera.maccamera.session")
    private let outputQueue = DispatchQueue(
        label: "com.dautov.SimulatorCamera.maccamera.output",
        qos: .userInteractive
    )
    private let normalizer = FrameNormalizer()
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "mac-camera")

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

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw FrameSourceError.noDevice
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
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(pts)
        guard let frame = normalizer.makeFrame(from: pb, timestamp: timestamp) else { return }
        onFrame?(frame)
    }
}
