/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import "GitHubReleaseUpdater.h"
#import "DpkgVersion.h"

// DEBUG-only logging macro for this implementation only.
#if DEBUG
#define GHRULog(fmt, ...) NSLog((@"[GHUpdater] " fmt), ##__VA_ARGS__)
#else
#define GHRULog(fmt, ...)                                                                                              \
    do {                                                                                                               \
    } while (0)
#endif

static NSString *const kGHUpdaterDefaultsSuite = @"com.zerzvx.waifuvnc.GitHubReleaseUpdater.Defaults";
static NSString *const kKeyPausedUntil = @"pausedUntil";
static NSString *const kKeySkippedVersion = @"skippedVersion";
static NSString *const kKeyLastCheckAt = @"lastCheckAt";
static NSString *const kKeyETag = @"eTag";

NSString *const GitHubReleaseUpdaterDidFindUpdateNotification = @"GitHubReleaseUpdaterDidFindUpdateNotification";
NSString *const GitHubReleaseUpdaterErrorDomain = @"GitHubReleaseUpdater";

#pragma mark - GHReleaseInfo

@implementation GHReleaseInfo

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)copyWithZone:(NSZone *)zone {
    GHReleaseInfo *c = [[[self class] allocWithZone:zone] init];
    c.tagName = [self.tagName copy];
    c.versionString = [self.versionString copy];
    c.name = [self.name copy];
    c.body = [self.body copy];
    c.htmlURL = [self.htmlURL copy];
    c.publishedAt = [self.publishedAt copy];
    c.prerelease = self.prerelease;
    c.isNewerThanCurrent = self.isNewerThanCurrent;
    return c;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.tagName forKey:@"tagName"];
    [coder encodeObject:self.versionString forKey:@"versionString"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.body forKey:@"body"];
    [coder encodeObject:self.htmlURL forKey:@"htmlURL"];
    [coder encodeObject:self.publishedAt forKey:@"publishedAt"];
    [coder encodeBool:self.prerelease forKey:@"prerelease"];
    [coder encodeBool:self.isNewerThanCurrent forKey:@"isNewerThanCurrent"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        _tagName = [[coder decodeObjectOfClass:[NSString class] forKey:@"tagName"] copy];
        _versionString = [[coder decodeObjectOfClass:[NSString class] forKey:@"versionString"] copy];
        _name = [[coder decodeObjectOfClass:[NSString class] forKey:@"name"] copy];
        _body = [[coder decodeObjectOfClass:[NSString class] forKey:@"body"] copy];
        _htmlURL = [[coder decodeObjectOfClass:[NSString class] forKey:@"htmlURL"] copy];
        _publishedAt = [[coder decodeObjectOfClass:[NSString class] forKey:@"publishedAt"] copy];
        _prerelease = [coder decodeBoolForKey:@"prerelease"];
        _isNewerThanCurrent = [coder decodeBoolForKey:@"isNewerThanCurrent"];
    }
    return self;
}

- (NSString *)description {
    return
        [NSString stringWithFormat:@"<%@: %p, tagName: %@, versionString: %@, name: %@, body: %@, htmlURL: %@, "
                                   @"publishedAt: %@, prerelease: %@>",
                                   NSStringFromClass([self class]), self, self.tagName, self.versionString, self.name,
                                   self.body, self.htmlURL, self.publishedAt, self.prerelease ? @"YES" : @"NO"];
}

@end

#pragma mark - GHUpdateStrategy

