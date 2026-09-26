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

    private func scan(_ frame: CVPixelBuffer) throws -> [VNBarcodeSymbology: String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.code128, .ean13]
        try VNImageRequestHandler(cvPixelBuffer: frame).perform([request])
        var found: [VNBarcodeSymbology: String] = [:]
        for result in request.results ?? [] { found[result.symbology] = result.payloadStringValue }
        return found
    }
}
