# Patch: `@fishjam-cloud/react-native-webrtc` for SimulatorCamera

Fishjam Cloud's fork of `react-native-webrtc` inherits the same WebRTC
simulator-bypass as upstream. Apply the same patch shape as
[`react-native-webrtc`](../react-native-webrtc/README.md).

## Status

All versions need this patch when used with SimulatorCamera.

## How the bypass looks

Same Objective-C / Swift pattern as upstream `react-native-webrtc` —
`#if targetEnvironment(simulator)` guards in the camera capturer. The
fork tracks upstream closely; when upstream removes the guard, this
patch will become unnecessary.

## Apply via patch-package

```bash
cp .../patches/fishjam-react-native-webrtc/@fishjam-cloud+react-native-webrtc+VERSION.patch \
   your-app/patches/
npm install
```

## Codec note

Same as upstream: prefer software H.264 or VP8 for simulator runs.
