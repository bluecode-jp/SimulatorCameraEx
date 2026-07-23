# SimulatorCamera MVP Design Doc
## Pre-recorded Video Playback as Simulated Camera Input

**Author:** Ruslan Dautov (dautovri)
**Date:** 2026-04-19
**Status:** SUPERSEDED (historical — v0.2.x TCP/SwiftPM architecture)
**Branch:** main
**Supersedes:** None (first design doc)
**Superseded by:** v1.0.0 `CMIOExtension` architecture — see
[ARCHITECTURE.md](ARCHITECTURE.md). The SwiftPM targets described below no
longer exist; there is no `Package.swift` and no SPM distribution.

---

## Problem Statement

iOS Simulator has no camera. `AVCaptureDevice.default(for: .video)` returns nil. Every iOS app that touches the camera -- QR scanners, barcode readers, document capture, ML pipelines, AR prototypes -- cannot be tested in the Simulator.

This is annoying for humans. It is **fatal for AI agents.** Claude Code, Cursor, Copilot, and other AI coding tools can build, run, and screenshot apps in the Simulator. But the moment the app touches the camera, the agent is blind. It writes camera code, cannot verify it works, and the developer becomes a manual relay between the agent and a physical device.

SimulatorCamera exists to close this loop.

## Demand Evidence

- **First user pain (Q1):** The author builds multiple camera-based iOS apps and cannot test them without deploying to a physical device every iteration.
- **Status quo (Q2):** AI agents write camera code blind. Developer manually deploys to device, observes result, describes problem in text, agent guesses at fix, deploy again. The development loop is broken.
- **Key insight (Q3):** The acute user is not "iOS developers in general" but specifically developers using AI agents to build camera-based iOS apps. This group is growing fast and has no workaround.
- **Narrowest wedge (Q4):** Pre-recorded video playback. No live webcam needed. Deterministic, reproducible, no camera permissions required.
- **Observation (Q5):** End-to-end flow has not been verified yet. The SDK pieces exist (SCMF protocol, AVCaptureSession shim, router) but frames have not been confirmed landing in a real iOS app in the Simulator.
- **Future-fit (Q6):** More essential over time. AI agents will be primary app builders; Simulator is their test environment. Apple has had 17 years to add camera support and hasn't. Window is open.

## Target User and Narrowest Wedge

**Target user:** A developer using an AI coding agent (Claude Code, Cursor) to build an iOS app with camera features. They want the agent to run the app in Simulator, feed it video frames, screenshot the result, and iterate -- all without a physical device.

**Narrowest wedge:** A Mac command-line tool that reads a video file and streams its frames over localhost:9876 using SCMF. The iOS SDK receives these frames and delivers them to the app's `AVCaptureVideoDataOutputSampleBufferDelegate` as if they came from a real camera.

## Constraints

1. Must work on macOS 13+ (Ventura) and iOS 16+ Simulator
2. No private APIs -- `Network.framework` + `CoreVideo` + `ImageIO` + `AVFoundation` only
3. Must compile and run without Xcode project files for the Mac server (SwiftPM only)
4. Pre-recorded video must loop continuously
5. Frame rate should target 15-30 FPS over localhost
6. The iOS SDK is already built (v0.2.0). Do not break existing API surface.

## Premises

1. The core value is enabling AI agents to build/test camera-based iOS apps in the Simulator without a physical device.
2. The MVP is pre-recorded video playback as simulated camera input, NOT live webcam.
3. Nothing else matters until end-to-end flow is verified: Mac sends frames, iOS app receives them as camera input.
4. The first user is Ruslan. Broader distribution comes after dogfooding.
5. Apple is the only existential risk. Their 17-year track record of not shipping this is the moat.

## Approaches Considered

### Approach A: Minimal Video-Only MVP (CHOSEN)
- **Summary:** Strip Mac server to one job: read video file with AVAssetReader, encode frames as SCMF, send over localhost TCP. iOS SDK stays as-is.
- **Effort:** S
- **Risk:** Low
- **Pros:** Fastest path to verification; no UI to build; AI-agent friendly (CLI invocation); deterministic test input
- **Cons:** No GUI for source selection; single video file at a time
- **Reuses:** Existing SCMF encoder, FrameStreamer, VideoFileReader on Mac side; entire iOS SDK unchanged

