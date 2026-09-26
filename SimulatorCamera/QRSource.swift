//
//  QRSource.swift
//  SimulatorCamera
//
//  Programmatic QR code source. Renders the supplied string as a QR code
//  on a canonical white pixel buffer and re-enqueues it at the canonical
//  rate. Useful for testing QR scanners + payment scanners without holding
//  a phone up to a screen.
//

import Foundation
import CoreVideo
import OSLog

final class QRSource: FrameSource {

    let kind: SimCamSourceKind = .qrCode
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFeedFrame: ((CVPixelBuffer) -> Void)?

    private let payload: String
    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCamera", category: "qr")
    private var task: Task<Void, Never>?

    init(payload: String) {
        self.payload = payload
    }

    func start() async throws {
        task?.cancel()
        let payload = self.payload
        let frame = try await Task.detached(priority: .userInitiated) {
            guard let frame = QRRenderer.render(payload: payload) else {
                throw FrameSourceError.invalidInput("Could not render a QR code for that payload (too long?).")
            }
            return frame
        }.value
        log.info("Rendered QR for payload (length=\(payload.count))")
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.tickLoop(frame)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onFrame = nil
        onFeedFrame = nil
    }

    private func tickLoop(_ frame: CVPixelBuffer) async {
        let interval = Duration.seconds(1.0 / Double(kSimCamFrameRate))
        var next = ContinuousClock.now
        var feedFrames: [String: CVPixelBuffer] = [:]  // keyed by "WxH"
        let payload = self.payload
        while !Task.isCancelled {
            onFrame?(frame)
            if let onFeedFrame, let feed = SimulatorFeed.shared.frame(from: frame, render: { size in
                let key = "\(Int(size.width))x\(Int(size.height))"
                if feedFrames[key] == nil { feedFrames[key] = QRRenderer.render(payload: payload, size: size) }
                return feedFrames[key]
            }) {
                onFeedFrame(feed)
            }
            next += interval
            try? await Task.sleep(until: next, clock: .continuous)
        }
    }
}
