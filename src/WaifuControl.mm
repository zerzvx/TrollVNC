/*
 WaifuControl.mm — servidor HTTP/JSON de control nativo del tweak.

 Endpoint:  POST /rpc   body = {"method":"<verbo>","params":{...}}
            (tambien acepta GET /health -> {"ok":true,"name":"WaifuControl"})
 Coordenadas de touch: normalizadas 0.0–1.0 (como CatMCP).
 Arranca solo via +load (no toca el main() del daemon). Puerto WAIFU_CONTROL_PORT.

 Verbos: tap, swipe, text, key, home, lock/power, volume_up, volume_down,
         brightness_up, brightness_down, keyboard, launch, kill, apps, url, shell, info.
 */
#import "WaifuControl.h"
#import "STHIDEventGenerator.h"

#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonHMAC.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

// ── private APIs (declaradas inline; la clase se resuelve por NSClassFromString → sin link dep) ──
@interface LSApplicationProxy : NSObject
@property(nonatomic, readonly) NSString *applicationIdentifier;
@property(nonatomic, readonly) NSString *localizedName;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (BOOL)openURL:(NSURL *)url;
- (BOOL)uninstallApplication:(NSString *)bundleID withOptions:(id)options;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

static LSApplicationWorkspace *WFWorkspace(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    return [cls defaultWorkspace];
}

// SpringBoardServices: pid por bundle id (para kill), resuelto en runtime (sin link dep)
static pid_t WFPidForBundle(NSString *bundleID) {
    static pid_t (*fn)(CFStringRef) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (h) fn = (pid_t (*)(CFStringRef))dlsym(h, "SBSProcessIDForDisplayIdentifier");
    });
    return fn ? fn((__bridge CFStringRef)bundleID) : -1;
}

static CGSize screenPoints(void) {
    CGRect b = [UIScreen mainScreen].bounds;
    return b.size;
}

static CGPoint ptFromNorm(double nx, double ny) {
    CGSize s = screenPoints();
    return CGPointMake(nx * s.width, ny * s.height);
}

// ── dispatch de verbos ──
static NSDictionary *WFHandle(NSString *method, NSDictionary *p) {
    if (!method) return @{@"error" : @"missing method"};
    STHIDEventGenerator *hid = [STHIDEventGenerator sharedGenerator];
    double x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];

    if ([method isEqualToString:@"tap"]) {
        // OJO: [hid tap:] de TrollVNC pasa delayBetweenTaps:0 → dispara su propia assertion
        // (STHIDEventGenerator.mm:844 delay>0.0) y el tap FALLA siempre. Usamos sendTaps con un
        // delay válido (para 1 tap el delay no afecta al timing, solo satisface la assertion).
        [hid sendTaps:1 location:ptFromNorm(x, y) numberOfTouches:1 delayBetweenTaps:0.15];
        return @{@"ok" : @YES};
    }
    if ([method isEqualToString:@"swipe"]) {
        double x1 = [p[@"x1"] doubleValue], y1 = [p[@"y1"] doubleValue];
        double x2 = [p[@"x2"] doubleValue], y2 = [p[@"y2"] doubleValue];
        double dur = p[@"duration"] ? [p[@"duration"] doubleValue] / 1000.0 : 0.3;
        if (dur <= 0.0) dur = 0.3; // dragLinear asserta seconds>0.0
        [hid dragLinearWithStartPoint:ptFromNorm(x1, y1) endPoint:ptFromNorm(x2, y2) duration:dur];
        return @{@"ok" : @YES};
    }
    if ([method isEqualToString:@"text"]) {
        NSString *t = p[@"text"] ?: @"";
        for (NSUInteger i = 0; i < t.length; i++) {
            [hid keyPress:[t substringWithRange:NSMakeRange(i, 1)]];
        }
        return @{@"ok" : @YES};
    }
    if ([method isEqualToString:@"key"]) {
        [hid keyPress:(p[@"key"] ?: @"\n")];
        return @{@"ok" : @YES};
    }
    if ([method isEqualToString:@"home"]) { [hid menuPress]; return @{@"ok" : @YES}; }
    if ([method isEqualToString:@"lock"] || [method isEqualToString:@"power"]) {
        [hid powerPress]; return @{@"ok" : @YES};
    }
    if ([method isEqualToString:@"volume_up"]) { [hid volumeIncrementPress]; return @{@"ok" : @YES}; }
    if ([method isEqualToString:@"volume_down"]) { [hid volumeDecrementPress]; return @{@"ok" : @YES}; }
    if ([method isEqualToString:@"brightness_up"]) { [hid displayBrightnessIncrementPress]; return @{@"ok" : @YES}; }
    if ([method isEqualToString:@"brightness_down"]) { [hid displayBrightnessDecrementPress]; return @{@"ok" : @YES}; }
    if ([method isEqualToString:@"keyboard"]) { [hid toggleOnScreenKeyboard]; return @{@"ok" : @YES}; }

    if ([method isEqualToString:@"launch"]) {
        BOOL ok = [WFWorkspace() openApplicationWithBundleID:(p[@"bundle"] ?: @"")];
        return @{@"ok" : @(ok)};
    }
    if ([method isEqualToString:@"kill"]) {
        pid_t pid = WFPidForBundle(p[@"bundle"] ?: @"");
        if (pid > 0) { kill(pid, SIGKILL); return @{@"ok" : @YES, @"pid" : @(pid)}; }
        return @{@"ok" : @NO, @"error" : @"app not running"};
    }
    if ([method isEqualToString:@"apps"]) {
        NSMutableArray *out = [NSMutableArray array];
        @try {
            for (LSApplicationProxy *a in [WFWorkspace() allApplications]) {
                NSString *bid = a.applicationIdentifier;
                if (bid) [out addObject:@{@"bundle" : bid, @"name" : (a.localizedName ?: bid)}];
            }
        } @catch (__unused id e) {}
        return @{@"ok" : @YES, @"apps" : out};
    }
    if ([method isEqualToString:@"url"]) {
        NSURL *u = [NSURL URLWithString:(p[@"url"] ?: @"")];
        BOOL ok = u ? [WFWorkspace() openURL:u] : NO;
        return @{@"ok" : @(ok)};
    }
    if ([method isEqualToString:@"shell"]) {
        NSString *cmd = p[@"command"] ?: @"";
        FILE *fp = popen(cmd.UTF8String, "r");
        NSMutableData *d = [NSMutableData data];
        if (fp) {
            char buf[4096]; size_t n;
            while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [d appendBytes:buf length:n];
            pclose(fp);
        }
        return @{@"ok" : @YES, @"output" : ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"")};
    }
    if ([method isEqualToString:@"notify"]) {
        // webhook saliente firmado (HMAC-SHA256 sobre "ts.body"), estilo Pringles
        NSString *urlS = p[@"url"] ?: @"";
        NSString *secret = p[@"secret"] ?: @"";
        NSData *body = [NSJSONSerialization dataWithJSONObject:(p[@"payload"] ?: @{}) options:0 error:nil] ?: [NSData data];
        NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
        NSMutableData *toSign = [[[ts stringByAppendingString:@"."] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [toSign appendData:body];
        unsigned char mac[CC_SHA256_DIGEST_LENGTH];
        CCHmac(kCCHmacAlgSHA256, secret.UTF8String, strlen(secret.UTF8String), toSign.bytes, toSign.length, mac);
        NSMutableString *hex = [NSMutableString string];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", mac[i]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlS]];
        req.HTTPMethod = @"POST"; req.HTTPBody = body;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:ts forHTTPHeaderField:@"X-Waifu-Timestamp"];
        [req setValue:[@"sha256=" stringByAppendingString:hex] forHTTPHeaderField:@"X-Waifu-Signature"];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSInteger code = 0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                         completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                                             code = [(NSHTTPURLResponse *)r statusCode];
                                             dispatch_semaphore_signal(sem);
                                         }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
        return @{@"ok" : @(code >= 200 && code < 300), @"status" : @(code)};
    }
    if ([method isEqualToString:@"info"]) {
        CGSize s = screenPoints();
        return @{@"ok" : @YES, @"name" : ([UIDevice currentDevice].name ?: @""),
                 @"model" : ([UIDevice currentDevice].model ?: @""),
                 @"screen" : @{@"w" : @(s.width), @"h" : @(s.height)}};
    }
    return @{@"error" : [NSString stringWithFormat:@"unknown method: %@", method]};
}

