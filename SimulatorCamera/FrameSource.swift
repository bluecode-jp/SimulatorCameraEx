//
//  FrameSource.swift
//  SimulatorCamera
//
//  Common shape for everything that produces frames in the container app:
//  Mac camera, video file, static image, QR generator. SourceManager owns
//  the active one and pumps its frames into XPCClient.
//
//  Every source hands the manager a canonical 1280x720 BGRA frame; the
//  FrameNormalizer below does the letterboxing / rotation / format
//  conversion once, with a reusable CIContext and pixel-buffer pool,
//  instead of each source improvising its own conversion per frame.
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

/// Converts arbitrary pixel buffers into canonical SimCamFrames.
///
/// Thread-safety: one instance per source; sources call it from a single
/// capture / decode thread. CIContext and CVPixelBufferPool are themselves
/// thread-safe, so sharing an instance across threads is also fine.
final class FrameNormalizer {

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: CVPixelBufferPool?
    private let canonicalExtent = CGRect(
        x: 0, y: 0,
        width: kSimCamFrameWidth, height: kSimCamFrameHeight
    )

    init() {
        var pool: CVPixelBufferPool?
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: kSimCamFrameWidth,
            kCVPixelBufferHeightKey: kSimCamFrameHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
        self.pool = pool
    }

    /// Produce a canonical frame from `pixelBuffer`. `transform` is applied
    /// first (video preferredTransform); the result is aspect-fit onto a
    /// black canonical canvas. Already-canonical BGRA buffers take a fast
    /// memcpy path.
    func makeFrame(
        from pixelBuffer: CVPixelBuffer,
        transform: CGAffineTransform = .identity,
        timestamp: Double
    ) -> SimCamFrame? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if transform.isIdentity,
           format == kCVPixelFormatType_32BGRA,
           width == kSimCamFrameWidth,
           height == kSimCamFrameHeight {
            return copyOut(pixelBuffer, timestamp: timestamp)
        }

        guard width > 0, height > 0 else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !transform.isIdentity {
            image = image.transformed(by: transform)
            // Move the rotated image back to the origin.
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }

        let fit = FrameRaster.aspectFitRect(for: image.extent.size)
        let scale = fit.width / max(image.extent.width, 1)
        image = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: fit.origin.x, y: fit.origin.y))

        guard let dst = dequeue() else { return nil }
        // Clear to black first so letterbox bars are deterministic.
        context.render(
            CIImage(color: .black).cropped(to: canonicalExtent),
            to: dst,
            bounds: canonicalExtent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        context.render(
            image.cropped(to: canonicalExtent),
            to: dst,
            bounds: canonicalExtent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return copyOut(dst, timestamp: timestamp)
    }

    private func dequeue() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    private func copyOut(_ pixelBuffer: CVPixelBuffer, timestamp: Double) -> SimCamFrame? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let data = Data(bytes: base, count: rowBytes * height)
        return SimCamFrame(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: height,
            bytesPerRow: rowBytes,
            timestampSeconds: timestamp,
            bgraData: data
        )
    }
}
