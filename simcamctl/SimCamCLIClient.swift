//
//  SimCamCLIClient.swift
//  simcamctl
//
//  Synchronous XPC wrapper for the CLI. Each method opens a connection,
//  fires a request, blocks on a semaphore for the reply (with a timeout,
//  so a wedged extension never hangs a shell script), prints the result,
//  exits with the right code.
//

import Foundation
import AppKit
import CoreVideo

final class SimCamCLIClient {

    /// How long any single XPC round-trip may take before we give up.
    private let replyTimeout: DispatchTimeInterval = .seconds(5)

    private func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: SimCamMachService.name, options: [])
        conn.remoteObjectInterface = SimulatorCameraXPCInterface.make()
        conn.invalidationHandler = {
            FileHandle.standardError.write(Data(
                "error: XPC connection to \(SimCamMachService.name) invalidated. Is the SimulatorCamera extension activated?\n".utf8
            ))
            exit(2)
        }
        conn.resume()
        return conn
    }

    private func proxy(_ conn: NSXPCConnection) -> SimulatorCameraXPCProtocol {
        guard let p = conn.remoteObjectProxyWithErrorHandler({ error in
            FileHandle.standardError.write(Data("error: XPC error — \(error.localizedDescription)\n".utf8))
            exit(2)
        }) as? SimulatorCameraXPCProtocol else {
            fail("could not create XPC proxy", code: 2)
        }
        return p
    }

    /// Block until `sem` is signalled or the reply timeout elapses.
    private func waitForReply(_ sem: DispatchSemaphore, _ what: String) {
        if sem.wait(timeout: .now() + replyTimeout) == .timedOut {
            fail("\(what) timed out after 5s", code: 2)
        }
    }

    // MARK: - Subcommands

    func runPing() {
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        proxy(conn).ping { pid, bundle in
            print("extension pid=\(pid) bundle=\(bundle)")
            sem.signal()
        }
        waitForReply(sem, "ping")
        conn.invalidate()
        exit(0)
    }

    func runStatus() {
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        proxy(conn).getStatus { status in
            print("active source:     \(status.activeSourceKind.label)")
            print("connected clients: \(status.connectedClientCount)")
            print("last frame ts:     \(String(format: "%.3f", status.lastFrameTimestampSeconds))s")
            print("stream running:    \(status.isStreamRunning ? "yes" : "no")")
            sem.signal()
        }
        waitForReply(sem, "status")
        conn.invalidate()
        exit(0)
    }

    func runSetSource(_ kind: SimCamSourceKind) {
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        proxy(conn).setSource(kind.rawValue) { ok in
            if ok {
                print("source switched to \(kind.label)")
            } else {
                self.fail("setSource returned false", code: 1)
            }
            sem.signal()
        }
        waitForReply(sem, "set-source")
        conn.invalidate()
        exit(0)
    }

    func runSetQR(payload: String) {
        guard !payload.isEmpty else { fail("empty QR payload", code: 3) }
        guard let bytes = QRRenderer.render(payload: payload) else {
            fail("could not render a QR code for that payload (too long?)", code: 1)
        }
        let frame = FrameRaster.makeFrame(bytes: bytes, timestamp: Date().timeIntervalSince1970)
        pushSingleFrame(frame, kind: .qrCode) {
            "QR pushed (\(payload.count) chars, \(frame.bgraData.count / 1024) KB)"
        }
    }

    func runSetImage(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such file '\(url.path)'", code: 3)
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bytes = FrameRaster.render(image: cgImage, background: CGColor(red: 0, green: 0, blue: 0, alpha: 1)) else {
            fail("could not load image", code: 1)
        }
        let frame = FrameRaster.makeFrame(bytes: bytes, timestamp: Date().timeIntervalSince1970)
        pushSingleFrame(frame, kind: .image) {
            "image pushed: \(url.lastPathComponent) (\(frame.width)x\(frame.height))"
        }
    }

    // MARK: - Helpers

    /// Switch the extension to `kind` and push one frame. The extension
    /// holds the frame until either the source switches again or another
    /// push comes in. For a continuously-rendered stream, run the
    /// container app instead.
    private func pushSingleFrame(_ frame: SimCamFrame, kind: SimCamSourceKind, success: @escaping () -> String) {
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        let p = proxy(conn)
        p.setSource(kind.rawValue) { switched in
            guard switched else {
                self.fail("setSource returned false", code: 1)
            }
            p.pushFrame(frame) { ok in
                if ok {
                    print(success())
                } else {
                    self.fail("pushFrame returned false — is a camera client (e.g. the Simulator) streaming from the virtual camera?", code: 1)
                }
                sem.signal()
            }
        }
        waitForReply(sem, "push")
        conn.invalidate()
        exit(0)
    }
}
