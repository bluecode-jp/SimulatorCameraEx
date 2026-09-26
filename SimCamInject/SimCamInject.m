//
//  SimCamInject.m
//  SimCamInject
//
//  Gives iOS Simulator apps a camera. The Simulator has no capture stack
//  (no mediaserverd / cameracaptured, zero AVCaptureDevices), so instead of
//  exposing a host camera we hook the AVFoundation capture API inside the app
//  process and feed it frames ourselves:
//
//    AVCaptureDevice / DiscoverySession   → one fake camera (SCDevice)
//    AVCaptureDeviceInput                 → SCInput wrapping it
//    AVCaptureSession                     → accepts SCInput, "runs" a pump
//    AVCaptureVideoDataOutput             → delegate gets CMSampleBuffers
//    AVCaptureVideoPreviewLayer           → shows the same frames
//
//  Built with manual reference counting (-fno-objc-arc): the fakes are made
//  with class_createInstance so AVFoundation's initializers never run, and
//  they live for the whole process anyway.
//

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <os/log.h>

#import "SimCamFrameSource.h"

static os_log_t SCLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("jp.co.bluecode.SimCamInject", "inject"); });
    return log;
}

static NSString *const kSCDeviceUniqueID = @"jp.co.bluecode.SimulatorCamera.inject";

// MARK: - Swizzling helpers

/// Replace `sel` on `cls` with `block`; returns the previous implementation
/// (inherited or own) so the block can call through.
static IMP SCHook(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        os_log_error(SCLog(), "hook: %{public}s has no %{public}s", class_getName(cls), sel_getName(sel));
        return NULL;
    }
    IMP original = method_getImplementation(m);
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        method_setImplementation(m, replacement);
    }
    return original;
}

static IMP SCHookClass(Class cls, SEL sel, id block) {
    return SCHook(object_getClass(cls), sel, block);
}

// MARK: - Fake device

@interface SCDevice : AVCaptureDevice
@end

@implementation SCDevice {
    AVCaptureFocusMode _focusMode;
    AVCaptureExposureMode _exposureMode;
    AVCaptureWhiteBalanceMode _whiteBalanceMode;
    CGFloat _zoom;
}

+ (SCDevice *)shared {
    static SCDevice *device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = class_createInstance([SCDevice class], 0);
        device->_focusMode = AVCaptureFocusModeContinuousAutoFocus;
        device->_exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        device->_whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        device->_zoom = 1.0;
    });
    return device;
}

- (NSString *)uniqueID { return kSCDeviceUniqueID; }
- (NSString *)modelID { return @"SimulatorCamera"; }
- (NSString *)localizedName { return @"SimulatorCamera"; }
- (NSString *)manufacturer { return @"SimulatorCamera"; }
- (NSString *)description { return @"<SCDevice SimulatorCamera>"; }
- (BOOL)hasMediaType:(AVMediaType)mediaType { return [mediaType isEqualToString:AVMediaTypeVideo]; }
- (AVCaptureDevicePosition)position { return AVCaptureDevicePositionBack; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)isInUseByAnotherApplication { return NO; }
- (BOOL)lockForConfiguration:(NSError **)error { return YES; }
- (void)unlockForConfiguration {}
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { return YES; }
- (NSArray<AVCaptureDeviceFormat *> *)formats { return @[]; }
- (AVCaptureDeviceFormat *)activeFormat { return nil; }
- (void)setActiveFormat:(AVCaptureDeviceFormat *)format {}
- (CMTime)activeVideoMinFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMinFrameDuration:(CMTime)t {}
- (CMTime)activeVideoMaxFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMaxFrameDuration:(CMTime)t {}

