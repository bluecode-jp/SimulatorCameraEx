//
//  AndroidCommands.swift
//  simcamctl
//
//  Android Emulator subcommands (see Shared/AndroidEmulator.swift):
//
//    android-list                 AVDs + the virtual camera's webcam label
//    android-launch AVD [--front] start an AVD with the virtual camera
//    android-setup AVD            make it the AVD's default back camera
//
//  Frames come from whatever SimulatorCameraEx.app (or set-source) is showing.
//

import Foundation

enum AndroidCommands {

    static func run(_ subcommand: String, _ options: [String]) -> Never {
        do {
            switch subcommand {
            case "android-list":
                let avds = try AndroidEmulator.listAVDs()
                let camera = (try? AndroidEmulator.webcamLabel()) ?? "not found (activate the camera extension)"
                print("virtual camera: \(camera)")
                print(avds.isEmpty ? "no AVDs (create one in Android Studio's Device Manager)" : "AVDs:")
                avds.forEach { print("  \($0)") }

            case "android-launch":
                guard let avd = options.first(where: { !$0.hasPrefix("--") }) else {
                    fail("usage: simcamctl android-launch AVD [--front]", code: 3)
                }
                let label = try AndroidEmulator.launch(avd: avd, front: options.contains("--front"))
                print("launched \(avd) with \(kSimCamDeviceName) (\(label)) as its "
                      + (options.contains("--front") ? "back and front cameras" : "back camera"))
                print("log: \(AndroidEmulator.logURL(avd: avd).path)")

            case "android-setup":
                guard let avd = options.first else { fail("usage: simcamctl android-setup AVD", code: 3) }
                let label = try AndroidEmulator.setDefaultCamera(avd: avd)
                print("\(avd): hw.camera.back=\(label)")
                print("note: \(label) changes when Mac cameras are added or removed; run this again then,"
                      + " or use android-launch, which looks it up each time.")

            default:
                fail("unknown subcommand \(subcommand)", code: 3)
            }
        } catch {
            fail(error.localizedDescription, code: 1)
        }
        exit(0)
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }
}
