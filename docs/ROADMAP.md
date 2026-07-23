# Roadmap

SimulatorCamera is **Act 1 of the iOS Simulator's missing sensor layer.**

There is no SwiftPM / CocoaPods / Carthage package, and none is planned:
a macOS system extension cannot be shipped as a linked library. **Public
distribution is still undecided** — see "Open questions" below. Today you
build and sign it yourself; see the [README](../README.md#install).

## v1.0 — current
- Virtual camera via `CMIOExtension`, visible to Xcode 16+ Simulators
- Five sources: test pattern, Mac camera, video file, static image, QR code
- `simcamctl` CLI for CI and agent-driven testing
- `patch-package` patches for RN / Expo / WebRTC libraries that hard-disable
  the simulator camera
- Build-from-source install (bring your own signing team)

## Open questions

**How does this ship to people who won't build it themselves?** macOS
system extensions constrain the options, and each has a cost:

- **Mac App Store** — works for individual developers, but sandbox and
  review constraints need validating against a CMIOExtension.
- **Developer ID + notarized `.dmg` / Homebrew cask** — the nicest
  developer UX, but shipping system extensions this way to non-MDM Macs
  has enrollment requirements worth confirming before promising it.

Until one is settled, the README documents build-from-source only. No
install path is advertised that hasn't actually been published.

## v1.1 — performance & control
- IOSurface zero-copy frames (1080p / 60 FPS)
- Front/back camera switch
- Video pause / scrub

## v1.2 — test integration
- Scenario DSL: `simcamctl scenario play receipt-then-qr.json`
- First-class `xcodebuild test` integration

## v2.0 — beyond video
- Microphone passthrough (same architecture, different sensor)

## Post-2.0 backlog
- BLE peripheral simulation
- Motion sensors, LiDAR
- Visual-regression harness: pipe frames into XCTest screenshot tests
- Android Emulator support

## Retired

The pre-1.0 roadmap targeted a TCP server + iOS SDK with SwiftPM,
CocoaPods, and Carthage distribution. That architecture was removed in
v1.0.0 — see [CHANGELOG.md](../CHANGELOG.md) and [DESIGN.md](../DESIGN.md).
