# Patch: `expo-camera` for SimulatorCamera

`expo-camera` versions `< 55.0.11` short-circuit the camera path on iOS
Simulator, returning an empty device list and never calling
`AVCaptureSession.startRunning()`. SimulatorCamera registers a real
virtual camera, so the simulator-bypass is no longer needed.

## Versions that need patching

| Version       | Needs patch? | Notes                                                  |
| ------------- | ------------ | ------------------------------------------------------ |
| `< 55.0.11`   | Yes          | `#if TARGET_IPHONE_SIMULATOR` guard in CameraView      |
| `>= 55.0.11`  | No           | Library now calls AVFoundation unconditionally         |

## How the bypass looks

The library has (or had) Objective-C / Swift guards similar to:

```objc
// CameraView.m / CameraViewManager.m
- (void)startRunning {
#if TARGET_IPHONE_SIMULATOR
    // Camera unavailable in simulator; skip.
    return;
#endif
    [self.captureSession startRunning];
}
```

After patching:

```objc
- (void)startRunning {
    [self.captureSession startRunning];
}
```

## Apply via patch-package

1. Install `patch-package` if not already in your project:
   ```bash
   npm install --save-dev patch-package postinstall-postinstall
   ```
2. Add to `package.json`:
   ```json
   "scripts": { "postinstall": "patch-package" }
   ```
3. Drop the `.patch` file from this directory into your project's
   `patches/` directory.
4. Run `npm install` (or just `npx patch-package`). The patch applies on
   next install.
5. Rebuild the iOS app. With SimulatorCamera active, the iOS Simulator now
   sees the virtual camera through expo-camera's AVFoundation path.

## Verification

After patching:

```bash
# In your app's iOS Simulator session:
# 1. Activate SimulatorCamera, pick a source.
# 2. Run the expo-camera example/playground app.
# 3. Camera preview should show your selected source.
```

If preview is still blank, run `simcamctl status` to confirm the
extension is active and a frame was recently pushed.

## Upstreaming

We track upstream PRs that remove these guards in
[issues.md](./issues.md). Please open an upstream PR if you maintain a
library that has these guards — it benefits all users on Xcode 16+.
