#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TFDPlayer.h"
#import <substrate.h>
#import "TFDConfig.h"

/*
 ============================================================================
 录屏岛帧动画 — hook 层
 ============================================================================

 ## 这个文件的接口依据

 参考实现里的 20 处 MSHookMessageEx 反汇编出来，selector 是明文的（类名
 加密在 __DATA 段里）。真实 selector 全集：

   群 A: detachedMinimalView / leadingView / layoutSubviews /
         initWithWaveformView:
   群 B: setTrailingAnimationView: /
         contentProviderWillTransitionToSize:inContainerView:transitionCoordinator: /
         preferredEdgeOutsetsForLayoutMode:suggestedOutsets:maximumOutsets: /
         setRenderMode: / setDisableUpdateMask: / layoutSubviews

 群 A 和群 B 各出现两次 —— 对应两套类（灵动岛元素视图 + 它的布局/控制器）。

 ## 显示：用哪个接口

 真正的接口不是 addSubview，是 **getter**：

     -[<元素视图> leadingView]        左槽
     -[<元素视图> detachedMinimalView] 脱离时的极小态
     -[<元素视图> setTrailingAnimationView:]  右槽动画位

 addSubview 加进去的视图不参与系统 layout pass —— 展开/收起不跟手、
 被圆角裁掉、尺寸永远是加进去那一刻的。所以这里 swizzle getter 直接
 **返回我们自己的视图**，系统会像对待它自己的子视图一样布局它。

 ## 层级：怎么找

 不硬编码类名（类名每个系统版本都可能变，参考实现里还是加密的）。
 改为在运行时枚举已加载的类，找「同时响应这些特征 selector」的那个：

     响应 setTrailingAnimationView: 或 leadingView 或 detachedMinimalView

 命中的就是灵动岛元素视图，不管是哪个私有类、叫什么都不影响。

 ## 必须先 hook 这几处，只 hook 一处一定漏状态

      layoutSubviews           bounds 已定
      setLayoutMode:           展开/收起/极小 切换
      setRenderMode:           渲染模式变了要重挂
      setDisableUpdateMask:    遮罩更新开关
      setTrailingAnimationView: / setElementIdentifier:  身份确立

 展开/收起/极小是三套独立布局，各有独立 layout 时机。这就是「只显示
 一半 / 某个状态没了」的根因。

 ## 隐藏：藏在哪一层

 1) 岛内系统内容：只 hidden，**不 removeFromSuperview**。系统视图会被
    复用，移除后后续状态还原不回来。范围是元素自身的子视图，但
    **不藏元素自己**（藏了自己也没了），也不藏它的 superview（那是整个
    灵动岛容器）。—— 藏在元素层，不藏容器层。
 2) 状态栏红点：hook applyUpdate:toDisplayItem: 直接 return，不执行原
    实现就不会挂上去。
 ============================================================================
 */

static const char *const kLogTag = "[TFD]";

static BOOL TFDEnabled(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:TFD_PREF_DOMAIN];
    if ([d objectForKey:TFD_KEY_ENABLED] == nil) return YES;   // 默认开
    return [d boolForKey:TFD_KEY_ENABLED];
}

static BOOL TFDIsRecording(void) {
    if (@available(iOS 11.0, *)) {
        return [UIScreen mainScreen].isCaptured;
    }
    return NO;
}

/// 素材名缺省时用 "默认"，避免空字符串导致读不到帧
static NSString *TFDResolvedAsset(NSString *prefix) {
    NSDictionary *s = TFDReadSettings(prefix);
    NSString *a = s[@"asset"];
    return a.length ? a : @"默认";
}

@interface TFDHost : NSObject
/// 每个被托管的宿主视图 → 我们的播放器
@property (nonatomic, strong) NSMapTable<UIView *, TFDPlayerView *> *map;
+ (instancetype)shared;
- (TFDPlayerView *)playerForHost:(UIView *)host kind:(NSString *)kind;
- (void)syncAll;
- (void)applyToHost:(UIView *)host kind:(NSString *)kind;
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
    }
    return self;
}

- (TFDPlayerView *)playerForHost:(UIView *)host kind:(NSString *)kind {
    TFDPlayerView *p = [self.map objectForKey:host];
    if (!p) {
        p = [[TFDPlayerView alloc] initWithFrame:host.bounds];
        p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.map setObject:p forKey:host];
    }
    NSDictionary *s = TFDReadSettings(kind);
    p.assetName          = TFDResolvedAsset(kind);
    p.fps                = [s[@"fps"] doubleValue];
    p.rotationEnabled    = [s[@"rotation"] boolValue];
    p.rotationReverse    = [s[@"rotationReverse"] boolValue];
    p.rotationSpeed      = [s[@"rotationSpeed"] doubleValue];
    p.assetScale         = [s[@"scale"] doubleValue];
    p.offsetX            = [s[@"offsetX"] doubleValue];
    p.offsetY            = [s[@"offsetY"] doubleValue];
    p.hideSiblings       = [s[@"hideSiblings"] boolValue];
    return p;
}