### Approach B: Test Pattern First
- **Summary:** Generate synthetic frames in-process on iOS side. No network, no Mac app.
- **Effort:** S
- **Risk:** Low
- **Pros:** Zero external dependencies; proves shim works
- **Cons:** Doesn't prove the network path; synthetic frames don't exercise real video decoding; not useful for actual camera app testing

### Approach C: Full Mac App + Video
- **Summary:** Scaffold .xcodeproj, build SwiftUI companion app with video picker, webcam toggle, streaming UI.
- **Effort:** M-L
- **Risk:** Medium
- **Pros:** Full product experience
- **Cons:** Too much surface area before core flow is verified; UI work is wasted if protocol doesn't work

## Recommended Approach

**Approach A.** Build a SwiftPM executable target (`SimulatorCameraServer`) that:

1. Takes a video file path as argument
2. Reads frames using `AVAssetReader` + `AVAssetReaderTrackOutput`
3. Encodes each frame as JPEG, wraps in SCMF header
4. Sends over TCP on `localhost:9876`
5. Loops the video when it reaches the end
6. Logs frame count and FPS to stdout

This is a command-line tool, not a GUI app. An AI agent can launch it with `swift run SimulatorCameraServer /path/to/test.mp4`.

## Data Flow

```
+------------------+     SCMF/TCP      +-------------------+
| Mac CLI Server   | ──────────────── | iOS Simulator     |
|                  |   localhost:9876   |                   |
| AVAssetReader    |                   | SimulatorCamera   |
| → JPEG encode    |                   |   Session         |
| → SCMF frame     |                   | → SCMFDecoder     |
| → TCP send       |                   | → _Router         |
|                  |                   | → SimulatorCamera |
| (loops video)    |                   |     Output        |
+------------------+                   | → delegate gets   |
                                       |   CMSampleBuffer  |
                                       +-------------------+
```

## Open Questions

1. **Video format support:** Should we require MP4/H.264, or also handle MOV/HEVC? (Start with MP4 only.)
2. **Frame rate control:** Should the server match the video's native FPS, or target a fixed rate? (Match native, cap at 30.)
3. **Resolution:** Pass through original resolution or downscale? (Pass through; let iOS SDK handle scaling if needed.)
4. **Bundled test video:** Should we include a sample video in the repo? (Yes -- a 5-second clip with a QR code, a barcode, and a face. Small enough for git.)

## Success Criteria

1. **End-to-end verification:** Run `swift run SimulatorCameraServer test.mp4` on Mac, run iOS demo app in Simulator, see video frames rendered in the app's camera preview view.
2. **Delegate fires:** The iOS app's `captureOutput(_:didOutput:from:)` receives a valid `CMSampleBuffer` with a `CVPixelBuffer` containing the video frame.
3. **AI agent loop:** Claude Code (or equivalent) can launch the server, run the iOS app, take a screenshot, see the video frame in the app, and iterate on camera code without human intervention.
4. **Looping:** Video replays continuously without connection drops.
5. **Performance:** Sustains 15+ FPS on localhost with 720p frames.

## Distribution Plan

- SwiftPM executable target in existing `Package.swift`
- `swift run SimulatorCameraServer /path/to/video.mp4`
- No Homebrew, no .dmg, no signing needed for MVP
- README updated with one-liner usage

## Dependencies

- macOS 13+ with Swift 5.9+ toolchain
- AVFoundation (AVAssetReader) on Mac side
- Existing SimulatorCameraClient iOS SDK (no changes)
- A test video file (MP4, H.264, 720p, 5-10 seconds)

## The Assignment

**Build the SwiftPM CLI server target and verify end-to-end.** Specifically:

1. Add `SimulatorCameraServer` executable target to `Package.swift`
2. Implement `VideoFileSource` that reads MP4 with `AVAssetReader`, outputs `CVPixelBuffer` frames at native FPS
3. Implement `FrameStreamer` that JPEG-encodes and SCMF-wraps frames, sends over TCP
4. Bundle or document a test video
5. Run it. Mac CLI → localhost → iOS Simulator → delegate callback → frame visible in preview. Screenshot proof.

Do not build UI. Do not add features. Verify the core promise works.

## What I Noticed

