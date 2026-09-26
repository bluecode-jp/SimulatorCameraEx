//
//  SimCamFrameSource.m
//  SimCamInject
//
//  Pulls frames from the SimulatorCamera Mac app (SimulatorFeed.swift) over
//  loopback TCP on a background thread and keeps the newest one. Simulator
//  apps are host processes, so 127.0.0.1 is the Mac itself. While the app is
//  not running, or has sent nothing for a second (test pattern selected),
//  a built-in test pattern is returned instead.
//

#import "SimCamFrameSource.h"

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <os/log.h>
#import <sys/socket.h>
#import <unistd.h>

static const size_t kWidth = 1280;
static const size_t kHeight = 720;
static const uint16_t kDefaultPort = 47847;  // kSimCamFeedPort
static const double kStaleAfterSeconds = 1.0;

static os_log_t SCSourceLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("jp.co.bluecode.SimCamInject", "source"); });
    return log;
}

static CVPixelBufferPoolRef SCPool(void) {
    static CVPixelBufferPoolRef pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(kWidth),
            (id)kCVPixelBufferHeightKey: @(kHeight),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (CFDictionaryRef)attrs, &pool);
    });
    return pool;
}

// MARK: - Test pattern

/// Colour bars with a white band scrolling down, so a frozen feed is obvious.
static CVPixelBufferRef SCCopyTestPattern(void) {
    static uint64_t tick;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, SCPool(), &pb) != kCVReturnSuccess) return NULL;
    static const uint8_t bars[8][3] = { // BGR
        {255, 255, 255}, {0, 255, 255}, {255, 255, 0}, {0, 255, 0},
        {255, 0, 255}, {0, 0, 255}, {255, 0, 0}, {0, 0, 0},
    };
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    size_t band = (tick * 8) % kHeight;
    for (size_t y = 0; y < kHeight; y++) {
        uint32_t *row = (uint32_t *)(base + y * stride);
        BOOL inBand = y >= band && y < band + 24;
        for (size_t x = 0; x < kWidth; x++) {
            const uint8_t *c = bars[x * 8 / kWidth];
            row[x] = inBand ? 0xFFFFFFFF : (0xFF000000u | (uint32_t)c[2] << 16 | (uint32_t)c[1] << 8 | c[0]);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    tick++;
    return pb;
}

// MARK: - Network feed

static NSObject *gFeedLock;
static CVPixelBufferRef gLatest;      // guarded by gFeedLock
static NSData *gLatestMeta;           // guarded by gFeedLock
static CFAbsoluteTime gLatestAt;      // guarded by gFeedLock

static BOOL SCReadFully(int fd, void *buffer, size_t length) {
    uint8_t *p = buffer;
    while (length > 0) {
        ssize_t n = recv(fd, p, length, 0);
        if (n <= 0) return NO;
        p += n;
        length -= (size_t)n;
    }
    return YES;
}

static int SCConnect(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct sockaddr_in addr = { .sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(port) };
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/// Read frames until the connection drops. Returns frames read.
static uint64_t SCReadFrames(int fd) {
    uint64_t count = 0;
    NSMutableData *scratch = [NSMutableData data];
    for (;;) {
        @autoreleasepool {
            uint32_t header[5];
            if (!SCReadFully(fd, header, sizeof(header))) return count;
            if (memcmp(&header[0], "SCF1", 4) != 0) {
                os_log_error(SCSourceLog(), "bad frame magic, dropping connection");
                return count;
            }
            uint32_t width = CFSwapInt32LittleToHost(header[1]);
            uint32_t height = CFSwapInt32LittleToHost(header[2]);
            uint32_t srcStride = CFSwapInt32LittleToHost(header[3]);
            uint32_t metaLength = CFSwapInt32LittleToHost(header[4]);
            size_t pixelBytes = (size_t)height * srcStride;
            if (width == 0 || height == 0 || srcStride < width * 4 || pixelBytes > 64u << 20 || metaLength > 1u << 20) {
                os_log_error(SCSourceLog(), "bad frame header %ux%u stride %u", width, height, srcStride);
                return count;
            }
            [scratch setLength:pixelBytes];
            if (!SCReadFully(fd, scratch.mutableBytes, pixelBytes)) return count;
            NSMutableData *meta = [NSMutableData dataWithLength:metaLength];
            if (metaLength && !SCReadFully(fd, meta.mutableBytes, metaLength)) return count;

            // Frames are canonical 1280x720; anything else is dropped rather
            // than scaled, the Mac app normalizes every source already.
            if (width != kWidth || height != kHeight) continue;
            CVPixelBufferRef pb = NULL;
            if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, SCPool(), &pb) != kCVReturnSuccess) continue;
            CVPixelBufferLockBaseAddress(pb, 0);
            uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
            size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
            const uint8_t *src = scratch.bytes;
            for (size_t y = 0; y < kHeight; y++) memcpy(dst + y * dstStride, src + y * srcStride, kWidth * 4);
            CVPixelBufferUnlockBaseAddress(pb, 0);

            @synchronized (gFeedLock) {
                if (gLatest) CVPixelBufferRelease(gLatest);
                gLatest = pb;
                [gLatestMeta release];
                gLatestMeta = [meta copy];
                gLatestAt = CFAbsoluteTimeGetCurrent();
            }
            count++;
        }
    }
}

static void SCFeedThread(void) {
    const char *portEnv = getenv("SIMCAM_PORT");
    uint16_t port = portEnv ? (uint16_t)atoi(portEnv) : kDefaultPort;
    BOOL reportedDown = NO;
    for (;;) {
        int fd = SCConnect(port);
        if (fd < 0) {
            if (!reportedDown) {
                os_log(SCSourceLog(), "Mac app not reachable on 127.0.0.1:%u, using test pattern", port);
                reportedDown = YES;
            }
            sleep(1);
            continue;
        }
        os_log(SCSourceLog(), "connected to Mac app on 127.0.0.1:%u", port);
        reportedDown = NO;
        uint64_t frames = SCReadFrames(fd);
        close(fd);
        os_log(SCSourceLog(), "Mac app connection closed after %llu frames", frames);
    }
}

static void SCStartFeed(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gFeedLock = [NSObject new];
        NSThread *thread = [[NSThread alloc] initWithBlock:^{ SCFeedThread(); }];
        thread.name = @"SimCamInject.feed";
        thread.qualityOfService = NSQualityOfServiceUserInitiated;
        [thread start];
        [thread release];
    });
}

// MARK: - Public

CVPixelBufferRef SCFrameSourceCopyFrame(void) {
    SCStartFeed();
    @synchronized (gFeedLock) {
        if (gLatest && CFAbsoluteTimeGetCurrent() - gLatestAt < kStaleAfterSeconds) {
            return CVPixelBufferRetain(gLatest);
        }
    }
    return SCCopyTestPattern();
}

NSData *SCFrameSourceCopyMeta(void) {
    SCStartFeed();
    @synchronized (gFeedLock) {
        if (gLatestMeta && CFAbsoluteTimeGetCurrent() - gLatestAt < kStaleAfterSeconds) return [gLatestMeta retain];
    }
    return nil;
}
