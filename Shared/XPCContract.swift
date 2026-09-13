//
//  XPCContract.swift
//  SimulatorCamera shared
//
//  Defines the XPC protocol both the container app and the system extension
//  link against. The container is the client (pushes frames + source-switch
//  commands); the extension is the listener (forwards frames to its
//  CMIOExtensionStream).
//
//  Every frame that crosses the wire is a canonical 1280x720 BGRA image:
//  the container normalizes all sources to that size, the extension
//  advertises exactly that format, and the extension rejects anything else.
//  One size everywhere means no per-frame format negotiation and no
//  surprises for the consumer on the other side of the virtual camera.
//

import Foundation
import CoreMedia
import Security

// MARK: - Canonical frame geometry

/// Width / height / rate of every frame the virtual camera emits.
public let kSimCamFrameWidth: Int = 1280
public let kSimCamFrameHeight: Int = 720
public let kSimCamFrameRate: Int = 30
public let kSimCamBytesPerPixel: Int = 4

// MARK: - Mach service naming

/// App-group identifier shared by the container app, the extension, and
/// simcamctl (must match the `com.apple.security.application-groups`
/// entitlement). Sandboxed processes may only register / look up Mach
/// services whose name is an immediate child of one of their app groups,
/// so the XPC endpoint name is derived from this.
public let kSimCamAppGroupSuffix = "com.dautov.SimulatorCamera"

public enum SimCamMachService {

    /// Mach service name the extension listens on and the clients connect to.
    /// `<TeamID>.com.dautov.SimulatorCamera.xpc` for signed builds; falls
    /// back to the unprefixed name when the running binary carries no team
    /// identifier (unsigned CI / ad-hoc dev builds).
    public static let name: String = {
        if let team = SimCamCodeSigning.teamIdentifier() {
            return "\(team).\(kSimCamAppGroupSuffix).xpc"
        }
        return "\(kSimCamAppGroupSuffix).xpc"
    }()
}

/// Kept for call-site compatibility; resolves to `SimCamMachService.name`.
public var kSimCamMachServiceName: String { SimCamMachService.name }

public enum SimCamCodeSigning {

    /// Team identifier baked into the running process's code signature, or
    /// nil when the binary is unsigned / ad-hoc signed.
    public static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            return nil
        }
        return team
    }

    /// Code-signing requirement clients must satisfy to talk to the
    /// extension: signed by Apple's developer program under the same team
    /// as the extension itself. Nil for unsigned builds (no gate possible).
    public static func peerRequirement() -> String? {
        guard let team = teamIdentifier() else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

// MARK: - Source kinds

/// What the container is currently sourcing frames from.
@objc public enum SimCamSourceKind: Int, Sendable, CaseIterable {
    case testPattern = 0   // built into extension; no XPC frames needed
    case macCamera = 1     // container's AVCaptureSession
    case videoFile = 2     // container's AVAssetReader
    case image = 3         // container's static CGImage
    case qrCode = 4        // container's CIQRCodeGenerator

    public var label: String {
        switch self {
        case .testPattern: return "test pattern"
        case .macCamera: return "mac camera"
        case .videoFile: return "video file"
        case .image: return "static image"
        case .qrCode: return "QR code"
        }
    }
}

// MARK: - Frame envelope

/// Frame envelope shipped over XPC. NSObject-based so NSXPCConnection accepts it.
/// Carries raw BGRA bytes — extension reconstructs the CVPixelBuffer locally.
/// v1.0 target: 1280x720 BGRA at 30fps (~105 MB/s, fine for localhost XPC).
/// v1.1 will switch to IOSurface for zero-copy and 1080p / 60fps.
@objc(SimCamFrame)
public final class SimCamFrame: NSObject, NSSecureCoding {

    public static var supportsSecureCoding: Bool { true }

    /// Largest dimension we will ever accept from the wire. Anything above
    /// this is treated as a malformed / hostile message.
    public static let maxDimension = 8192

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
        self.pixelFormat = OSType(bitPattern: coder.decodeInt32(forKey: "pixelFormat"))
        self.timestampSeconds = coder.decodeDouble(forKey: "timestampSeconds")
        self.bgraData = data
        super.init()
        // Refuse to even materialize a frame whose geometry cannot be trusted.
        // The extension re-checks via validationError() before touching bytes.
        if validationError() != nil { return nil }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(width, forKey: "width")
        coder.encode(height, forKey: "height")
        coder.encode(bytesPerRow, forKey: "bytesPerRow")
        coder.encode(Int32(bitPattern: pixelFormat), forKey: "pixelFormat")
        coder.encode(timestampSeconds, forKey: "timestampSeconds")
        coder.encode(bgraData as NSData, forKey: "bgraData")
    }

    /// Structural validity: geometry is sane and the payload is large enough
    /// to be read row-by-row without running past the end of the buffer.
    /// Returns nil when the frame is safe to consume.
    public func validationError() -> String? {
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            return "unsupported pixel format \(pixelFormat)"
        }
        guard width > 0, height > 0 else {
            return "non-positive dimensions \(width)x\(height)"
        }
        guard width <= Self.maxDimension, height <= Self.maxDimension else {
            return "dimensions \(width)x\(height) exceed \(Self.maxDimension)"
        }
        let minRowBytes = width * kSimCamBytesPerPixel
        guard bytesPerRow >= minRowBytes else {
            return "bytesPerRow \(bytesPerRow) < \(minRowBytes)"
        }
        // Last row may be unpadded, so require rows-1 full strides + one row of pixels.
        let required = bytesPerRow * (height - 1) + minRowBytes
        guard bgraData.count >= required else {
            return "payload \(bgraData.count) bytes < required \(required)"
        }
        guard timestampSeconds.isFinite else {
            return "non-finite timestamp"
        }
        return nil
    }

    /// True when the frame matches the canonical geometry the extension advertises.
    public var isCanonicalSize: Bool {
        width == kSimCamFrameWidth && height == kSimCamFrameHeight
    }
}

// MARK: - Status snapshot

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

// MARK: - Protocol

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

/// Single place that knows which secure-coding classes travel on which
/// selector. Listener and every client build their NSXPCInterface here so
/// the allow-lists can never drift apart.
public enum SimulatorCameraXPCInterface {
    public static func make() -> NSXPCInterface {
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
        return interface
    }
}