// Flash / torch: none.
- (BOOL)hasFlash { return NO; }
- (BOOL)isFlashAvailable { return NO; }
- (BOOL)isFlashActive { return NO; }
- (BOOL)hasTorch { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (BOOL)isTorchActive { return NO; }
- (float)torchLevel { return 0; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (void)setTorchMode:(AVCaptureTorchMode)mode {}
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)mode { return mode == AVCaptureTorchModeOff; }
- (BOOL)setTorchModeOnWithLevel:(float)level error:(NSError **)error { return NO; }
- (AVCaptureFlashMode)flashMode { return AVCaptureFlashModeOff; }
- (void)setFlashMode:(AVCaptureFlashMode)mode {}
- (BOOL)isFlashModeSupported:(AVCaptureFlashMode)mode { return mode == AVCaptureFlashModeOff; }

// Focus / exposure / white balance: accept and remember.
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)mode { return YES; }
- (AVCaptureFocusMode)focusMode { return _focusMode; }
- (void)setFocusMode:(AVCaptureFocusMode)mode { _focusMode = mode; }
- (BOOL)isFocusPointOfInterestSupported { return YES; }
- (CGPoint)focusPointOfInterest { return CGPointMake(0.5, 0.5); }
- (void)setFocusPointOfInterest:(CGPoint)p {}
- (BOOL)isAdjustingFocus { return NO; }
- (BOOL)isAutoFocusRangeRestrictionSupported { return NO; }
- (AVCaptureAutoFocusRangeRestriction)autoFocusRangeRestriction { return AVCaptureAutoFocusRangeRestrictionNone; }
- (void)setAutoFocusRangeRestriction:(AVCaptureAutoFocusRangeRestriction)r {}
- (BOOL)isSmoothAutoFocusSupported { return NO; }
- (BOOL)isSmoothAutoFocusEnabled { return NO; }
- (void)setSmoothAutoFocusEnabled:(BOOL)e {}
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)mode { return YES; }
- (AVCaptureExposureMode)exposureMode { return _exposureMode; }
- (void)setExposureMode:(AVCaptureExposureMode)mode { _exposureMode = mode; }
- (BOOL)isExposurePointOfInterestSupported { return YES; }
- (CGPoint)exposurePointOfInterest { return CGPointMake(0.5, 0.5); }
- (void)setExposurePointOfInterest:(CGPoint)p {}
- (BOOL)isAdjustingExposure { return NO; }
- (float)exposureTargetBias { return 0; }
- (float)minExposureTargetBias { return 0; }
- (float)maxExposureTargetBias { return 0; }
- (void)setExposureTargetBias:(float)bias completionHandler:(void (^)(CMTime))handler {
    if (handler) handler(kCMTimeInvalid);
}
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)mode { return YES; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return _whiteBalanceMode; }
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)mode { _whiteBalanceMode = mode; }
- (BOOL)isAdjustingWhiteBalance { return NO; }
- (BOOL)isSubjectAreaChangeMonitoringEnabled { return NO; }
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)e {}
- (BOOL)isLowLightBoostSupported { return NO; }
- (BOOL)isLowLightBoostEnabled { return NO; }
- (BOOL)automaticallyEnablesLowLightBoostWhenAvailable { return NO; }
- (void)setAutomaticallyEnablesLowLightBoostWhenAvailable:(BOOL)e {}
- (BOOL)isVideoHDREnabled { return NO; }
- (void)setVideoHDREnabled:(BOOL)e {}
- (BOOL)automaticallyAdjustsVideoHDREnabled { return NO; }
- (void)setAutomaticallyAdjustsVideoHDREnabled:(BOOL)e {}

// Zoom: accepted, not applied to the picture.
- (CGFloat)videoZoomFactor { return _zoom; }
- (void)setVideoZoomFactor:(CGFloat)zoom { _zoom = zoom; }
- (CGFloat)minAvailableVideoZoomFactor { return 1.0; }
- (CGFloat)maxAvailableVideoZoomFactor { return 16.0; }
- (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate { _zoom = factor; }
- (void)cancelVideoZoomRamp {}
- (BOOL)isRampingVideoZoom { return NO; }
- (NSArray<NSNumber *> *)virtualDeviceSwitchOverVideoZoomFactors { return @[]; }
- (NSArray<AVCaptureDevice *> *)constituentDevices { return @[]; }
- (BOOL)isVirtualDevice { return NO; }

@end

// MARK: - Fake input

@interface SCInput : AVCaptureDeviceInput
@end

@implementation SCInput
+ (SCInput *)shared {
    static SCInput *input;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ input = class_createInstance([SCInput class], 0); });
    return input;
}
- (AVCaptureDevice *)device { return [SCDevice shared]; }
- (NSArray<AVCaptureInputPort *> *)ports { return @[]; }
- (NSString *)description { return @"<SCInput SimulatorCamera>"; }
@end

// MARK: - Fake connection

@interface SCConnection : AVCaptureConnection
@end

@implementation SCConnection {
    AVCaptureOutput *_output;               // unretained; outputs outlive their connection use
    AVCaptureVideoPreviewLayer *_layer;     // unretained
    BOOL _enabled;
    BOOL _mirrored;
    BOOL _autoMirror;
    AVCaptureVideoOrientation _orientation;
    CGFloat _rotation;
}

+ (SCConnection *)connectionForOutput:(AVCaptureOutput *)output layer:(AVCaptureVideoPreviewLayer *)layer {
    SCConnection *c = class_createInstance([SCConnection class], 0);
    c->_output = output;
    c->_layer = layer;
    c->_enabled = YES;
    c->_autoMirror = YES;
    c->_orientation = AVCaptureVideoOrientationPortrait;
    c->_rotation = 90;
    return c;
}

- (AVCaptureOutput *)output { return _output; }
- (AVCaptureVideoPreviewLayer *)videoPreviewLayer { return _layer; }
- (NSArray<AVCaptureInputPort *> *)inputPorts { return @[]; }
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)enabled { _enabled = enabled; }
- (BOOL)isActive { return YES; }
- (BOOL)isVideoOrientationSupported { return YES; }
- (AVCaptureVideoOrientation)videoOrientation { return _orientation; }
- (void)setVideoOrientation:(AVCaptureVideoOrientation)o { _orientation = o; }
- (BOOL)isVideoRotationAngleSupported:(CGFloat)angle { return YES; }
- (CGFloat)videoRotationAngle { return _rotation; }
- (void)setVideoRotationAngle:(CGFloat)angle { _rotation = angle; }
- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoMirrored { return _mirrored; }
- (void)setVideoMirrored:(BOOL)m { _mirrored = m; }
- (BOOL)automaticallyAdjustsVideoMirroring { return _autoMirror; }
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)a { _autoMirror = a; }
- (BOOL)isVideoStabilizationSupported { return NO; }
- (AVCaptureVideoStabilizationMode)preferredVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (void)setPreferredVideoStabilizationMode:(AVCaptureVideoStabilizationMode)m {}
- (AVCaptureVideoStabilizationMode)activeVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (BOOL)isCameraIntrinsicMatrixDeliverySupported { return NO; }
- (BOOL)isCameraIntrinsicMatrixDeliveryEnabled { return NO; }
- (void)setCameraIntrinsicMatrixDeliveryEnabled:(BOOL)e {}
- (NSArray<AVCaptureAudioChannel *> *)audioChannels { return @[]; }
- (NSString *)description { return @"<SCConnection SimulatorCamera>"; }
// Private accessors AVFoundation's own code calls on connections.
- (AVCaptureDevice *)sourceDevice { return [SCDevice shared]; }
- (AVCaptureDeviceInput *)sourceDeviceInput { return [SCInput shared]; }
- (AVMediaType)mediaType { return AVMediaTypeVideo; }
@end

