# SimulatorCamera v0.2.0 — "Use my real camera"

> ⚠️ **Historical release notes — do not follow these instructions.**
> v0.2.x used a TCP server + iOS SDK (`SimulatorCameraClient`) distributed
> via SwiftPM. That architecture was **removed in v1.0.0**. There is no
> `Package.swift`, and **SimulatorCamera cannot be installed via SPM,
> CocoaPods, or Carthage.** It is now a macOS system extension, built and
> signed from source — your iOS app links nothing. Neither the SwiftPM
> snippet nor the `brew` command below works: **v0.2.0 was never tagged
> and no release was ever published.** See the
> [README](../README.md#install) for current install steps and
> [CHANGELOG.md](../CHANGELOG.md) for the migration path. Kept for
> historical reference only.

*Released 2026-04-15*

This is the first release that lets you point an existing `AVCaptureSession`-shaped codebase at a live Mac webcam with a one-for-one type substitution — no branches, no stubs, no cables.

## Highlights

**Drop-in `AVCaptureSession` shim.** Rename `AVCaptureSession` → `SimulatorCaptureSession`, `AVCaptureDevice` → `SimulatorCaptureDevice`, `AVCaptureDeviceInput` → `SimulatorCaptureDeviceInput`, `AVCaptureVideoDataOutput` → `SimulatorCameraOutput`. Your `AVCaptureVideoDataOutputSampleBufferDelegate` fires unchanged with a real `CMSampleBuffer`.

**Live Mac camera source.** The companion app now has a Source picker — **Video File** or **Mac Camera**. Webcam frames go out over localhost TCP at up to 30 FPS.

**One-line install.**

```
# ⚠️ DOES NOT WORK — no cask was ever published to the tap.
brew install --cask dautovri/tap/simulatorcamera
```

And in Swift:

```swift
// ⚠️ DOES NOT WORK — the 0.2.0 tag was never pushed, so SwiftPM cannot
// resolve this. The package itself was removed in v1.0.0.
dependencies: [
    .package(url: "https://github.com/dautovri/SimulatorCamera.git", from: "0.2.0"),
]
```

## What's in it

- `SimulatorCamera` top-level facade (`configure`, `start`, `stop`, `isActive`).
- Single shared `_Router` — one TCP connection feeds any number of outputs and preview views.
- Mac Camera reader (`AVCaptureDevice.default(for: .video)`) wired into the server UI.
- Signed + notarized `.dmg` and `.zip` via `scripts/build-release.sh`.
- Tag-driven GitHub Actions release pipeline.
- Homebrew cask formula in [`Casks/simulatorcamera.rb`](../Casks/simulatorcamera.rb).

## Breaking changes

None. 0.1.0 code compiles against 0.2.0 unchanged.

## Bug fixes

- Fixed a compile error in `SimulatorCameraOutput` (`objc_setAssociatedObject` key type).

## Upgrading

1. Bump your package requirement to `from: "0.2.0"`.
2. (Optional) swap your `#if targetEnvironment(simulator)` camera stub for the `SimulatorCaptureSession` flow — see README.
3. Install the new Mac app: `brew upgrade --cask simulatorcamera`, or grab the `.dmg` from the Release page.

## What's next (v0.3)

HEVC codec, audio track, front/back camera switch, Obj-C-callable headers, CocoaPods/Carthage distribution. See [ROADMAP.md](ROADMAP.md).

## Thanks

SimulatorCamera is fully MIT-licensed and donation-funded. If it saves you time, consider [sponsoring the project](https://github.com/sponsors/dautovri).
