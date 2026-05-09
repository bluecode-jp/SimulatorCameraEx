//
//  ImageSource.swift
//  SimulatorCamera
//
//  Static image source. Loads CGImage from a URL, renders into a
//  1280x720 BGRA pixel buffer ONCE (or on file change), then ticks at
//  30fps so the iOS Simulator gets a steady stream. Same frame, fresh
//  timestamps.
//

import Foundation
import AppKit
import CoreImage
import CoreVideo
import OSLog

final class ImageSource: FrameSource {

    let kind: SimCamSourceKind = .image
    var onFrame: ((SimCamFrame) -> Void)?

    private let url: URL
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "image")
    private var task: Task<Void, Never>?
    private var cachedFrameData: Data?
    private var cachedWidth: Int = 1280
    private var cachedHeight: Int = 720
    private var cachedRowBytes: Int = 1280 * 4

    init(url: URL) {
        self.url = url
    }

    func start() async throws {
        try renderOnce()
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.tickLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func renderOnce() throws {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FrameSourceError.invalidInput("Could not load image at \(url.path)")
        }

        // Render to 1280x720 BGRA (letterboxed centered).
        let targetW = 1280
        let targetH = 720
        let imageW = cgImage.width
        let imageH = cgImage.height

        let scale = min(Double(targetW) / Double(imageW), Double(targetH) / Double(imageH))
        let drawW = Double(imageW) * scale
        let drawH = Double(imageH) * scale
        let drawX = (Double(targetW) - drawW) / 2
        let drawY = (Double(targetH) - drawH) / 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw FrameSourceError.invalidInput("Could not create CGContext")
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        context.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        guard let data = context.data else {
            throw FrameSourceError.invalidInput("CGContext has no backing buffer")
        }
        cachedFrameData = Data(bytes: data, count: targetW * 4 * targetH)
        cachedWidth = targetW
        cachedHeight = targetH
        cachedRowBytes = targetW * 4
        log.info("Rendered image \(self.url.lastPathComponent, privacy: .public) at \(self.cachedWidth)x\(self.cachedHeight)")
    }

    private func tickLoop() async {
        let interval = 1.0 / 30.0
        let startTime = Date()
        while !Task.isCancelled {
            guard let data = cachedFrameData else { break }
            let elapsed = Date().timeIntervalSince(startTime)
            let frame = SimCamFrame(
                width: cachedWidth,
                height: cachedHeight,
                bytesPerRow: cachedRowBytes,
                timestampSeconds: elapsed,
                bgraData: data
            )
            onFrame?(frame)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
