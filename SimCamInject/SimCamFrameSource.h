//
//  SimCamFrameSource.h
//  SimCamInject
//
//  Where injected frames come from. Always returns a frame: the latest one
//  received from the SimulatorCamera Mac app, or a built-in test pattern
//  while the app is not reachable.
//

#import <CoreVideo/CoreVideo.h>

/// Current frame, BGRA, +1 retained: 720x1280 (portrait) or 1280x720 as the
/// Mac app sends it. NULL only if allocation fails.
CVPixelBufferRef SCFrameSourceCopyFrame(void);

/// JSON metadata that came with the current frame (barcodes), +1 retained,
/// or nil when showing the test pattern.
@class NSData;
NSData *SCFrameSourceCopyMeta(void);
