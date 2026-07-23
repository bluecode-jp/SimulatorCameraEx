# Architecture

SimulatorCamera registers a **virtual camera at the macOS system level**
using Apple's `CMIOExtension` API. The iOS Simulator picks it up through
standard `AVFoundation`, exactly as it would a physical webcam.

There is **no iOS SDK and no Swift Package.** Your app links nothing.

## Components

```
┌──────────────────────────────────────────────────────────────┐
│  SimulatorCamera.app  (container, macOS 14+)                 │
│                                                              │
│   MainView / SourceManager      ← SwiftUI source picker      │
│   ExtensionController           ← OSSystemExtensionRequest    │
│   XPCClient ──────────────┐                                  │
│   FrameSource impls:      │                                  │
│     MacCameraSource       │                                  │
│     VideoFileSource       │                                  │
│     ImageSource           │                                  │
│     QRSource              │                                  │
└───────────────────────────┼──────────────────────────────────┘
                            │ XPC  (Shared/XPCContract.swift)
                            ▼
┌──────────────────────────────────────────────────────────────┐
│  SimulatorCameraExtension.systemextension                    │
│  (bundled at .app/Contents/Library/SystemExtensions/)        │
│                                                              │
│   XPCListener               ← receives frames + source cmds  │
│   SimulatorCameraProvider   ← CMIOExtensionDeviceSource      │
│                               CMIOExtensionStreamSource      │
└───────────────────────────┬──────────────────────────────────┘
                            │ CMIOExtensionStream.send
                            ▼
              macOS CoreMediaIO subsystem
                            │
                            ▼ host AVFoundation
              ┌───────────────────────────────┐
              │  iOS Simulator process        │
              │  AVCaptureDevice.default(...) │
              │  → "SimulatorCamera Virtual"  │
              └───────────────────────────────┘
```

`simcamctl` is a separate CLI target that speaks the same XPC contract
(`simcamctl/SimCamCLIClient.swift`), so CI scripts and agents can drive
the source selection without the GUI.

## Process model

| Process | Role | Lifetime |
| --- | --- | --- |
| `SimulatorCamera.app` | UI, frame production, activation requests | User-controlled |
| `SimulatorCameraExtension` | Virtual camera device + stream | Managed by `systemextensionsd` |
| `simcamctl` | Scripted control | Per-invocation |

The extension runs **outside** the app. It keeps serving the last pushed
frame even when the container app is closed, because CoreMediaIO owns its
lifecycle — not the app.

## Activation

`ExtensionController` submits an `OSSystemExtensionRequest.activationRequest`.
macOS prompts the user to approve in System Settings → General → Login Items
& Extensions. This approval is required once per machine, and is why the app
must be **signed, notarized, and installed in `/Applications`** — system
extensions are refused from arbitrary locations.

## Frame path

1. A `FrameSource` produces a `CVPixelBuffer` (1280×720, 30 FPS).
2. The container app sends it over XPC to the extension.
3. `SimulatorCameraProvider` wraps it in a `CMSampleBuffer` and calls
   `CMIOExtensionStream.send`.
4. CoreMediaIO delivers it to every host client — including the Simulator.

Frames are currently copied across the XPC boundary. IOSurface-backed
zero-copy is the v1.1 target (see the roadmap in the [README](../README.md#roadmap)).

## Why a system extension, not a TCP server + SDK?

v0.2.x used a localhost TCP server and an iOS SDK the app had to import.
That required source changes in every consuming app (`import
SimulatorCameraClient`, type substitutions, `#if targetEnvironment(simulator)`
guards). The `CMIOExtension` approach needs **none** of that: the Simulator
sees a real `AVCaptureDevice`, so unmodified `AVCaptureSession` code works.

The retired design is preserved in [DESIGN.md](../DESIGN.md) and
[PROTOCOL.md](PROTOCOL.md) for reference.

## Failure modes

| Symptom | Likely cause |
| --- | --- |
| Camera missing in Simulator | Extension not approved. Check System Settings → General → Login Items & Extensions. |
| Activation prompt never appears | App is not in `/Applications`, or the build is unsigned. |
| `simcamctl ping` fails | Extension not running. Launch the container app once to activate it. |
| Simulator shows black frames | No source selected, or the source failed to start — check the app's source picker. |
| Camera works in Photo Booth but not the Simulator | Requires Xcode 16+; older Simulator runtimes don't enumerate host virtual cameras. |
