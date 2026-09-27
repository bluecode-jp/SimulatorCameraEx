// SimCamWebShim.js — injected into every frame of web views in Safari and
// in apps that have SimCamInject loaded (see SimCamWeb.m).
//
// WebKit captures the camera for getUserMedia in its GPU process, which the
// simulator starts without DYLD_INSERT_LIBRARIES, so the fake camera never
// exists there. Instead, getUserMedia's video is served from a canvas that
// shows the SimulatorCamera frames, fetched from the hosting app through the
// "simcamFrame" message handler (base64 JPEG). No permission prompt appears.
(() => {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.simcamFrame;
  const devices = navigator.mediaDevices;
  if (!handler || !devices || devices.__simcam) return;
  Object.defineProperty(devices, '__simcam', { value: true });

  const LABEL = 'SimulatorCamera';
  const DEVICE_ID = 'simulatorcamera';
  // Replaced on the prototype, not just on navigator.mediaDevices, so code
  // that calls MediaDevices.prototype.getUserMedia directly (webrtc-adapter
  // and similar polyfills) gets the camera too.
  const proto = Object.getPrototypeOf(devices);
  const originalGetUserMedia = proto.getUserMedia.bind(devices);
  const originalEnumerate = proto.enumerateDevices.bind(devices);

  const camera = {
    deviceId: DEVICE_ID, groupId: DEVICE_ID, kind: 'videoinput', label: LABEL,
    toJSON() { return { deviceId: DEVICE_ID, groupId: DEVICE_ID, kind: 'videoinput', label: LABEL }; },
  };
  if (window.MediaDeviceInfo) Object.setPrototypeOf(camera, MediaDeviceInfo.prototype);

  proto.enumerateDevices = async function () {
    const list = await originalEnumerate().catch(() => []);
    return list.filter((d) => d.kind !== 'videoinput').concat([camera]);
  };

  // One canvas and one frame loop, shared by every open video track.
  let canvas = null;
  let context = null;
  let openTracks = 0;

  function decode(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return createImageBitmap(new Blob([bytes], { type: 'image/jpeg' }));
  }

  async function frameLoop() {
    while (openTracks > 0) {
      const started = performance.now();
      try {
        const jpeg = await handler.postMessage('frame');
        if (jpeg) {
          const image = await decode(jpeg);
          if (canvas.width !== image.width || canvas.height !== image.height) {
            canvas.width = image.width;
            canvas.height = image.height;
          }
          context.drawImage(image, 0, 0);
          image.close();
        }
      } catch (e) { /* app went away or frame undecodable: keep the last picture */ }
      await new Promise((r) => setTimeout(r, Math.max(0, 33 - (performance.now() - started))));
    }
  }

  function videoStream() {
    if (!canvas) {
      canvas = document.createElement('canvas');
      canvas.width = 720;
      canvas.height = 1280;
      context = canvas.getContext('2d');
    }
    const stream = canvas.captureStream(30);
    const track = stream.getVideoTracks()[0];
    let ended = false;
    const end = () => { if (!ended) { ended = true; openTracks--; } };
    const stop = track.stop.bind(track);
    const getSettings = track.getSettings.bind(track);
    Object.defineProperties(track, {
      label: { value: LABEL },
      stop: { value: () => { end(); stop(); } },
      getSettings: { value: () => Object.assign(getSettings(), {
        deviceId: DEVICE_ID, groupId: DEVICE_ID, facingMode: 'environment',
        width: canvas.width, height: canvas.height, frameRate: 30,
      }) },
      getCapabilities: { value: () => ({
        deviceId: DEVICE_ID, groupId: DEVICE_ID, facingMode: ['environment'],
        width: { min: 1, max: canvas.width }, height: { min: 1, max: canvas.height },
        frameRate: { min: 1, max: 30 },
      }) },
      applyConstraints: { value: () => Promise.resolve() },
    });
    track.addEventListener('ended', end);
    openTracks++;
    if (openTracks === 1) frameLoop();
    return stream;
  }

  proto.getUserMedia = async function (constraints) {
    if (!constraints || !constraints.video) return originalGetUserMedia(constraints);
    const stream = videoStream();
    if (constraints.audio) {
      try {
        const audio = await originalGetUserMedia({ audio: constraints.audio });
        audio.getAudioTracks().forEach((t) => stream.addTrack(t));
      } catch (e) {
        stream.getTracks().forEach((t) => t.stop());
        throw e;
      }
    }
    return stream;
  };
})();
