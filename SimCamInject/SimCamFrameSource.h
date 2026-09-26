//
//  SimCamFrameSource.h
//  SimCamInject
//
//  Where injected frames come from. Always returns a frame: the latest one
//  received from the SimulatorCamera Mac app, or a built-in test pattern
//  while the app is not reachable.
//

#import <CoreVideo/CoreVideo.h>

/// Current frame, 1280x720 BGRA, +1 retained. NULL only if allocation fails.
CVPixelBufferRef SCFrameSourceCopyFrame(void);

/// JSON metadata that came with the current frame (barcodes), +1 retained,
/// or nil when showing the test pattern.
@class NSData;
NSData *SCFrameSourceCopyMeta(void);
