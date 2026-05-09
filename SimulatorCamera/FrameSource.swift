//
//  FrameSource.swift
//  SimulatorCamera
//
//  Common shape for everything that produces frames in the container app:
//  Mac camera, video file, static image, QR generator. SourceManager owns
//  the active one and pumps its frames into XPCClient.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

protocol FrameSource: AnyObject {
    /// Kind reported to the extension via XPC setSource.
    var kind: SimCamSourceKind { get }

    /// Start producing frames. Throw if hardware/file fails to open.
    func start() async throws

    /// Stop producing frames. Idempotent.
    func stop()

    /// Hook the SourceManager registers. Called on a background queue.
    var onFrame: ((SimCamFrame) -> Void)? { get set }
}

/// Errors a source can throw on start.
enum FrameSourceError: LocalizedError {
    case noDevice
    case permissionDenied
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No camera device found."
        case .permissionDenied: return "Camera access denied. Grant access in System Settings → Privacy & Security → Camera."
        case .invalidInput(let m): return m
        }
    }
}

/// Convert a CVPixelBuffer to BGRA Data + a SimCamFrame.
/// Handles the row-padding + format-conversion path.
@inline(__always)
func makeSimCamFrame(from pixelBuffer: CVPixelBuffer, timestamp: Double) -> SimCamFrame? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

    // Fast path: already BGRA, just copy the bytes.
    if format == kCVPixelFormatType_32BGRA {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = Data(bytes: base, count: rowBytes * height)
        return SimCamFrame(
            width: width,
            height: height,
            bytesPerRow: rowBytes,
            timestampSeconds: timestamp,
            bgraData: data
        )
    }

    // Slow path: convert to BGRA via Core Image.
    let ci = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext(options: [.cacheIntermediates: false])
    var converted: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let createStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary, &converted
    )
    guard createStatus == kCVReturnSuccess, let dst = converted else { return nil }
    context.render(ci, to: dst)

    CVPixelBufferLockBaseAddress(dst, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(dst, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(dst) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(dst)
    let data = Data(bytes: base, count: rowBytes * height)
    return SimCamFrame(
        width: width,
        height: height,
        bytesPerRow: rowBytes,
        timestampSeconds: timestamp,
        bgraData: data
    )
}
