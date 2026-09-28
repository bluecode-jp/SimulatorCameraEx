//
//  BarcodePreviewView.swift
//  SimulatorCamera
//
//  Preview window for the generated codes (QR Code, Code 128, EAN-13):
//  shows the frame iOS Simulator apps would receive, in the current frame
//  orientation, redrawn as the payload field changes — before Inject.
//

import CoreImage
import SwiftUI

extension SimCamSourceKind: Codable {}

struct BarcodePreviewView: View {
    let kind: SimCamSourceKind
    @Environment(SourceManager.self) private var sourceManager
    @AppStorage(SimulatorFeed.orientationDefaultsKey) private var orientationRaw = SimulatorFeed.Orientation.portrait.rawValue

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private var orientation: SimulatorFeed.Orientation {
        SimulatorFeed.Orientation(rawValue: orientationRaw) ?? .portrait
    }

    private var payload: String {
        switch kind {
        case .qrCode: sourceManager.qrPayload
        case .code128: sourceManager.code128Payload
        case .ean13: sourceManager.ean13Payload
        default: ""
        }
    }

    /// Same renderers and frame size as the simulator feed.
    private var image: CGImage? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let size = orientation.frameSize
        let buffer: CVPixelBuffer? = switch kind {
        case .qrCode: QRRenderer.render(payload: text, size: size)
        case .code128: BarcodeRenderer.render(payload: text, symbology: .code128, size: size)
        case .ean13: BarcodeRenderer.render(payload: text, symbology: .ean13, size: size)
        default: nil
        }
        guard let buffer else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return Self.context.createCGImage(ci, from: ci.extent)
    }

    var body: some View {
        let size = orientation.frameSize
        VStack(spacing: 10) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.4)))
                } else {
                    ContentUnavailableView(
                        "Nothing to preview",
                        systemImage: "exclamationmark.triangle",
                        description: Text(invalidMessage)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 2) {
                Text(payload.isEmpty ? " " : payload)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(Int(size.width))×\(Int(size.height)) · iOS Simulator frame (\(orientation.rawValue))"
                     + (sourceManager.activeKind == kind ? " · injected" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 280, minHeight: 360)
        .navigationTitle("\(title) Preview")
    }

    private var title: String {
        switch kind {
        case .qrCode: "QR Code"
        case .code128: "Code 128"
        case .ean13: "EAN-13"
        default: kind.label
        }
    }

    private var invalidMessage: String {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a value in the main window." }
        switch kind {
        case .ean13: return "EAN-13 needs 1–12 digits (check digit added) or 13 digits with a valid check digit."
        case .code128: return "Code 128 needs printable ASCII text."
        default: return "Could not render a QR code for that payload (too long?)."
        }
    }
}
