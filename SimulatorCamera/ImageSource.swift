//
//  ImageSource.swift
//  SimulatorCamera
//
//  Static image source. Loads CGImage from a URL, renders into the
//  canonical 1280x720 BGRA bitmap ONCE, then ticks at the canonical rate
//  so the iOS Simulator gets a steady stream. Same frame, fresh timestamps.
//

import Foundation
import AppKit
import CoreVideo
import OSLog

final class ImageSource: FrameSource {

    let kind: SimCamSourceKind = .image
    var onFrame: ((SimCamFrame) -> Void)?

    private let url: URL
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "image")
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func start() async throws {
        task?.cancel()
        // Decode + rasterize off the main actor: large images take long
        // enough to visibly hitch the UI otherwise.
        let url = self.url
        let bytes = try await Task.detached(priority: .userInitiated) {
            try Self.render(url: url)
        }.value
        log.info("Rendered image \(url.lastPathComponent, privacy: .public)")
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.tickLoop(bytes)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onFrame = nil
    }

    private static func render(url: URL) throws -> Data {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FrameSourceError.invalidInput("Could not load image at \(url.path)")
        }
        guard let bytes = FrameRaster.render(image: cgImage, background: CGColor(red: 0, green: 0, blue: 0, alpha: 1)) else {
            throw FrameSourceError.invalidInput("Could not rasterize \(url.lastPathComponent)")
        }
        return bytes
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

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
