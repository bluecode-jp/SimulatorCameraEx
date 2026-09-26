//
//  AndroidEmulatorTests.swift
//  Finding the virtual camera in `emulator -webcam-list` output.
//

import XCTest

final class AndroidEmulatorTests: XCTestCase {

    // Captured from Android Emulator 37.1 with five cameras attached.
    private let webcamList = """
    List of web cameras connected to the computer:
     Camera 'USB 2.0 Camera' can be specified by label as 'webcam0' or by id as '0x1110000041102da' and will use pixel format 'NV12'
     Camera 'Studio Displayのカメラ' can be specified by label as 'webcam1' or by id as '0x2014000015bc0000' and will use pixel format 'NV12'
     Camera 'SimulatorCamera Virtual' can be specified by label as 'webcam3' or by id as '6F58C7E7-5C3A-4A0E-9F7E-9F0E3D8F1A0B' and will use pixel format 'BGR4'
     Camera 'iPhoneのカメラ' can be specified by label as 'webcam4' or by id as 'EBD56F50-12C1-4701-88E7-9E5200000001' and will use pixel format 'NV12'
    """

    func testFindsVirtualCamera() {
        XCTAssertEqual(AndroidEmulator.webcamLabel(inWebcamList: webcamList), "webcam3")
    }

    func testMissingCamera() {
        XCTAssertNil(AndroidEmulator.webcamLabel(inWebcamList: "List of web cameras connected to the computer:\n"))
        XCTAssertNil(AndroidEmulator.webcamLabel(inWebcamList: webcamList, name: "SimulatorCamera"),
                     "matches the whole quoted name, not a prefix")
    }
}
