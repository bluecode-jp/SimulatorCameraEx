//
//  AndroidEmulator.swift
//  Shared (container app + simcamctl)
//
//  Android Emulator side of SimulatorCamera. The emulator can use any Mac
//  camera as an Android camera ("webcamN"), and our CMIO extension is one of
//  them, so no injection is needed: launch the AVD with
//  `-camera-back webcamN` and Android apps see the active source.
//
//  N is the camera's position in the emulator's own list and shifts when
//  cameras come and go (USB cameras, Continuity Camera), so it is looked up
//  by name right before each launch instead of being stored.
//

import Foundation

public enum AndroidEmulator {

    public enum Failure: LocalizedError {
        case sdkNotFound
        case cameraNotFound
        case avdNotFound(String)
        case alreadyRunning(String)
        case exited(String)
        case configUnwritable(String)

        public var errorDescription: String? {
            switch self {
            case .sdkNotFound:
                return "Android SDK not found. Install the Android Emulator (Android Studio) or set ANDROID_HOME."
            case .cameraNotFound:
                return "The emulator does not list '\(kSimCamDeviceName)'. Activate the camera extension in SimulatorCameraEx first."
            case .avdNotFound(let avd):
                return "No Android virtual device named '\(avd)'."
            case .alreadyRunning(let avd):
                return "'\(avd)' is already running. Close it first; the camera is chosen when the emulator starts."
            case .exited(let log):
                return "The emulator quit right after starting:\n\(log)"
            case .configUnwritable(let reason):
                return "Could not update the AVD settings: \(reason)"
            }
        }
    }

    // MARK: - SDK

    /// ANDROID_HOME, ANDROID_SDK_ROOT, then Android Studio's default location.
    public static func sdkRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }
            + [NSHomeDirectory() + "/Library/Android/sdk"]
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("emulator/emulator").path) }
    }

    public static func emulatorPath() -> String? {
        sdkRoot()?.appendingPathComponent("emulator/emulator").path
    }

    // MARK: - Queries (each runs the emulator binary; call off the main thread)

    /// AVD names, as `emulator -list-avds` prints them.
    public static func listAVDs() throws -> [String] {
        guard let emulator = emulatorPath() else { throw Failure.sdkNotFound }
        return (run(emulator, ["-list-avds"]) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // Newer emulators print INFO/WARNING lines on stdout too.
            .filter { !$0.isEmpty && !$0.contains("|") }
    }

    /// Current "webcamN" label of the SimulatorCamera virtual camera.
    public static func webcamLabel() throws -> String {
        guard let emulator = emulatorPath() else { throw Failure.sdkNotFound }
        guard let label = webcamLabel(inWebcamList: run(emulator, ["-webcam-list"]) ?? "") else {
            throw Failure.cameraNotFound
        }
        return label
    }

    /// Parses `emulator -webcam-list` lines such as
    ///   Camera 'SimulatorCamera Virtual' can be specified by label as 'webcam3' or by id as '…'
    public static func webcamLabel(inWebcamList output: String, name: String = kSimCamDeviceName) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("'\(name)'") {
            if let range = line.range(of: #"'webcam\d+'"#, options: .regularExpression) {
                return String(line[range].dropFirst().dropLast())
            }
        }
        return nil
    }

    // MARK: - Launch

    /// Launch `avd` with the virtual camera as its back camera (and front
    /// camera too if `front`). The emulator runs in its own session so it
    /// outlives simcamctl and the terminal; its output goes to `logURL(avd)`.
    /// Returns the webcam label used. Throws if the emulator quits within a
    /// few seconds (typically: this AVD is already running).
    @discardableResult
    public static func launch(avd: String, front: Bool = false) throws -> String {
        guard let emulator = emulatorPath() else { throw Failure.sdkNotFound }
        guard try listAVDs().contains(avd) else { throw Failure.avdNotFound(avd) }
        let label = try webcamLabel()

        var arguments = ["-avd", avd, "-camera-back", label]
        if front { arguments += ["-camera-front", label] }

        let log = logURL(avd: avd)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pid = try spawnDetached(emulator, arguments, log: log)

        // A duplicate AVD or a bad option makes the emulator quit at once.
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                if text.contains("multiple emulators with the same AVD") { throw Failure.alreadyRunning(avd) }
                let tail = text.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
                throw Failure.exited(tail)
            }
        }
        // Reap it whenever it quits, so a long-running app leaves no zombie.
        DispatchQueue.global(qos: .background).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return label
    }

    public static func logURL(avd: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/SimulatorCamera/emulator-\(avd).log")
    }

    // MARK: - AVD default camera

    /// Point the AVD's `hw.camera.back` at the virtual camera, for launches
    /// from Android Studio's Device Manager. The label is only valid while
    /// the Mac's camera set stays the same. Returns the label written.
    @discardableResult
    public static func setDefaultCamera(avd: String) throws -> String {
        let label = try webcamLabel()
        guard let config = avdDirectory(avd)?.appendingPathComponent("config.ini") else {
            throw Failure.avdNotFound(avd)
        }
        guard let text = try? String(contentsOf: config, encoding: .utf8) else {
            throw Failure.configUnwritable("cannot read \(config.path)")
        }
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("hw.camera.back=") }) {
            lines[index] = "hw.camera.back=\(label)"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += ["hw.camera.back=\(label)", ""]
        }
        do {
            try lines.joined(separator: "\n").write(to: config, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.configUnwritable(error.localizedDescription)
        }
        return label
    }

    /// `<avd home>/<name>.ini` names the AVD's directory (it need not be
    /// `<name>.avd`: Android Studio keeps the old folder when renaming).
    static func avdDirectory(_ avd: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = env["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: env["ANDROID_USER_HOME"] ?? NSHomeDirectory() + "/.android")
                .appendingPathComponent("avd")
        let ini = home.appendingPathComponent("\(avd).ini")
        if let text = try? String(contentsOf: ini, encoding: .utf8),
           let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("path=") }) {
            return URL(fileURLWithPath: String(line.dropFirst("path=".count)))
        }
        let fallback = home.appendingPathComponent("\(avd).avd")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    // MARK: - Processes

    /// Run to completion; stdout on success.
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// posix_spawn in a new session (no SIGHUP when the terminal closes),
    /// stdout/stderr appended to `log`.
    private static func spawnDetached(_ path: String, _ arguments: [String], log: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard result == 0 else {
            throw Failure.exited(String(cString: strerror(result)))
        }
        return pid
    }
}
