//
//  manual.m — SimCamInject check: connections wired by hand
//
//  Like react-native-vision-camera 5: addInputWithNoConnections /
//  addOutputWithNoConnections, AVCaptureConnection(inputPorts:output:),
//  setSessionWithNoConnection + AVCaptureConnection(inputPort:videoPreviewLayer:),
//  session.connections, removeConnection. Also reads the format details such
//  libraries resolve constraints with. MULTICAM=1 uses AVCaptureMultiCamSession.
//  Run through scripts/test-inject.sh.
//
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
@interface D : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property int frames; @property NSString *code;
@end
@implementation D
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c { self.frames++; }
- (void)captureOutput:(AVCaptureOutput *)o didOutputMetadataObjects:(NSArray *)objs fromConnection:(AVCaptureConnection *)c {
    for (AVMetadataMachineReadableCodeObject *m in objs) self.code = m.stringValue;
}
@end
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; NSLog(@"NG: " __VA_ARGS__); } else NSLog(@"ok: " __VA_ARGS__); } while (0)
int main(void) {
    @autoreleasepool {
        D *d = [D new];
        NSLog(@"multiCamSupported=%d", AVCaptureMultiCamSession.isMultiCamSupported);
        AVCaptureDevice *device = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
            mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices.firstObject;
        CHECK(device != nil, @"device %@", device);
        for (AVCaptureDeviceFormat *f in device.formats) {
            CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
            NSLog(@"  format %dx%d fps=%@ colorSpaces=%@ afs=%ld hdr=%d multicam=%d photo=%@ fov=%.0f zoom=%.0f stab=%d",
                  dim.width, dim.height, f.videoSupportedFrameRateRanges.firstObject, f.supportedColorSpaces,
                  (long)f.autoFocusSystem, f.isVideoHDRSupported, f.isMultiCamSupported, f.supportedMaxPhotoDimensions,
                  f.videoFieldOfView, f.videoMaxZoomFactor, [f isVideoStabilizationModeSupported:AVCaptureVideoStabilizationModeStandard]);
        }
        NSLog(@"  device: activeColorSpace=%ld zoomMultiplier=%.1f switchOver=%@ constituents=%@ minISO=%.0f",
              (long)device.activeColorSpace, device.displayVideoZoomFactorMultiplier, device.virtualDeviceSwitchOverVideoZoomFactors,
              device.constituentDevices, device.activeFormat.minISO);
        NSError *e = nil;
        if ([device lockForConfiguration:&e]) { device.activeFormat = device.formats.firstObject; device.activeVideoMinFrameDuration = CMTimeMake(1, 30); [device unlockForConfiguration]; }

        AVCaptureSession *s = getenv("MULTICAM") ? [AVCaptureMultiCamSession new] : [AVCaptureSession new]; NSLog(@"session class %@", [s class]);
        dispatch_queue_t q = dispatch_queue_create("com.margelo.camera.session", 0);
        CALayer *root = [CALayer layer];
        AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer new];
        layer.frame = CGRectMake(0, 0, 390, 844); [root addSublayer:layer];
        __block AVCaptureVideoDataOutput *video; __block AVCaptureMetadataOutput *meta;
        dispatch_sync(q, ^{
            [s beginConfiguration];
            s.sessionPreset = AVCaptureSessionPresetInputPriority;
            AVCaptureDeviceInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:device error:nil];
            CHECK([s canAddInput:input], @"canAddInput");
            [s addInputWithNoConnections:input];
            NSArray *ports = [input.ports filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"mediaType == %@", AVMediaTypeVideo]];
            CHECK(ports.count == 1, @"video ports %@ (input %@, clock %@)", ports, [ports.firstObject input], [ports.firstObject clock]);

            video = [AVCaptureVideoDataOutput new];
            [video setSampleBufferDelegate:d queue:dispatch_get_main_queue()];
            meta = [AVCaptureMetadataOutput new];
            for (AVCaptureOutput *o in @[video, meta]) {
                CHECK(o.connections.count == 0, @"%@ has no connections before it is added", [o class]);
                CHECK([s canAddOutput:o], @"canAddOutput %@", [o class]);
                [s addOutputWithNoConnections:o];
                CHECK(o.connections.count == 0, @"%@ has no connections after addOutputWithNoConnections", [o class]);
                AVCaptureConnection *c = [[AVCaptureConnection alloc] initWithInputPorts:ports output:o];
                CHECK([s canAddConnection:c], @"canAddConnection %@", c);
                [s addConnection:c];
                CHECK(o.connections.firstObject == c, @"%@ reports the connection it was given", [o class]);
                CHECK([c.inputPorts.firstObject.input isKindOfClass:[AVCaptureDeviceInput class]], @"connection → port → device input");
            }
            [meta setMetadataObjectsDelegate:d queue:dispatch_get_main_queue()];
            meta.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];

            CHECK(layer.session == nil, @"preview has no session yet");
            [layer setSessionWithNoConnection:s];
            CHECK(layer.connection == nil, @"preview has no connection after setSessionWithNoConnection");
            AVCaptureConnection *pc = [[AVCaptureConnection alloc] initWithInputPort:ports.firstObject videoPreviewLayer:layer];
            CHECK([s canAddConnection:pc], @"canAddConnection(preview)");
            [s addConnection:pc];
            CHECK(layer.connection == pc && pc.videoPreviewLayer == layer, @"preview reports its connection");
            [s commitConfiguration];
            CHECK(s.connections.count == 3, @"session.connections = %lu", (unsigned long)s.connections.count);
            [s startRunning];
        });
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
        CHECK(d.frames > 30, @"frames %d", d.frames);
        CHECK(d.code.length > 0, @"code %@", d.code);
        CHECK(layer.sublayers.count > 0, @"preview has content");
        dispatch_sync(q, ^{
            [s beginConfiguration];
            for (AVCaptureConnection *c in s.connections) [s removeConnection:c];
            CHECK(video.connections.count == 0 && layer.connection == nil, @"connections removed");
            for (AVCaptureInput *i in s.inputs) [s removeInput:i];
            for (AVCaptureOutput *o in s.outputs) [s removeOutput:o];
            [s commitConfiguration];
            [s stopRunning];
        });
        NSLog(@"%@ (%d failures)", failures ? @"FAIL" : @"PASS", failures);
    }
    return failures ? 1 : 0;
}
