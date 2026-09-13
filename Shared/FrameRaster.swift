//
//  FrameRaster.swift
//  SimulatorCamera shared
//
//  CPU rasterizer for the static sources (image, QR) and simcamctl: draws
//  into a canonical 1280x720 BGRA bitmap and hands back the bytes as Data.
//  One implementation instead of three copies of the same CGContext dance.
//

import Foundation
import CoreGraphics
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

    /// Render a canonical BGRA frame. `draw` receives a context already
    /// filled with `background`; origin is bottom-left (CoreGraphics).
    public static func render(
        background: CGColor,
        draw: (CGContext) -> Void
    ) -> Data? {
        let width = kSimCamFrameWidth
        let height = kSimCamFrameHeight
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
        guard let base = ctx.data else { return nil }
        return Data(bytes: base, count: bytesPerRow * height)
    }

    /// Aspect-fit `image` on `background` and return the canonical frame bytes.
    public static func render(image: CGImage, background: CGColor) -> Data? {
        render(background: background) { ctx in
            let rect = aspectFitRect(for: CGSize(width: image.width, height: image.height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
        }
    }

    /// Wrap canonical frame bytes in a SimCamFrame.
    public static func makeFrame(bytes: Data, timestamp: Double) -> SimCamFrame {
        SimCamFrame(
            width: kSimCamFrameWidth,
            height: kSimCamFrameHeight,
            bytesPerRow: bytesPerRow,
            timestampSeconds: timestamp,
            bgraData: bytes
        )
    }
}
