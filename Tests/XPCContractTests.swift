//
//  XPCContractTests.swift
//  SimulatorCameraTests
//
//  Pins down the parts of the wire contract that, if they regress, crash
//  the camera extension or silently blank the virtual camera.
//

import XCTest
import CoreVideo

final class XPCContractTests: XCTestCase {

    private func canonicalFrame(payloadBytes: Int? = nil, timestamp: Double = 1) -> SimCamFrame {
        let rowBytes = kSimCamFrameWidth * kSimCamBytesPerPixel
        let count = payloadBytes ?? rowBytes * kSimCamFrameHeight
        return SimCamFrame(
            width: kSimCamFrameWidth,
            height: kSimCamFrameHeight,
            bytesPerRow: rowBytes,
            timestampSeconds: timestamp,
            bgraData: Data(count: count)
        )
    }

    // MARK: Validation

    func testCanonicalFrameIsValid() {
        XCTAssertNil(canonicalFrame().validationError())
        XCTAssertTrue(canonicalFrame().isCanonicalSize)
    }

    func testShortPayloadIsRejected() {
        let frame = canonicalFrame(payloadBytes: 100)
        XCTAssertNotNil(frame.validationError())
    }

    func testUnpaddedLastRowIsAccepted() {
        // rows-1 full strides + one row of pixels is the minimum we read.
        let rowBytes = kSimCamFrameWidth * kSimCamBytesPerPixel
        let frame = canonicalFrame(payloadBytes: rowBytes * (kSimCamFrameHeight - 1) + rowBytes)
        XCTAssertNil(frame.validationError())
    }

    func testNonPositiveDimensionsAreRejected() {
        let frame = SimCamFrame(width: 0, height: 720, bytesPerRow: 0, timestampSeconds: 0, bgraData: Data())
        XCTAssertNotNil(frame.validationError())
        let negative = SimCamFrame(width: 1280, height: -1, bytesPerRow: 5120, timestampSeconds: 0, bgraData: Data())
        XCTAssertNotNil(negative.validationError())
    }

    func testOversizedDimensionsAreRejected() {
        let frame = SimCamFrame(
            width: SimCamFrame.maxDimension + 1, height: 1,
            bytesPerRow: (SimCamFrame.maxDimension + 1) * 4,
            timestampSeconds: 0,
            bgraData: Data(count: (SimCamFrame.maxDimension + 1) * 4)
        )
        XCTAssertNotNil(frame.validationError())
    }

    func testBytesPerRowSmallerThanWidthIsRejected() {
        let frame = SimCamFrame(width: 1280, height: 720, bytesPerRow: 1280, timestampSeconds: 0, bgraData: Data(count: 1280 * 720))
        XCTAssertNotNil(frame.validationError())
    }

    func testNonBGRAFormatIsRejected() {
        let frame = SimCamFrame(
            width: 1280, height: 720, bytesPerRow: 5120,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            timestampSeconds: 0, bgraData: Data(count: 5120 * 720)
        )
        XCTAssertNotNil(frame.validationError())
    }

    func testNonFiniteTimestampIsRejected() {
        XCTAssertNotNil(canonicalFrame(timestamp: .nan).validationError())
        XCTAssertNotNil(canonicalFrame(timestamp: .infinity).validationError())
    }

    // MARK: Secure coding round trip

