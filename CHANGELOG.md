# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Extension no longer crashes on malformed frames.** `SimCamFrame` is validated
  on decode and again before any byte is copied (dimensions, stride, payload
  length, pixel format, finite timestamp). Previously a short payload or a
  negative height was an out-of-bounds `memcpy` / integer trap inside the
  camera extension.
- **Injected frames now match the advertised format.** The extension advertised
  1920x1080@60 but every container source produced 1280x720, so
  `CMSampleBufferCreateForImageBuffer` failed for each pushed frame. The whole
  pipeline now uses one canonical geometry (`kSimCamFrameWidth/Height/Rate`)
  and the extension rejects anything else with a clear log line.
- **Test-pattern timer leak.** Each CMIO client that started streaming created
  a new timer without cancelling the previous one; orphaned timers kept emitting
  at full rate forever. Only the first client creates the timer now.
- **Host-clock timestamps.** Pushed frames were stamped with source-relative
  seconds (often near zero, sometimes negative → `UInt64` trap). The extension
  now stamps every outgoing sample with the host clock.
- **Mach service name is app-group scoped.** `<TeamID>.com.dautov.SimulatorCamera.xpc`
  (derived from the running binary's code signature) instead of a bare name the
  sandbox would refuse to look up.
- **XPC client recovers on its own.** Interruptions re-ping and invalidations
  reconnect with capped backoff instead of dropping the connection until the
  user clicks "Run Diagnostics". Frames are dropped, not queued, when more than
  two are in flight so a slow extension can't balloon memory.
- **Source switching is race-free.** Rapid switches are serialized by a
  generation counter; a camera that finishes warming up after a newer switch is
  stopped instead of leaking. The extension is told about the new source only
  once frames are actually flowing.
- **Video file source** cancels its reader on stop, stops instead of spinning on
  unreadable files, clamps negative PTS, and paces against the wall clock.
- **Mac camera source** honours a `stop()` that lands while the session is still
  starting, so the camera light always goes off.
- `simcamctl status` now reports real `stream running` and `connected clients`
  values; every CLI round-trip has a 5 s timeout.
- Extension state is queried at launch (`propertiesRequest`) so a relaunched
  app shows "Active" instead of "Not checked". Leftover activation diagnostics
  that wrote files into `~/Library/Logs` are gone.

### Added
- The extension only accepts XPC peers signed by the same team as itself
  (`setCodeSigningRequirement`). Unsigned dev builds are unaffected.
- `SimulatorCameraTests`: 19 logic tests for the wire contract, secure-coding
  round trips, raster helpers and QR rendering. CI runs them.
- Delivery counters in the UI (frames dropped / rejected) to tell "no camera
  client is streaming" apart from "the extension is busy".

### Changed
- Virtual camera format is 1280x720 BGRA @ 30 fps (was 1920x1080 @ 60 with
  1280x720 payloads that never rendered).
- Image, QR and simcamctl share one rasterizer (`FrameRaster`, `QRRenderer`).

## [1.0.0] — 2026-04-26

**Architectural rewrite.** v1.0.0 abandons the v0.x TCP/SDK approach in
favor of Apple's `CMIOExtension` system extension. The iOS Simulator
(Xcode 16+) sees a real virtual camera through standard `AVFoundation`.
**No SDK to import. No `Info.plist` key required in your app. No
`#if targetEnvironment(simulator)` branches.**

### Added
- **macOS Camera Extension** (`SimulatorCameraExtension.systemextension`)
  bundled inside the container app, registers as "SimulatorCamera Virtual"
  in `AVCaptureDevice.devices(for: .video)`.
- **Container app** (`SimulatorCamera.app`) submits
  `OSSystemExtensionRequest` activation, hosts SwiftUI source picker,
  pumps frames into the extension over XPC.
- **Five frame sources:**
  - Test pattern (built into extension; works with no setup)
  - Mac webcam (`AVCaptureSession` on host)
  - Video file (`AVAssetReader`, MP4/MOV/HEVC, loops at EOF)
  - Static image (PNG/JPG, letterboxed to 1280x720)
  - QR code generator (any UTF-8 string)
- **`simcamctl` CLI** — `simcamctl set-source --qr "..."`,
  `--image PATH`, `--pattern`, `status`, `ping`. Useful for AI agents
  + CI that need deterministic frame fixtures.
- **`patches/` directory** — `patch-package`-compatible patches for
  `expo-camera < 55.0.11`, `react-native-vision-camera < 5.0`,
  `react-native-webrtc`, `@fishjam-cloud/react-native-webrtc`. These
  libraries hard-code `#if targetEnvironment(simulator)` to disable the
  camera; we patch around the guard.
- **XcodeGen project** (`project.yml`) — Xcode project regenerable from
  YAML, suitable for `git diff`-friendly review.
- **Run Diagnostics UI** in container app — XPC connection state,
  extension activation state, frame counter.

### Changed
- **Tagline:** "Stream a real camera into the iOS Simulator" → "Your
  Mac's camera, in the iOS Simulator. Free and open." Positions
  SimulatorCamera as Act 1 of the Simulator's missing sensor layer
  (microphone, BLE, motion, LiDAR coming in v2+).
- **Min macOS:** 13.0 (Ventura) → 14.0 (Sonoma) for `@Observable` +
  `@Environment(.self)` SwiftUI APIs.
- **Distribution:** arm64-only. Intel Macs not supported in v1.x.
- **Bundle ID:** `com.simulatorcamera.server` →
  `com.dautov.SimulatorCamera` (container) +
  `com.dautov.SimulatorCamera.Extension` (system extension).

### Removed
- **Entire iOS SDK** (`SimulatorCameraClient` Swift Package). The new
  architecture requires zero iOS SDK; user apps go through
  `AVFoundation` unchanged.
- **TCP server** (`SimulatorCameraServer` CLI). Replaced by the system
  extension's XPC interface.
- **SCMF wire protocol.** Frames now flow through Apple's
  `CMIOExtensionStream` infrastructure.
- **`SimulatorCameraSession`, `SimulatorCameraPreviewView`, `SimulatorCameraView`,
  `SimulatorCaptureSession`, `SimulatorCameraOutput`** — all v0.x SDK types
  gone. User code that imported `SimulatorCameraClient` must drop the
  import; the camera "just works" through standard AVFoundation.
- **iOS demo app** (`apps/iOSDemo/`). With no SDK, no demo is needed —
  any iOS Simulator app that uses `AVCaptureDevice` IS the demo.
- **`NSLocalNetworkUsageDescription` requirement.** No more local
  network — XPC is in-process to the system extension.
- **SwiftPM `Package.swift`.** System extensions cannot be built by
  SwiftPM; the project is now Xcode-managed (XcodeGen → .xcodeproj).

### Migration from v0.2.x

If you were on v0.2.x, the upgrade is structural:

1. `brew upgrade --cask simulatorcamera` (cask now points at the new app)
2. Open SimulatorCamera, click Activate, click Allow in System Settings
3. **Remove `SimulatorCameraClient` from your iOS app's Package.swift**
4. **Remove all `import SimulatorCameraClient` lines from your code**
5. **Remove the `NSLocalNetworkUsageDescription` Info.plist key** (was
   the v0.2 silent-failure gotcha; no longer needed)
6. **Remove the `SimulatorCameraSession` / `SimulatorCameraView` /
   `SimulatorCaptureSession` usage** — your existing
   `AVCaptureSession`-based code is now the path.

Net effect: the migration deletes code from your app rather than adding it.

## [0.2.0] — 2026-04-15

### Added
- **Full `AVCaptureSession` drop-in shim.** New `SimulatorCaptureSession`, `SimulatorCaptureDevice`, `SimulatorCaptureDeviceInput` types let existing camera-setup code port by prefixing each AVFoundation type with `Simulator`.
- `SimulatorCamera` top-level facade (`configure(host:port:)`, `start()`, `stop()`, `isActive`) — one entry point for the whole SDK.
- Internal `_Router` fan-out: a single network session drives N `SimulatorCameraOutput` / preview sinks.
- **Mac Camera source** in the companion app (`AVCaptureDevice.default(for: .video)`) — pick between video file and live Mac webcam from the server UI.
- Homebrew cask formula + tap instructions for one-line install of the Mac companion app.
- `scripts/build-release.sh` — archive, codesign, notarize, staple, and package the Mac app as both `.dmg` and `.zip`.
- `.github/workflows/release.yml` — tag-driven release: builds artifacts, drafts GitHub Release, uploads the `.dmg` and `.zip`.
- `RELEASING.md` runbook.
- `FUNDING.yml` for GitHub Sponsors / Buy Me a Coffee.

### Changed
- README: Homebrew install path, donation badge, v0.2 feature matrix, new "Full AVCaptureSession drop-in" usage block.
- Package is stable on iOS 16 / macOS 13; no source-breaking changes from 0.1.0 — existing `SimulatorCameraSession` / `SimulatorCameraOutput` code compiles unchanged.

### Fixed
- `SimulatorCameraOutput`: replaced broken `objc_setAssociatedObject(_, String, …)` wiring with a typed `routerToken` — package now compiles cleanly.

## [0.1.0] — 2026-04-14

First public alpha.

### Added
- Monorepo layout with root SwiftPM `Package.swift`.
- `FrameSource` protocol + `SimulatorCameraSession` + `SimulatorCameraPreviewView`.
- Reference SCMF codec and stream decoder.
- Mac companion app with test-pattern source.
- iOS demo app with Vision rectangle-detection hook.
- Protocol spec ([docs/PROTOCOL.md](docs/PROTOCOL.md)), architecture overview, roadmap.
