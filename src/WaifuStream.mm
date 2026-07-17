/*
 WaifuStream.mm — servidor JPEG-sobre-WebSocket (estilo DUFF).
 Ver WaifuStream.h para la arquitectura. GPLv2 (parte de TrollVNC).
*/
#import "WaifuStream.h"
#import "ScreenCapturer.h"

#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h> // kCGImageDestinationLossyCompressionQuality
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

// ── config (override por env en el plist del daemon) ──
static double gFps = 20.0;    // fps objetivo del stream
static double gQuality = 0.4; // calidad JPEG 0..1
static double gScale = 0.5;   // factor de reescalado (0.5 = mitad)

// ── estado ──
static NSMutableArray<NSNumber *> *gClients; // fds de clientes WS
static NSObject *gClientsLock;
static dispatch_queue_t gEncodeQ;   // serial: encode + broadcast
static CIContext *gCICtx;           // GPU-backed
static CGColorSpaceRef gRGB;
static atomic_int gInflight = 0;    // 1 mientras encodamos → drop de los intermedios
static double gLastPush = 0.0;      // throttle de fps
static NSData *gLastJPEG = nil;     // frame-diff: saltar frames idénticos

static inline double nowSec(void) { return CACurrentMediaTime(); }

static int clientCount(void) {
    @synchronized(gClientsLock) {
        return (int)gClients.count;
    }
}

static void removeClient(int fd) {
    @synchronized(gClientsLock) {
        [gClients removeObject:@(fd)];
    }
    close(fd);
}

static bool writeAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t left = len;
    while (left) {
        ssize_t n = send(fd, p, left, 0);
        if (n > 0) {
            p += n;
            left -= (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        return false; // EAGAIN (timeout SO_SNDTIMEO) o error → soltar cliente
    }
    return true;
}

// Envía un frame binario WS (server→client, sin máscara) a todos los clientes.
static void broadcastJPEG(NSData *payload) {
    NSUInteger len = payload.length;
    uint8_t hdr[10];
    size_t hlen = 0;
    hdr[0] = 0x82; // FIN + opcode binary
    if (len < 126) {
        hdr[1] = (uint8_t)len;
        hlen = 2;
    } else if (len < 65536) {
        hdr[1] = 126;
        hdr[2] = (uint8_t)((len >> 8) & 0xff);
        hdr[3] = (uint8_t)(len & 0xff);
        hlen = 4;
    } else {
        hdr[1] = 127;
        for (int i = 0; i < 8; i++)
            hdr[2 + i] = (uint8_t)((len >> (8 * (7 - i))) & 0xff);
        hlen = 10;
    }

    NSArray<NSNumber *> *snapshot;
    @synchronized(gClientsLock) {
        snapshot = [gClients copy];
    }
    for (NSNumber *n in snapshot) {
        int fd = n.intValue;
        if (!writeAll(fd, hdr, hlen) || !writeAll(fd, payload.bytes, len)) {
            removeClient(fd);
        }
    }
}

static void encodeAndBroadcast(CVPixelBufferRef pb) {
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci)
        return;
    if (gScale < 0.999) {
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(gScale, gScale)];
    }
    NSDictionary *opts = @{(id)kCGImageDestinationLossyCompressionQuality : @(gQuality)};
    NSData *jpeg = [gCICtx JPEGRepresentationOfImage:ci colorSpace:gRGB options:opts];
    if (!jpeg.length)
        return;
    if (gLastJPEG && [gLastJPEG isEqualToData:jpeg])
        return; // pantalla estática → no reenviar
    gLastJPEG = jpeg;
    broadcastJPEG(jpeg);
}

// Punto de tee llamado por el gFrameHandler del daemon en cada frame capturado.
void WFStreamPushSampleBuffer(CMSampleBufferRef sb) {
    if (!gClients || clientCount() == 0)
        return;
    double t = nowSec();
    if (t - gLastPush < 1.0 / gFps)
        return; // throttle de fps
    if (atomic_load(&gInflight) > 0)
        return; // aún encodando el anterior → dropear este (latest-only)
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb)
        return;
    gLastPush = t;
    atomic_fetch_add(&gInflight, 1);
    CVPixelBufferRetain(pb);
    dispatch_async(gEncodeQ, ^{
        @autoreleasepool {
            encodeAndBroadcast(pb);
        }
        CVPixelBufferRelease(pb);
        atomic_fetch_sub(&gInflight, 1);
    });
}

