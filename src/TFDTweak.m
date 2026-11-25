#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TFDPlayer.h"
#import <substrate.h>
#import "TFDConfig.h"

/*
 ============================================================================
 录屏岛帧动画 — hook 层  v1.0.2
 ============================================================================

 ## 接口依据（从参考实现反汇编出 20 处 MSHookMessageEx 的明文 selector）

   setTrailingAnimationView: / leadingView / detachedMinimalView /
   layoutSubviews / setLayoutMode: / setRenderMode: / setDisableUpdateMask: /
   setElementIdentifier: / contentProviderWillTransitionToSize:...

 ## 本版修正的真 bug

 1. **原始 IMP 不能用一个全局槽**。多个类都被 hook 时，后 hook 的会覆盖前一个
    的 orig，A 类就会调到 B 类的实现 —— 直接崩。本版按「类+selector」分别存。

 2. **MSHookMessageEx 第 3 参数传 NULL 就拿不到 old IMP**；
    用 class_getMethodImplementation(父类) 冒充更糟，会把本类实现整个跳过。

 3. **不用 addSubview 塞进元素视图、也不改 getter 返回值**。getter 返回外部
    视图时系统会按自己的生命周期 retain/release，容易类型错乱。改为在元素
    视图 layoutSubviews 里维护 overlay 子视图，每次布局同步 frame。

 4. **只 hook 类自身方法表里的方法**（class_copyMethodList），不用
    class_getInstanceMethod —— 后者会把继承来的方法也算命中，
    导致所有子类都被打桩。

 5. **隐藏只在 overlay 挂上之后执行**，只作用于元素自身子视图，
    不碰元素自己、不碰 superview。
 ============================================================================
 */

static const char *const kLogTag = "[TFD]";

// ------------------------------------------------------------ 文件日志
// 用户看不到 NSLog（要用电脑接 log stream），所以同时写文件，
// 设置面板里有「日志」按钮直接查看这个文件。
#define TFD_LOG_PATH "/var/mobile/Library/Logs/TFDRecordIsland.log"

static void TFDLog(NSString *fmt, ...) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Logs"
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
    });

    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], body];

    NSLog(@"[TFD] %@", body);

    // 超过 512KB 就截断重来，避免无限增长
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:@TFD_LOG_PATH error:NULL];
    if ([attr fileSize] > 512 * 1024) {
        [fm removeItemAtPath:@TFD_LOG_PATH error:NULL];
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@TFD_LOG_PATH];
    if (!fh) {
        [line writeToFile:@TFD_LOG_PATH atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (__unused NSException *e) {}
        [fh closeFile];
    }
}


// ---------------------------------------------------------------- 原始 IMP
// 按 "类名|selector" 分别保存，绝不用一个全局槽
static NSMutableDictionary<NSString *, id> *gOrigIMPs;

static NSString *TFDOrigKey(Class cls, NSString *sel) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), sel];
}

static IMP TFDOrig(Class cls, NSString *sel) {
    id v = gOrigIMPs[TFDOrigKey(cls, sel)];
    return v ? (IMP)[v pointerValue] : NULL;
}

static void TFDStoreOrig(Class cls, NSString *sel, IMP imp) {
    if (!imp) return;
    gOrigIMPs[TFDOrigKey(cls, sel)] = [NSValue valueWithPointer:imp];
}

// ---------------------------------------------------------------- 基础判定
static BOOL TFDEnabled(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:TFD_PREF_DOMAIN];
    if ([d objectForKey:TFD_KEY_ENABLED] == nil) return YES;   // 默认开
    return [d boolForKey:TFD_KEY_ENABLED];
}

static BOOL TFDIsRecording(void) {
    if (@available(iOS 11.0, *)) return [UIScreen mainScreen].isCaptured;
    return NO;
}

// ---------------------------------------------------------------- 宿主管理
@interface TFDHost : NSObject
@property (nonatomic, strong) NSMapTable<UIView *, TFDPlayerView *> *map;
@property (nonatomic, strong) NSMapTable<UIView *, NSString *> *kinds;
+ (instancetype)shared;
- (void)attachToHost:(UIView *)host kind:(NSString *)kind;
- (void)detachFromHost:(UIView *)host;
- (void)syncAll;
@end

@implementation TFDHost

