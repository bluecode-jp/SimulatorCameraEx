//
//  SimulatorInjection.swift
//  simcamctl
//
//  iOS Simulator side of SimulatorCamera. The Simulator has no capture stack,
//  so apps get their camera from SimCamInject.dylib (bundled in the app under
//  Contents/Resources/SimCamInject), which fakes AVFoundation in-process and
//  pulls frames from the running container app. These subcommands load it:
//
//    sim-enable   set DYLD_INSERT_LIBRARIES in the simulator's launchd, so
//                 every app launched afterwards (or only --app ones) has it
//    sim-disable  undo that (rebooting the simulator also clears it)
//    sim-status   show what is set and whether the Mac app is serving frames
//    sim-launch   launch one app with the dylib, leaving nothing behind
//
//  Everything here stays inside the chosen simulator; nothing on the Mac changes.
//

import Foundation

enum SimulatorInjection {

    /// Directory holding SimCamLoader.dylib / SimCamInject.dylib. SIMCAM_INJECT_DIR
    /// overrides it (e.g. a repo build); otherwise it sits next to our bundle.
    static func injectDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SIMCAM_INJECT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            // <App>.app/Contents/MacOS/simcamctl → <App>.app/Contents/Resources/SimCamInject
            exe.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/SimCamInject"),
            URL(fileURLWithPath: "/Applications/SimulatorCamera.app/Contents/Resources/SimCamInject"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SimCamLoader.dylib").path)
        }
    }

    static func loaderPath() -> String {
        guard let dir = injectDirectory() else {
            fail("SimCamLoader.dylib not found. Install SimulatorCamera.app in /Applications or set SIMCAM_INJECT_DIR.", code: 1)
        }
        return dir.appendingPathComponent("SimCamLoader.dylib").path
    }

    // MARK: - Subcommands

    static func run(_ subcommand: String, _ options: [String]) -> Never {
        var device = "booted"
        var apps: [String] = []
        var url: String?
        var all = false
        var positional: [String] = []
        var i = 0
        while i < options.count {
            let opt = options[i]
            func value() -> String {
                i += 1
                guard i < options.count else { fail("\(opt) needs a value", code: 3) }
                return options[i]
            }
            switch opt {
            case "--device": device = value()
            case "--app": apps.append(value())
            case "--url": url = value()
            case "--all": all = true
            default: positional.append(opt)
            }
            i += 1
        }

        switch subcommand {
        case "sim-enable":
            if all && !apps.isEmpty { fail("use either --all or --app, not both", code: 3) }
            let loader = loaderPath()
            launchctl(device, ["setenv", "DYLD_INSERT_LIBRARIES", loader])
            if apps.isEmpty {
                launchctl(device, ["unsetenv", "SIMCAM_APPS"])
            } else {
                launchctl(device, ["setenv", "SIMCAM_APPS", apps.joined(separator: ",")])
            }
            print("camera injection enabled on simulator \(device) for \(apps.isEmpty ? "all installed apps" : apps.joined(separator: ", "))")
            print("apps already running keep their old state: relaunch them to get the camera.")
            print("undo with `\(progName) sim-disable` (rebooting the simulator also clears it).")
            exit(0)

        case "sim-disable":
            launchctl(device, ["unsetenv", "DYLD_INSERT_LIBRARIES"])
            launchctl(device, ["unsetenv", "SIMCAM_APPS"])
            print("camera injection disabled on simulator \(device); relaunch apps to drop it.")
            exit(0)

        case "sim-status":
            let inserted = launchctlGet(device, "DYLD_INSERT_LIBRARIES")
            let targets = launchctlGet(device, "SIMCAM_APPS")
            let enabled = inserted?.contains("SimCamLoader.dylib") == true
            print("simulator:          \(device)")
            print("injection:          \(enabled ? "enabled (\(inserted!))" : "disabled")")
            if enabled { print("target apps:        \(targets.map { $0.isEmpty ? "all installed apps" : $0 } ?? "all installed apps")") }
            print("Mac app frame feed: \(feedReachable() ? "reachable on 127.0.0.1:\(kSimCamFeedPort)" : "not reachable — launch SimulatorCamera.app")")
            exit(0)

        case "sim-launch":
            guard let bundleID = positional.first else { fail("usage: \(progName) sim-launch BUNDLE_ID [--url URL] [--device UDID]", code: 3) }
            let loader = loaderPath()
            var env = ProcessInfo.processInfo.environment
            env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = loader
            simctl(["launch", "--terminate-running-process", device, bundleID], environment: env)
            if let url {
                Thread.sleep(forTimeInterval: 2)
                simctl(["openurl", device, url])
            }
            print("launched \(bundleID) with camera injection (this launch only).")
            exit(0)

        default:
            usage()
        }
    }

    // MARK: - Helpers

    private static func launchctl(_ device: String, _ arguments: [String]) {
        simctl(["spawn", device, "launchctl"] + arguments)
    }

    private static func launchctlGet(_ device: String, _ name: String) -> String? {
        let out = simctl(["spawn", device, "launchctl", "getenv", name], allowFailure: true)
        let trimmed = out?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    @discardableResult
    private static func simctl(_ arguments: [String], environment: [String: String]? = nil, allowFailure: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            fail("could not run xcrun simctl: \(error.localizedDescription)", code: 1)
        }
        process.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            if allowFailure { return nil }
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            fail("simctl \(arguments.joined(separator: " ")) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))", code: 1)
        }
        return output
    }

    private static func feedReachable() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = kSimCamFeedPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }
}
