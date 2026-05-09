//
//  SimCamCLIClient.swift
//  simcamctl
//
//  Synchronous XPC wrapper for the CLI. Each method opens a connection,
//  fires a request, blocks on a semaphore for the reply, prints the result,
//  exits with the right code.
//

import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

final class SimCamCLIClient {

    private func makeConnection() -> NSXPCConnection {
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
        conn.invalidationHandler = {
            FileHandle.standardError.write(Data("error: XPC connection invalidated. Is the SimulatorCamera extension activated?\n".utf8))
            exit(2)
        }
        conn.resume()
        return conn
    }

    private func proxy(_ conn: NSXPCConnection) -> SimulatorCameraXPCProtocol {
        return conn.remoteObjectProxyWithErrorHandler { error in
            FileHandle.standardError.write(Data("error: XPC error — \(error.localizedDescription)\n".utf8))
            exit(2)
        } as! SimulatorCameraXPCProtocol
    }

    // MARK: - Subcommands

    func runPing() {
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        proxy(conn).ping { pid, bundle in
            print("extension pid=\(pid) bundle=\(bundle)")
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            FileHandle.standardError.write(Data("error: ping timed out\n".utf8))
            exit(2)
        }
        conn.invalidate()
        exit(0)
    }

    func runStatus() {
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        proxy(conn).getStatus { status in
            print("active source:    \(self.sourceLabel(status.activeSourceKind))")
            print("connected clients:\(status.connectedClientCount)")
            print("last frame ts:    \(String(format: "%.3f", status.lastFrameTimestampSeconds))s")
            print("stream running:   \(status.isStreamRunning ? "yes" : "no")")
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            FileHandle.standardError.write(Data("error: status timed out\n".utf8))
            exit(2)
        }
        conn.invalidate()
        exit(0)
    }

    func runSetSource(_ kind: SimCamSourceKind) {
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        proxy(conn).setSource(kind.rawValue) { ok in
            if ok {
                print("source switched to \(self.sourceLabel(kind))")
            } else {
                FileHandle.standardError.write(Data("error: setSource returned false\n".utf8))
                exit(1)
            }
            sem.signal()
        }
        sem.wait()
        conn.invalidate()
        exit(0)
    }

    func runSetQR(payload: String) {
        guard !payload.isEmpty else {
            FileHandle.standardError.write(Data("error: empty QR payload\n".utf8))
            exit(3)
        }

        let frame = renderQRFrame(payload: payload)
        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        let p = proxy(conn)
        p.setSource(SimCamSourceKind.qrCode.rawValue) { _ in
            // CLI pushes a single frame; the extension will hold it until
            // either source switches again or another push comes in. For a
            // continuously-rendered QR (so the iOS Simulator sees a stream),
            // run the container app instead.
            p.pushFrame(frame) { ok in
                if ok {
                    print("QR pushed (\(payload.count) chars, \(frame.bgraData.count / 1024) KB)")
                } else {
                    FileHandle.standardError.write(Data("error: pushFrame returned false\n".utf8))
                    exit(1)
                }
                sem.signal()
            }
        }
        sem.wait()
        conn.invalidate()
        exit(0)
    }

    func runSetImage(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("error: no such file '\(url.path)'\n".utf8))
            exit(3)
        }

        guard let frame = renderImageFrame(url: url) else {
            FileHandle.standardError.write(Data("error: could not load image\n".utf8))
            exit(1)
        }

        let conn = makeConnection()
        let sem = DispatchSemaphore(value: 0)
        let p = proxy(conn)
        p.setSource(SimCamSourceKind.image.rawValue) { _ in
            p.pushFrame(frame) { ok in
                if ok {
                    print("image pushed: \(url.lastPathComponent) (\(frame.width)x\(frame.height))")
                } else {
                    FileHandle.standardError.write(Data("error: pushFrame returned false\n".utf8))
                    exit(1)
                }
                sem.signal()
            }
        }
        sem.wait()
        conn.invalidate()
        exit(0)
    }

    // MARK: - Helpers

    private func sourceLabel(_ kind: SimCamSourceKind) -> String {
        switch kind {
        case .testPattern: return "test pattern"
        case .macCamera: return "mac camera"
        case .videoFile: return "video file"
        case .image: return "static image"
        case .qrCode: return "QR code"
        }
    }

    private func renderQRFrame(payload: String) -> SimCamFrame {
        let qrFilter = CIFilter.qrCodeGenerator()
        qrFilter.message = Data(payload.utf8)
        qrFilter.correctionLevel = "M"
        let baseQR = qrFilter.outputImage!
        let qrSize: CGFloat = 600
        let scaledQR = baseQR.transformed(by: CGAffineTransform(
            scaleX: qrSize / baseQR.extent.width,
            y: qrSize / baseQR.extent.height
        ))
        let context = CIContext(options: [.cacheIntermediates: false])
        let width = 1280, height = 720
        let rowBytes = width * 4
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let cg = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        )!
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let qrRect = CGRect(
            x: (CGFloat(width) - qrSize) / 2,
            y: (CGFloat(height) - qrSize) / 2,
            width: qrSize, height: qrSize
        )
        if let qrCG = context.createCGImage(scaledQR, from: scaledQR.extent) {
            cg.draw(qrCG, in: qrRect)
        }
        let data = Data(bytes: cg.data!, count: rowBytes * height)
        return SimCamFrame(
            width: width, height: height,
            bytesPerRow: rowBytes,
            timestampSeconds: Date().timeIntervalSince1970,
            bgraData: data
        )
    }

    private func renderImageFrame(url: URL) -> SimCamFrame? {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = 1280, height = 720
        let rowBytes = width * 4
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        ) else { return nil }
        let scale = min(Double(width) / Double(cgImage.width), Double(height) / Double(cgImage.height))
        let drawW = Double(cgImage.width) * scale
        let drawH = Double(cgImage.height) * scale
        let drawX = (Double(width) - drawW) / 2
        let drawY = (Double(height) - drawH) / 2
        cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        let data = Data(bytes: cg.data!, count: rowBytes * height)
        return SimCamFrame(
            width: width, height: height,
            bytesPerRow: rowBytes,
            timestampSeconds: Date().timeIntervalSince1970,
            bgraData: data
        )
    }
}