+ (instancetype)shared {
    static TFDHost *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TFDHost new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _map = [NSMapTable weakToStrongObjectsMapTable];
        _kinds = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (TFDPlayerView *)playerForHost:(UIView *)host kind:(NSString *)kind {
    TFDPlayerView *p = [self.map objectForKey:host];
    if (!p) {
        p = [[TFDPlayerView alloc] initWithFrame:host.bounds];
        p.userInteractionEnabled = NO;      // 不抢触摸
        p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.map setObject:p forKey:host];
    }
    NSDictionary *s = TFDReadSettings(kind);
    // 素材名为空时自动用目录里第一个素材 —— 否则用户放了素材也不会有任何效果
    NSString *asset = s[@"asset"];
    if (!asset.length) {
        NSArray *list = [TFDPlayerView availableAssets];
        if (list.count) asset = list.firstObject;
    }
    p.assetName       = asset;
    p.fps             = [s[@"fps"] doubleValue];
    p.rotationEnabled = [s[@"rotation"] boolValue];
    p.rotationReverse = [s[@"rotationReverse"] boolValue];
    p.rotationSpeed   = [s[@"rotationSpeed"] doubleValue];
    p.assetScale      = [s[@"scale"] doubleValue];
    p.offsetX         = [s[@"offsetX"] doubleValue];
    p.offsetY         = [s[@"offsetY"] doubleValue];
    p.hideSiblings    = [s[@"hideSiblings"] boolValue];
    return p;
}

- (void)attachToHost:(UIView *)host kind:(NSString *)kind {
    if (!host) return;
    if (!kind.length) kind = @"默认";

    if (!TFDEnabled() || !TFDIsRecording()) {
        [self detachFromHost:host];
        return;
    }

    [self.kinds setObject:kind forKey:host];
    TFDPlayerView *p = [self playerForHost:host kind:kind];

    // 首次布局时 bounds 往往还是 0，直接 return 会导致永远挂不上。
    // 这里改为延迟重试，最多 8 次（约 0.8 秒）。
    if (host.bounds.size.width <= 0 || host.bounds.size.height <= 0) {
        static NSMapTable<UIView *, NSNumber *> *retries;
        static dispatch_once_t once; dispatch_once(&once, ^{ retries = [NSMapTable weakToStrongObjectsMapTable]; });
        NSNumber *n = [retries objectForKey:host] ?: @0;
        if (n.integerValue < 8) {
            [retries setObject:@(n.integerValue + 1) forKey:host];
            __weak UIView *weakHost = host;
            __weak typeof(self) weakSelf = self;
            NSString *k2 = kind;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *h = weakHost;
                if (h) [weakSelf attachToHost:h kind:k2];
            });
        }
        return;
    }

    if (p.superview != host) {
        p.frame = host.bounds;
        [host addSubview:p];
        static NSMutableSet *logged;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
        NSString *key = NSStringFromClass([host class]);
        if (![logged containsObject:key]) {
            [logged addObject:key];
            TFDLog(@"挂载 %@ kind=%@ %.0fx%.0f", key, kind,
                  host.bounds.size.width, host.bounds.size.height);
        }
    } else if (!CGRectEqualToRect(p.frame, host.bounds)) {
        p.frame = host.bounds;              // 每次布局同步尺寸
    }

    [p applyTransform];

    // 先挂自己的视图，再藏兄弟 —— 顺序反了会把自己也藏掉
    for (UIView *v in host.subviews) {
        if (v == p) continue;
        v.hidden = p.hideSiblings;
    }
}

- (void)detachFromHost:(UIView *)host {
    TFDPlayerView *p = [self.map objectForKey:host];
    if (!p) return;
    [p stopPlayback];
    if (p.superview == host) [p removeFromSuperview];
    for (UIView *v in host.subviews) v.hidden = NO;      // 还原系统内容
}

- (void)syncAll {
    NSMutableArray *hosts = [NSMutableArray array];
    for (UIView *h in self.map.keyEnumerator) if (h) [hosts addObject:h];
    for (UIView *h in hosts) {
        NSString *k = [self.kinds objectForKey:h] ?: @"默认";
        [self attachToHost:h kind:k];
    }
}

@end

// ---------------------------------------------------------------- 元素身份
static NSString *TFDKindForHost(id host) {
    SEL s = NSSelectorFromString(@"elementIdentifier");
    if ([host respondsToSelector:s]) {
        id ident = ((id (*)(id, SEL))objc_msgSend)(host, s);
        if (ident) return [NSString stringWithFormat:@"%@", ident];
    }
    return @"默认";
}

