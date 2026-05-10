//
//  ExtensionController.swift
//  SimulatorCamera
//
//  Owns the OSSystemExtensionRequest lifecycle. The container app loads
//  this on launch and exposes activation state to the UI. The user clicks
//  Activate, the system prompts them to allow in System Settings, then
//  the extension daemon starts and registers the virtual camera.
//

import Foundation
import Observation
import OSLog
import SystemExtensions

private let extensionBundleIdentifier = "com.dautov.SimulatorCamera.Extension"

@Observable
@MainActor
final class ExtensionController: NSObject {

    enum State: Equatable {
        case unknown
        case checking
        case inactive            // installed, not yet activated
        case activating          // OS request in flight
        case awaitingApproval    // user needs to click Allow in System Settings
        case active              // running, virtual camera available
        case deactivating
        case error(String)
    }

    private(set) var state: State = .unknown
    private(set) var lastMessage: String = ""

    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "extension")

    override init() {
        super.init()
        // No automatic check on init. The UI calls .check() once it's on screen
        // so we don't fire OS requests during SwiftUI's @State materialization.
    }

    func activate() {
        state = .activating
        // DIAGNOSTIC: dump what THIS process sees as Bundle.main + the extension
        // bundle the framework should match. Write to /tmp file so we can read
        // from terminal regardless of os_log filtering quirks.
        let mainURL = Bundle.main.bundleURL
        var diag = "=== Activation diagnostic ===\n"
        diag += "Bundle.main: \(mainURL.path)\n"
        let extDir = mainURL.appendingPathComponent("Contents/Library/SystemExtensions")
        diag += "Looking in: \(extDir.path)\n"
        diag += "Looking for identifier: \(extensionBundleIdentifier)\n"
        let exts = (try? FileManager.default.contentsOfDirectory(at: extDir, includingPropertiesForKeys: nil)) ?? []
        diag += "Extensions dir items: \(exts.count)\n"
        for url in exts {
            diag += "  - \(url.lastPathComponent)\n"
            if let b = Bundle(url: url) {
                diag += "    bundleId=\(b.bundleIdentifier ?? "<nil>")\n"
                diag += "    isLoaded=\(b.isLoaded)\n"
                diag += "    matches=\(b.bundleIdentifier == extensionBundleIdentifier)\n"
            } else {
                diag += "    Bundle(url:) returned nil!\n"
            }
        }
        diag += "=== end diagnostic ===\n"
        log.info("\(diag, privacy: .public)")
        // App is sandboxed → can't write to /tmp. Use NSTemporaryDirectory()
        // (per-container temp). Also dump to NSHomeDirectory()/Library/Logs/
        // which sandboxed apps can write.
        let containerTmp = NSTemporaryDirectory().appending("simcam-activate-diag.txt")
        let logsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/SimulatorCamera")
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        let logFile = (logsDir as NSString).appendingPathComponent("activate-diag.txt")
        try? diag.write(toFile: containerTmp, atomically: true, encoding: .utf8)
        try? diag.write(toFile: logFile, atomically: true, encoding: .utf8)
        lastMessage = "Diag at: \(containerTmp)\nAlso: \(logFile)"

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted activation request for \(extensionBundleIdentifier, privacy: .public)")
    }

    func deactivate() {
        state = .deactivating
        lastMessage = "Requesting deactivation..."
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted deactivation request")
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension ExtensionController: OSSystemExtensionRequestDelegate {

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Replace older with newer version automatically.
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .awaitingApproval
            self.lastMessage = "Open System Settings → Privacy & Security → click Allow for SimulatorCamera."
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.state = .active
                self.lastMessage = "Extension active. The virtual camera is now available in AVFoundation."
            case .willCompleteAfterReboot:
                self.state = .awaitingApproval
                self.lastMessage = "Activation queued. Reboot to finalize."
            @unknown default:
                self.state = .error("Unexpected activation result.")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .error(error.localizedDescription)
            self.lastMessage = "Activation failed: \(error.localizedDescription)"
            self.log.error("activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
