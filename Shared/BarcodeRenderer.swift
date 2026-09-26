//
//  BarcodeRenderer.swift
//  SimulatorCamera shared
//
//  1D barcodes for scanner testing, next to QRRenderer: Code 128 (Core
//  Image's generator) and EAN-13 (encoded here; Core Image has none).
//  Drawn black on white with quiet zones and the human-readable text
//  underneath, on a frame of any size (landscape for the CMIO extension,
//  portrait for iOS Simulator apps).
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import CoreVideo
import Foundation

public enum BarcodeSymbology: String, CaseIterable, Sendable {
    case code128
    case ean13
}

public enum BarcodeRenderer {

    // MARK: - EAN-13

    /// The 13-digit EAN for `input`: 1–12 digits are left-padded with zeros
    /// to 12 and get their check digit appended; 13 digits must carry a
    /// correct check digit. Nil for anything else.
    public static func ean13(from input: String) -> String? {
        let digits = input.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        switch digits.count {
        case 1...12:
            let body = String(repeating: "0", count: 12 - digits.count) + digits
            return body + String(ean13CheckDigit(body))
        case 13:
            let body = String(digits.prefix(12))
            return ean13CheckDigit(body) == Int(String(digits.last!)) ? digits : nil
        default:
            return nil
        }
    }

    /// Check digit for a 12-digit body: weights 1,3,1,3… from the left.
    public static func ean13CheckDigit(_ body: String) -> Int {
        let sum = body.compactMap { $0.wholeNumberValue }.enumerated()
            .reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return (10 - sum % 10) % 10
    }

    /// 95 modules (true = bar) for a valid 13-digit EAN.
    static func ean13Modules(_ code: String) -> [Bool] {
        let l = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
        let g = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
        let r = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
        // First digit selects the L/G parity of the left half.
        let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
        let d = code.compactMap { $0.wholeNumberValue }
        var bits = "101"
        for (i, digit) in d[1...6].enumerated() {
            bits += Array(parity[d[0]])[i] == "L" ? l[digit] : g[digit]
        }
        bits += "01010"
        for digit in d[7...12] { bits += r[digit] }
        bits += "101"
        return bits.map { $0 == "1" }
    }

    // MARK: - Rendering

    /// Nil when `payload` cannot be encoded (empty, non-ASCII for Code 128,
    /// wrong digits for EAN-13).
    public static func render(
        payload: String,
        symbology: BarcodeSymbology,
        size: CGSize = FrameRaster.canonicalSize
    ) -> CVPixelBuffer? {
        let modules: [Bool]
        let caption: String
        switch symbology {
        case .ean13:
            guard let code = ean13(from: payload) else { return nil }
            modules = ean13Modules(code)
            caption = code
        case .code128:
            guard let bars = code128Modules(payload) else { return nil }
            modules = bars
            caption = payload
        }

        // Integer module width so bars stay crisp; quiet zone of 10 modules
        // per side, the barcode filling at most 84% of the frame width.
        let quiet = 10
        let moduleWidth = max(1, Int(size.width * 0.84) / (modules.count + 2 * quiet))
        let barsWidth = CGFloat(modules.count * moduleWidth)
        let barHeight = (min(size.width, size.height) * 0.30).rounded()
        let fontSize = max(18, (barHeight * 0.16).rounded())
        let gap = (fontSize * 0.5).rounded()
        let blockHeight = barHeight + gap + fontSize
        let x0 = ((size.width - barsWidth) / 2).rounded()
        let yText = ((size.height - blockHeight) / 2).rounded()   // CG: bottom-left origin
        let yBars = yText + fontSize + gap

        return FrameRaster.render(size: size, background: CGColor(gray: 1, alpha: 1)) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for (i, bar) in modules.enumerated() where bar {
                ctx.fill(CGRect(x: x0 + CGFloat(i * moduleWidth), y: yBars, width: CGFloat(moduleWidth), height: barHeight))
            }
            drawCaption(caption, in: ctx, centerX: size.width / 2, baselineY: yText + fontSize * 0.2, fontSize: fontSize)
        }
    }

    /// Code 128 bars from Core Image, read back as one module per pixel.
    static func code128Modules(_ payload: String) -> [Bool]? {
        guard !payload.isEmpty, let data = payload.data(using: .ascii) else { return nil }
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = data
        filter.quietSpace = 0
        filter.barcodeHeight = 1
        guard let image = filter.outputImage, image.extent.width > 0 else { return nil }
        let width = Int(image.extent.width)
        var pixels = [UInt8](repeating: 255, count: width * 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            image, toBitmap: &pixels, rowBytes: width * 4,
            bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: CGFloat(width), height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0..<width).map { pixels[$0 * 4] < 128 }
    }

    private static func drawCaption(_ text: String, in ctx: CGContext, centerX: CGFloat, baselineY: CGFloat, fontSize: CGFloat) {
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: centerX - CGFloat(width) / 2, y: baselineY)
        CTLineDraw(line, ctx)
    }
}