/// 把播放器挂到宿主上（或从宿主上摘下），并按录屏状态决定显隐
- (void)applyToHost:(UIView *)host kind:(NSString *)kind {
    if (!host) return;

    BOOL want = TFDEnabled() && TFDIsRecording();
    TFDPlayerView *p = [self.map objectForKey:host];

    if (!want) {
        if (p) {
            [p stopPlayback];
            if (p.superview == host) [p removeFromSuperview];
        }
        // 还原被我们藏起来的内容
        [self setSystemContentHidden:NO inHost:host excluding:p];
        return;
    }

    p = [self playerForHost:host kind:kind];
    if (p.superview != host) {
        p.frame = host.bounds;
        [host addSubview:p];
        NSLog(@"%s 挂载 %@ -> %@ (%.0fx%.0f)", kLogTag, kind, host.class, host.bounds.size.width, host.bounds.size.height);
    }
    [p reloadAndPlay];
    [p applyTransform];
    // 注意顺序：先挂自己的视图，再藏兄弟，否则把自己也藏了
    [self setSystemContentHidden:p.hideSiblings inHost:host excluding:p];
}

- (void)setSystemContentHidden:(BOOL)hidden inHost:(UIView *)host excluding:(UIView *)keep {
    for (UIView *v in host.subviews) {
        if (v == keep) continue;
        v.hidden = hidden;
    }
}

- (void)syncAll {
    for (UIView *host in self.map.keyEnumerator) {
        [self applyToHost:host kind:@"默认"];
    }
}

@end

#pragma mark - 运行时发现元素视图类

/// 特征 selector：只要一个类响应其中任意一个，就认为它是灵动岛元素视图
static NSString *const kMarkerSelectors[] = {
    @"setTrailingAnimationView:",
    @"leadingView",
    @"detachedMinimalView",
    @"setMiniAnimationView:",
    nil
};

typedef void (*TFDVoidIMP)(id, SEL);
typedef UIView *(*TFDViewIMP)(id, SEL);

static NSMutableSet<NSString *> *gHookedClasses;
static BOOL gRecordingHandlerInstalled = NO;

/// 被托管视图的 layoutSubviews：系统每次重新布局都要把我们的视图尺寸跟上，
/// 并且重新按录屏状态决定挂/摘。
static void TFDLayoutSubviews(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    // 调原实现（父类链上的第一个实现）
    IMP orig = class_getMethodImplementation(class_getSuperclass(cls), _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);

    if (![self isKindOfClass:[UIView class]]) return;
    NSString *kind = @"默认";
    SEL identSel = NSSelectorFromString(@"elementIdentifier");
    if ([self respondsToSelector:identSel]) {
        id ident = ((id (*)(id, SEL))objc_msgSend)(self, identSel);
        if (ident) kind = [NSString stringWithFormat:@"%@", ident];
    }
    [[TFDHost shared] applyToHost:(UIView *)self kind:kind.length ? kind : @"默认"];
}

static void TFDLayoutMode(id self, SEL _cmd, long long mode) {
    IMP orig = class_getMethodImplementation(class_getSuperclass(object_getClass(self)), _cmd);
    if (orig) ((void (*)(id, SEL, long long))orig)(self, _cmd, mode);
    if (![self isKindOfClass:[UIView class]]) return;
    [[TFDHost shared] applyToHost:(UIView *)self kind:@"默认"];
}

/// 关键：swizzle getter，直接返回我们的视图（不是 addSubview）
static UIView *TFDLeadingView(id self, SEL _cmd) {
    if (TFDEnabled() && TFDIsRecording()) {
        TFDPlayerView *p = [[TFDHost shared] playerForHost:(UIView *)self kind:@"leading"];
        [[TFDHost shared] applyToHost:(UIView *)self kind:@"leading"];
        return p;
    }
    // 不录屏时走原实现
    Class sup = class_getSuperclass(object_getClass(self));
    IMP orig = class_getMethodImplementation(sup, _cmd);
    if (orig) return ((UIView *(*)(id, SEL))orig)(self, _cmd);
    return nil;
}

static UIView *TFDDetachedMinimalView(id self, SEL _cmd) {
    if (TFDEnabled() && TFDIsRecording()) {
        TFDPlayerView *p = [[TFDHost shared] playerForHost:(UIView *)self kind:@"minimal"];
        [[TFDHost shared] applyToHost:(UIView *)self kind:@"minimal"];
        return p;
    }
    IMP orig = class_getMethodImplementation(class_getSuperclass(object_getClass(self)), _cmd);
    if (orig) return ((UIView *(*)(id, SEL))orig)(self, _cmd);
    return nil;
}

static void TFDSetTrailingAnimationView(id self, SEL _cmd, UIView *v) {
    IMP orig = class_getMethodImplementation(class_getSuperclass(object_getClass(self)), _cmd);
    if (orig) ((void (*)(id, SEL, UIView *))orig)(self, _cmd, v);
    if (TFDEnabled() && TFDIsRecording()) {
        [[TFDHost shared] applyToHost:(UIView *)self kind:@"trailing"];
    }
}