// MARK: - Fake barcode

/// Aspect-fit/fill mapping of a normalized point in a `frame`-sized image
/// into a preview layer.
static CGPoint SCLayerPoint(AVCaptureVideoPreviewLayer *layer, CGSize frame, CGPoint p) {
    CGSize size = layer.bounds.size;
    CGFloat sx = size.width / frame.width, sy = size.height / frame.height;
    NSString *gravity = layer.videoGravity;
    CGFloat w, h;
    if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        w = size.width; h = size.height;
    } else {
        CGFloat scale = [gravity isEqualToString:AVLayerVideoGravityResizeAspectFill] ? MAX(sx, sy) : MIN(sx, sy);
        w = frame.width * scale; h = frame.height * scale;
    }
    return CGPointMake((size.width - w) / 2 + p.x * w, (size.height - h) / 2 + p.y * h);
}


@interface SCCodeObject : AVMetadataMachineReadableCodeObject
@end

@implementation SCCodeObject {
    AVMetadataObjectType _type;
    NSString *_value;
    CGRect _bounds;
    NSArray *_corners;   // CGPoint dictionaries, like AVFoundation's
    CMTime _time;
    CGSize _frameSize;   // pixel size of the frame the code was found in
}

+ (SCCodeObject *)codeWithType:(AVMetadataObjectType)type value:(NSString *)value
                        bounds:(CGRect)bounds corners:(NSArray *)corners time:(CMTime)time
                     frameSize:(CGSize)frameSize {
    SCCodeObject *o = class_createInstance([SCCodeObject class], 0);
    o->_frameSize = frameSize;
    o->_type = [type copy];
    o->_value = [value copy];
    o->_bounds = bounds;
    o->_corners = [corners copy];
    o->_time = time;
    return [o autorelease];
}

- (void)dealloc {
    [_type release];
    [_value release];
    [_corners release];
    [super dealloc];
}

- (AVMetadataObjectType)type { return _type; }
- (NSString *)stringValue { return _value; }
- (CGRect)bounds { return _bounds; }
- (NSArray *)corners { return _corners; }
- (CMTime)time { return _time; }
- (CMTime)duration { return kCMTimeInvalid; }
- (CIBarcodeDescriptor *)descriptor { return nil; }
- (NSString *)description { return [NSString stringWithFormat:@"<SCCodeObject %@ %@>", _type, _value]; }

/// Same code mapped into a preview layer's coordinate space.
- (SCCodeObject *)transformedForLayer:(AVCaptureVideoPreviewLayer *)layer {
    NSMutableArray *corners = [NSMutableArray array];
    for (NSDictionary *d in _corners) {
        CGPoint p;
        CGPointMakeWithDictionaryRepresentation((CFDictionaryRef)d, &p);
        CFDictionaryRef mapped = CGPointCreateDictionaryRepresentation(SCLayerPoint(layer, _frameSize, p));
        [corners addObject:(id)mapped];
        CFRelease(mapped);
    }
    CGPoint a = SCLayerPoint(layer, _frameSize, _bounds.origin);
    CGPoint b = SCLayerPoint(layer, _frameSize, CGPointMake(CGRectGetMaxX(_bounds), CGRectGetMaxY(_bounds)));
    CGRect bounds = CGRectMake(a.x, a.y, b.x - a.x, b.y - a.y);
    return [SCCodeObject codeWithType:_type value:_value bounds:bounds corners:corners time:_time
                            frameSize:_frameSize];
}
@end

/// Barcodes that arrived with the current frame, as fake metadata objects.
static NSArray<SCCodeObject *> *SCCurrentCodes(CMTime time, CGSize frameSize) {
    NSData *json = SCFrameSourceCopyMeta();
    if (!json) return @[];
    NSArray *items = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    [json release];
    if (![items isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *codes = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = item[@"type"], *value = item[@"value"];
        NSArray *b = item[@"bounds"];
        if (![type isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]] || b.count != 4) continue;
        CGRect bounds = CGRectMake([b[0] doubleValue], [b[1] doubleValue], [b[2] doubleValue], [b[3] doubleValue]);
        NSMutableArray *corners = [NSMutableArray array];
        for (NSArray *c in item[@"corners"]) {
            if (![c isKindOfClass:[NSArray class]] || c.count != 2) continue;
            CFDictionaryRef d = CGPointCreateDictionaryRepresentation(CGPointMake([c[0] doubleValue], [c[1] doubleValue]));
            [corners addObject:(id)d];
            CFRelease(d);
        }
        [codes addObject:[SCCodeObject codeWithType:type value:value bounds:bounds corners:corners time:time
                                          frameSize:frameSize]];
    }
    return codes;
}

