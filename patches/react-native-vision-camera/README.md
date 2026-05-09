# Patch: `react-native-vision-camera` for SimulatorCamera

`react-native-vision-camera` versions `< 5.0` had hard-coded simulator
guards that disabled camera permission requests and short-circuited the
preview view. With SimulatorCamera active, the iOS Simulator does have a
camera (our virtual camera), so the guards prevent users from seeing the
SimCam virtual feed.

## Versions that need patching

| Version    | Needs patch? | Notes                                                  |
| ---------- | ------------ | ------------------------------------------------------ |
| `< 5.0`    | Yes          | Camera class returns nil on simulator                  |
| `>= 5.0`   | No           | Library passes through to AVFoundation                 |

## How the bypass looks

Older versions of `CameraView.swift` or `CameraViewManager.swift` have:

```swift
public static func getAvailableCameraDevices() -> [AVCaptureDevice] {
#if targetEnvironment(simulator)
    return []   // <-- the bypass
#else
    return AVCaptureDevice.DiscoverySession(...).devices
#endif
}
```

After patching: remove the `#if`/`#endif` so the discovery session always
runs, and the simulator returns whatever AVFoundation reports (which now
includes "SimulatorCamera Virtual" if our extension is active).

## Apply via patch-package

Same pattern as `expo-camera`:

```bash
npm install --save-dev patch-package postinstall-postinstall
# add postinstall script to package.json
cp .../patches/react-native-vision-camera/react-native-vision-camera+VERSION.patch \
   your-app/patches/
npm install
```

## Frame processor compatibility

Vision Camera's frame processors (Vision API, ML Kit) work the same way
regardless of source — they receive `CMSampleBuffer` from AVFoundation,
which our virtual camera produces normally. No special setup required.

## Verification

After patching:

```bash
# In your iOS app on Simulator:
# 1. SimulatorCamera Extension active, source = QR code with payload "TEST"
# 2. Vision Camera preview should show the QR
# 3. Frame processor / barcode scanner should detect "TEST"
```

## Upstreaming

A PR removing the simulator guard was merged to react-native-vision-camera
in v5.0. Versions < 5.0 are EOL and won't get the upstream fix; this patch
is for projects that haven't upgraded yet.
