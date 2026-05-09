//
//  XPCListener.swift
//  SimulatorCameraExtension
//
//  NSXPCListener inside the extension. Accepts connections from the container
//  app, exposes SimulatorCameraXPCProtocol. Each pushed frame is forwarded
//  into the active CMIOExtensionStream via the provider's frame-injection hook.
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
    /// into the camera stream.
    var onFrameReceived: ((SimCamFrame) -> Void)?

    /// Provider state — exposed via getStatus.
    var currentSourceKind: SimCamSourceKind = .testPattern
    var lastFrameTimestamp: Double = 0
    var isStreamRunning: Bool = false

    /// Hook the provider calls when source switches; lets the device-source
    /// know to stop generating its built-in test pattern when XPC takes over.
    var onSourceSwitched: ((SimCamSourceKind) -> Void)?

    private override init() {
        self.listener = NSXPCListener(machServiceName: kSimCamMachServiceName)
        super.init()
        self.listener.delegate = self
    }

    func start() {
        listener.resume()
        log.info("XPC listener started on \(kSimCamMachServiceName, privacy: .public)")
    }

    nonisolated func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let interface = NSXPCInterface(with: SimulatorCameraXPCProtocol.self)
        // Register the SimCamFrame + SimCamStatus secure-coding classes so the
        // XPC machinery decodes them from the wire. NSSet → Set<AnyHashable>
        // bridge is the only Swift-clean way to express this with class metadata.
        let frameClasses = NSSet(array: [SimCamFrame.self, NSData.self]) as! Set<AnyHashable>
        let statusClasses = NSSet(array: [SimCamStatus.self]) as! Set<AnyHashable>
        interface.setClasses(
            frameClasses,
            for: #selector(SimulatorCameraXPCProtocol.pushFrame(_:withReply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            statusClasses,
            for: #selector(SimulatorCameraXPCProtocol.getStatus(withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        newConnection.exportedInterface = interface
        let exported = XPCExportedObject(listener: self)
        newConnection.exportedObject = exported
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.removeClient(newConnection)
            }
        }
        newConnection.interruptionHandler = { [weak self] in
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
        let kind = SimCamSourceKind(rawValue: kindRaw) ?? .testPattern
        Task { @MainActor [weak listener] in
            guard let listener else { reply(false); return }
            listener.currentSourceKind = kind
            listener.onSourceSwitched?(kind)
            reply(true)
        }
    }

    func pushFrame(_ frame: SimCamFrame, withReply reply: @escaping (Bool) -> Void) {
        Task { @MainActor [weak listener] in
            guard let listener else { reply(false); return }
            listener.lastFrameTimestamp = frame.timestampSeconds
            listener.onFrameReceived?(frame)
            reply(true)
        }
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
                connectedClientCount: 0,  // populated by streamSource client list
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