// ---------------------------------------------------------------- hook 实现
// 每个 trampoline 都用「自己所属的类」去取 orig，避免全局槽串味

static void TFDLayoutSubviews(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    IMP o = TFDOrig(cls, @"layoutSubviews");
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
    if ([self isKindOfClass:[UIView class]])
        [[TFDHost shared] attachToHost:(UIView *)self kind:TFDKindForHost(self)];
}

static void TFDLayoutMode(id self, SEL _cmd, long long mode) {
    Class cls = object_getClass(self);
    IMP o = TFDOrig(cls, @"setLayoutMode:");
    if (o) ((void (*)(id, SEL, long long))o)(self, _cmd, mode);
    if ([self isKindOfClass:[UIView class]])
        [[TFDHost shared] attachToHost:(UIView *)self kind:TFDKindForHost(self)];
}

static void TFDRenderMode(id self, SEL _cmd, long long mode) {
    Class cls = object_getClass(self);
    IMP o = TFDOrig(cls, @"setRenderMode:");
    if (o) ((void (*)(id, SEL, long long))o)(self, _cmd, mode);
    if ([self isKindOfClass:[UIView class]])
        [[TFDHost shared] attachToHost:(UIView *)self kind:TFDKindForHost(self)];
}

static void TFDDisableMask(id self, SEL _cmd, BOOL disable) {
    Class cls = object_getClass(self);
    IMP o = TFDOrig(cls, @"setDisableUpdateMask:");
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, disable);
    if ([self isKindOfClass:[UIView class]])
        [[TFDHost shared] attachToHost:(UIView *)self kind:TFDKindForHost(self)];
}

static void TFDSetTrailingAnim(id self, SEL _cmd, UIView *v) {
    Class cls = object_getClass(self);
    IMP o = TFDOrig(cls, @"setTrailingAnimationView:");
    if (o) ((void (*)(id, SEL, UIView *))o)(self, _cmd, v);
    if ([self isKindOfClass:[UIView class]])
        [[TFDHost shared] attachToHost:(UIView *)self kind:TFDKindForHost(self)];
}

/// 身份确立早于首次布局 —— 很多版本「第一次展开不显示」的根因
static void TFDSetElementIdent(id self, SEL _cmd, id ident) {
    Class cls = object_getClass(self);
    IMP o = TFDOrig(cls, @"setElementIdentifier:");
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, ident);
    if ([self isKindOfClass:[UIView class]]) {
        NSString *k = ident ? [NSString stringWithFormat:@"%@", ident] : @"默认";
        [[TFDHost shared] attachToHost:(UIView *)self kind:k];
    }
}

// ---------------------------------------------------------------- 状态栏红点
static void TFDApplyUpdate(id self, SEL _cmd, id a, id b) {
    if (TFDEnabled() && TFDIsRecording()) {
        static BOOL once; if (!once) { once = YES; TFDLog(@"已拦下状态栏录屏指示", kLogTag); }
        return;                                   // 不调原实现 = 不挂指示器
    }
    Class cls = object_getClass(self);
    IMP o = TFDOrig(cls, @"applyUpdate:toDisplayItem:");
    if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a, b);
}

// ---------------------------------------------------------------- 安装
static NSMutableSet<NSString *> *gHooked;

/// 只认类自身方法表里的实现（继承来的不算），避免对所有子类打桩
static BOOL TFDClassOwnsSelector(Class cls, SEL s) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(ms[i]) == s) { own = YES; break; }
    }
    if (ms) free(ms);
    return own;
}

static void TFDHookOne(Class cls, NSString *selName, IMP newImp) {
    if (!cls || !selName) return;
    SEL s = NSSelectorFromString(selName);
    if (!TFDClassOwnsSelector(cls, s)) return;      // 不碰继承来的方法

    IMP orig = NULL;
    MSHookMessageEx(cls, s, newImp, &orig);
    TFDStoreOrig(cls, selName, orig);               // 按类分别保存
    TFDLog(@"  hook %@ -%@", NSStringFromClass(cls), selName);
}