@implementation GHUpdateStrategy

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)init {
    if (self = [super init]) {
        _repoFullName = @"";
        _minimumCheckInterval = 6 * 60 * 60; // 6h
        _maxRetryCount = 3;
        _minRetryInterval = 60; // 60s
        _includePrereleases = NO;
        _githubToken = nil;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    GHUpdateStrategy *c = [[[self class] allocWithZone:zone] init];
    c.repoFullName = [self.repoFullName copy];
    c.minimumCheckInterval = self.minimumCheckInterval;
    c.maxRetryCount = self.maxRetryCount;
    c.minRetryInterval = self.minRetryInterval;
    c.includePrereleases = self.includePrereleases;
    c.githubToken = [self.githubToken copy];
    return c;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.repoFullName forKey:@"repoFullName"];
    [coder encodeDouble:self.minimumCheckInterval forKey:@"minimumCheckInterval"];
    [coder encodeInteger:self.maxRetryCount forKey:@"maxRetryCount"];
    [coder encodeDouble:self.minRetryInterval forKey:@"minRetryInterval"];
    [coder encodeBool:self.includePrereleases forKey:@"includePrereleases"];
    [coder encodeObject:self.githubToken forKey:@"githubToken"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        _repoFullName = [[coder decodeObjectOfClass:[NSString class] forKey:@"repoFullName"] copy] ?: @"";
        _minimumCheckInterval = [coder decodeDoubleForKey:@"minimumCheckInterval"];
        _maxRetryCount = [coder decodeIntegerForKey:@"maxRetryCount"];
        _minRetryInterval = [coder decodeDoubleForKey:@"minRetryInterval"];
        _includePrereleases = [coder decodeBoolForKey:@"includePrereleases"];
        _githubToken = [[coder decodeObjectOfClass:[NSString class] forKey:@"githubToken"] copy];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, repoFullName: %@, minCheckInterval: %.0fs, maxRetryCount: %ld, "
                                       "minRetryInterval: %.0fs, includePrereleases: %@, githubToken: %@>",
                                      NSStringFromClass([self class]), self, self.repoFullName,
                                      self.minimumCheckInterval, (long)self.maxRetryCount, self.minRetryInterval,
                                      self.includePrereleases ? @"YES" : @"NO", self.githubToken ?: @"<none>"];
}

@end

#pragma mark - GitHubReleaseUpdater

@interface GitHubReleaseUpdater ()
@property(nonatomic, strong) GHUpdateStrategy *strategy;
@property(nonatomic, copy) NSString *currentVersion;
@property(nonatomic, strong) GHReleaseInfo *cachedLatest;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) dispatch_queue_t queue;  // serial queue for all state
@property(nonatomic, strong) dispatch_source_t timer; // periodic checks
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, copy) NSString *defaultsPrefix; // unique per repo
@end

@implementation GitHubReleaseUpdater

+ (instancetype)shared {
    static GitHubReleaseUpdater *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[GitHubReleaseUpdater alloc] initPrivate];
    });
    return inst;
}

- (instancetype)initPrivate {
    if (self = [super init]) {
        _queue = dispatch_queue_create("com.zerzvx.waifuvnc.GitHubReleaseUpdater.queue", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.timeoutIntervalForRequest = 30;
        cfg.HTTPAdditionalHeaders =
            @{@"Accept" : @"application/vnd.github+json", @"X-GitHub-Api-Version" : @"2022-11-28"};
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kGHUpdaterDefaultsSuite];
    }
    return self;
}

- (instancetype)init {
    NSAssert(NO, @"Use +shared");
    return nil;
}

#pragma mark - Public API

- (void)configureWithStrategy:(GHUpdateStrategy *)strategy {
    NSString *currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    [self configureWithStrategy:strategy currentVersion:currentVersion];
}

- (void)configureWithStrategy:(GHUpdateStrategy *)strategy currentVersion:(NSString *)currentVersion {
    if (strategy.repoFullName.length == 0) {
        GHRULog("Invalid repoFullName in strategy");
    }
    GHRULog("Configuring updater with strategy: %@, currentVersion: %@", strategy, currentVersion);
    dispatch_sync(self.queue, ^{
        self.strategy = [strategy copy];
        self.currentVersion = [currentVersion copy] ?: @"";
        self.defaultsPrefix = [self _defaultsPrefixForRepo:self.strategy.repoFullName];
        [self _loadCachedLatestLocked];
        [self _setupTimerLockedIfNeeded];
    });
}

- (void)start {
    dispatch_sync(self.queue, ^{
        [self _setupTimerLockedIfNeeded];
        [self _rescheduleTimerLocked];
    });
}