// MARK: - Per-object state (associated objects)

static char kSCInputsKey, kSCRunningKey, kSCConnectionKey, kSCVideoSettingsKey, kSCPreviewSublayerKey, kSCDiscoveryVideoKey,
    kSCMetadataTypesKey;

static NSMutableArray *SCSessionInputs(AVCaptureSession *session) {
    NSMutableArray *inputs = objc_getAssociatedObject(session, &kSCInputsKey);
    if (!inputs) {
        inputs = [NSMutableArray array];
        objc_setAssociatedObject(session, &kSCInputsKey, inputs, OBJC_ASSOCIATION_RETAIN);
    }
    return inputs;
}

static BOOL SCSessionHasFakeInput(AVCaptureSession *session) {
    return [objc_getAssociatedObject(session, &kSCInputsKey) count] > 0;
}

static BOOL SCSessionIsRunning(AVCaptureSession *session) {
    return [objc_getAssociatedObject(session, &kSCRunningKey) boolValue];
}

static SCConnection *SCConnectionFor(AVCaptureOutput *output) {
    SCConnection *c = objc_getAssociatedObject(output, &kSCConnectionKey);
    if (!c) {
        c = [SCConnection connectionForOutput:output layer:nil];
        objc_setAssociatedObject(output, &kSCConnectionKey, c, OBJC_ASSOCIATION_RETAIN);
        [c release];
    }
    return c;
}

// MARK: - Pump

/// Sessions currently "running" on the fake camera, and preview layers.
static NSHashTable<AVCaptureSession *> *gSessions;
static NSHashTable<AVCaptureVideoPreviewLayer *> *gLayers;
static dispatch_queue_t gPumpQueue;
static dispatch_source_t gTimer;
static NSObject *gLock;
static uint64_t gFramesDelivered;

static CMSampleBufferRef SCMakeSampleBuffer(CVPixelBufferRef pixelBuffer) {
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) return NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, format, &timing, &sample);
    CFRelease(format);
    return sample;
}

static NSString *SCGravity(AVLayerVideoGravity gravity) {
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) return kCAGravityResizeAspectFill;
    if ([gravity isEqualToString:AVLayerVideoGravityResize]) return kCAGravityResize;
    return kCAGravityResizeAspect;
}

static CGImageRef SCCopyCGImage(CVPixelBufferRef pixelBuffer) {
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, CVPixelBufferGetBaseAddress(pixelBuffer), (CFIndex)(stride * height));
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (!data) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, space,
                                     kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return image;
}

static void SCUpdatePreviewLayers(CVPixelBufferRef pixelBuffer) {
    NSArray<AVCaptureVideoPreviewLayer *> *layers;
    @synchronized (gLock) { layers = [[gLayers allObjects] retain]; }
    NSMutableArray *live = [NSMutableArray array];
    for (AVCaptureVideoPreviewLayer *layer in layers) {
        AVCaptureSession *session = layer.session;
        if (session && SCSessionIsRunning(session)) [live addObject:layer];
    }
    [layers release];
    if (live.count == 0) return;

    // Copy the pixels: a CGImage from VTCreateCGImageFromCVPixelBuffer may
    // alias the pooled buffer, which the next network frame overwrites
    // while Core Animation is still drawing it (visible as tearing).
    CGImageRef image = SCCopyCGImage(pixelBuffer);
    if (!image) return;
    [live retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (AVCaptureVideoPreviewLayer *layer in live) {
            // Draw into our own sublayer on top: the preview layer's private
            // sublayers are opaque black when there is no real capture graph.
            CALayer *content = objc_getAssociatedObject(layer, &kSCPreviewSublayerKey);
            if (!content) {
                content = [CALayer layer];
                content.masksToBounds = YES;
                objc_setAssociatedObject(layer, &kSCPreviewSublayerKey, content, OBJC_ASSOCIATION_RETAIN);
            }
            if (content.superlayer != layer || layer.sublayers.lastObject != content) {
                [content removeFromSuperlayer];
                [layer addSublayer:content];
            }
            content.frame = layer.bounds;
            content.contentsGravity = SCGravity(layer.videoGravity);
            content.contents = (id)image;
        }
        [CATransaction commit];
        [live release];
        CGImageRelease(image);
    });
}

