# Patch: `react-native-webrtc` for SimulatorCamera

`react-native-webrtc` wraps Google's WebRTC stack. WebRTC's iOS
implementation has long had a simulator-bypass for the
`AVCaptureDevice`-driven video source: when running in the simulator,
the video track produces zero frames and remote peers receive nothing.

With SimulatorCamera providing a real virtual camera, WebRTC's bypass is
no longer needed; we want the camera path to behave exactly as on device.

## Status

All versions of `react-native-webrtc` (as of 2026-04) require this patch
when used with SimulatorCamera. Upstream WebRTC has the simulator-bypass
deeply embedded; the workaround applies at the React Native bridge layer.

## How the bypass looks

The library's `RTCCameraVideoCapturer` subclass or its bridge layer
contains:

```swift
override func startCapture(...) {
#if targetEnvironment(simulator)
    completion(NSError(domain: "RTC", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "Camera unavailable in simulator"
    ]))
    return
#endif
    super.startCapture(...)
}
```

After patching: remove the `#if`/`#endif` so `super.startCapture(...)`
always runs.

## Codec note: hardware H.264 encoder

WebRTC's hardware H.264 encoder path doesn't run in the iOS Simulator
even with SimulatorCamera providing frames. Workaround: force a software
codec for simulator builds:

```javascript
const peerConnection = new RTCPeerConnection({
    sdpSemantics: 'unified-plan',
    // For simulator runs, prefer VP8 or software H.264:
    encodedInsertableStreams: false,
});

// Set codec preference at offer time
const transceiver = peerConnection.addTransceiver('video');
const capabilities = RTCRtpSender.getCapabilities('video');
const preferredCodecs = capabilities.codecs.filter(c =>
    c.mimeType === 'video/VP8'
    || (c.mimeType === 'video/H264' && c.sdpFmtpLine?.includes('packetization-mode=1'))
);
transceiver.setCodecPreferences(preferredCodecs);
```

## Apply via patch-package

```bash
npm install --save-dev patch-package postinstall-postinstall
cp .../patches/react-native-webrtc/react-native-webrtc+VERSION.patch \
   your-app/patches/
npm install
```

## Verification

After patching:

1. Two iOS Simulators (or one Sim + one device) connected to a WebRTC
   signaling server.
2. SimulatorCamera Extension active on the host Mac, source = QR or video.
3. The simulator's WebRTC `MediaStream` should carry video to the remote
   peer.
4. If video is still blank: check that `getUserMedia({ video: true })`
   returned a non-empty MediaStream. If it errored with "no video
   device", the patch wasn't applied.

## Why upstream isn't fixed

WebRTC is upstream-of-upstream — the Google project's iOS support
pre-dates SimulatorCamera-style virtual cameras. Until Google removes
the bypass at the WebRTC level, every fork (including the React Native
binding) needs this patch.
