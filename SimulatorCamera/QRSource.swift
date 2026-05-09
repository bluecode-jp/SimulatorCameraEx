//
//  QRSource.swift
//  SimulatorCamera
//
//  Programmatic QR code source. Renders the supplied string as a QR code
//  on a 1280x720 white BGRA buffer and ticks at 30fps. Useful for testing
//  QR scanners + payment scanners without holding a phone up to a screen.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import AppKit
import OSLog

final class QRSource: FrameSource {

    let kind: SimCamSourceKind = .qrCode
    var onFrame: ((SimCamFrame) -> Void)?

    private let payload: String
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "qr")
    private var task: Task<Void, Never>?
    private var cachedFrameData: Data?
    private let width: Int = 1280
    private let height: Int = 720
    private var rowBytes: Int { width * 4 }

    init(payload: String) {
        self.payload = payload
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
        let qrFilter = CIFilter.qrCodeGenerator()
        qrFilter.message = Data(payload.utf8)
        qrFilter.correctionLevel = "M"
        guard let baseQR = qrFilter.outputImage else {
            throw FrameSourceError.invalidInput("CIQRCodeGenerator returned nil")
        }

        // Scale up the QR (it generates at small size). Target 600x600.
        let qrSize: CGFloat = 600
        let scaleX = qrSize / baseQR.extent.width
        let scaleY = qrSize / baseQR.extent.height
        let scaledQR = baseQR.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Render against white background, centered.
        let context = CIContext(options: [.cacheIntermediates: false])
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw FrameSourceError.invalidInput("Could not create CGContext for QR")
        }
        // White background.
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Render QR centered.
        let qrRect = CGRect(
            x: (CGFloat(width) - qrSize) / 2,
            y: (CGFloat(height) - qrSize) / 2,
            width: qrSize,
            height: qrSize
        )
        if let qrCG = context.createCGImage(scaledQR, from: scaledQR.extent) {
            cg.draw(qrCG, in: qrRect)
        }

        guard let data = cg.data else {
            throw FrameSourceError.invalidInput("CGContext has no backing buffer")
        }
        cachedFrameData = Data(bytes: data, count: rowBytes * height)
        log.info("Rendered QR for payload (length=\(self.payload.count))")
    }

    private func tickLoop() async {
        let interval = 1.0 / 30.0
        let startTime = Date()
        while !Task.isCancelled {
            guard let data = cachedFrameData else { break }
            let elapsed = Date().timeIntervalSince(startTime)
            let frame = SimCamFrame(
                width: width,
                height: height,
                bytesPerRow: rowBytes,
                timestampSeconds: elapsed,
                bgraData: data
            )
            onFrame?(frame)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