- (void)stop {
    dispatch_sync(self.queue, ^{
        if (self.timer) {
            dispatch_source_cancel(self.timer);
            self.timer = nil;
        }
        [self _cancelTaskLocked];
    });
}

- (void)checkNowWithCompletion:(GHUpdateCheckCompletion)completion {
    dispatch_async(self.queue, ^{
        [self _performCheckLockedIgnoreInterval:YES completion:completion];
    });
}

- (void)pauseUntil:(NSDate *)date {
    dispatch_async(self.queue, ^{
        [self.defaults setObject:date forKey:[self _k:kKeyPausedUntil]];
        [self.defaults synchronize];
        GHRULog("Paused checks until %@", date);
        [self _rescheduleTimerLocked];
    });
}

- (void)pauseFor:(NSTimeInterval)interval {
    [self pauseUntil:[NSDate dateWithTimeIntervalSinceNow:interval]];
}

- (void)skipVersion:(NSString *)versionString {
    dispatch_async(self.queue, ^{
        [self.defaults setObject:versionString forKey:[self _k:kKeySkippedVersion]];
        [self.defaults synchronize];
        GHRULog("Skipping version %@", versionString);
    });
}

- (void)clearSkippedVersion {
    dispatch_async(self.queue, ^{
        [self.defaults removeObjectForKey:[self _k:kKeySkippedVersion]];
        [self.defaults synchronize];
    });
}

- (GHReleaseInfo *)cachedLatestRelease {
    __block GHReleaseInfo *r = nil;
    dispatch_sync(self.queue, ^{
        r = [self.cachedLatest copy];
    });
    return r;
}

- (BOOL)hasNewerVersionInCache {
    __block BOOL newer = NO;
    dispatch_sync(self.queue, ^{
        newer = [self _isReleaseNewerLocked:self.cachedLatest];
    });
    return newer;
}

#pragma mark - Internals (locked)

- (NSString *)_defaultsPrefixForRepo:(NSString *)repo {
    if (repo.length == 0)
        return @"default";
    NSString *safe = [[repo lowercaseString] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [NSString stringWithFormat:@"gh_%@_", safe];
}

- (NSString *)_k:(NSString *)suffix {
    return [self.defaultsPrefix stringByAppendingString:suffix];
}

- (NSURL *)_cacheFileURLLocked {
    NSArray<NSURL *> *dirs = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                    inDomains:NSUserDomainMask];
    NSURL *dir =
        dirs.firstObject
            ?: [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"GitHubReleaseUpdater"]
                          isDirectory:YES];
    dir = [dir URLByAppendingPathComponent:@"GitHubReleaseUpdater" isDirectory:YES];
    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&err];
    if (err) {
        GHRULog("Failed ensuring cache dir: %@", err);
    }
    NSString *fname = [NSString stringWithFormat:@"%@latest.archive", self.defaultsPrefix ?: @"default_"];
    return [dir URLByAppendingPathComponent:fname];
}

- (void)_loadCachedLatestLocked {
    NSURL *url = [self _cacheFileURLLocked];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length > 0) {
        NSError *err = nil;
        GHReleaseInfo *info = [NSKeyedUnarchiver unarchivedObjectOfClass:[GHReleaseInfo class]
                                                                fromData:data
                                                                   error:&err];
        if (info && !err) {
            self.cachedLatest = info;
            GHRULog("Loaded cached release: %@ (%@)", info.tagName, info.versionString);
        }
    }
}

- (void)_saveCachedLatestLocked {
    if (!self.cachedLatest)
        return;
    NSURL *url = [self _cacheFileURLLocked];
    NSError *err = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.cachedLatest requiringSecureCoding:YES error:&err];
    if (data) {
        [data writeToURL:url atomically:YES];
    } else {
        GHRULog("Failed archiving cache: %@", err);
    }
}

- (NSDate *)_pausedUntilLocked {
    NSDate *d = [self.defaults objectForKey:[self _k:kKeyPausedUntil]];
    return d ?: [NSDate dateWithTimeIntervalSince1970:0];
}

