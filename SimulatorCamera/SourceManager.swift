//
//  SourceManager.swift
//  SimulatorCamera
//
//  Owns the active FrameSource. UI calls switchTo(.macCamera, ...) etc.
//  Manager: stops the old source, starts the new one, pipes frames to
//  CameraLink.pushFrame, tells the extension which source is live.
//
//  Switches are serialized by a generation counter: if the user clicks
//  twice while a camera is still warming up, the first start is discarded
//  when it finally completes instead of leaking a running source.
//

import Foundation
import CoreVideo
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
            case .noPayloadProvided: return "Type a payload first."
            case .startFailed(let m): return m
            }
        }
    }

    private(set) var activeKind: SimCamSourceKind = .testPattern
    private(set) var isSwitching = false
    private(set) var lastError: String?
    private(set) var framesPushed: Int = 0

    /// User input fields the UI binds to.
    var selectedFileURL: URL?
    var selectedImageURL: URL?
    var qrPayload: String = "https://www.bluecode.co.jp"
    /// uniqueID of the Mac camera to use; nil = automatic (built-in first).
    /// Remembered across launches.
    var selectedCameraID: String? = UserDefaults.standard.string(forKey: "selectedCameraID") {
        didSet { UserDefaults.standard.set(selectedCameraID, forKey: "selectedCameraID") }
    }
    /// Camera the running Mac Camera source was started with, so a picker
    /// change that simcamctl already applied does not restart it again.
    private(set) var activeCameraID: String?
    var code128Payload: String = "123456789"
    /// 1–12 digits get zero-padded and a check digit; see BarcodeRenderer.ean13.
    var ean13Payload: String = "1234567890128"

    private var activeSource: FrameSource?
    private var switchGeneration = 0
    private let link: CameraLink
    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCameraEx", category: "source-manager")

    init(link: CameraLink) {
        self.link = link
        // A sink that failed to open (extension still starting) and later
        // recovers leaves a stale "Extension not reachable" message behind.
        link.onSinkRecovered = { [weak self] in self?.lastError = nil }
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
            declare(.testPattern)
            return
        }

        // Build the new source.
        let source: FrameSource
        switch kind {
        case .testPattern:
            return
        case .macCamera:
            activeCameraID = selectedCameraID
            source = MacCameraSource(deviceID: selectedCameraID)
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
        case .code128:
            let payload = code128Payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { throw SwitchError.noPayloadProvided }
            source = BarcodeSource(payload: payload, symbology: .code128)
        case .ean13:
            let payload = ean13Payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { throw SwitchError.noPayloadProvided }
            source = BarcodeSource(payload: payload, symbology: .ean13)
        }

        isSwitching = true
        defer { if switchGeneration == generation { isSwitching = false } }

        // The sink needs camera access (TCC gates CMIO device streams).
        guard await link.requestCameraAccessIfNeeded() else {
            lastError = FrameSourceError.permissionDenied.localizedDescription
            throw SwitchError.startFailed(lastError ?? "camera access denied")
        }

        // Open the sink before the producer starts so its first frames have
        // somewhere to go. The extension keeps showing the test pattern
        // until we declare the new kind below.
        // The extension is optional now: frames also reach iOS Simulator apps
        // through SimulatorFeed, so a missing extension is only a warning.
        do {
            try link.openSink()
        } catch {
            log.warning("sink unavailable, feeding simulator only: \(error.localizedDescription, privacy: .public)")
        }

        // Frames go straight to the sink from the producer's thread; only
        // the counter hops to the main actor, and only every few frames.
        let link = self.link
        var localCount = 0
        let feed = SimulatorFeed.shared
        source.onFeedFrame = { frame in feed.publish(frame) }
        source.onFrame = { [weak self] frame in
            link.pushFrame(frame)
            localCount += 1
            if localCount % 10 == 0 {
                let count = localCount
                Task { @MainActor [weak self] in
                    guard let self, self.switchGeneration == generation else { return }
                    self.framesPushed = count
                }
            }
        }

        do {
            try await source.start()
        } catch {
            // A newer switch may already own the UI; only report if we're current.
            if switchGeneration == generation {
                lastError = error.localizedDescription
                declare(.testPattern)
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
        // Tell the extension only once frames are actually flowing, so the
        // test pattern keeps running during a slow camera warm-up instead
        // of freezing the virtual camera.
        declare(kind)
        log.info("source switched to \(kind.label, privacy: .public)")
    }

    func stop() {
        switchGeneration += 1
        tearDownActiveSource()
        declare(.testPattern)
        isSwitching = false
    }

    /// Tell the extension which source is live; failures are surfaced in
    /// the UI but do not stop the local source (the link retries on its own).
    private func declare(_ kind: SimCamSourceKind) {
        activeKind = kind
        do {
            try link.setSource(kind)
        } catch {
            lastError = "Extension not reachable: \(error.localizedDescription)"
            log.error("setSource failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func tearDownActiveSource() {
        activeSource?.onFrame = nil
        activeSource?.onFeedFrame = nil
        activeSource?.stop()
        activeSource = nil
        framesPushed = 0
        SimulatorFeed.shared.reset()
    }
}
