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
    private let outputQueue = DispatchQueue(
        label: "com.dautov.SimulatorCamera.maccamera",
        qos: .userInteractive
    )
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "mac-camera")

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

        try await Task.detached(priority: .userInitiated) { [self] in
            try self.configureAndStart()
        }.value
    }

    private func configureAndStart() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw FrameSourceError.noDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
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
            session.commitConfiguration()
            throw FrameSourceError.invalidInput("Cannot add video output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        log.info("Mac camera capture started: \(device.localizedName, privacy: .public)")
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        log.info("Mac camera capture stopped")
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
        guard let frame = makeSimCamFrame(from: pb, timestamp: timestamp) else { return }
        onFrame?(frame)
    }
}
