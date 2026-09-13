//
//  XPCListener.swift
//  SimulatorCameraExtension
//
//  NSXPCListener inside the extension. Accepts connections from the container
//  app, exposes SimulatorCameraXPCProtocol. Each pushed frame is forwarded
//  into the active CMIOExtensionStream via the provider's frame-injection hook.
//
//  Frames are injected on the XPC delivery queue directly — no hop through
//  the main actor — so a busy UI thread in the extension can never stall
//  the camera. Only the diagnostic counters live on the main actor.
//

import Foundation
import CoreMedia
import CoreVideo
import os.log

@MainActor
final class XPCListener: NSObject, NSXPCListenerDelegate {

    static let shared = XPCListener()

    private let log = Logger(subsystem: "com.dautov.SimulatorCamera.Extension", category: "xpc")
    private let listener: NSXPCListener

    /// Connected container clients (the container app, plus simcamctl).
    private var clients: [NSXPCConnection] = []

    /// Hook the provider source registers so we can deliver pushed frames
    /// into the camera stream. Called on the XPC queue; returns whether the
    /// frame was accepted.
    nonisolated(unsafe) var onFrameReceived: ((SimCamFrame) -> Bool)?

    /// Hook the provider calls when source switches; lets the device-source
    /// know to stop generating its built-in test pattern when XPC takes over.
    nonisolated(unsafe) var onSourceSwitched: ((SimCamSourceKind) -> Void)?

    /// Provider state — exposed via getStatus.
    var currentSourceKind: SimCamSourceKind = .testPattern
    var lastFrameTimestamp: Double = 0
    var isStreamRunning: Bool = false
    var connectedClientCount: Int = 0

    private override init() {
        self.listener = NSXPCListener(machServiceName: SimCamMachService.name)
        super.init()
        self.listener.delegate = self
    }

    func start() {
        listener.resume()
        log.info("XPC listener started on \(SimCamMachService.name, privacy: .public)")
    }

    nonisolated func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Only accept peers signed by the same team as this extension. Without
        // this any local process could push frames into the virtual camera.
        // Unsigned dev builds carry no team and therefore no gate.
        if let requirement = SimCamCodeSigning.peerRequirement() {
            do {
                try newConnection.setCodeSigningRequirement(requirement)
            } catch {
                os_log(.error, "XPC: could not apply code-signing requirement: \(error.localizedDescription)")
                return false
            }
        }

        newConnection.exportedInterface = SimulatorCameraXPCInterface.make()
        newConnection.exportedObject = XPCExportedObject(listener: self)
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            Task { @MainActor [weak self] in
                self?.removeClient(newConnection)
            }
        }
        // An interruption means the peer died; the connection object is
        // finished for a listener, so treat it the same as invalidation.
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            Task { @MainActor [weak self] in
                self?.removeClient(newConnection)
            }
        }
        newConnection.resume()
        Task { @MainActor [weak self] in
            self?.clients.append(newConnection)
            self?.log.info("XPC client connected (total=\(self?.clients.count ?? 0))")
        }
        return true
    }

    private func removeClient(_ conn: NSXPCConnection) {
        clients.removeAll { $0 === conn }
        log.info("XPC client disconnected (remaining=\(self.clients.count))")
    }
}

/// Object that NSXPCConnection vends to clients. Wraps the listener-state
/// access so XPC's serialization stays simple.
@objc final class XPCExportedObject: NSObject, SimulatorCameraXPCProtocol {

    private weak var listener: XPCListener?

    init(listener: XPCListener) {
        self.listener = listener
        super.init()
    }

    func setSource(_ kindRaw: Int, withReply reply: @escaping (Bool) -> Void) {
        guard let kind = SimCamSourceKind(rawValue: kindRaw) else {
            reply(false)
            return
        }
        guard let listener else { reply(false); return }
        listener.onSourceSwitched?(kind)
        Task { @MainActor [weak listener] in
            listener?.currentSourceKind = kind
        }
        reply(true)
    }

    func pushFrame(_ frame: SimCamFrame, withReply reply: @escaping (Bool) -> Void) {
        guard let listener, let inject = listener.onFrameReceived else {
            reply(false)
            return
        }
        let accepted = inject(frame)
        if accepted {
            Task { @MainActor [weak listener] in
                listener?.lastFrameTimestamp = frame.timestampSeconds
            }
        }
        reply(accepted)
    }

    func getStatus(withReply reply: @escaping (SimCamStatus) -> Void) {
        Task { @MainActor [weak listener] in
            guard let listener else {
                reply(SimCamStatus(
                    activeSourceKind: .testPattern,
                    connectedClientCount: 0,
                    lastFrameTimestampSeconds: 0,
                    isStreamRunning: false
                ))
                return
            }
            reply(SimCamStatus(
                activeSourceKind: listener.currentSourceKind,
                connectedClientCount: listener.connectedClientCount,
                lastFrameTimestampSeconds: listener.lastFrameTimestamp,
                isStreamRunning: listener.isStreamRunning
            ))
        }
    }

    func ping(withReply reply: @escaping (Int32, String) -> Void) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        reply(pid, bundle)
    }
}
