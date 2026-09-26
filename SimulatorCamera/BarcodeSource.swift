//
//  BarcodeSource.swift
//  SimulatorCamera
//
//  Streams a generated 1D barcode (Code 128 or EAN-13) as a static frame,
//  like QRSource: rendered once per frame size, re-sent at the canonical
//  frame rate so capture clients see a live stream.
//

import CoreVideo
import Foundation
import OSLog

final class BarcodeSource: FrameSource {

    let kind: SimCamSourceKind
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFeedFrame: ((CVPixelBuffer) -> Void)?

    private let payload: String
    private let symbology: BarcodeSymbology
    private let log = Logger(subsystem: "jp.co.bluecode.SimulatorCamera", category: "barcode")
    private var task: Task<Void, Never>?

    init(payload: String, symbology: BarcodeSymbology) {
        self.payload = payload
        self.symbology = symbology
        self.kind = symbology == .code128 ? .code128 : .ean13
    }

    func start() async throws {
        task?.cancel()
        let payload = self.payload, symbology = self.symbology
        let frame = try await Task.detached(priority: .userInitiated) {
            guard let frame = BarcodeRenderer.render(payload: payload, symbology: symbology) else {
                throw FrameSourceError.invalidInput(symbology == .ean13
                    ? "EAN-13 needs 1–12 digits (check digit added) or 13 digits with a valid check digit."
                    : "Code 128 needs printable ASCII text.")
            }
            return frame
        }.value
        log.info("Rendered \(symbology.rawValue, privacy: .public) for payload (length=\(payload.count))")
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
        let payload = self.payload, symbology = self.symbology
        while !Task.isCancelled {
            onFrame?(frame)
            if let onFeedFrame, let feed = SimulatorFeed.shared.frame(from: frame, render: { size in
                let key = "\(Int(size.width))x\(Int(size.height))"
                if feedFrames[key] == nil { feedFrames[key] = BarcodeRenderer.render(payload: payload, symbology: symbology, size: size) }
                return feedFrames[key]
            }) {
                onFeedFrame(feed)
            }
            next += interval
            try? await Task.sleep(until: next, clock: .continuous)
        }
    }
}