#pragma mark - 状态栏红点

static void TFDApplyUpdate(id self, SEL _cmd, id a, id b) {
    if (TFDEnabled() && TFDIsRecording()) {
        NSLog(@"%s 拦下状态栏录屏指示", kLogTag);
        return;   // 不调用原实现 = 不挂
    }
    IMP orig = class_getMethodImplementation(class_getSuperclass(object_getClass(self)), _cmd);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, a, b);
}

#pragma mark - 遍历 class 表

static void TFDHookClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    if (!name || [gHookedClasses containsObject:name]) return;
    [gHookedClasses addObject:name];

    int hooked = 0;

    // layoutSubviews：一定在类自身实现上才 hook（父类的不用管）
    if (class_getInstanceMethod(cls, @selector(layoutSubviews))) {
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)&TFDLayoutSubviews, NULL);
        hooked++;
    }

    SEL sels[] = {
        NSSelectorFromString(@"setLayoutMode:"),
        NSSelectorFromString(@"setTrailingAnimationView:"),
        NSSelectorFromString(@"setDisableUpdateMask:"),
        NSSelectorFromString(@"setRenderMode:"),
    };
    IMP imps[] = { (IMP)&TFDLayoutMode, (IMP)&TFDSetTrailingAnimationView,
                   (IMP)&TFDLayoutMode, (IMP)&TFDLayoutMode };
    for (size_t i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
        if (class_getInstanceMethod(cls, sels[i])) {
            MSHookMessageEx(cls, sels[i], imps[i], NULL);
            hooked++;
        }
    }

    // getter 注入（真接口）
    if (class_getInstanceMethod(cls, NSSelectorFromString(@"leadingView"))) {
        MSHookMessageEx(cls, NSSelectorFromString(@"leadingView"), (IMP)&TFDLeadingView, NULL);
        hooked++;
    }
    if (class_getInstanceMethod(cls, NSSelectorFromString(@"detachedMinimalView"))) {
        MSHookMessageEx(cls, NSSelectorFromString(@"detachedMinimalView"), (IMP)&TFDDetachedMinimalView, NULL);
        hooked++;
    }

    NSLog(@"%s hooked %@ (%d 个点)", kLogTag, name, hooked);
}

static void TFDDiscoverAndHook(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * n);
    n = objc_getClassList(classes, n);

    int found = 0;
    for (int i = 0; i < n; i++) {
        Class c = classes[i];
        BOOL match = NO;
        for (int k = 0; kMarkerSelectors[k]; k++) {
            if (class_getInstanceMethod(c, NSSelectorFromString(kMarkerSelectors[k]))) {
                match = YES;
                break;
            }
        }
        if (!match) continue;
        // 跳过我们自己的类
        NSString *cn = NSStringFromClass(c);
        if ([cn hasPrefix:@"TFD"]) continue;
        TFDHookClass(c);
        found++;
    }
    free(classes);
    NSLog(@"%s 发现 %d 个灵动岛元素类", kLogTag, found);
}

static void TFDHookStatusBar(void) {
    // STUIStatusBarIndicatorRecordingItem -applyUpdate:toDisplayItem:
    Class c = NSClassFromString(@"STUIStatusBarIndicatorRecordingItem");
    if (!c) {
        NSLog(@"%s 没有 STUIStatusBarIndicatorRecordingItem（iOS 版本差异，跳过）", kLogTag);
        return;
    }
    SEL s = NSSelectorFromString(@"applyUpdate:toDisplayItem:");
    if (class_getInstanceMethod(c, s)) {
        MSHookMessageEx(c, s, (IMP)&TFDApplyUpdate, NULL);
        NSLog(@"%s 状态栏指示器已接管", kLogTag);
    }
}

static void TFDRecordingChanged(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    BOOL rec = TFDIsRecording();
    NSLog(@"%s 录屏状态 -> %@", kLogTag, rec ? @"开始" : @"结束");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TFDHost shared] syncAll];
    });

    if (rec && !gRecordingHandlerInstalled) {
        gRecordingHandlerInstalled = YES;
        TFDDiscoverAndHook();
    }
}

__attribute__((constructor)) static void TFDInstall(void) {
    NSLog(@"%s v1.0.1 载入 (pid=%d, bundle=%@)", kLogTag, getpid(),
          [NSBundle mainBundle].bundleIdentifier);

    gHookedClasses = [NSMutableSet set];

    // 素材根目录兜底创建
    [[NSFileManager defaultManager] createDirectoryAtPath:TFDDefaultAssetRoot
                              withIntermediateDirectories:YES attributes:nil error:NULL];

    // 类可能还没加载完，延迟一轮再补扫
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TFDDiscoverAndHook();
        TFDHookStatusBar();
    });

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, TFDRecordingChanged,
                                    CFSTR("UIScreenCapturedDidChangeNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    NSLog(@"%s 初始化完成", kLogTag);
}
