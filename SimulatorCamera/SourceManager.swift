//
//  SourceManager.swift
//  SimulatorCamera
//
//  Owns the active FrameSource. UI calls switchTo(.macCamera, ...) etc.
//  Manager: stops the old source, starts the new one, pipes frames to
//  XPCClient.pushFrame, tells the extension via setSource.
//
//  Switches are serialized by a generation counter: if the user clicks
//  twice while a camera is still warming up, the first start is discarded
//  when it finally completes instead of leaking a running source.
//

import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class SourceManager {

    enum SwitchError: LocalizedError {
        case noFileSelected
        case noPayloadProvided
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFileSelected: return "Pick a file first."
            case .noPayloadProvided: return "Type a QR payload first."
            case .startFailed(let m): return m
            }
        }
    }

    private(set) var activeKind: SimCamSourceKind = .testPattern
    private(set) var isSwitching = false
    private(set) var lastError: String?
    private(set) var framesPushed: Int = 0
    private(set) var lastFrameTimestamp: Double = 0

    /// User input fields the UI binds to.
    var selectedFileURL: URL?
    var selectedImageURL: URL?
    var qrPayload: String = "https://github.com/dautovri/SimulatorCamera"

    private var activeSource: FrameSource?
    private var switchGeneration = 0
    private let xpc: XPCClient
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "source-manager")

    init(xpc: XPCClient) {
        self.xpc = xpc
    }

    /// Switch to the given source kind. Throws on user-correctable issues
    /// (no file selected, no QR payload) and on start failures. Returns
    /// once the new source is running; it keeps running until stop() or
    /// another switch.
    func switchTo(_ kind: SimCamSourceKind) async throws {
        switchGeneration += 1
        let generation = switchGeneration

        // Stop whatever's running.
        tearDownActiveSource()
        lastError = nil

        // testPattern needs no container-side source.
        if kind == .testPattern {
            xpc.setSource(.testPattern)
            activeKind = .testPattern
            return
        }

        // Build the new source.
        let source: FrameSource
        switch kind {
        case .testPattern:
            return
        case .macCamera:
            source = MacCameraSource()
        case .videoFile:
            guard let url = selectedFileURL else { throw SwitchError.noFileSelected }
            source = VideoFileSource(url: url)
        case .image:
            guard let url = selectedImageURL else { throw SwitchError.noFileSelected }
            source = ImageSource(url: url)
        case .qrCode:
            let payload = qrPayload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { throw SwitchError.noPayloadProvided }
            source = QRSource(payload: payload)
        }

        // Frames go straight to XPC from the producer's thread; only the
        // counters hop to the main actor.
        let xpc = self.xpc
        source.onFrame = { [weak self] frame in
            xpc.pushFrame(frame)
            Task { @MainActor [weak self] in
                guard let self, self.switchGeneration == generation else { return }
                self.framesPushed += 1
                self.lastFrameTimestamp = frame.timestampSeconds
            }
        }

        isSwitching = true
        defer { if switchGeneration == generation { isSwitching = false } }

        do {
            try await source.start()
        } catch {
            // A newer switch may already own the UI; only report if we're current.
            if switchGeneration == generation {
                lastError = error.localizedDescription
                xpc.setSource(.testPattern)
                activeKind = .testPattern
            }
            throw SwitchError.startFailed(error.localizedDescription)
        }

        // Lost the race to a newer switch while starting: discard quietly.
        guard switchGeneration == generation else {
            source.stop()
            return
        }

        activeSource = source
        activeKind = kind
        framesPushed = 0
        xpc.resetCounters()
        // Tell the extension only once frames are actually flowing, so the
        // test pattern keeps running during a slow camera warm-up instead
        // of freezing the virtual camera.
        xpc.setSource(kind)
        log.info("source switched to \(kind.label, privacy: .public)")
    }

    func stop() {
        switchGeneration += 1
        tearDownActiveSource()
        xpc.setSource(.testPattern)
        activeKind = .testPattern
        isSwitching = false
    }

    private func tearDownActiveSource() {
        activeSource?.onFrame = nil
        activeSource?.stop()
        activeSource = nil
        framesPushed = 0
    }
}
