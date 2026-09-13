//
//  XPCClient.swift
//  SimulatorCamera
//
//  Container-side XPC client. Connects to the extension's NSXPCListener
//  via the shared Mach service name, exposes a typed API to the rest of
//  the container app: setSource, pushFrame, getStatus, ping.
//
//  Lifecycle:
//    - connect() is idempotent and lazy.
//    - An *interruption* (extension crashed / restarted) keeps the
//      NSXPCConnection: the next message re-launches the peer. We re-ping
//      after a short delay so the UI recovers on its own.
//    - An *invalidation* (service unavailable, peer refused us) drops the
//      connection and retries with capped exponential backoff until
//      disconnect() is called.
//
//  pushFrame is nonisolated and safe from any thread: the capture / decode
//  queues call it directly. Frames are dropped, not queued, when the
//  extension falls behind, so memory can't balloon behind a slow peer.
//

import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class XPCClient {

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var lastPingPid: Int32 = 0
    private(set) var lastPingBundle: String = ""
    /// Frames dropped because too many were already in flight.
    private(set) var framesDropped: Int = 0
    /// Frames the extension refused (not streaming, malformed).
    private(set) var framesRejected: Int = 0

    /// Upper bound on un-acknowledged pushFrame calls. At 30 fps two frames
    /// is ~66 ms of slack — enough to ride out scheduler hiccups, small
    /// enough that a stalled extension never accumulates hundreds of MB.
    static let maxInFlightFrames = 2

    private let box = ConnectionBox()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var wantsConnection = false
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "xpc-client")

    // MARK: - Connection lifecycle

    func connect() {
        wantsConnection = true
        guard box.connection == nil else { return }
        connectionState = .connecting

        let conn = NSXPCConnection(machServiceName: SimCamMachService.name, options: [])
        conn.remoteObjectInterface = SimulatorCameraXPCInterface.make()
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.handleInvalidation() }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.handleInterruption() }
        }
        conn.resume()
        box.connection = conn
        log.info("connecting to \(SimCamMachService.name, privacy: .public)")

        // Smoke ping to confirm the listener picked up.
        ping()
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        box.connection?.invalidate()
        box.connection = nil
        connectionState = .disconnected
    }

    private func handleInterruption() {
        log.info("xpc connection interrupted; will re-ping")
        connectionState = .failed("interrupted")
        scheduleRetry { [weak self] in self?.ping() }
    }

    private func handleInvalidation() {
        log.info("xpc connection invalidated")
        box.connection = nil
        box.resetInFlight()
        connectionState = .failed("invalidated")
        scheduleRetry { [weak self] in self?.connect() }
    }

    private func scheduleRetry(_ action: @escaping @MainActor () -> Void) {
        guard wantsConnection else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 10.0)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self?.wantsConnection == true else { return }
            action()
        }
    }

    private func proxy(
        errorHandler: @escaping @Sendable (Error) -> Void = { _ in }
    ) -> SimulatorCameraXPCProtocol? {
        box.proxy(errorHandler: errorHandler)
    }

    // MARK: - Public API

    func ping(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let p = proxy(errorHandler: { [weak self] err in
            Task { @MainActor [weak self] in
                self?.connectionState = .failed("ping failed: \(err.localizedDescription)")
                completion?(false)
            }
        }) else {
            completion?(false)
            return
        }
        p.ping { [weak self] pid, bundle in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastPingPid = pid
                self.lastPingBundle = bundle
                self.connectionState = .connected
                self.reconnectAttempt = 0
                completion?(true)
            }
        }
    }

    func setSource(_ kind: SimCamSourceKind, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let p = proxy(errorHandler: { _ in
            Task { @MainActor in completion(false) }
        }) else {
            completion(false)
            return
        }
        p.setSource(kind.rawValue, withReply: { ok in
            Task { @MainActor in completion(ok) }
        })
    }

    /// Fire-and-forget frame push. Safe from any thread; drops the frame
    /// when the extension already has `maxInFlightFrames` outstanding.
    nonisolated func pushFrame(_ frame: SimCamFrame) {
        guard box.tryAcquireInFlight(limit: Self.maxInFlightFrames) else {
            Task { @MainActor [weak self] in self?.framesDropped += 1 }
            return
        }
        guard let p = box.proxy(errorHandler: { [box, weak self] err in
            box.releaseInFlight()
            Task { @MainActor [weak self] in
                self?.log.error("pushFrame failed: \(err.localizedDescription, privacy: .public)")
            }
        }) else {
            box.releaseInFlight()
            return
        }
        p.pushFrame(frame, withReply: { [box, weak self] accepted in
            box.releaseInFlight()
            if !accepted {
                Task { @MainActor [weak self] in self?.framesRejected += 1 }
            }
        })
    }

    func getStatus(completion: @escaping @MainActor (SimCamStatus?) -> Void) {
        guard let p = proxy(errorHandler: { _ in
            Task { @MainActor in completion(nil) }
        }) else {
            completion(nil)
            return
        }
        p.getStatus(withReply: { status in
            Task { @MainActor in completion(status) }
        })
    }

    func resetCounters() {
        framesDropped = 0
        framesRejected = 0
    }
}

/// Lock-protected holder so the connection can be used off the main actor.
/// NSXPCConnection itself is thread-safe; the lock only guards our pointer
/// and the in-flight counter.
private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _connection: NSXPCConnection?
    private var _inFlight = 0

    var connection: NSXPCConnection? {
        get { lock.lock(); defer { lock.unlock() }; return _connection }
        set { lock.lock(); _connection = newValue; lock.unlock() }
    }

    func proxy(errorHandler: @escaping @Sendable (Error) -> Void) -> SimulatorCameraXPCProtocol? {
        guard let conn = connection else { return nil }
        return conn.remoteObjectProxyWithErrorHandler(errorHandler) as? SimulatorCameraXPCProtocol
    }

    func tryAcquireInFlight(limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _inFlight < limit else { return false }
        _inFlight += 1
        return true
    }

    func releaseInFlight() {
        lock.lock()
        _inFlight = max(0, _inFlight - 1)
        lock.unlock()
    }

    func resetInFlight() {
        lock.lock()
        _inFlight = 0
        lock.unlock()
    }
}
