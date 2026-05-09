# SimulatorCamera

> Your Mac's camera, in the iOS Simulator. Free and open.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](#install)
[![Xcode 16+](https://img.shields.io/badge/Xcode-16%2B-blue.svg)](#install)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/dautovri/SimulatorCamera?include_prereleases&label=release)](../../releases)
[![Sponsor](https://img.shields.io/github/sponsors/dautovri?label=Sponsor&logo=github-sponsors)](https://github.com/sponsors/dautovri)

The iOS Simulator has never had a real camera. `AVCaptureDevice` returns
nil. Every app that touches the camera — QR scanners, barcode readers,
document capture, ML pipelines, AR prototypes, video calling — either
stubs the camera path, runs only on physical devices, or ships a brittle
"use a photo instead" fallback.

**SimulatorCamera registers a virtual camera at the macOS system level**
using Apple's `CMIOExtension` API. The iOS Simulator (Xcode 16+) sees the
virtual camera through standard `AVFoundation`. **Your existing
`AVCaptureSession` code Just Works.** Zero SDK integration. Zero
`Info.plist` changes. Zero `#if targetEnvironment(simulator)` branches.

## What you get

- 🎥 **Mac webcam → iOS Simulator** — your existing app sees frames at 30 FPS, 1280×720
- 🎬 **Video file source** — drop in any MP4 / MOV / HEVC, loops cleanly
- 🖼 **Static image source** — pick a PNG / JPG, becomes the camera feed
- 🔲 **QR code generator** — programmatic QR for scanner testing
- 🌈 **Test pattern** — built-in colorbar / scrolling stripe, always available
- 🤖 **`simcamctl` CLI** — `simcamctl set-source --qr "TOKEN"` for CI / AI agents
- 🛡 **Zero SDK** — your iOS app code does not import or link anything from this project
- 📵 **Zero device required** — runs entirely in the iOS Simulator
- 🆓 **Free, MIT-licensed, open source** — fork it, ship it, sell it, no fees

## Demo

[hero GIF lands here in v1.0.0 release]

## 60-second install

**1. Install the Mac companion app:**

```bash
brew install --cask dautovri/tap/simulatorcamera
open -a SimulatorCamera
```

**2. Click Activate, then click Allow when System Settings prompts.**

That's it. No Xcode integration, no `Info.plist` changes, no `#if`
guards anywhere in your code.

**3. Run any iOS Simulator app that uses the camera.** Open it in Xcode
16+, run on a Simulator, and `AVCaptureDevice.default(for: .video)`
returns "SimulatorCamera Virtual."

```swift
// This — yes, exactly this — works in the iOS Simulator now:
let session = AVCaptureSession()
let device = AVCaptureDevice.default(for: .video)!
let input = try AVCaptureDeviceInput(device: device)
session.addInput(input)
session.startRunning()
// frames flow through your existing AVCaptureVideoDataOutput delegates
```

## Picking a source

Open the SimulatorCamera Mac app:

| Source             | Use case                                                   |
| ------------------ | ---------------------------------------------------------- |
| **Test Pattern**   | Default. Confirms wiring works. No permissions, no setup.  |
| **Mac Camera**     | Live webcam (built-in or external). First use prompts for camera access. |
| **Video File**     | Pre-recorded scenarios. Loops at EOF. Honors orientation metadata. |
| **Static Image**   | Pin a frame for visual UI tests. Same image, fresh timestamps. |
| **QR Code**        | Programmatic QR for scanner / payment-flow tests.          |

## Driving from the command line

`simcamctl` is bundled with the app and can be symlinked into `$PATH`:

```bash
ln -s /Applications/SimulatorCamera.app/Contents/MacOS/simcamctl /usr/local/bin/simcamctl

simcamctl ping
# extension pid=12345 bundle=com.dautov.SimulatorCamera.Extension

simcamctl set-source --qr "https://example.com/auth?token=ABC123"
# QR pushed (40 chars, 3686 KB)

simcamctl set-source --image ./test-fixtures/receipt.png
# image pushed: receipt.png (1280x720)

simcamctl status
# active source:    QR code
# connected clients:1
# last frame ts:    1714159823.412s
# stream running:   yes
```

Useful for:

- CI scripts that run `xcodebuild test` against scanner / vision flows
- AI agents that need to feed deterministic test fixtures into UI tests
- Manual QA scripts that walk through `simcamctl set-source --image fixture-N.png`

## React Native / Expo / WebRTC apps

Some popular libraries hard-code `#if targetEnvironment(simulator)` to
disable camera entirely. With SimulatorCamera the simulator does have a
camera, so those guards prevent the virtual feed from reaching your app.

We ship `patch-package`-compatible patches for known libraries:

| Library                              | Versions that may need patching | Patch                                              |
| ------------------------------------ | ------------------------------- | -------------------------------------------------- |
| `expo-camera`                        | `<55.0.11`                      | [patches/expo-camera/](./patches/expo-camera/)     |
| `react-native-vision-camera`         | `<5.0`                          | [patches/react-native-vision-camera/](./patches/react-native-vision-camera/) |
| `react-native-webrtc`                | all                             | [patches/react-native-webrtc/](./patches/react-native-webrtc/) |
| `@fishjam-cloud/react-native-webrtc` | all                             | [patches/fishjam-react-native-webrtc/](./patches/fishjam-react-native-webrtc/) |

## Architecture

```
SimulatorCamera.app  (container)
   ↓ XPC
.app/Contents/Library/SystemExtensions/
   SimulatorCameraExtension.systemextension
   ↓ CMIOExtensionStream.send
macOS CoreMediaIO subsystem
   ↓ host AVFoundation
iOS Simulator process
   ↓ AVCaptureDevice.default(for: .video)
   "SimulatorCamera Virtual"  ← your app
```

Full diagrams in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Why this exists

[Software Mansion](https://swmansion.com/) shipped [SimCam][simcam] in
March 2026 — the same architecture as a polished commercial product
($19 lifetime). SimulatorCamera is the free, open-source alternative for
people who'd rather pay $0 and have the source. Both projects exist
because Apple has not (yet) shipped first-party simulator camera
support; both rely on Apple's public `CMIOExtension` API.

If you're after polished commercial support, buy SimCam — Software
Mansion deserves it. If you'd rather contribute fixes back instead of
opening tickets, you're in the right repo.

[simcam]: https://simcam.swmansion.com

## Roadmap

This is **Act 1 of the iOS Simulator's missing sensor layer.**

- **v1.0** *(now)* — virtual camera, 5 sources, CLI, library patches
- **v1.1** — IOSurface zero-copy frames (1080p/60fps), front/back camera switch, video pause/scrub
- **v1.2** — scenario DSL: `simcamctl scenario play receipt-then-qr.json` for `xcodebuild test` integration
- **v2.0** — microphone passthrough (same architecture, different sensor)
- **vN** — BLE peripheral simulation, motion sensors, LiDAR — every sensor the iPhone has, simulated

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Good first issues are labelled on the tracker.
For release mechanics, see [RELEASING.md](RELEASING.md).

## Sponsor

SimulatorCamera is fully MIT-licensed and maintained on donations. If it
saves you a device-build loop, consider
[sponsoring](https://github.com/sponsors/dautovri) or
[buying a coffee](https://www.buymeacoffee.com/dautovri).

## License

MIT — see [LICENSE](LICENSE).
