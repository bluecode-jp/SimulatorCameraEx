//
//  FrameSource.swift
//  SimulatorCamera
//
//  Common shape for everything that produces frames in the container app:
//  Mac camera, video file, static image, QR generator. SourceManager owns
//  the active one and pumps its frames into CameraLink.
//
//  Every source hands the manager a canonical 1280x720 BGRA, IOSurface-
//  backed CVPixelBuffer; the FrameNormalizer below does the letterboxing /
//  rotation / format conversion once, with a reusable CIContext and
//  pixel-buffer pool, instead of each source improvising its own conversion.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

protocol FrameSource: AnyObject {
    /// Kind reported to the extension.
    var kind: SimCamSourceKind { get }

    /// Start producing frames. Throw if hardware/file fails to open.
    func start() async throws

    /// Stop producing frames. Idempotent.
    func stop()

    /// Hook the SourceManager registers. Called on a background queue with
    /// a canonical pixel buffer.
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }

    /// Frames for iOS Simulator apps, shaped per SimulatorFeed.orientation
    /// (portrait by default). Called right after onFrame, only while a
    /// simulator app is connected.
    var onFeedFrame: ((CVPixelBuffer) -> Void)? { get set }
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

/// Converts arbitrary pixel buffers into canonical ones.
///
/// Thread-safety: one instance per source; sources call it from a single
/// capture / decode thread. CIContext and CVPixelBufferPool are themselves
/// thread-safe, so sharing an instance across threads is also fine.
final class FrameNormalizer {

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let poolLock = NSLock()
    private var pools: [String: CVPixelBufferPool] = [:]

    /// Return a pixel buffer of `size` (canonical by default) for
    /// `pixelBuffer`. `transform` is applied first (video preferredTransform);
    /// the result is aspect-fit (or, with `fill`, aspect-filled and cropped)
    /// onto a black canvas. Buffers already in the requested shape are
    /// returned as-is (zero copy).
    func canonicalize(
        _ pixelBuffer: CVPixelBuffer,
        transform: CGAffineTransform = .identity,
        size: CGSize = FrameRaster.canonicalSize,
        fill: Bool = false
    ) -> CVPixelBuffer? {
        let canvas = CGRect(origin: .zero, size: size)
        if transform.isIdentity,
           CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetWidth(pixelBuffer) == Int(size.width),
           CVPixelBufferGetHeight(pixelBuffer) == Int(size.height) {
            return pixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !transform.isIdentity {
            // preferredTransform is expressed in top-left-origin (y down)
            // pixel space; Core Image is bottom-left-origin (y up). Conjugate
            // with a y-flip, otherwise a 90° portrait rotation turns the
            // wrong way and the video comes out upside down.
            let flipY = CGAffineTransform(scaleX: 1, y: -1)
            image = image.transformed(by: flipY.concatenating(transform).concatenating(flipY))
            // Move the rotated image back to the origin.
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }

        let extent = image.extent.size
        let scale = fill
            ? max(size.width / max(extent.width, 1), size.height / max(extent.height, 1))
            : min(size.width / max(extent.width, 1), size.height / max(extent.height, 1))
        let origin = CGPoint(x: (size.width - extent.width * scale) / 2,
                             y: (size.height - extent.height * scale) / 2)
        image = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        guard let dst = dequeue(size: size) else { return nil }
        // Clear to black first so letterbox bars are deterministic.
        context.render(
            CIImage(color: .black).cropped(to: canvas),
            to: dst,
            bounds: canvas,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        context.render(
            image.cropped(to: canvas),
            to: dst,
            bounds: canvas,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return dst
    }

    private func dequeue(size: CGSize) -> CVPixelBuffer? {
        let key = "\(Int(size.width))x\(Int(size.height))"
        poolLock.lock()
        if pools[key] == nil { pools[key] = FrameRaster.makePool(size: size) }
        let pool = pools[key]
        poolLock.unlock()
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }
}
