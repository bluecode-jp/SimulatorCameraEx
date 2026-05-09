//
//  VideoFileSource.swift
//  SimulatorCamera
//
//  AVAssetReader against a local video file. Decodes BGRA frames at the
//  asset's native frame rate, loops at EOF. Honors preferredTransform so
//  iPhone-shot portrait videos render upright.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import OSLog

final class VideoFileSource: FrameSource {

    let kind: SimCamSourceKind = .videoFile
    var onFrame: ((SimCamFrame) -> Void)?

    private let url: URL
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "video-file")
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func start() async throws {
        // Cancel any prior loop.
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        log.info("VideoFileSource stopped")
    }

    private func runLoop() async {
        var loopCount = 0
        var loopOffset: Double = 0

        while !Task.isCancelled {
            do {
                let asset = AVURLAsset(url: url)
                let isPlayable = try await asset.load(.isPlayable)
                let hasProtected = try await asset.load(.hasProtectedContent)
                guard isPlayable, !hasProtected else {
                    log.error("asset not playable or DRM-protected")
                    return
                }

                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    log.error("asset has no video track")
                    return
                }

                let naturalSize = try await track.load(.naturalSize)
                let nominalFPS = try await track.load(.nominalFrameRate)
                let xform = try await track.load(.preferredTransform)

                let reader = try AVAssetReader(asset: asset)
                let trackOutput = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    ]
                )
                trackOutput.alwaysCopiesSampleData = false
                guard reader.canAdd(trackOutput) else {
                    log.error("reader can't add output")
                    return
                }
                reader.add(trackOutput)
                guard reader.startReading() else {
                    log.error("reader failed to start: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
                    return
                }

                let frameInterval = nominalFPS > 0 ? 1.0 / Double(nominalFPS) : 1.0 / 30.0
                let needsRotation = !xform.isIdentity
                let displayWidth = needsRotation ? Int(abs(naturalSize.height)) : Int(naturalSize.width)
                let displayHeight = needsRotation ? Int(abs(naturalSize.width)) : Int(naturalSize.height)

                let context = CIContext(options: [.cacheIntermediates: false])
                var lastPTS: Double = 0

                while !Task.isCancelled, reader.status == .reading {
                    guard let sb = trackOutput.copyNextSampleBuffer(),
                          let pb = CMSampleBufferGetImageBuffer(sb) else {
                        break
                    }
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
                    lastPTS = pts
                    let absoluteTimestamp = loopOffset + pts

                    // Apply rotation if needed.
                    let outputBuffer: CVPixelBuffer
                    if needsRotation {
                        let oriented = CIImage(cvPixelBuffer: pb).transformed(by: xform)
                        var dst: CVPixelBuffer?
                        let attrs: [CFString: Any] = [
                            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                        ]
                        CVPixelBufferCreate(
                            kCFAllocatorDefault, displayWidth, displayHeight,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dst
                        )
                        guard let rotated = dst else { continue }
                        context.render(oriented, to: rotated)
                        outputBuffer = rotated
                    } else {
                        outputBuffer = pb
                    }

                    guard let frame = makeSimCamFrame(from: outputBuffer, timestamp: absoluteTimestamp) else {
                        continue
                    }
                    onFrame?(frame)

                    // Pace to native frame rate.
                    try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
                }

                // EOF — bump loop offset for monotonic timestamps and restart.
                loopOffset = loopOffset + lastPTS + frameInterval
                loopCount += 1
                log.info("video EOF, looping (count=\(loopCount))")
            } catch {
                log.error("video file source error: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }
}