- Ruslan's sharpest insight was not about camera testing but about **AI agents being blind.** The positioning should lead with "unblock agentic iOS development" not "test your camera in Simulator."
- The project has strong infrastructure (protocol, shim, router, tests) but zero end-to-end verification. This is the single biggest risk and the single most important next step.
- The "donations only" business model may be premature. If this genuinely unblocks agentic development for camera apps, there's a real business in developer tooling (think: Proxyman, Charles Proxy, Reveal pricing models). Worth revisiting after dogfooding.
- The AVCaptureSession shim approach (subclassing AVCaptureVideoDataOutput) is clever and differentiated. Most attempts at this would wrap or mock; this one passes `self` as a real AV output. That's a technical moat worth protecting.

---

## NOT in Scope

- Live webcam streaming (post-MVP)
- Screen region capture (post-MVP)
- SwiftUI Mac companion app with GUI (post-MVP)
- Audio track support (v0.3 roadmap)
- Homebrew distribution of CLI tool (post-verification)
- Multiple simultaneous video sources (post-MVP)
- Frame rate adjustment UI (post-MVP)

---

## Implementation Plan

### Step 1: Add CLI executable target to Package.swift
- **Files:** `Package.swift`, `Sources/SimulatorCameraServer/main.swift`
- **What:** Add `.executableTarget(name: "SimulatorCameraServer")` with dependencies on `AVFoundation`, `Network`, `CoreMedia`, `CoreVideo`, `ImageIO`
- **Effort:** 15 min

### Step 2: Implement VideoFileSource
- **Files:** `Sources/SimulatorCameraServer/VideoFileSource.swift`
- **What:** `AVAssetReader` + `AVAssetReaderTrackOutput` reads video file, outputs `CVPixelBuffer` at native frame rate, loops on completion
- **Effort:** 1-2 hrs

### Step 3: Implement SCMF encoder + TCP server
- **Files:** `Sources/SimulatorCameraServer/SCMFEncoder.swift`, `Sources/SimulatorCameraServer/TCPServer.swift`
- **What:** JPEG-encode `CVPixelBuffer`, prepend SCMF header (magic + length + timestamp + width + height), accept TCP connection on port 9876, send frames
- **Effort:** 1-2 hrs

### Step 4: Wire up main.swift
- **Files:** `Sources/SimulatorCameraServer/main.swift`
- **What:** Parse CLI args (video path, optional port), create VideoFileSource, connect to TCPServer, start streaming, log FPS to stdout
- **Effort:** 30 min

### Step 5: Create or source test video
- **Files:** `assets/test-qr.mp4` or documented URL
- **What:** 5-10 second 720p video containing a QR code, a barcode, or a face. Must be small enough for git (<2MB) or documented download.
- **Effort:** 15 min

### Step 6: End-to-end verification on Mac
- **What:** `swift build`, `swift run SimulatorCameraServer assets/test-qr.mp4`, boot iPhone Simulator, run iOS demo app, confirm frames land in delegate, screenshot proof
- **Effort:** 30 min - 1 hr (debugging time)

### Step 7: Update README with CLI usage
- **Files:** `README.md`
- **What:** Add "Quick Start (CLI)" section showing one-liner server launch + iOS demo
- **Effort:** 15 min

### Test Coverage

```
[TESTED]  SCMF codec encode/decode (SCMFCodecTests.swift)
[TESTED]  AVCaptureSession shim wiring (ShimTests.swift)
[TESTED]  Router subscribe/unsubscribe (ShimTests.swift)
[TESTED]  SimulatorCameraOutput delivers to delegate (ShimTests.swift)
[GAP]     VideoFileSource reads MP4 and outputs CVPixelBuffer
[GAP]     SCMFEncoder produces valid SCMF frames
[GAP]     TCPServer accepts connection and sends data
[GAP]     End-to-end: server → network → iOS SDK → delegate
```

### Failure Modes

| Codepath | Failure scenario | Covered? |
|----------|-----------------|----------|
| AVAssetReader | Video file is corrupt or unsupported codec | Error logged, no crash |
| TCP bind | Port 9876 already in use | Error message, suggest alternative port |
| TCP connection | iOS app not running when server starts | Server waits for connection, retries |
| SCMF decode | Malformed frame header | SCMFDecoder returns nil, frame skipped |
| Video loop | AVAssetReader cannot re-read after completion | Recreate reader on loop |
| Memory | Large video frames accumulate in TCP buffer | Back-pressure or frame drop |