static NSString *headerValue(NSString *head, NSString *name) {
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSRange r = [line rangeOfString:@":"];
        if (r.location != NSNotFound) {
            NSString *k = [[line substringToIndex:r.location]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([k caseInsensitiveCompare:name] == NSOrderedSame)
                return [[line substringFromIndex:r.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

static void handleNewConn(int fd) {
    NSMutableData *req = [NSMutableData data];
    char buf[4096];
    NSRange end = {NSNotFound, 0};
    while (end.location == NSNotFound) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            close(fd);
            return;
        }
        [req appendBytes:buf length:(NSUInteger)n];
        end = [req rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                       options:0
                         range:NSMakeRange(0, req.length)];
        if (req.length > 32768) {
            close(fd);
            return;
        }
    }
    NSString *head = [[NSString alloc] initWithData:[req subdataWithRange:NSMakeRange(0, end.location)]
                                           encoding:NSUTF8StringEncoding]
                         ?: @"";
    NSString *key = headerValue(head, @"Sec-WebSocket-Key");
    if (!key) {
        // GET normal → health (para el health-check TCP/HTTP del relay)
        NSString *j = [NSString stringWithFormat:@"{\"ok\":true,\"name\":\"WaifuStream\",\"port\":%u}", WAIFU_STREAM_PORT];
        NSString *resp = [NSString
            stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: "
                             @"close\r\n\r\n%@",
                             (unsigned long)j.length, j];
        NSData *d = [resp dataUsingEncoding:NSUTF8StringEncoding];
        write(fd, d.bytes, d.length);
        close(fd);
        return;
    }
    // handshake WS
    NSString *magic = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    NSData *keyData = [magic dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char sha[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(keyData.bytes, (CC_LONG)keyData.length, sha);
    NSString *accept = [[NSData dataWithBytes:sha length:CC_SHA1_DIGEST_LENGTH] base64EncodedStringWithOptions:0];
    NSString *resp = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: "
                                                @"Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
                                                accept];
    NSData *rd = [resp dataUsingEncoding:NSUTF8StringEncoding];
    if (write(fd, rd.bytes, rd.length) < 0) {
        close(fd);
        return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval tv = {0, 300 * 1000}; // 300ms SO_SNDTIMEO → cliente lento se dropea, no atasca
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    @synchronized(gClientsLock) {
        [gClients addObject:@(fd)];
    }
    gLastJPEG = nil; // forzar que el nuevo cliente reciba un frame aunque esté estática
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ScreenCapturer sharedCapturer] forceNextFrameUpdate];
    });
    NSLog(@"[WaifuStream] cliente conectado fd=%d (total=%d)", fd, clientCount());

    // lector: solo detecta cierre (el input va por WaifuControl:46900)
    char rbuf[2048];
    while (1) {
        ssize_t n = read(fd, rbuf, sizeof(rbuf));
        if (n <= 0)
            break;
        if (n >= 1 && (rbuf[0] & 0x0f) == 0x8)
            break; // opcode close
    }
    removeClient(fd);
    NSLog(@"[WaifuStream] cliente desconectado fd=%d (total=%d)", fd, clientCount());
}

static void readEnvConfig(void) {
    char *e;
    if ((e = getenv("WAIFU_STREAM_FPS"))) {
        double v = atof(e);
        if (v > 0 && v <= 60)
            gFps = v;
    }
    if ((e = getenv("WAIFU_STREAM_QUALITY"))) {
        double v = atof(e);
        if (v > 0 && v <= 1)
            gQuality = v;
    }
    if ((e = getenv("WAIFU_STREAM_SCALE"))) {
        double v = atof(e);
        if (v > 0 && v <= 1)
            gScale = v;
    }
}

@implementation WaifuStream

+ (void)startOnPort:(uint16_t)port {
    gClients = [NSMutableArray array];
    gClientsLock = [NSObject new];
    gEncodeQ = dispatch_queue_create("com.zerzvx.waifustream.encode", DISPATCH_QUEUE_SERIAL);
    gRGB = CGColorSpaceCreateDeviceRGB();
    gCICtx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace : [NSNull null]}];
    readEnvConfig();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0)
            return;
        int yes = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(port);
        if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            NSLog(@"[WaifuStream] bind falló en :%u", port);
            close(s);
            return;
        }
        if (listen(s, 16) < 0) {
            close(s);
            return;
        }
        NSLog(@"[WaifuStream] escuchando en :%u (fps=%.0f q=%.2f scale=%.2f)", port, gFps, gQuality, gScale);
        while (1) {
            int fd = accept(s, NULL, NULL);
            if (fd < 0)
                continue;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                handleNewConn(fd);
            });
        }
    });
}

+ (void)load {
    // Arranca ~3s tras cargar (deja que el daemon monte la captura primero).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [WaifuStream startOnPort:WAIFU_STREAM_PORT];
    });
}

@end