// ── HTTP mínimo ──
static void WFWriteJSON(int fd, NSDictionary *obj) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [NSData data];
    NSString *hdr = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                                @"Content-Length: %lu\r\nConnection: close\r\n\r\n",
                                                (unsigned long)body.length];
    NSData *h = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, h.bytes, h.length);
    write(fd, body.bytes, body.length);
}

static void WFHandleConnection(int fd) {
    NSMutableData *req = [NSMutableData data];
    char buf[8192];
    NSInteger contentLen = -1;
    NSRange hdrEnd = {NSNotFound, 0};
    // leer cabeceras
    while (hdrEnd.location == NSNotFound) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) { close(fd); return; }
        [req appendBytes:buf length:n];
        hdrEnd = [req rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                          options:0 range:NSMakeRange(0, req.length)];
        if (req.length > 1 << 20) break; // guard
    }
    NSString *head = [[NSString alloc] initWithData:[req subdataWithRange:NSMakeRange(0, hdrEnd.location)]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    if ([head hasPrefix:@"GET /health"] || [head hasPrefix:@"GET / "]) {
        WFWriteJSON(fd, @{@"ok" : @YES, @"name" : @"WaifuControl", @"port" : @(WAIFU_CONTROL_PORT)});
        close(fd); return;
    }
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        if ([[line lowercaseString] hasPrefix:@"content-length:"]) {
            contentLen = [[line substringFromIndex:15] integerValue];
        }
    }
    NSUInteger bodyStart = hdrEnd.location + 4;
    NSMutableData *body = [[req subdataWithRange:NSMakeRange(bodyStart, req.length - bodyStart)] mutableCopy];
    while (contentLen > 0 && (NSInteger)body.length < contentLen) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) break;
        [body appendBytes:buf length:n];
    }
    NSDictionary *resp;
    @try {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        resp = WFHandle(j[@"method"], (j[@"params"] ?: @{}));
    } @catch (id e) {
        resp = @{@"error" : [NSString stringWithFormat:@"%@", e]};
    }
    WFWriteJSON(fd, resp ?: @{@"error" : @"nil"});
    close(fd);
}

@implementation WaifuControl

+ (void)startOnPort:(uint16_t)port {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) return;
        int yes = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(port);
        if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(s); return; }
        if (listen(s, 16) < 0) { close(s); return; }
        NSLog(@"[WaifuControl] escuchando en :%u", port);
        while (1) {
            int fd = accept(s, NULL, NULL);
            if (fd < 0) continue;
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                WFHandleConnection(fd);
            });
        }
    });
}

+ (void)load {
    // Arranca el server de control ~2s tras cargar (device ya en marcha). No toca el main() del daemon.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [WaifuControl startOnPort:WAIFU_CONTROL_PORT];
    });
}

@end
