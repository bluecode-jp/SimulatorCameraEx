//
//  BarcodeRendererTests.swift
//  Code 128 / EAN-13 generation: check digits, and a Vision round trip so
//  the frames really scan (the Mac app detects barcodes with Vision too).
//

import CoreVideo
import Vision
import XCTest

final class BarcodeRendererTests: XCTestCase {

    func testEAN13CheckDigit() {
        XCTAssertEqual(BarcodeRenderer.ean13CheckDigit("400638133393"), 1)   // 4006381333931
        XCTAssertEqual(BarcodeRenderer.ean13CheckDigit("490123456789"), 4)   // 4901234567894
    }

    func testEAN13Normalization() {
        XCTAssertEqual(BarcodeRenderer.ean13(from: "123456789"), "0001234567895")
        XCTAssertEqual(BarcodeRenderer.ean13(from: "4006381333931"), "4006381333931")
        XCTAssertNil(BarcodeRenderer.ean13(from: "4006381333932"), "wrong check digit")
        XCTAssertNil(BarcodeRenderer.ean13(from: "12345678901234"), "too long")
        XCTAssertNil(BarcodeRenderer.ean13(from: "12a4"))
        XCTAssertNil(BarcodeRenderer.ean13(from: ""))
    }

    func testEAN13ModuleCount() {
        XCTAssertEqual(BarcodeRenderer.ean13Modules("4006381333931").count, 95)
    }

    func testRejectsUnencodablePayloads() {
        XCTAssertNil(BarcodeRenderer.render(payload: "", symbology: .code128))
        XCTAssertNil(BarcodeRenderer.render(payload: "日本語", symbology: .code128))
        XCTAssertNil(BarcodeRenderer.render(payload: "abc", symbology: .ean13))
    }

    func testCode128ScansInBothOrientations() throws {
        for size in [FrameRaster.canonicalSize, FrameRaster.portraitSize] {
            let frame = try XCTUnwrap(BarcodeRenderer.render(payload: "123456789", symbology: .code128, size: size))
            XCTAssertEqual(CVPixelBufferGetWidth(frame), Int(size.width))
            XCTAssertEqual(try scan(frame), [.code128: "123456789"], "size \(size)")
        }
    }

    func testEAN13ScansInBothOrientations() throws {
        for size in [FrameRaster.canonicalSize, FrameRaster.portraitSize] {
            let frame = try XCTUnwrap(BarcodeRenderer.render(payload: "123456789", symbology: .ean13, size: size))
            XCTAssertEqual(try scan(frame), [.ean13: "0001234567895"], "size \(size)")
        }
    }

    /// The Android Emulator gives portrait apps only part of the landscape
    /// virtual camera: the middle 3:4 in the camera app, and a 9:16 strip
    /// off to the right of the middle in Chrome (both measured). Codes must
    /// fit both with their quiet zones (the edge columns stay white), scan
    /// in each, and look centered in Chrome's strip.
    func testCodesSurviveAndroidPortraitCrops() throws {
        let size = FrameRaster.canonicalSize
        XCTAssertEqual(FrameRaster.cropSafeRect(for: size), CGRect(x: 505, y: 0, width: 404, height: 720))
        let crops = [CGRect(x: 370, y: 0, width: 540, height: 720),   // camera app
                     CGRect(x: 506, y: 0, width: 403, height: 720)]   // Chrome
        let cases: [(CVPixelBuffer?, VNBarcodeSymbology, String)] = [
            (BarcodeRenderer.render(payload: "123456789", symbology: .code128, virtualCamera: true), .code128, "123456789"),
            (BarcodeRenderer.render(payload: "ABCDEFGHIJKLMNOPQRST", symbology: .code128, virtualCamera: true), .code128, "ABCDEFGHIJKLMNOPQRST"),
            (BarcodeRenderer.render(payload: "123456789012", symbology: .ean13, virtualCamera: true), .ean13, "1234567890128"),
            (QRRenderer.render(payload: "https://www.bluecode.co.jp", virtualCamera: true), .qr, "https://www.bluecode.co.jp"),
        ]
        for (frame, symbology, value) in cases {
          let frame = try XCTUnwrap(frame)
          for crop in crops {
            let image = CIImage(cvPixelBuffer: frame).cropped(to: crop)
            for x in [crop.minX, crop.maxX - 1] {
                XCTAssertTrue(try isWhiteColumn(image, x: x), "\(symbology.rawValue) touches the crop edge at x=\(x)")
            }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [symbology]
            try VNImageRequestHandler(ciImage: image).perform([request])
            XCTAssertEqual(request.results?.first?.payloadStringValue, value, "\(symbology.rawValue) in \(crop)")
          }
          let chrome = crops[1]
          let ink = try inkColumns(CIImage(cvPixelBuffer: frame), in: chrome)
          XCTAssertEqual((ink.lowerBound + ink.upperBound) / 2, chrome.midX, accuracy: 3, "\(symbology.rawValue) centered in Chrome")
        }
    }

    /// Simulator frames keep the full-width layout: the Android crop sizing
    /// applies to the virtual camera only.
    func testSimulatorFramesIgnoreAndroidCrop() throws {
        let size = FrameRaster.canonicalSize
        let simulator = CIImage(cvPixelBuffer: try XCTUnwrap(
            BarcodeRenderer.render(payload: "123456789", symbology: .code128, size: size)))
        let virtualCamera = CIImage(cvPixelBuffer: try XCTUnwrap(
            BarcodeRenderer.render(payload: "123456789", symbology: .code128, size: size, virtualCamera: true)))
        // x = 300 is outside the 540 px crop-safe middle (370…910).
        XCTAssertFalse(try isWhiteColumn(simulator, x: 300), "simulator frame should still span the width")
        XCTAssertTrue(try isWhiteColumn(virtualCamera, x: 300))
    }

    /// Leftmost…rightmost column with dark pixels, within `crop`.
    private func inkColumns(_ image: CIImage, in crop: CGRect) throws -> ClosedRange<CGFloat> {
        let width = Int(crop.width), height = Int(crop.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image.cropped(to: crop), toBitmap: &pixels, rowBytes: width * 4, bounds: crop,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let dark = (0..<width).filter { x in (0..<height).contains { y in pixels[(y * width + x) * 4] < 128 } }
        let first = try XCTUnwrap(dark.first), last = try XCTUnwrap(dark.last)
        return (crop.minX + CGFloat(first))...(crop.minX + CGFloat(last))
    }

    private func isWhiteColumn(_ image: CIImage, x: CGFloat) throws -> Bool {
        let column = image.cropped(to: CGRect(x: x, y: image.extent.minY, width: 1, height: image.extent.height))
        let height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: height * 4)
        CIContext().render(column, toBitmap: &pixels, rowBytes: 4, bounds: column.extent,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixels.allSatisfy { $0 > 200 }
    }

    private func scan(_ frame: CVPixelBuffer) throws -> [VNBarcodeSymbology: String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.code128, .ean13]
        try VNImageRequestHandler(cvPixelBuffer: frame).perform([request])
        var found: [VNBarcodeSymbology: String] = [:]
        for result in request.results ?? [] { found[result.symbology] = result.payloadStringValue }
        return found
    }
}
