//
//  QRSource.swift
//  SimulatorCamera
//
//  Programmatic QR code source. Renders the supplied string as a QR code
//  on a canonical white BGRA frame and ticks at the canonical rate. Useful
//  for testing QR scanners + payment scanners without holding a phone up
//  to a screen.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import OSLog

final class QRSource: FrameSource {

    let kind: SimCamSourceKind = .qrCode
    var onFrame: ((SimCamFrame) -> Void)?

    private let payload: String
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "qr")
    private var task: Task<Void, Never>?

    init(payload: String) {
        self.payload = payload
    }

    func start() async throws {
        task?.cancel()
        let payload = self.payload
        let bytes = try await Task.detached(priority: .userInitiated) {
            guard let bytes = QRRenderer.render(payload: payload) else {
                throw FrameSourceError.invalidInput("Could not render a QR code for that payload (too long?).")
            }
            return bytes
        }.value
        log.info("Rendered QR for payload (length=\(payload.count))")
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.tickLoop(bytes)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onFrame = nil
    }

    private func tickLoop(_ bytes: Data) async {
        let interval = Duration.seconds(1.0 / Double(kSimCamFrameRate))
        let start = ContinuousClock.now
        var next = start
        while !Task.isCancelled {
            let elapsed = start.duration(to: .now)
            onFrame?(FrameRaster.makeFrame(bytes: bytes, timestamp: elapsed.seconds))
            next += interval
            try? await Task.sleep(until: next, clock: .continuous)
        }
    }
}
