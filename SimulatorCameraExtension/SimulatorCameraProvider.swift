//
//  SimulatorCameraProvider.swift
//  SimulatorCameraExtension
//
//  CMIOExtensionProvider + DeviceSource + StreamSource for the
//  "SimulatorCamera Virtual" camera. v1.0.0 Phase 1 ships a scrolling
//  white-stripe test pattern (adapted from Apple's Camera Extension
//  template) at 1920x1080 / 60fps to prove the pipeline works.
//
//  v1.1+ replaces the test pattern with XPC-pushed frames from the
//  container app's Mac camera capture.
//

import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

private let kWhiteStripeHeight: Int = 10
private let kFrameRate: Int = 60

// Stable UUIDs so System Profiler / AVCaptureDevice see the same device
// across launches. Generated once with `uuidgen`.
private let kDeviceUUID = UUID(uuidString: "6F58C7E7-5C3A-4A0E-9F7E-9F0E3D8F1A0B")!
private let kStreamUUID = UUID(uuidString: "D2E4B9F1-7A3C-4D8E-A0B2-3F5E7D9C1B0A")!

// MARK: - Device Source

final class SimulatorCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var _streamSource: SimulatorCameraStreamSource!

    private var _streamingCounter: UInt32 = 0
    private var _timer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(
        label: "com.dautov.SimulatorCameraExtension.timer",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem,
        target: .global(qos: .userInteractive)
    )

    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!

    private var _whiteStripeStartRow: UInt32 = 0
    private var _whiteStripeIsAscending: Bool = false

    /// Active source kind. testPattern = local timer emission. Anything else
    /// = container is pushing frames via XPC, the timer no-ops.
    private var _activeSource: SimCamSourceKind = .testPattern
    private let _sourceLock = NSLock()

    var activeSource: SimCamSourceKind {
        get { _sourceLock.lock(); defer { _sourceLock.unlock() }; return _activeSource }
        set { _sourceLock.lock(); _activeSource = newValue; _sourceLock.unlock() }
    }

    init(localizedName: String) {
        super.init()

        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: kDeviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        let dims = CMVideoDimensions(width: 1920, height: 1080)
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dims.width,
            height: dims.height,
            extensions: nil,
            formatDescriptionOut: &_videoDescription
        )

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: dims.width,
            kCVPixelBufferHeightKey: dims.height,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)

        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil
        )
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        _streamSource = SimulatorCameraStreamSource(
            localizedName: "SimulatorCamera.Video",
            streamID: kStreamUUID,
            streamFormat: videoStreamFormat,
            device: device
        )
        do {
            try device.addStream(_streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "SimulatorCamera Virtual"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No settable device properties in v1.0.
    }

    func startStreaming() {
        guard let _ = _bufferPool else { return }
        _streamingCounter += 1

        _timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
        _timer!.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .seconds(0))

        _timer!.setEventHandler { [weak self] in
            guard let self else { return }
            // Test pattern timer no-ops when an external source (Mac camera,
            // video, image, QR) is pushing frames over XPC. The XPC-pushed
            // frames take their own path through injectFrame.
            if self.activeSource == .testPattern {
                self.emitTestPatternFrame()
            }
        }
        _timer!.setCancelHandler { }
        _timer!.resume()
    }

    func stopStreaming() {
        if _streamingCounter > 1 {
            _streamingCounter -= 1
        } else {
            _streamingCounter = 0
            if let timer = _timer {
                timer.cancel()
                _timer = nil
            }
        }
    }

    /// Generate one frame of the scrolling-white-stripe-on-black test pattern
    /// and push it to the active CMIOExtensionStream.
    private func emitTestPatternFrame() {
        var err: OSStatus = 0
        let now = CMClockGetTime(CMClockGetHostTimeClock())

        var pixelBuffer: CVPixelBuffer?
        err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            _bufferPool,
            _bufferAuxAttributes,
            &pixelBuffer
        )
        if err != 0 {
            os_log(.error, "out of pixel buffers \(err)")
            return
        }

        guard let pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        var bufferPtr = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        memset(bufferPtr, 0, rowBytes * height)

        let whiteStripeStartRow = _whiteStripeStartRow
        if _whiteStripeIsAscending {
            _whiteStripeStartRow = whiteStripeStartRow - 1
            _whiteStripeIsAscending = _whiteStripeStartRow > 0
        } else {
            _whiteStripeStartRow = whiteStripeStartRow + 1
            _whiteStripeIsAscending = _whiteStripeStartRow >= (UInt32(height) - UInt32(kWhiteStripeHeight))
        }
        bufferPtr += rowBytes * Int(whiteStripeStartRow)
        for _ in 0..<kWhiteStripeHeight {
            for _ in 0..<width {
                var white: UInt32 = 0xFFFFFFFF
                memcpy(bufferPtr, &white, MemoryLayout.size(ofValue: white))
                bufferPtr += MemoryLayout.size(ofValue: white)
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var sbuf: CMSampleBuffer!
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: _videoDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sbuf
        )
        if err == 0 {
            _streamSource.stream.send(
                sbuf,
                discontinuity: [],
                hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
            )
        }
        os_log(.debug, "video frame ts=\(timingInfo.presentationTimeStamp.seconds) now=\(now.seconds) err=\(err)")
    }

    /// Inject a frame pushed from the container app over XPC. BGRA bytes →
    /// CVPixelBuffer → CMSampleBuffer → CMIOExtensionStream.send.
    /// Called from XPC reply handlers (off the timer queue).
    func injectFrame(_ frame: SimCamFrame) {
        // Only inject when streaming is actually active. Otherwise we waste work.
        guard _streamingCounter > 0 else { return }
        guard frame.pixelFormat == kCVPixelFormatType_32BGRA else {
            os_log(.error, "injectFrame: unsupported pixel format \(frame.pixelFormat)")
            return
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.width,
            frame.height,
            frame.pixelFormat,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pb = pixelBuffer else {
            os_log(.error, "injectFrame: CVPixelBufferCreate failed status=\(createStatus)")
            return
        }

        CVPixelBufferLockBaseAddress(pb, [])
        if let dest = CVPixelBufferGetBaseAddress(pb) {
            let destRowBytes = CVPixelBufferGetBytesPerRow(pb)
            frame.bgraData.withUnsafeBytes { srcRaw in
                guard let src = srcRaw.baseAddress else { return }
                if destRowBytes == frame.bytesPerRow {
                    memcpy(dest, src, frame.bytesPerRow * frame.height)
                } else {
                    // Different alignment: copy row by row.
                    let copyBytes = min(destRowBytes, frame.bytesPerRow)
                    for row in 0..<frame.height {
                        memcpy(
                            dest.advanced(by: row * destRowBytes),
                            src.advanced(by: row * frame.bytesPerRow),
                            copyBytes
                        )
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        // Build a CMSampleBuffer matching our advertised format.
        var sampleBuffer: CMSampleBuffer!
        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMTime(
            seconds: frame.timestampSeconds,
            preferredTimescale: 1_000_000_000
        )
        let cmStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: _videoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if cmStatus == 0, let sb = sampleBuffer {
            _streamSource.stream.send(
                sb,
                discontinuity: [],
                hostTimeInNanoseconds: UInt64(frame.timestampSeconds * Double(NSEC_PER_SEC))
            )
        } else {
            os_log(.error, "injectFrame: CMSampleBufferCreate failed status=\(cmStatus)")
        }
    }
}

// MARK: - Stream Source

final class SimulatorCameraStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 { os_log(.error, "Invalid index") }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // v1.0 trusts all clients. Future: gate on bundle ID for app-list whitelist.
        true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? SimulatorCameraDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? SimulatorCameraDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }
}

// MARK: - Provider Source

@objc(SimulatorCameraProviderSource)
final class SimulatorCameraProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: SimulatorCameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = SimulatorCameraDeviceSource(localizedName: "SimulatorCamera Virtual")

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }

        // Start the XPC listener so the container app can push frames + switch
        // sources. The listener wires its frame-receive hook to the device
        // source's injectFrame method, and its source-switch hook to the
        // device source's activeSource property.
        let dev = deviceSource!
        Task { @MainActor in
            let listener = XPCListener.shared
            listener.onFrameReceived = { [weak dev] frame in
                dev?.injectFrame(frame)
            }
            listener.onSourceSwitched = { [weak dev] kind in
                dev?.activeSource = kind
            }
            listener.start()
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        // v1.0 no-op. Phase 2 will track connected clients for diagnostics.
    }

    func disconnect(from client: CMIOExtensionClient) {
        // v1.0 no-op.
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "SimulatorCamera (open source)"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable properties in v1.0.
    }
}