static void SCDeliverMetadata(AVCaptureMetadataOutput *output, NSArray<SCCodeObject *> *codes) {
    id<AVCaptureMetadataOutputObjectsDelegate> delegate = output.metadataObjectsDelegate;
    dispatch_queue_t queue = output.metadataObjectsCallbackQueue;
    if (!delegate || !queue || codes.count == 0) return;
    if (![delegate respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) return;
    NSArray *wanted = objc_getAssociatedObject(output, &kSCMetadataTypesKey);
    NSMutableArray *matching = [NSMutableArray array];
    for (SCCodeObject *code in codes) {
        if ([wanted containsObject:code.type]) [matching addObject:code];
    }
    if (matching.count == 0) return;
    SCConnection *connection = SCConnectionFor(output);
    [(id)delegate retain];
    [matching retain];
    dispatch_async(queue, ^{
        [delegate captureOutput:output didOutputMetadataObjects:matching fromConnection:connection];
        [matching release];
        [(id)delegate release];
    });
}

static void SCDeliverToOutputs(AVCaptureSession *session, CMSampleBufferRef sample, NSArray<SCCodeObject *> *codes) {
    for (AVCaptureOutput *output in session.outputs) {
        if ([output isKindOfClass:[AVCaptureMetadataOutput class]]) {
            SCDeliverMetadata((AVCaptureMetadataOutput *)output, codes);
            continue;
        }
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            AVCaptureVideoDataOutput *video = (AVCaptureVideoDataOutput *)output;
            id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = video.sampleBufferDelegate;
            dispatch_queue_t queue = video.sampleBufferCallbackQueue;
            if (!delegate || !queue) continue;
            if (![delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) continue;
            SCConnection *connection = SCConnectionFor(output);
            CFRetain(sample);
            [(id)delegate retain];
            dispatch_async(queue, ^{
                [delegate captureOutput:video didOutputSampleBuffer:sample fromConnection:connection];
                [(id)delegate release];
                CFRelease(sample);
            });
        }
    }
}

static void SCPumpTick(void) {
    CVPixelBufferRef pixelBuffer = SCFrameSourceCopyFrame();
    if (!pixelBuffer) return;

    NSArray<AVCaptureSession *> *sessions;
    @synchronized (gLock) { sessions = [[gSessions allObjects] retain]; }
    CMSampleBufferRef sample = SCMakeSampleBuffer(pixelBuffer);
    if (sample) {
        // Metadata at ~10 Hz is plenty for scanners and keeps delegates calm.
        NSArray *codes = (gFramesDelivered % 3 == 0)
            ? SCCurrentCodes(CMSampleBufferGetPresentationTimeStamp(sample),
                             CGSizeMake(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
            : @[];
        for (AVCaptureSession *session in sessions) SCDeliverToOutputs(session, sample, codes);
        CFRelease(sample);
    }
    [sessions release];

    SCUpdatePreviewLayers(pixelBuffer);
    CVPixelBufferRelease(pixelBuffer);

    gFramesDelivered++;
    if (gFramesDelivered == 1 || gFramesDelivered % 300 == 0) {
        os_log(SCLog(), "pump: %llu frames delivered", gFramesDelivered);
    }
}

static void SCStartPumpIfNeeded(void) {
    dispatch_async(gPumpQueue, ^{
        if (gTimer) return;
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gPumpQueue);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{ @autoreleasepool { SCPumpTick(); } });
        dispatch_resume(gTimer);
        os_log(SCLog(), "pump started");
    });
}

static void SCStopPumpIfIdle(void) {
    dispatch_async(gPumpQueue, ^{
        NSUInteger running;
        @synchronized (gLock) { running = gSessions.count; }
        if (running > 0 || !gTimer) return;
        dispatch_source_cancel(gTimer);
        dispatch_release(gTimer);
        gTimer = NULL;
        os_log(SCLog(), "pump stopped");
    });
}

// MARK: - Hooks

static void SCInstallDeviceHooks(void) {
    Class dev = [AVCaptureDevice class];

    __block IMP origDefault = SCHookClass(dev, @selector(defaultDeviceWithMediaType:), ^id(id cls, AVMediaType type) {
        if ([type isEqualToString:AVMediaTypeVideo]) return [SCDevice shared];
        return ((id (*)(id, SEL, AVMediaType))origDefault)(cls, @selector(defaultDeviceWithMediaType:), type);
    });
    __block IMP origDefaultTyped = SCHookClass(dev, @selector(defaultDeviceWithDeviceType:mediaType:position:),
        ^id(id cls, AVCaptureDeviceType deviceType, AVMediaType type, AVCaptureDevicePosition position) {
            if (!type || [type isEqualToString:AVMediaTypeVideo]) return [SCDevice shared];
            return ((id (*)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition))origDefaultTyped)(
                cls, @selector(defaultDeviceWithDeviceType:mediaType:position:), deviceType, type, position);
        });
    __block IMP origWithID = SCHookClass(dev, @selector(deviceWithUniqueID:), ^id(id cls, NSString *uid) {
        if ([uid isEqualToString:kSCDeviceUniqueID]) return [SCDevice shared];
        return ((id (*)(id, SEL, NSString *))origWithID)(cls, @selector(deviceWithUniqueID:), uid);
    });
    __block IMP origStatus = SCHookClass(dev, @selector(authorizationStatusForMediaType:), ^NSInteger(id cls, AVMediaType type) {
        if ([type isEqualToString:AVMediaTypeVideo]) return AVAuthorizationStatusAuthorized;
        return ((NSInteger (*)(id, SEL, AVMediaType))origStatus)(cls, @selector(authorizationStatusForMediaType:), type);
    });
    __block IMP origRequest = SCHookClass(dev, @selector(requestAccessForMediaType:completionHandler:),
        ^(id cls, AVMediaType type, void (^handler)(BOOL)) {
            if ([type isEqualToString:AVMediaTypeVideo]) {
                void (^copy)(BOOL) = [handler copy];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ copy(YES); [copy release]; });
                return;
            }
            ((void (*)(id, SEL, AVMediaType, id))origRequest)(cls, @selector(requestAccessForMediaType:completionHandler:), type, handler);
        });

    // Discovery sessions: remember whether they asked for video, then append the fake.
    Class disc = [AVCaptureDeviceDiscoverySession class];
    __block IMP origDiscCreate = SCHookClass(disc, @selector(discoverySessionWithDeviceTypes:mediaType:position:),
        ^id(id cls, NSArray *types, AVMediaType type, AVCaptureDevicePosition position) {
            id session = ((id (*)(id, SEL, NSArray *, AVMediaType, AVCaptureDevicePosition))origDiscCreate)(
                cls, @selector(discoverySessionWithDeviceTypes:mediaType:position:), types, type, position);
            BOOL video = !type || [type isEqualToString:AVMediaTypeVideo];
            if (session) objc_setAssociatedObject(session, &kSCDiscoveryVideoKey, @(video), OBJC_ASSOCIATION_RETAIN);
            return session;
        });
    __block IMP origDiscDevices = SCHook(disc, @selector(devices), ^NSArray *(id self) {
        NSArray *real = ((NSArray * (*)(id, SEL))origDiscDevices)(self, @selector(devices));
        NSNumber *video = objc_getAssociatedObject(self, &kSCDiscoveryVideoKey);
        if (video && !video.boolValue) return real;
        return [@[[SCDevice shared]] arrayByAddingObjectsFromArray:real ?: @[]];
    });
}