    func testFrameSurvivesSecureCodingRoundTrip() throws {
        let original = canonicalFrame(timestamp: 42.5)
        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClasses: [SimCamFrame.self, NSData.self], from: data) as? SimCamFrame
        )
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
        XCTAssertEqual(decoded.bytesPerRow, original.bytesPerRow)
        XCTAssertEqual(decoded.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(decoded.timestampSeconds, 42.5)
        XCTAssertEqual(decoded.bgraData.count, original.bgraData.count)
    }

    func testMalformedFrameFailsToDecode() throws {
        let bogus = SimCamFrame(width: 4096, height: 4096, bytesPerRow: 4096 * 4, timestampSeconds: 0, bgraData: Data(count: 16))
        let data = try NSKeyedArchiver.archivedData(withRootObject: bogus, requiringSecureCoding: true)
        let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [SimCamFrame.self, NSData.self], from: data)
        XCTAssertNil(decoded, "a frame whose payload cannot cover its geometry must not decode")
    }

    func testStatusSurvivesSecureCodingRoundTrip() throws {
        let original = SimCamStatus(activeSourceKind: .qrCode, connectedClientCount: 3, lastFrameTimestampSeconds: 7, isStreamRunning: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: SimCamStatus.self, from: data)
        )
        XCTAssertEqual(decoded.activeSourceKind, .qrCode)
        XCTAssertEqual(decoded.connectedClientCount, 3)
        XCTAssertEqual(decoded.lastFrameTimestampSeconds, 7)
        XCTAssertTrue(decoded.isStreamRunning)
    }

    // MARK: Mach service naming

    func testMachServiceNameIsChildOfAppGroup() {
        let name = SimCamMachService.name
        XCTAssertTrue(name.hasSuffix(".xpc"))
        XCTAssertTrue(name.contains(kSimCamAppGroupSuffix))
        if let team = SimCamCodeSigning.teamIdentifier() {
            XCTAssertEqual(name, "\(team).\(kSimCamAppGroupSuffix).xpc")
        } else {
            XCTAssertEqual(name, "\(kSimCamAppGroupSuffix).xpc")
        }
    }

    func testPeerRequirementOnlyExistsForSignedBuilds() {
        let requirement = SimCamCodeSigning.peerRequirement()
        if let team = SimCamCodeSigning.teamIdentifier() {
            XCTAssertEqual(requirement, "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        } else {
            XCTAssertNil(requirement)
        }
    }

    // MARK: Raster helpers

    func testAspectFitLetterboxesPortrait() {
        let rect = FrameRaster.aspectFitRect(for: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(rect.height, 720, accuracy: 0.001)
        XCTAssertEqual(rect.width, 405, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 640, accuracy: 0.001)
    }

    func testAspectFitPillarboxesWide() {
        let rect = FrameRaster.aspectFitRect(for: CGSize(width: 3840, height: 1080))
        XCTAssertEqual(rect.width, 1280, accuracy: 0.001)
        XCTAssertEqual(rect.height, 360, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 360, accuracy: 0.001)
    }

    func testAspectFitHandlesDegenerateSize() {
        let rect = FrameRaster.aspectFitRect(for: .zero)
        XCTAssertEqual(rect.width, CGFloat(kSimCamFrameWidth))
        XCTAssertEqual(rect.height, CGFloat(kSimCamFrameHeight))
    }

    func testRasterProducesCanonicalFrame() throws {
        let bytes = try XCTUnwrap(FrameRaster.render(background: CGColor(red: 0, green: 0, blue: 0, alpha: 1)) { _ in })
        XCTAssertEqual(bytes.count, kSimCamFrameWidth * kSimCamFrameHeight * kSimCamBytesPerPixel)
        let frame = FrameRaster.makeFrame(bytes: bytes, timestamp: 0)
        XCTAssertNil(frame.validationError())
        XCTAssertTrue(frame.isCanonicalSize)
    }

    func testQRRendererProducesValidFrame() throws {
        let bytes = try XCTUnwrap(QRRenderer.render(payload: "https://example.com"))
        let frame = FrameRaster.makeFrame(bytes: bytes, timestamp: 0)
        XCTAssertNil(frame.validationError())
        // White background: first pixel's blue/green/red channels all 0xFF.
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1], 0xFF)
        XCTAssertEqual(bytes[2], 0xFF)
    }

    func testQRRendererRejectsOversizedPayload() {
        // QR max capacity is ~2953 bytes at level M; Core Image returns nil above that.
        let huge = String(repeating: "x", count: 5000)
        XCTAssertNil(QRRenderer.render(payload: huge))
    }
}
