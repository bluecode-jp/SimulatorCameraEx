//
//  SimulatorAutoEnabler.swift
//  SimulatorCamera (container app)
//
//  While the app runs, watches for iOS Simulators that boot (or reboot) and
//  does what `simcamctl sim-enable` does for each: sets DYLD_INSERT_LIBRARIES
//  in that simulator's launchd so apps launched in it load SimCamInject.
//  The setting lives only inside the simulator and a reboot clears it, which
//  is exactly why this re-applies it on every boot.
//
//  Only newly booted devices are touched, so a manual `simcamctl sim-disable`
//  sticks until that simulator boots again. Requires the app to run outside
//  the App Sandbox (simctl talks to CoreSimulatorService).
//

import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class SimulatorAutoEnabler {

    static let defaultsKey = "autoEnableSimulators"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            isEnabled ? start() : stop()
        }
    }

    /// Names of booted simulators the camera was enabled in, for the UI.
    private(set) var enabledDevices: [String] = []
    private(set) var lastError: String?

    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCameraEx", category: "sim-auto-enable")
    private var task: Task<Void, Never>?
    private var handled: Set<String> = []

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func start() {
        guard isEnabled, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        handled = []
        enabledDevices = []
    }

    private func scan() async {
        guard let loader = Bundle.main.resourceURL?
            .appendingPathComponent("SimCamInject/SimCamLoader.dylib").path,
              FileManager.default.fileExists(atPath: loader) else {
            lastError = "SimCamLoader.dylib is missing from the app bundle"
            return
        }
        let alreadyHandled = handled
        let result = await Task.detached {
            Self.enableNewlyBooted(loader: loader, alreadyHandled: alreadyHandled)
        }.value

        // Forget devices that shut down so a reboot is handled again.
        handled = handled.intersection(result.booted.keys)
        handled.formUnion(result.newlyEnabled)
        enabledDevices = handled.compactMap { result.booted[$0] }.sorted()
        lastError = result.error
    }

    // MARK: - simctl (off the main actor)

    /// Enable injection in every booted simulator not handled yet.
    nonisolated private static func enableNewlyBooted(
        loader: String,
        alreadyHandled: Set<String>
    ) -> (booted: [String: String], newlyEnabled: [String], error: String?) {
        guard let booted = bootedDevices() else {
            return ([:], [], "could not list simulators (is Xcode installed?)")
        }
        var enabled: [String] = []
        var error: String?
        for (udid, name) in booted where !alreadyHandled.contains(udid) {
            if simctl(["spawn", udid, "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", loader]) != nil {
                enabled.append(udid)
                Logger(subsystem: "jp.co.bluecode.SimulatorCameraEx", category: "sim-auto-enable")
                    .info("camera injection enabled in \(name, privacy: .public) (\(udid, privacy: .public))")
            } else {
                error = "could not enable the camera in \(name)"
            }
        }
        return (booted, enabled, error)
    }

    /// UDID → "iPhone 16 Pro (iOS 18.5)" for booted devices.
    nonisolated private static func bootedDevices() -> [String: String]? {
        guard let json = simctl(["list", "devices", "booted", "-j"]),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return nil }
        var result: [String: String] = [:]
        for (runtime, devices) in runtimes {
            // com.apple.CoreSimulator.SimRuntime.iOS-18-5 → iOS 18.5
            let os = runtime.components(separatedBy: ".").last?
                .replacingOccurrences(of: "-", with: " ", options: [], range: nil) ?? runtime
            let osLabel = os.replacingOccurrences(of: #" (\d+) (\d+)$"#, with: " $1.$2", options: .regularExpression)
            for device in devices where device["state"] as? String == "Booted" {
                guard let udid = device["udid"] as? String else { continue }
                result[udid] = "\(device["name"] as? String ?? udid) (\(osLabel))"
            }
        }
        return result
    }

    nonisolated private static func simctl(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