static void SCInstallInputHooks(void) {
    Class cls = [AVCaptureDeviceInput class];
    __block IMP origFactory = SCHookClass(cls, @selector(deviceInputWithDevice:error:), ^id(id c, AVCaptureDevice *device, NSError **error) {
        if ([device isKindOfClass:[SCDevice class]]) return [SCInput shared];
        return ((id (*)(id, SEL, AVCaptureDevice *, NSError **))origFactory)(c, @selector(deviceInputWithDevice:error:), device, error);
    });
    __block IMP origInit = SCHook(cls, @selector(initWithDevice:error:), ^id(id self, AVCaptureDevice *device, NSError **error) {
        if ([device isKindOfClass:[SCDevice class]]) {
            [self release];
            return [[SCInput shared] retain];
        }
        return ((id (*)(id, SEL, AVCaptureDevice *, NSError **))origInit)(self, @selector(initWithDevice:error:), device, error);
    });
}

static void SCInstallSessionHooks(void) {
    Class cls = [AVCaptureSession class];

    __block IMP origCanAdd = SCHook(cls, @selector(canAddInput:), ^BOOL(AVCaptureSession *self, AVCaptureInput *input) {
        if ([input isKindOfClass:[SCInput class]]) return ![SCSessionInputs(self) containsObject:input];
        return ((BOOL (*)(id, SEL, id))origCanAdd)(self, @selector(canAddInput:), input);
    });
    __block IMP origAdd = SCHook(cls, @selector(addInput:), ^(AVCaptureSession *self, AVCaptureInput *input) {
        if ([input isKindOfClass:[SCInput class]]) {
            NSMutableArray *inputs = SCSessionInputs(self);
            if (![inputs containsObject:input]) [inputs addObject:input];
            os_log(SCLog(), "session %p: fake input added", self);
            return;
        }
        ((void (*)(id, SEL, id))origAdd)(self, @selector(addInput:), input);
    });
    __block IMP origRemove = SCHook(cls, @selector(removeInput:), ^(AVCaptureSession *self, AVCaptureInput *input) {
        if ([input isKindOfClass:[SCInput class]]) {
            [SCSessionInputs(self) removeObject:input];
            return;
        }
        ((void (*)(id, SEL, id))origRemove)(self, @selector(removeInput:), input);
    });
    __block IMP origInputs = SCHook(cls, @selector(inputs), ^NSArray *(AVCaptureSession *self) {
        NSArray *real = ((NSArray * (*)(id, SEL))origInputs)(self, @selector(inputs));
        NSArray *fake = objc_getAssociatedObject(self, &kSCInputsKey);
        return fake.count ? [(real ?: @[]) arrayByAddingObjectsFromArray:fake] : real;
    });
    __block IMP origCanPreset = SCHook(cls, @selector(canSetSessionPreset:), ^BOOL(AVCaptureSession *self, AVCaptureSessionPreset preset) {
        if (SCSessionHasFakeInput(self)) return YES;
        return ((BOOL (*)(id, SEL, id))origCanPreset)(self, @selector(canSetSessionPreset:), preset);
    });
    __block IMP origSetPreset = SCHook(cls, @selector(setSessionPreset:), ^(AVCaptureSession *self, AVCaptureSessionPreset preset) {
        @try {
            ((void (*)(id, SEL, id))origSetPreset)(self, @selector(setSessionPreset:), preset);
        } @catch (NSException *e) {
            os_log(SCLog(), "setSessionPreset %{public}@ ignored: %{public}@", preset, e.reason);
        }
    });
    __block IMP origStart = SCHook(cls, @selector(startRunning), ^(AVCaptureSession *self) {
        if (!SCSessionHasFakeInput(self)) {
            ((void (*)(id, SEL))origStart)(self, @selector(startRunning));
            return;
        }
        if (SCSessionIsRunning(self)) return;
        objc_setAssociatedObject(self, &kSCRunningKey, @YES, OBJC_ASSOCIATION_RETAIN);
        @synchronized (gLock) { [gSessions addObject:self]; }
        os_log(SCLog(), "session %p: startRunning (fake)", self);
        SCStartPumpIfNeeded();
        [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
    });
    __block IMP origStop = SCHook(cls, @selector(stopRunning), ^(AVCaptureSession *self) {
        if (!SCSessionIsRunning(self)) {
            ((void (*)(id, SEL))origStop)(self, @selector(stopRunning));
            return;
        }
        objc_setAssociatedObject(self, &kSCRunningKey, @NO, OBJC_ASSOCIATION_RETAIN);
        @synchronized (gLock) { [gSessions removeObject:self]; }
        os_log(SCLog(), "session %p: stopRunning (fake)", self);
        SCStopPumpIfIdle();
        [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
    });
    __block IMP origIsRunning = SCHook(cls, @selector(isRunning), ^BOOL(AVCaptureSession *self) {
        if (SCSessionIsRunning(self)) return YES;
        return ((BOOL (*)(id, SEL))origIsRunning)(self, @selector(isRunning));
    });
    __block IMP origInterrupted = SCHook(cls, @selector(isInterrupted), ^BOOL(AVCaptureSession *self) {
        if (SCSessionHasFakeInput(self)) return NO;
        return ((BOOL (*)(id, SEL))origInterrupted)(self, @selector(isInterrupted));
    });
    // With no real input the private capture graph fails to build and the
    // session reports -11800 runtime errors; apps treat those as fatal.
    SEL postError = NSSelectorFromString(@"_postRuntimeError:");
    if (class_getInstanceMethod(cls, postError)) {
        __block IMP origPostError = SCHook(cls, postError, ^(AVCaptureSession *self, NSError *error) {
            if (SCSessionHasFakeInput(self)) {
                os_log(SCLog(), "session %p: suppressed runtime error %{public}@", self, error);
                return;
            }
            ((void (*)(id, SEL, id))origPostError)(self, postError, error);
        });
    }
    __block IMP origCanAddOutput = SCHook(cls, @selector(canAddOutput:), ^BOOL(AVCaptureSession *self, AVCaptureOutput *output) {
        BOOL real = ((BOOL (*)(id, SEL, id))origCanAddOutput)(self, @selector(canAddOutput:), output);
        return real || (SCSessionHasFakeInput(self) && ![self.outputs containsObject:output]);
    });
}

static IMP gOrigOutputConnections;

/// True when AVFoundation itself wired this output to a real input; false
/// for outputs that only ever see our fake camera.
static BOOL SCOutputHasRealConnection(AVCaptureOutput *output) {
    if (!gOrigOutputConnections) return YES;
    NSArray *real = ((NSArray * (*)(id, SEL))gOrigOutputConnections)(output, @selector(connections));
    return real.count > 0;
}

static NSArray<AVMetadataObjectType> *SCBarcodeTypes(void) {
    return @[AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN13Code, AVMetadataObjectTypeEAN8Code,
             AVMetadataObjectTypeUPCECode, AVMetadataObjectTypeCode128Code, AVMetadataObjectTypeCode39Code,
             AVMetadataObjectTypeCode39Mod43Code, AVMetadataObjectTypeCode93Code, AVMetadataObjectTypeITF14Code,
             AVMetadataObjectTypeInterleaved2of5Code, AVMetadataObjectTypeDataMatrixCode,
             AVMetadataObjectTypePDF417Code, AVMetadataObjectTypeAztecCode];
}

static void SCInstallOutputHooks(void) {
    // Outputs have no real connection (no real input), so hand out fakes.
    Class out = [AVCaptureOutput class];
    __block IMP origConnWithType = SCHook(out, @selector(connectionWithMediaType:), ^id(AVCaptureOutput *self, AVMediaType type) {
        id real = ((id (*)(id, SEL, id))origConnWithType)(self, @selector(connectionWithMediaType:), type);
        if (real || ![type isEqualToString:AVMediaTypeVideo]) return real;
        return SCConnectionFor(self);
    });
    __block IMP origConns = SCHook(out, @selector(connections), ^NSArray *(AVCaptureOutput *self) {
        NSArray *real = ((NSArray * (*)(id, SEL))origConns)(self, @selector(connections));
        return real.count ? real : @[SCConnectionFor(self)];
    });
    gOrigOutputConnections = origConns;

    // Video data output validates settings against the (empty) connection.
    Class vdo = [AVCaptureVideoDataOutput class];
    __block IMP origSetSettings = SCHook(vdo, @selector(setVideoSettings:), ^(AVCaptureVideoDataOutput *self, NSDictionary *settings) {
        objc_setAssociatedObject(self, &kSCVideoSettingsKey, settings, OBJC_ASSOCIATION_COPY);
        // The real setter vets settings against the connection's source
        // device, which crashes on our fake connection.
        if (!SCOutputHasRealConnection(self)) return;
        @try {
            ((void (*)(id, SEL, id))origSetSettings)(self, @selector(setVideoSettings:), settings);
        } @catch (NSException *e) {
            os_log(SCLog(), "setVideoSettings ignored: %{public}@", e.reason);
        }
    });
    __block IMP origSettings = SCHook(vdo, @selector(videoSettings), ^NSDictionary *(AVCaptureVideoDataOutput *self) {
        NSDictionary *stored = objc_getAssociatedObject(self, &kSCVideoSettingsKey);
        return stored ?: ((NSDictionary * (*)(id, SEL))origSettings)(self, @selector(videoSettings));
    });
    SCHook(vdo, @selector(availableVideoCVPixelFormatTypes), ^NSArray *(id self) {
        return @[@(kCVPixelFormatType_32BGRA), @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                 @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)];
    });

    // Metadata output: with no real connection it offers no types and
    // throws when any are requested.
    Class mdo = [AVCaptureMetadataOutput class];
    __block IMP origAvailable = SCHook(mdo, @selector(availableMetadataObjectTypes), ^NSArray *(AVCaptureMetadataOutput *self) {
        if (!SCOutputHasRealConnection(self)) return SCBarcodeTypes();
        return ((NSArray * (*)(id, SEL))origAvailable)(self, @selector(availableMetadataObjectTypes));
    });
    __block IMP origSetTypes = SCHook(mdo, @selector(setMetadataObjectTypes:), ^(AVCaptureMetadataOutput *self, NSArray *types) {
        objc_setAssociatedObject(self, &kSCMetadataTypesKey, types, OBJC_ASSOCIATION_COPY);
        if (!SCOutputHasRealConnection(self)) return;
        ((void (*)(id, SEL, id))origSetTypes)(self, @selector(setMetadataObjectTypes:), types);
    });
    __block IMP origTypes = SCHook(mdo, @selector(metadataObjectTypes), ^NSArray *(AVCaptureMetadataOutput *self) {
        if (!SCOutputHasRealConnection(self)) return objc_getAssociatedObject(self, &kSCMetadataTypesKey) ?: @[];
        return ((NSArray * (*)(id, SEL))origTypes)(self, @selector(metadataObjectTypes));
    });
}

static void SCInstallPreviewHooks(void) {
    Class cls = [AVCaptureVideoPreviewLayer class];
    void (^track)(AVCaptureVideoPreviewLayer *) = ^(AVCaptureVideoPreviewLayer *layer) {
        @synchronized (gLock) { [gLayers addObject:layer]; }
    };
    track = [track copy];
    __block IMP origInitSession = SCHook(cls, @selector(initWithSession:), ^id(id self, AVCaptureSession *session) {
        id layer = ((id (*)(id, SEL, id))origInitSession)(self, @selector(initWithSession:), session);
        if (layer) track(layer);
        return layer;
    });
    __block IMP origInitNoConn = SCHook(cls, @selector(initWithSessionWithNoConnection:), ^id(id self, AVCaptureSession *session) {
        id layer = ((id (*)(id, SEL, id))origInitNoConn)(self, @selector(initWithSessionWithNoConnection:), session);
        if (layer) track(layer);
        return layer;
    });
    __block IMP origSetSession = SCHook(cls, @selector(setSession:), ^(id self, AVCaptureSession *session) {
        ((void (*)(id, SEL, id))origSetSession)(self, @selector(setSession:), session);
        track(self);
    });
    __block IMP origTransform = SCHook(cls, @selector(transformedMetadataObjectForMetadataObject:),
        ^id(AVCaptureVideoPreviewLayer *self, AVMetadataObject *object) {
            if ([object isKindOfClass:[SCCodeObject class]]) return [(SCCodeObject *)object transformedForLayer:self];
            return ((id (*)(id, SEL, id))origTransform)(self, @selector(transformedMetadataObjectForMetadataObject:), object);
        });
    __block IMP origConnection = SCHook(cls, @selector(connection), ^id(AVCaptureVideoPreviewLayer *self) {
        id real = ((id (*)(id, SEL))origConnection)(self, @selector(connection));
        if (real || !self.session || !SCSessionHasFakeInput(self.session)) return real;
        SCConnection *c = objc_getAssociatedObject(self, &kSCConnectionKey);
        if (!c) {
            c = [SCConnection connectionForOutput:nil layer:self];
            objc_setAssociatedObject(self, &kSCConnectionKey, c, OBJC_ASSOCIATION_RETAIN);
            [c release];
        }
        return c;
    });
}

/// SIMCAM_APPS (comma-separated bundle IDs), set by `simcamctl sim-enable
/// --app`, limits the hooks to those apps; unset means every installed app.
static BOOL SCIsTargetApp(void) {
    const char *apps = getenv("SIMCAM_APPS");
    if (!apps || !*apps) return YES;
    NSString *me = [[NSBundle mainBundle] bundleIdentifier];
    for (NSString *app in [@(apps) componentsSeparatedByString:@","]) {
        NSString *trimmed = [app stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed isEqualToString:me]) return YES;
    }
    return NO;
}

__attribute__((constructor))
static void SCInit(void) {
    @autoreleasepool {
        if (!SCIsTargetApp()) return;
        gLock = [NSObject new];
        gSessions = [[NSHashTable weakObjectsHashTable] retain];
        gLayers = [[NSHashTable weakObjectsHashTable] retain];
        gPumpQueue = dispatch_queue_create("jp.co.bluecode.SimCamInject.pump", DISPATCH_QUEUE_SERIAL);
        SCInstallDeviceHooks();
        SCInstallInputHooks();
        SCInstallSessionHooks();
        SCInstallOutputHooks();
        SCInstallPreviewHooks();
        os_log(SCLog(), "SimCamInject loaded into %{public}@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}