- (NSString *)_skippedVersionLocked {
    return [self.defaults stringForKey:[self _k:kKeySkippedVersion]] ?: @"";
}

- (NSDate *)_lastCheckAtLocked {
    id obj = [self.defaults objectForKey:[self _k:kKeyLastCheckAt]];
    NSDate *d = [obj isKindOfClass:[NSDate class]] ? (NSDate *)obj : nil;
    // If the stored last check time is in the future (device clock was moved back), clear it.
    if (d && [d timeIntervalSinceNow] > 0) {
        GHRULog("Detected invalid lastCheckAt in future (%@); clearing.", d);
        [self.defaults removeObjectForKey:[self _k:kKeyLastCheckAt]];
        [self.defaults synchronize];
        return [NSDate dateWithTimeIntervalSince1970:0];
    }
    return d ?: [NSDate dateWithTimeIntervalSince1970:0];
}

- (void)_setLastCheckNowLocked {
    NSDate *now = [NSDate date];
    [self.defaults setObject:now forKey:[self _k:kKeyLastCheckAt]];
    [self.defaults synchronize];
}

- (NSString *)_etagLocked {
    return [self.defaults stringForKey:[self _k:kKeyETag]];
}
- (void)_setETagLocked:(NSString *)etag {
    if (etag) {
        [self.defaults setObject:etag forKey:[self _k:kKeyETag]];
        [self.defaults synchronize];
    }
}

- (BOOL)_eligibleForCheckLocked {
    if (self.strategy.repoFullName.length == 0)
        return NO;
    NSDate *pausedUntil = [self _pausedUntilLocked];
    if ([pausedUntil timeIntervalSinceNow] > 0) {
        return NO;
    }
    NSTimeInterval since = [[NSDate date] timeIntervalSinceDate:[self _lastCheckAtLocked]];
    return since >= MAX(0, self.strategy.minimumCheckInterval);
}

- (void)_setupTimerLockedIfNeeded {
    if (self.timer)
        return;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        __strong typeof(self) s = weakSelf;
        if (!s)
            return;
        [s _timerFiredLocked];
    });
    dispatch_resume(self.timer);
}

- (void)_rescheduleTimerLocked {
    if (!self.timer)
        return;
    NSDate *pausedUntil = [self _pausedUntilLocked];
    NSDate *last = [self _lastCheckAtLocked];
    NSDate *now = [NSDate date];
    NSDate *earliest = [last dateByAddingTimeInterval:self.strategy.minimumCheckInterval];
    NSDate *next = [now laterDate:[pausedUntil laterDate:earliest]];
    NSTimeInterval delta = MAX(1, [next timeIntervalSinceDate:now]);
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delta * NSEC_PER_SEC)),
                              (uint64_t)(self.strategy.minimumCheckInterval * NSEC_PER_SEC),
                              (uint64_t)(5 * NSEC_PER_SEC));
    GHRULog("Timer scheduled in %.0fs (min interval=%.0fs)", delta, self.strategy.minimumCheckInterval);
}

- (void)_timerFiredLocked {
    [self _performCheckLockedIgnoreInterval:NO completion:nil];
}

- (void)_cancelTaskLocked {
    if (self.task && self.task.state == NSURLSessionTaskStateRunning) {
        [self.task cancel];
    }
    self.task = nil;
}

