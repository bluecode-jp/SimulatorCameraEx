//
//  SimulatorCameraProvider.swift
//  SimulatorCameraExtension
//
//  CMIOExtensionProvider + DeviceSource + StreamSource for the
//  "SimulatorCamera Virtual" camera. Advertises one format — the canonical
//  1280x720 BGRA @ 30fps from XPCContract — and emits either a built-in
//  scrolling-stripe test pattern or frames pushed by the container app.
//

import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

private let kWhiteStripeHeight: Int = 10
private let log = Logger(subsystem: "com.dautov.SimulatorCamera.Extension", category: "provider")

// Stable UUIDs so System Profiler / AVCaptureDevice see the same device
// across launches. Generated once with `uuidgen`.
private let kDeviceUUID = UUID(uuidString: "6F58C7E7-5C3A-4A0E-9F7E-9F0E3D8F1A0B")!
private let kStreamUUID = UUID(uuidString: "D2E4B9F1-7A3C-4D8E-A0B2-3F5E7D9C1B0A")!

// MARK: - Device Source

final class SimulatorCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var _streamSource: SimulatorCameraStreamSource!

    /// Number of CMIO clients that asked us to stream. Guarded by `_lock`
    /// because CMIO calls start/stop on its client queue while injectFrame
    /// arrives on the XPC queue.
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
    private let _lock = NSLock()

    /// Fired (on whatever queue CMIO used) whenever streaming flips on/off.
    var onStreamingChanged: ((Bool) -> Void)?

    var activeSource: SimCamSourceKind {
        get { _lock.lock(); defer { _lock.unlock() }; return _activeSource }
        set { _lock.lock(); _activeSource = newValue; _lock.unlock() }
    }

    var isStreaming: Bool {
        _lock.lock(); defer { _lock.unlock() }
        return _streamingCounter > 0
    }

    init(localizedName: String) {
        super.init()

        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: kDeviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        let dims = CMVideoDimensions(width: Int32(kSimCamFrameWidth), height: Int32(kSimCamFrameHeight))
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

        let frameDuration = CMTime(value: 1, timescale: Int32(kSimCamFrameRate))
        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
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

    // MARK: Streaming lifecycle

    func startStreaming() {
        guard _bufferPool != nil else { return }

        _lock.lock()
        _streamingCounter += 1
        let isFirstClient = _streamingCounter == 1
        _lock.unlock()

        // Only the first client creates the timer. Creating one per client
        // (as Apple's template does) leaks the earlier timers: they keep
        // firing forever, doubling the frame rate and never stopping.
        guard isFirstClient else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
        timer.schedule(
            deadline: .now(),
            repeating: 1.0 / Double(kSimCamFrameRate),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Test pattern timer no-ops when an external source (Mac camera,
            // video, image, QR) is pushing frames over XPC. The XPC-pushed
            // frames take their own path through injectFrame.
            if self.activeSource == .testPattern {
                self.emitTestPatternFrame()
            }
        }
        _timer?.cancel()
        _timer = timer
        timer.resume()
        log.info("streaming started")
        onStreamingChanged?(true)
    }

    func stopStreaming() {
        _lock.lock()
        if _streamingCounter > 0 { _streamingCounter -= 1 }
        let isLastClient = _streamingCounter == 0
        _lock.unlock()

        guard isLastClient else { return }
        _timer?.cancel()
        _timer = nil
        log.info("streaming stopped")
        onStreamingChanged?(false)
    }

    // MARK: Frame emission

    /// Pull a buffer from the pool. Nil (and a log line) when the pool is
    /// exhausted, which means the consumer is not draining frames.
    private func dequeuePixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            _bufferPool,
            _bufferAuxAttributes,
            &pixelBuffer
        )
        if err != kCVReturnSuccess {
            log.error("out of pixel buffers (\(err))")
            return nil
        }
        return pixelBuffer
    }

    /// Stamp `pixelBuffer` with the host clock and hand it to the stream.
    private func send(_ pixelBuffer: CVPixelBuffer) -> OSStatus {
        var sbuf: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        timingInfo.presentationTimeStamp = now
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: _videoDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sbuf
        )
        guard err == noErr, let sbuf else {
            log.error("CMSampleBufferCreateForImageBuffer failed (\(err))")
            return err
        }
        _streamSource.stream.send(
            sbuf,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))
        )
        return noErr
    }

    /// Generate one frame of the scrolling-white-stripe-on-black test pattern
    /// and push it to the active CMIOExtensionStream.
    private func emitTestPatternFrame() {
        guard let pixelBuffer = dequeuePixelBuffer() else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            memset(base, 0, rowBytes * height)

            let maxStart = UInt32(max(0, height - kWhiteStripeHeight))
            let stripeStart = min(_whiteStripeStartRow, maxStart)
            if _whiteStripeIsAscending {
                _whiteStripeStartRow = stripeStart > 0 ? stripeStart - 1 : 0
                _whiteStripeIsAscending = _whiteStripeStartRow > 0
            } else {
                _whiteStripeStartRow = stripeStart + 1
                _whiteStripeIsAscending = _whiteStripeStartRow >= maxStart
            }

            var rowPtr = base.advanced(by: rowBytes * Int(stripeStart))
            let rowsToPaint = min(kWhiteStripeHeight, height - Int(stripeStart))
            for _ in 0..<max(0, rowsToPaint) {
                memset(rowPtr, 0xFF, width * kSimCamBytesPerPixel)
                rowPtr += rowBytes
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        _ = send(pixelBuffer)
    }

    /// Inject a frame pushed from the container app over XPC. BGRA bytes →
    /// pooled CVPixelBuffer → CMSampleBuffer → CMIOExtensionStream.send.
    /// Called on the XPC delivery queue. Returns false when the frame was
    /// rejected (not streaming, malformed, wrong geometry) so the sender
    /// can see it in the reply.
    func injectFrame(_ frame: SimCamFrame) -> Bool {
        // Only inject when streaming is actually active. Otherwise we waste work.
        guard isStreaming else { return false }

        if let problem = frame.validationError() {
            log.error("injectFrame rejected: \(problem, privacy: .public)")
            return false
        }
        guard frame.isCanonicalSize else {
            log.error("injectFrame rejected: \(frame.width)x\(frame.height) != \(kSimCamFrameWidth)x\(kSimCamFrameHeight)")
            return false
        }
        guard let pb = dequeuePixelBuffer() else { return false }

        CVPixelBufferLockBaseAddress(pb, [])
        if let dest = CVPixelBufferGetBaseAddress(pb) {
            let destRowBytes = CVPixelBufferGetBytesPerRow(pb)
            let pixelRowBytes = frame.width * kSimCamBytesPerPixel
            frame.bgraData.withUnsafeBytes { srcRaw in
                guard let src = srcRaw.baseAddress else { return }
                if destRowBytes == frame.bytesPerRow, srcRaw.count >= frame.bytesPerRow * frame.height {
                    memcpy(dest, src, frame.bytesPerRow * frame.height)
                } else {
                    // Different alignment: copy only the pixel bytes of each row.
                    let copyBytes = min(destRowBytes, pixelRowBytes)
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

        return send(pb) == noErr
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
            if activeFormatIndex >= 1 { log.error("Invalid format index \(self.activeFormatIndex)") }
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
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(kSimCamFrameRate))
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

    private let _clientLock = NSLock()
    private var _clientCount = 0

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = SimulatorCameraDeviceSource(localizedName: "SimulatorCamera Virtual")

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }

        // Wire the XPC listener to the device source: pushed frames go
        // straight into injectFrame, source switches flip activeSource, and
        // streaming state flows back into the status snapshot.
        let dev = deviceSource!
        dev.onStreamingChanged = { running in
            Task { @MainActor in XPCListener.shared.isStreamRunning = running }
        }
        Task { @MainActor [weak dev] in
            let listener = XPCListener.shared
            listener.onFrameReceived = { frame in
                dev?.injectFrame(frame) ?? false
            }
            listener.onSourceSwitched = { kind in
                dev?.activeSource = kind
            }
            listener.start()
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        _clientLock.lock()
        _clientCount += 1
        let count = _clientCount
        _clientLock.unlock()
        log.info("CMIO client connected (total=\(count))")
        Task { @MainActor in XPCListener.shared.connectedClientCount = count }
    }

    func disconnect(from client: CMIOExtensionClient) {
        _clientLock.lock()
        _clientCount = max(0, _clientCount - 1)
        let count = _clientCount
        _clientLock.unlock()
        log.info("CMIO client disconnected (remaining=\(count))")
        Task { @MainActor in XPCListener.shared.connectedClientCount = count }
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
