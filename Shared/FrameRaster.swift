//
//  FrameRaster.swift
//  SimulatorCamera shared
//
//  CPU rasterizer for the static sources (image, QR) and simcamctl: draws
//  straight into an IOSurface-backed canonical 1280x720 BGRA pixel buffer
//  that can be enqueued on the extension's sink stream without a copy.
//

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo

public enum FrameRaster {

    public static var bytesPerRow: Int { kSimCamFrameWidth * kSimCamBytesPerPixel }

    /// Aspect-fit `size` inside the canonical frame, centered.
    public static func aspectFitRect(for size: CGSize) -> CGRect {
        aspectFitRect(for: size, in: CGSize(width: kSimCamFrameWidth, height: kSimCamFrameHeight))
    }

    public static func aspectFitRect(for size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Part of a frame that survives a centered portrait 3:4 crop. The
    /// Android Emulator hands a landscape webcam to portrait apps as a
    /// 3:4 crop of its middle (only 540 of 1280 px), so codes generated for
    /// the virtual camera are sized to this area, quiet zones included.
    public static func cropSafeSize(for size: CGSize) -> CGSize {
        CGSize(width: min(size.width, (size.height * 3 / 4).rounded(.down)), height: size.height)
    }

    /// Canonical frame size (what the CMIO extension accepts).
    public static let canonicalSize = CGSize(width: kSimCamFrameWidth, height: kSimCamFrameHeight)

    /// Portrait frame size for iOS Simulator apps (SimulatorFeed): the
    /// canonical frame turned on its side, like an iPhone held upright.
    public static let portraitSize = CGSize(width: kSimCamFrameHeight, height: kSimCamFrameWidth)

    /// Pixel-buffer attributes every canonical buffer is created with.
    public static var pixelBufferAttributes: [CFString: Any] { pixelBufferAttributes(size: canonicalSize) }

    public static func pixelBufferAttributes(size: CGSize) -> [CFString: Any] {
        [
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
    }

    /// A fresh, IOSurface-backed pixel buffer (canonical size by default).
    public static func makePixelBuffer(size: CGSize = canonicalSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            pixelBufferAttributes(size: size) as CFDictionary,
            &pb
        )
        return status == kCVReturnSuccess ? pb : nil
    }

    /// A pool of canonical pixel buffers for sources that emit continuously.
    public static func makePool(size: CGSize = canonicalSize) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes(size: size) as CFDictionary, &pool)
        return pool
    }

    /// Render a canonical frame. `draw` receives a context already filled
    /// with `background`; origin is bottom-left (CoreGraphics).
    public static func render(
        size: CGSize = canonicalSize,
        background: CGColor,
        draw: (CGContext) -> Void
    ) -> CVPixelBuffer? {
        guard let pb = makePixelBuffer(size: size) else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: size))
        draw(ctx)
        return pb
    }

    /// Aspect-fit `image` on `background` into a canonical pixel buffer.
    public static func render(image: CGImage, background: CGColor, size: CGSize = canonicalSize) -> CVPixelBuffer? {
        render(size: size, background: background) { ctx in
            let rect = aspectFitRect(for: CGSize(width: image.width, height: image.height), in: size)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
        }
    }

    /// Wrap a canonical pixel buffer in a host-clock-stamped CMSampleBuffer,
    /// the shape the sink stream expects. `formatDescription` is created
    /// from the buffer so it always matches.
    public static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(kSimCamFrameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else {
            return nil
        }
        return sample
    }
}
