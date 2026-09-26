//
//  SimulatorLaunchRow.swift
//  SimulatorCamera
//
//  Boot an iOS Simulator device and bring up its window, from the iOS
//  Simulator card. Nothing camera-specific happens here: SimulatorAutoEnabler
//  loads the camera into a simulator once it has booted.
//

import AppKit
import SwiftUI

struct SimulatorLaunchRow: View {
    @AppStorage("iosSimulatorUDID") private var selectedUDID = ""
    @State private var devices: [SimulatorLauncher.Device] = []
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Device", selection: $selectedUDID) {
                    if devices.isEmpty { Text("No simulators").tag("") }
                    ForEach(devices) { device in
                        Text(device.label + (device.isBooted ? " — booted" : "")).tag(device.udid)
                    }
                }
                .fixedSize()
                .disabled(devices.isEmpty)
                Button("Refresh") { refresh() }
                    .controlSize(.small)
                    .disabled(isBusy)
                Spacer()
                Button("Launch") { launch() }
                    .disabled(isBusy || !devices.contains { $0.udid == selectedUDID })
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        isBusy = true
        Task {
            let list = await Task.detached { SimulatorLauncher.devices() }.value
            isBusy = false
            devices = list
            if !list.contains(where: { $0.udid == selectedUDID }) {
                selectedUDID = (list.first(where: \.isBooted) ?? list.first)?.udid ?? ""
            }
            if list.isEmpty { show("No iOS simulators found (xcrun simctl).", error: true) }
        }
    }

    private func launch() {
        guard let device = devices.first(where: { $0.udid == selectedUDID }) else { return }
        isBusy = true
        show("Starting \(device.label)…", error: false)
        Task {
            let error = await Task.detached { SimulatorLauncher.launch(device) }.value
            isBusy = false
            if let error {
                show(error, error: true)
            } else {
                show("\(device.label) is running. The camera is enabled once it has booted; then open your app.", error: false)
            }
            refresh()
        }
    }

    private func show(_ message: String, error: Bool) {
        status = message
        statusIsError = error
    }
}

enum SimulatorLauncher {

    struct Device: Identifiable, Sendable {
        let udid: String
        let label: String       // "iPhone 16 Pro (iOS 18.5)"
        let isBooted: Bool
        var id: String { udid }
    }

    /// Available iOS devices: newest runtime first, iPhones before iPads.
    static func devices() -> [Device] {
        guard let json = simctl(["list", "devices", "available", "-j"]).output,
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [(version: [Int], device: Device)] = []
        for (runtime, list) in runtimes {
            // com.apple.CoreSimulator.SimRuntime.iOS-18-5 → iOS 18.5, [18, 5]
            guard let tail = runtime.components(separatedBy: ".").last, tail.hasPrefix("iOS-") else { continue }
            let version = tail.dropFirst(4).split(separator: "-").compactMap { Int($0) }
            let os = "iOS " + version.map(String.init).joined(separator: ".")
            for device in list {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                result.append((version, Device(udid: udid, label: "\(name) (\(os))",
                                               isBooted: device["state"] as? String == "Booted")))
            }
        }
        return result
            .sorted { a, b in
                if a.version != b.version { return b.version.lexicographicallyPrecedes(a.version) }
                let aPhone = a.device.label.hasPrefix("iPhone"), bPhone = b.device.label.hasPrefix("iPhone")
                if aPhone != bPhone { return aPhone }
                return a.device.label.localizedStandardCompare(b.device.label) == .orderedAscending
            }
            .map(\.device)
    }

    /// Boot (unless already booted) and open the Simulator window. Nil on success.
    static func launch(_ device: Device) -> String? {
        if !device.isBooted {
            let boot = simctl(["boot", device.udid])
            // "Unable to boot device in current state: Booted" is fine.
            if boot.status != 0, !boot.error.contains("current state: Booted") {
                return "Could not boot \(device.label): \(boot.error.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        guard let app = simulatorApp() else {
            return "\(device.label) booted, but Simulator.app / DeviceHub.app was not found in Xcode."
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["-CurrentDeviceUDID", device.udid]   // honored by Simulator.app
        NSWorkspace.shared.openApplication(at: app, configuration: config)
        return nil
    }

    /// Simulator.app, or DeviceHub.app, which replaces it from Xcode 27.
    private static func simulatorApp() -> URL? {
        guard let developer = run("/usr/bin/xcode-select", ["-p"]).output?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // …/Xcode.app/Contents/Developer → …/Xcode.app/Contents/Applications
        let apps = URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent("Applications")
        return ["Simulator.app", "DeviceHub.app"]
            .map { apps.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func simctl(_ arguments: [String]) -> (status: Int32, output: String?, error: String) {
        run("/usr/bin/xcrun", ["simctl"] + arguments)
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String?, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, nil, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationStatus
        return (status, status == 0 ? String(decoding: data, as: UTF8.self) : nil, String(decoding: errData, as: UTF8.self))
    }
}
