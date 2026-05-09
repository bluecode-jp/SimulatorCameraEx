# Library patches for SimulatorCamera

SimulatorCamera registers a virtual camera at the macOS system level via
`CMIOExtension`. The iOS Simulator (Xcode 16+) sees host AVFoundation
devices, so any iOS app code that goes through `AVCaptureDevice` works
unchanged.

**However**, some popular iOS camera libraries have hard-coded
`#if targetEnvironment(simulator)` (or the ObjC equivalent
`#if TARGET_IPHONE_SIMULATOR`) guards that disable camera functionality
entirely on the iOS Simulator, regardless of whether a camera is actually
available. These libraries assumed (correctly until SimCam and
SimulatorCamera came along) that no camera could ever exist in the
simulator.

This directory documents how to patch the libraries we know about. We
work with library maintainers to remove these checks upstream; older
versions still need patching. The patches use [`patch-package`][patch-package]
which most React Native projects already have in their dev toolchain.

## Apply a patch

```bash
# In your iOS project root:
npm install --save-dev patch-package postinstall-postinstall
# then add postinstall script to package.json:
#   "scripts": { "postinstall": "patch-package" }

# Copy the relevant .patch file from this directory to your-project/patches/
# Then on next `npm install`, patch-package applies it automatically.
```

## Libraries

| Library                              | Versions that may need patching | Subdirectory                                           |
| ------------------------------------ | ------------------------------- | ------------------------------------------------------ |
| `expo-camera`                        | `<55.0.11`                      | [`expo-camera/`](./expo-camera/)                       |
| `react-native-vision-camera`         | `<5.0`                          | [`react-native-vision-camera/`](./react-native-vision-camera/) |
| `react-native-webrtc`                | all (as of 2026-04)             | [`react-native-webrtc/`](./react-native-webrtc/)       |
| `@fishjam-cloud/react-native-webrtc` | all                             | [`fishjam-react-native-webrtc/`](./fishjam-react-native-webrtc/) |

## Reporting a new library that needs patching

If you find a camera library that doesn't work with SimulatorCamera in
the iOS Simulator and adding the patches above doesn't fix it, please open
an issue. Include:

- Library name + version
- The exact failure (no preview? black frames? crash on init?)
- A minimal reproducer if possible

We prioritize documenting common libraries here together with
patch-package–compatible diffs.

## Why these patches are tiny

Almost all of these libraries have the same shape of fix: remove a
preprocessor guard or an early-return in a few lines of native code so
that AVFoundation gets called normally. The simulator camera then "just
works" because the host's CoreMediaIO subsystem hands our virtual camera
to AVFoundation requests inside the simulator process.

[patch-package]: https://github.com/ds300/patch-package
