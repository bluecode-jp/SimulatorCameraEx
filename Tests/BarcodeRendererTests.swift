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

    /// The Android Emulator gives portrait apps only the middle 3:4 of the
    /// landscape virtual camera (540 of 1280 px). Codes must fit there with
    /// their quiet zones: the crop's edge columns stay white, and it scans.
    func testCodesSurviveAndroidPortraitCrop() throws {
        let size = FrameRaster.canonicalSize
        let safe = FrameRaster.cropSafeSize(for: size)
        XCTAssertEqual(safe, CGSize(width: 540, height: 720))
        let crop = CGRect(x: (size.width - safe.width) / 2, y: 0, width: safe.width, height: safe.height)
        let cases: [(CVPixelBuffer?, VNBarcodeSymbology, String)] = [
            (BarcodeRenderer.render(payload: "123456789", symbology: .code128, virtualCamera: true), .code128, "123456789"),
            (BarcodeRenderer.render(payload: "ABCDEFGHIJKLMNOPQRST", symbology: .code128, virtualCamera: true), .code128, "ABCDEFGHIJKLMNOPQRST"),
            (BarcodeRenderer.render(payload: "123456789012", symbology: .ean13, virtualCamera: true), .ean13, "1234567890128"),
            (QRRenderer.render(payload: "https://www.bluecode.co.jp", virtualCamera: true), .qr, "https://www.bluecode.co.jp"),
        ]
        for (frame, symbology, value) in cases {
            let frame = try XCTUnwrap(frame)
            let image = CIImage(cvPixelBuffer: frame).cropped(to: crop)
            for x in [crop.minX, crop.maxX - 1] {
                XCTAssertTrue(try isWhiteColumn(image, x: x), "\(symbology.rawValue) touches the crop edge at x=\(x)")
            }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [symbology]
            try VNImageRequestHandler(ciImage: image).perform([request])
            XCTAssertEqual(request.results?.first?.payloadStringValue, value, symbology.rawValue)
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
