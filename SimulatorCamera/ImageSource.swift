//
//  ImageSource.swift
//  SimulatorCamera
//
//  Static image source. Loads CGImage from a URL, renders into a canonical
//  1280x720 BGRA pixel buffer ONCE, then re-enqueues that same buffer at
//  the canonical rate so the iOS Simulator gets a steady stream.
//

import Foundation
import AppKit
import CoreVideo
import OSLog

final class ImageSource: FrameSource {

    let kind: SimCamSourceKind = .image
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFeedFrame: ((CVPixelBuffer) -> Void)?

    private let url: URL
    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCamera", category: "image")
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func start() async throws {
        task?.cancel()
        // Decode + rasterize off the main actor: large images take long
        // enough to visibly hitch the UI otherwise.
        let url = self.url
        let (frame, image) = try await Task.detached(priority: .userInitiated) {
            try Self.render(url: url)
        }.value
        log.info("Rendered image \(url.lastPathComponent, privacy: .public)")
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.tickLoop(frame, image: image)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onFrame = nil
        onFeedFrame = nil
    }

    private static func render(url: URL) throws -> (CVPixelBuffer, CGImage) {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FrameSourceError.invalidInput("Could not load image at \(url.path)")
        }
        guard let frame = FrameRaster.render(image: cgImage, background: CGColor(red: 0, green: 0, blue: 0, alpha: 1)) else {
            throw FrameSourceError.invalidInput("Could not rasterize \(url.lastPathComponent)")
        }
        return (frame, cgImage)
    }

    private func tickLoop(_ frame: CVPixelBuffer, image: CGImage) async {
        let interval = Duration.seconds(1.0 / Double(kSimCamFrameRate))
        var next = ContinuousClock.now
        var feedFrames: [String: CVPixelBuffer] = [:]  // keyed by "WxH"
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        while !Task.isCancelled {
            onFrame?(frame)
            if let onFeedFrame, let feed = SimulatorFeed.shared.frame(from: frame, render: { size in
                let key = "\(Int(size.width))x\(Int(size.height))"
                if feedFrames[key] == nil { feedFrames[key] = FrameRaster.render(image: image, background: black, size: size) }
                return feedFrames[key]
            }) {
                onFeedFrame(feed)
            }
            next += interval
            try? await Task.sleep(until: next, clock: .continuous)
        }
    }
}
