//
//  XPCClient.swift
//  SimulatorCamera
//
//  Container-side XPC client. Connects to the extension's NSXPCListener
//  via the shared Mach service name, exposes a typed API to the rest of
//  the container app: setSource, pushFrame, getStatus, ping.
//
//  Connection is lazy: established on first call, reused, restored on
//  invalidation. Most calls are fire-and-forget; pushFrame is async to
//  avoid blocking the camera capture queue.
//

import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class XPCClient {

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var lastPingPid: Int32 = 0
    private(set) var lastPingBundle: String = ""

    private var connection: NSXPCConnection?
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "xpc-client")

    func connect() {
        guard connection == nil else { return }
        connectionState = .connecting

        let conn = NSXPCConnection(
            machServiceName: kSimCamMachServiceName,
            options: []
        )
        let interface = NSXPCInterface(with: SimulatorCameraXPCProtocol.self)
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
        conn.remoteObjectInterface = interface

        conn.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDisconnect(reason: "invalidated")
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDisconnect(reason: "interrupted")
            }
        }
        conn.resume()
        self.connection = conn

        // Smoke ping to confirm the listener picked up.
        ping()
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
        connectionState = .disconnected
    }

    private func handleDisconnect(reason: String) {
        log.info("xpc connection \(reason, privacy: .public)")
        connection = nil
        connectionState = .failed(reason)
    }

    private func proxy(
        errorHandler: @escaping (Error) -> Void = { _ in }
    ) -> SimulatorCameraXPCProtocol? {
        guard let conn = connection else { return nil }
        return conn.remoteObjectProxyWithErrorHandler { error in
            errorHandler(error)
        } as? SimulatorCameraXPCProtocol
    }

    // MARK: - Public API

    func ping() {
        proxy(errorHandler: { [weak self] err in
            Task { @MainActor [weak self] in
                self?.connectionState = .failed("ping failed: \(err.localizedDescription)")
            }
        })?.ping { [weak self] pid, bundle in
            Task { @MainActor [weak self] in
                self?.lastPingPid = pid
                self?.lastPingBundle = bundle
                self?.connectionState = .connected
            }
        }
    }

    func setSource(_ kind: SimCamSourceKind, completion: @escaping (Bool) -> Void = { _ in }) {
        proxy(errorHandler: { _ in completion(false) })?
            .setSource(kind.rawValue, withReply: { ok in
                Task { @MainActor in completion(ok) }
            })
    }

    /// Fire-and-forget frame push. Capture-queue callers can use this without blocking.
    func pushFrame(_ frame: SimCamFrame) {
        proxy(errorHandler: { [weak self] err in
            self?.log.error("pushFrame failed: \(err.localizedDescription, privacy: .public)")
        })?.pushFrame(frame, withReply: { _ in })
    }

    func getStatus(completion: @escaping (SimCamStatus?) -> Void) {
        proxy(errorHandler: { _ in
            Task { @MainActor in completion(nil) }
        })?.getStatus(withReply: { status in
            Task { @MainActor in completion(status) }
        })
    }
}
