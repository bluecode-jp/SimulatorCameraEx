//
//  XPCContract.swift
//  SimulatorCamera shared
//
//  Defines the XPC protocol both the container app and the system extension
//  link against. The container is the client (pushes frames + source-switch
//  commands); the extension is the listener (forwards frames to its
//  CMIOExtensionStream). Mach service name matches the extension's
//  CMIOExtensionMachServiceName so we can colocate.
//

import Foundation
import CoreMedia

public let kSimCamMachServiceName = "com.dautov.SimulatorCamera.Extension"

/// What the container is currently sourcing frames from.
@objc public enum SimCamSourceKind: Int, Sendable {
    case testPattern = 0   // built into extension; no XPC frames needed
    case macCamera = 1     // container's AVCaptureSession
    case videoFile = 2     // container's AVAssetReader
    case image = 3         // container's static CGImage
    case qrCode = 4        // container's CIQRCodeGenerator
}

/// Frame envelope shipped over XPC. NSObject-based so NSXPCConnection accepts it.
/// Carries raw BGRA bytes — extension reconstructs the CVPixelBuffer locally.
/// v1.0 target: 1280x720 BGRA at 30fps (~105 MB/s, fine for localhost XPC).
/// v1.1 will switch to IOSurface for zero-copy and 1080p / 60fps.
@objc(SimCamFrame)
public final class SimCamFrame: NSObject, NSSecureCoding {

    public static var supportsSecureCoding: Bool { true }

    @objc public let width: Int
    @objc public let height: Int
    @objc public let bytesPerRow: Int
    @objc public let pixelFormat: OSType        // expected: kCVPixelFormatType_32BGRA
    @objc public let timestampSeconds: Double
    @objc public let bgraData: Data

    public init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        timestampSeconds: Double,
        bgraData: Data
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.timestampSeconds = timestampSeconds
        self.bgraData = bgraData
        super.init()
    }

    public init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "bgraData") as Data? else {
            return nil
        }
        self.width = coder.decodeInteger(forKey: "width")
        self.height = coder.decodeInteger(forKey: "height")
        self.bytesPerRow = coder.decodeInteger(forKey: "bytesPerRow")
        self.pixelFormat = OSType(coder.decodeInt32(forKey: "pixelFormat"))
        self.timestampSeconds = coder.decodeDouble(forKey: "timestampSeconds")
        self.bgraData = data
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(width, forKey: "width")
        coder.encode(height, forKey: "height")
        coder.encode(bytesPerRow, forKey: "bytesPerRow")
        coder.encode(Int32(pixelFormat), forKey: "pixelFormat")
        coder.encode(timestampSeconds, forKey: "timestampSeconds")
        coder.encode(bgraData as NSData, forKey: "bgraData")
    }
}

/// Snapshot of extension state for diagnostics + container UI.
@objc(SimCamStatus)
public final class SimCamStatus: NSObject, NSSecureCoding {

    public static var supportsSecureCoding: Bool { true }

    @objc public let activeSourceKindRaw: Int
    @objc public let connectedClientCount: Int
    @objc public let lastFrameTimestampSeconds: Double
    @objc public let isStreamRunning: Bool

    public var activeSourceKind: SimCamSourceKind {
        SimCamSourceKind(rawValue: activeSourceKindRaw) ?? .testPattern
    }

    public init(
        activeSourceKind: SimCamSourceKind,
        connectedClientCount: Int,
        lastFrameTimestampSeconds: Double,
        isStreamRunning: Bool
    ) {
        self.activeSourceKindRaw = activeSourceKind.rawValue
        self.connectedClientCount = connectedClientCount
        self.lastFrameTimestampSeconds = lastFrameTimestampSeconds
        self.isStreamRunning = isStreamRunning
        super.init()
    }

    public init?(coder: NSCoder) {
        self.activeSourceKindRaw = coder.decodeInteger(forKey: "activeSourceKind")
        self.connectedClientCount = coder.decodeInteger(forKey: "connectedClientCount")
        self.lastFrameTimestampSeconds = coder.decodeDouble(forKey: "lastFrameTimestampSeconds")
        self.isStreamRunning = coder.decodeBool(forKey: "isStreamRunning")
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(activeSourceKindRaw, forKey: "activeSourceKind")
        coder.encode(connectedClientCount, forKey: "connectedClientCount")
        coder.encode(lastFrameTimestampSeconds, forKey: "lastFrameTimestampSeconds")
        coder.encode(isStreamRunning, forKey: "isStreamRunning")
    }
}

/// XPC protocol: container → extension. The extension's NSXPCListener exposes this.
/// All replies are nullable Bool/SimCamStatus so missing extension is non-fatal.
@objc public protocol SimulatorCameraXPCProtocol {

    /// Switch source. testPattern is "stop pushing, use built-in pattern."
    /// All other kinds mean "expect pushFrame calls from the container."
    func setSource(_ kindRaw: Int, withReply reply: @escaping (Bool) -> Void)

    /// Push one BGRA frame. Extension repackages into CMSampleBuffer + sends to stream.
    /// reply(true) on success; reply(false) if no stream is running or frame is malformed.
    func pushFrame(_ frame: SimCamFrame, withReply reply: @escaping (Bool) -> Void)

    /// Get extension state for diagnostics.
    func getStatus(withReply reply: @escaping (SimCamStatus) -> Void)

    /// Health check. Returns extension's pid + bundle id.
    func ping(withReply reply: @escaping (Int32, String) -> Void)
}
