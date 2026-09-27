//
//  QRRenderer.swift
//  SimulatorCamera shared
//
//  Renders a QR payload onto a canonical white frame. Used by the QR
//  source in the container app and by simcamctl.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

public enum QRRenderer {
    public static let qrSide: CGFloat = 600

    /// Nil when Core Image cannot encode the payload (empty or too long).
    /// `virtualCamera`: a frame for the CMIO extension, sized to survive the
    /// Android Emulator's crop.
    public static func render(
        payload: String,
        size: CGSize = FrameRaster.canonicalSize,
        virtualCamera: Bool = false
    ) -> CVPixelBuffer? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let base = filter.outputImage, base.extent.width > 0, base.extent.height > 0 else {
            return nil
        }
        // Scanner screens often show a portrait camera frame in a landscape
        // 4:3 box, which shows only 3/4 of the frame's width in height. Keep
        // the code within 85% of that, measured on the frame's short side:
        // 459 px on simulator frames, and on the virtual camera the short
        // side of the crop-safe area (see FrameRaster.cropSafeRect), which is
        // what the Android Emulator hands Chrome.
        let area = virtualCamera ? FrameRaster.cropSafeRect(for: size) : CGRect(origin: .zero, size: size)
        let qrSide = min(Self.qrSide, (min(area.width, area.height) * 3 / 4 * 0.85).rounded(.down))
        let scaled = base.transformed(by: CGAffineTransform(
            scaleX: qrSide / base.extent.width,
            y: qrSide / base.extent.height
        ))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let qrCG = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return FrameRaster.render(size: size, background: CGColor(red: 1, green: 1, blue: 1, alpha: 1)) { ctx in
            let rect = CGRect(
                x: (area.midX - qrSide / 2).rounded(),
                y: (size.height - qrSide) / 2,
                width: qrSide, height: qrSide
            )
            ctx.interpolationQuality = .none
            ctx.draw(qrCG, in: rect)
        }
    }
}