- (void)_performCheckLockedIgnoreInterval:(BOOL)ignoreInterval completion:(GHUpdateCheckCompletion)completion {
    if (!ignoreInterval && ![self _eligibleForCheckLocked]) {
        GHRULog("Not eligible for check yet, skipping");
        if (completion) {
            BOOL fromCache = (self.cachedLatest != nil);
            completion([self.cachedLatest copy], nil, fromCache);
        }
        [self _rescheduleTimerLocked];
        return;
    }

    NSDate *pausedUntil = [self _pausedUntilLocked];
    if ([pausedUntil timeIntervalSinceNow] > 0) {
        GHRULog("Update check paused until %@", pausedUntil);
        if (completion)
            completion(nil, [self _error:@"Paused" code:1], YES);
        [self _rescheduleTimerLocked];
        return;
    }

    [self _cancelTaskLocked];

    GHRULog("Checking releases for %@...", self.strategy.repoFullName);
    [self _setLastCheckNowLocked];

    __weak typeof(self) weakSelf2 = self;
    [self _fetchLatestReleaseLockedWithRetry:0
                                  completion:^(GHReleaseInfo *latest, NSString *_Nullable etag, NSError *error,
                                               BOOL fromCache) {
                                      __strong typeof(self) s = weakSelf2;
                                      if (!s)
                                          return;
                                      if (etag.length > 0) {
                                          [s _setETagLocked:etag];
                                      }

                                      if (latest && !error) {
                                          s.cachedLatest = latest;
                                          [s _saveCachedLatestLocked];
                                          BOOL newer = [s _isReleaseNewerLocked:latest];
                                          [latest setIsNewerThanCurrent:newer];
                                          GHRULog("Latest upstream: %@ (newer=%@)", latest.versionString,
                                                  newer ? @"YES" : @"NO");
                                          if (newer) {
                                              [[NSNotificationCenter defaultCenter]
                                                  postNotificationName:GitHubReleaseUpdaterDidFindUpdateNotification
                                                                object:s
                                                              userInfo:@{@"release" : latest}];
                                          }
                                          if (completion)
                                              completion([latest copy], nil, NO);
                                      } else {
                                          GHRULog("Check failed: %@", error);
                                          if (completion)
                                              completion([s.cachedLatest copy], error, YES);
                                      }
                                      [s _rescheduleTimerLocked];
                                  }];
}

- (BOOL)_isReleaseNewerLocked:(GHReleaseInfo *)releaseInfo {
    if (!releaseInfo || self.currentVersion.length == 0)
        return NO;
    NSString *skip = [self _skippedVersionLocked];
    if (skip.length > 0) {
        // If the upstream version is <= skipped version, suppress
        NSInteger cmp = [DpkgVersion compareVersionString:releaseInfo.versionString to:skip];
        if (cmp <= 0) {
            return NO;
        }
    }
    NSInteger r = [DpkgVersion compareVersionString:self.currentVersion to:releaseInfo.versionString];
    return (r < 0);
}

- (NSError *)_error:(NSString *)msg code:(NSInteger)code {
    NSDictionary *info = @{NSLocalizedDescriptionKey : msg ?: @"Error"};
    return [NSError errorWithDomain:GitHubReleaseUpdaterErrorDomain code:code userInfo:info];
}

#pragma mark - Networking

