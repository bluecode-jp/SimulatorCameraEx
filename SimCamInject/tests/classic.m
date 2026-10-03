//
//  classic.m — SimCamInject check: the classic capture setup
//
//  Calls the AVFoundation API camera libraries use (expo-camera, plain
//  AVFoundation apps): discovery, device configuration, addInput/addOutput
//  with implicit connections, preview layer, rotation coordinator, teardown.
//  Passes when nothing crashes and frames and a barcode arrive.
//  `--no-start` skips startRunning, like expo-camera 17 in simulator builds.
//  Run through scripts/test-inject.sh.
//
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#define STEP(name, ...) do { NSLog(@"step: %s", name); __VA_ARGS__; } while (0)
@interface D : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property int frames; @property NSString *code; @property int kvo;
@end
@implementation D
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)b fromConnection:(AVCaptureConnection *)c { self.frames++; }
- (void)captureOutput:(AVCaptureOutput *)o didOutputMetadataObjects:(NSArray *)objs fromConnection:(AVCaptureConnection *)c {
    for (AVMetadataMachineReadableCodeObject *m in objs) self.code = m.stringValue;
}
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)x { self.kvo++; }
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL autoStart = argc > 1 && !strcmp(argv[1], "--no-start");
        D *d = [D new];
        __block AVCaptureDevice *device;
        STEP("discovery", {
            AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInDualCamera,
                                                  AVCaptureDeviceTypeBuiltInTripleCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera]
                mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            device = ds.devices.firstObject;
            NSLog(@"  devices=%@ systemPreferred=%@ userPreferred=%@ default=%@", ds.devices,
                  AVCaptureDevice.systemPreferredCamera, AVCaptureDevice.userPreferredCamera,
                  [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront]);
            NSLog(@"  auth=%ld type=%@ pos=%ld torch=%d", (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo],
                  device.deviceType, (long)device.position, device.hasTorch);
        });
        if (!device) { NSLog(@"FAIL: no device"); return 1; }
        STEP("device config", {
            NSError *e = nil;
            if ([device lockForConfiguration:&e]) {
                if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
                device.videoZoomFactor = MIN(2, device.activeFormat.videoMaxZoomFactor);
                NSLog(@"  zoom=%.1f min=%.1f max=%.1f", device.videoZoomFactor, device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor);
                [device unlockForConfiguration];
            }
        });
        AVCaptureSession *s = [AVCaptureSession new];
        dispatch_queue_t q = dispatch_queue_create("captureSessionQueue", 0);
        __block AVCaptureVideoPreviewLayer *layer;
        STEP("preview layer", { layer = [AVCaptureVideoPreviewLayer layerWithSession:s]; layer.frame = CGRectMake(0, 0, 390, 844);
                                layer.videoGravity = AVLayerVideoGravityResizeAspectFill; });
        dispatch_sync(q, ^{
            STEP("configure", {
                [s beginConfiguration];
                if ([s canSetSessionPreset:AVCaptureSessionPresetHigh]) s.sessionPreset = AVCaptureSessionPresetHigh;
                AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
                if ([s canAddInput:in]) [s addInput:in];
                AVCapturePhotoOutput *photo = [AVCapturePhotoOutput new];
                if ([s canAddOutput:photo]) [s addOutput:photo];
                AVCaptureMovieFileOutput *movie = [AVCaptureMovieFileOutput new];
                if ([s canAddOutput:movie]) [s addOutput:movie];
                AVCaptureMetadataOutput *m = [AVCaptureMetadataOutput new];
                if ([s canAddOutput:m]) [s addOutput:m];
                [m setMetadataObjectsDelegate:d queue:dispatch_get_main_queue()];
                NSArray *avail = m.availableMetadataObjectTypes;
                m.metadataObjectTypes = [avail containsObject:AVMetadataObjectTypeQRCode] ? @[AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN13Code] : @[];
                m.rectOfInterest = CGRectMake(0, 0, 1, 1);
                AVCaptureVideoDataOutput *v = [AVCaptureVideoDataOutput new];
                v.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
                if ([s canAddOutput:v]) [s addOutput:v];
                [v setSampleBufferDelegate:d queue:dispatch_get_main_queue()];
                AVCaptureConnection *c = [v connectionWithMediaType:AVMediaTypeVideo];
                if ([c isVideoRotationAngleSupported:90]) c.videoRotationAngle = 90;
                if (c.isVideoStabilizationSupported) c.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
                [s commitConfiguration];
                NSLog(@"  inputs=%lu outputs=%lu metadataTypes=%lu", (unsigned long)s.inputs.count, (unsigned long)s.outputs.count, (unsigned long)m.metadataObjectTypes.count);
            });
            if (!autoStart) STEP("startRunning", [s startRunning]);
        });
        if (@available(iOS 17.0, *)) {
            STEP("rotation coordinator", {
                AVCaptureDeviceRotationCoordinator *rc = [[AVCaptureDeviceRotationCoordinator alloc] initWithDevice:device previewLayer:layer];
                [rc addObserver:d forKeyPath:@"videoRotationAngleForHorizonLevelPreview" options:NSKeyValueObservingOptionNew context:NULL];
                NSLog(@"  preview=%.0f capture=%.0f", rc.videoRotationAngleForHorizonLevelPreview, rc.videoRotationAngleForHorizonLevelCapture);
                layer.connection.videoRotationAngle = rc.videoRotationAngleForHorizonLevelPreview;
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
                [rc removeObserver:d forKeyPath:@"videoRotationAngleForHorizonLevelPreview"];
            });
        } else {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
        }
        NSLog(@"  running=%d frames=%d code=%@", s.isRunning, d.frames, d.code);
        dispatch_sync(q, ^{
            STEP("stop + teardown", {
                [s stopRunning];
                [s beginConfiguration];
                for (AVCaptureInput *i in s.inputs) [s removeInput:i];
                for (AVCaptureOutput *o in s.outputs) [s removeOutput:o];
                [s commitConfiguration];
            });
        });
        BOOL ok = d.frames > 30 && d.code.length > 0;
        NSLog(@"%@ frames=%d code=%@", ok ? @"PASS" : @"FAIL", d.frames, d.code);
        return ok ? 0 : 1;
    }
}