static void TFDHookClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    if (!name || [name hasPrefix:@"TFD"] || [gHooked containsObject:name]) return;
    [gHooked addObject:name];

    TFDHookOne(cls, @"layoutSubviews",            (IMP)&TFDLayoutSubviews);
    TFDHookOne(cls, @"setLayoutMode:",            (IMP)&TFDLayoutMode);
    TFDHookOne(cls, @"setRenderMode:",            (IMP)&TFDRenderMode);
    TFDHookOne(cls, @"setDisableUpdateMask:",     (IMP)&TFDDisableMask);
    TFDHookOne(cls, @"setTrailingAnimationView:", (IMP)&TFDSetTrailingAnim);
    TFDHookOne(cls, @"setElementIdentifier:",     (IMP)&TFDSetElementIdent);
}

/// 特征 selector：响应任意一个就认为是灵动岛元素视图（不硬编码类名）
static const char *kMarkers[] = {
    "setTrailingAnimationView:",
    "leadingView",
    "detachedMinimalView",
    "setElementIdentifier:",
    "setMiniAnimationView:",
    NULL
};

static int gDiscovered = -1;

static void TFDDiscoverAndHook(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!classes) return;
    n = objc_getClassList(classes, n);

    int found = 0;
    for (int i = 0; i < n; i++) {
        Class c = classes[i];
        NSString *cn = NSStringFromClass(c);
        if (!cn || [cn hasPrefix:@"TFD"]) continue;
        BOOL match = NO;
        for (int k = 0; kMarkers[k]; k++) {
            SEL mk = sel_registerName(kMarkers[k]);
            if (TFDClassOwnsSelector(c, mk)) { match = YES; break; }
        }
        if (!match) continue;
        TFDHookClass(c);
        found++;
    }
    free(classes);
    if (found != gDiscovered) {
        gDiscovered = found;
        TFDLog(@"扫到 %d 个候选元素类", found);
    }
}

static void TFDHookStatusBar(void) {
    Class c = NSClassFromString(@"STUIStatusBarIndicatorRecordingItem");
    if (!c) {
        TFDLog(@"无 STUIStatusBarIndicatorRecordingItem（版本差异，跳过）", kLogTag);
        return;
    }
    SEL s = NSSelectorFromString(@"applyUpdate:toDisplayItem:");
    if (!TFDClassOwnsSelector(c, s)) return;
    IMP orig = NULL;
    MSHookMessageEx(c, s, (IMP)&TFDApplyUpdate, &orig);
    TFDStoreOrig(c, @"applyUpdate:toDisplayItem:", orig);
    TFDLog(@"状态栏指示器已接管", kLogTag);
}

static void TFDRecordingChanged(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    BOOL rec = TFDIsRecording();
    TFDLog(@"录屏通知 -> %@", rec ? @"开始" : @"结束");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (rec && gDiscovered <= 0) TFDDiscoverAndHook();   // 首次录屏补扫
        [[TFDHost shared] syncAll];
    });
}

/// 通知有时收不到（尤其是控制中心启动录屏），加 1 秒轮询兜底。
/// 只在状态发生变化时才动作，平时几乎零开销。
static void TFDStartPolling(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
            1 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            static BOOL last = NO;
            BOOL now = TFDIsRecording();
            if (now == last) return;
            last = now;
            TFDLog(@"轮询捕获到录屏 %@", now ? @"开始" : @"结束");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (now && gDiscovered <= 0) TFDDiscoverAndHook();
                [[TFDHost shared] syncAll];
            });
        });
        dispatch_resume(timer);
    });
}

__attribute__((constructor)) static void TFDInstall(void) {
    TFDLog(@"v1.0.2 载入 pid=%d bundle=%@", getpid(),
          [NSBundle mainBundle].bundleIdentifier);

    gHooked = [NSMutableSet set];
    gOrigIMPs = [NSMutableDictionary dictionary];

    [[NSFileManager defaultManager] createDirectoryAtPath:TFDDefaultAssetRoot
                              withIntermediateDirectories:YES attributes:nil error:NULL];

    // 类加载时机不保证，分多轮补扫（0.3s / 1.2s / 3s / 录屏触发时）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TFDDiscoverAndHook(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TFDDiscoverAndHook(); TFDHookStatusBar(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TFDDiscoverAndHook(); });

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, TFDRecordingChanged,
                                    CFSTR("UIScreenCapturedDidChangeNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    TFDStartPolling();
    TFDLog(@"初始化完成，素材根=%@", TFDDefaultAssetRoot);
}