- (void)_fetchLatestReleaseLockedWithRetry:(NSInteger)attempt
                                completion:(void (^)(GHReleaseInfo *_Nullable latest, NSString *_Nullable etag,
                                                     NSError *_Nullable error, BOOL fromCache))completion {
    if (attempt > self.strategy.maxRetryCount) {
        completion(nil, nil, [self _error:@"Max retry reached" code:429], YES);
        return;
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases",
                                                                 self.strategy.repoFullName]];
    if (!url) {
        completion(nil, nil, [self _error:@"Invalid repo URL" code:400], YES);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    if (self.strategy.githubToken.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", self.strategy.githubToken]
            forHTTPHeaderField:@"Authorization"];
    }
    NSString *etag = [self _etagLocked];
    if (etag.length > 0) {
        [req setValue:etag forHTTPHeaderField:@"If-None-Match"];
    }

    __weak typeof(self) weakSelf3 = self;
    self.task = [self.session
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              __strong typeof(self) s = weakSelf3;
              if (!s)
                  return;
              NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
              NSString *newETag = http.allHeaderFields[@"ETag"] ?: http.allHeaderFields[@"Etag"];

              if (error) {
                  GHRULog("Network error: %@ (attempt %ld)", error, (long)attempt);
                  [s _scheduleRetryLockedAfter:s.strategy.minRetryInterval * pow(2, attempt)
                                       attempt:attempt
                                    completion:completion];
                  return;
              }

              NSInteger status = http.statusCode;
              if (status == 304) {
                  // Not modified, keep existing cache
                  completion(s.cachedLatest, newETag, nil, YES);
                  return;
              }
              if (status < 200 || status >= 300) {
                  NSError *e = [s _error:[NSString stringWithFormat:@"HTTP %ld", (long)status] code:status];
                  GHRULog("HTTP error: %@ (attempt %ld)", e, (long)attempt);
                  [s _scheduleRetryLockedAfter:s.strategy.minRetryInterval * pow(2, attempt)
                                       attempt:attempt
                                    completion:completion];
                  return;
              }

              NSError *jsonErr = nil;
              id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
              if (jsonErr || ![obj isKindOfClass:[NSArray class]]) {
                  completion(nil, newETag, [s _error:@"Invalid JSON" code:500], YES);
                  return;
              }

              NSArray *arr = (NSArray *)obj;
              GHReleaseInfo *best = nil;
              for (NSDictionary *item in arr) {
                  if (![item isKindOfClass:[NSDictionary class]])
                      continue;
                  BOOL draft = [item[@"draft"] boolValue];
                  BOOL prerelease = [item[@"prerelease"] boolValue];
                  if (draft)
                      continue;
                  if (!s.strategy.includePrereleases && prerelease)
                      continue;

                  NSString *tag = item[@"tag_name"];
                  if (![tag isKindOfClass:[NSString class]])
                      continue;
                  NSString *ver = [s _normalizeTagToVersion:tag];
                  if (![DpkgVersion isValid:ver])
                      continue;

                  GHReleaseInfo *info = [[GHReleaseInfo alloc] init];
                  info.tagName = tag;
                  info.versionString = ver;
                  info.name = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
                  info.body = [item[@"body"] isKindOfClass:[NSString class]] ? item[@"body"] : nil;
                  info.htmlURL = [item[@"html_url"] isKindOfClass:[NSString class]] ? item[@"html_url"] : nil;
                  info.publishedAt =
                      [item[@"published_at"] isKindOfClass:[NSString class]] ? item[@"published_at"] : nil;
                  info.prerelease = prerelease;

                  if (!best) {
                      best = info;
                      continue;
                  }
                  NSInteger cmp = [DpkgVersion compareVersionString:info.versionString to:best.versionString];
                  if (cmp > 0)
                      best = info;
              }

              if (!best) {
                  completion(nil, newETag, [s _error:@"No valid releases found" code:404], YES);
                  return;
              }

              completion(best, newETag, nil, NO);
          }];
    [self.task resume];
}

- (void)_scheduleRetryLockedAfter:(NSTimeInterval)delay
                          attempt:(NSInteger)attempt
                       completion:(void (^)(GHReleaseInfo *_Nullable latest, NSString *_Nullable etag,
                                            NSError *_Nullable error, BOOL fromCache))completion {
    if (attempt >= self.strategy.maxRetryCount) {
        completion(nil, nil, [self _error:@"Exhausted retries" code:429], YES);
        return;
    }
    GHRULog("Scheduling retry in %.0fs (attempt %ld/%ld)", delay, (long)(attempt + 1),
            (long)self.strategy.maxRetryCount);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.queue, ^{
        __strong typeof(self) s = weakSelf;
        if (!s)
            return;
        [s _fetchLatestReleaseLockedWithRetry:(attempt + 1) completion:completion];
    });
}

#pragma mark - Helpers

- (NSString *)_normalizeTagToVersion:(NSString *)tag {
    NSString *t = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t hasPrefix:@"refs/tags/"]) {
        t = [t substringFromIndex:10];
    }
    // Common prefix 'v' or 'V' should be stripped if followed by a digit
    if (t.length > 1) {
        unichar c0 = [t characterAtIndex:0];
        unichar c1 = [t characterAtIndex:1];
        if ((c0 == 'v' || c0 == 'V') && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c1]) {
            t = [t substringFromIndex:1];
        }
    }
    return t;
}

@end
