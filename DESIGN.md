# SimulatorCamera — Design Document

> ⚠️ **Historical (v0.2.x).** This describes the retired TCP + iOS SDK
> architecture. The shipping design is a macOS `CMIOExtension` system
> extension with **no SDK and no SwiftPM package** — see
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Overview

SimulatorCamera is a two-part developer tool that feeds synthetic video frames
to iOS apps running in the Simulator, enabling testing of AVCaptureSession-based
pipelines (Vision, Core ML, ARKit preprocessing) without a physical device.

## Architecture

```
┌─────────────────────────┐         TCP localhost:9876         ┌──────────────────────────────┐
│  macOS Companion App    │ ──────────────────────────────────▶│  iOS SDK (in Simulator)       │
│  SimulatorCameraServer  │         length-prefixed JPEG       │  SimulatorCameraClient        │
│                         │                                    │                                │
│  • NSOpenPanel → file   │                                    │  • Receives frames             │
│  • AVAssetReader decode │                                    │  • Decodes JPEG → CVPixelBuf   │
│  • Mac camera (opt.)    │                                    │  • Delivers via delegate/cb    │
│  • TCP server on :9876  │                                    │  • Mimics AVCapture interface   │
└─────────────────────────┘                                    └──────────────────────────────┘
```

## Streaming Protocol (SCMF v1)

**Transport:** TCP over localhost, port 9876 (configurable).

**Message format (little-endian):**

| Offset | Size  | Field         | Description                                |
|--------|-------|---------------|--------------------------------------------|
| 0      | 4     | magic         | `0x53434D46` ("SCMF")                      |
| 4      | 4     | payloadLength | Total bytes after this header (20 + JPEG)  |
| 8      | 8     | timestamp     | Frame PTS as Float64 seconds               |
| 16     | 4     | width         | Pixel width of the decoded frame            |
| 20     | 4     | height        | Pixel height of the decoded frame           |
| 24     | N     | jpegData      | JPEG-compressed frame bytes                 |

**Total message size:** 24 + N bytes.

### Why this design

- **JPEG compression:** A 1920×1080 BGRA frame is ~8 MB raw. JPEG at quality 0.8
  compresses to ~50–100 KB, making 30 FPS viable over localhost (~3 MB/s).
- **TCP:** Localhost has zero packet loss and sub-millisecond latency. TCP gives
  ordered delivery and flow control without custom reliability logic.
- **Length prefix:** Allows the receiver to read exactly the right number of bytes
  per frame, trivially handling partial reads.
- **Magic bytes:** Guard against connecting to the wrong service.

### Expected latencies

| Stage                    | Time      |
|--------------------------|-----------|
| JPEG encode (server)     | ~1–2 ms   |
| TCP send (localhost)     | <0.5 ms   |
| TCP receive (client)     | <0.5 ms   |
| JPEG decode → CVPixelBuf | ~1–2 ms   |
| **Total overhead**       | **~3–5 ms** |

At 30 FPS (33 ms per frame), the protocol overhead is <15% of frame budget.

### Error handling & reconnect

- The iOS client attempts to connect on `start()`. If the server isn't running,
  it retries every 2 seconds with exponential backoff (max 10 s).
- If the TCP connection drops, the client fires a `.disconnected` state change
  and begins reconnecting automatically.
- The server accepts multiple sequential connections (one active client at a time).

## No-op on Device

The Swift Package uses conditional compilation:
- `#if targetEnvironment(simulator)` → full networking client.
- Otherwise → empty stubs that compile to zero code.

This ensures the SDK has **zero** impact on production App Store builds.
