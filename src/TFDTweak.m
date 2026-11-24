#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "TFDPlayer.h"
#import "TFDConfig.h"

/*
 * ==========================================================================
 *  录屏岛帧动画 · 接口与层级说明（原创实现，非修改他人二进制）
 * ==========================================================================
 *
 *  【一、显示：用哪个接口】
 *
 *    灵动岛不是"一个 view"，而是 ActivityKit 驱动的 SAUI* 体系。层级：
 *
 *        SBIslandWindow
 *          └─ SAUILayoutView / SAUIPresentationView
 *               └─ SAUIElementView              ← 每个"元素"一个实例
 *                    ├─ leadingView             ← 左槽
 *                    ├─ trailingView            ← 右槽
 *                    ├─ minimalView             ← 极小态
 *                    ├─ miniAnimationView       ← ★ 极小态的动画槽（可直接设）
 *                    └─ trailingAnimationView   ← ★ 右槽的动画槽（可直接设）
 *
 *    ★ 这两个就是真正该用的接口：
 *          -[SAUIElementView setMiniAnimationView:(UIView *)]
 *          -[SAUIElementView setTrailingAnimationView:(UIView *)]
 *
 *    为什么用它们而不是 addSubview：
 *      - 系统自己负责布局与动画，尺寸/圆角/遮罩都对
 *      - addSubview 塞进去的内容不参与系统的 layout pass，
 *        展开/收起时不会跟随，会出现"尺寸不跟手"、"被裁掉"
 *      - 系统在切状态时会重建这些槽，所以我们必须在状态切换时重新设置
 *
 *    三个必须知道的坑：
 *      (a) SAUIElementView 不止一个实例。系统同时存在"当前显示的"和
 *          "预加载待切换的"，还有 SwiftUI 宿主副本。必须做活跃性判断，
 *          否则会出现"两个动画重叠"或"塞进看不见的那个"。
 *      (b) 展开(expanded)/收起(compact)/极小(minimal) 是三套独立布局，
 *          各自有独立的 layout 时机。只 hook 一个方法必然漏状态。
 *      (c) 元素视图会被复用，必须幂等：已在位就不再重建。
 *
 *    hook 锚点（三个组合才覆盖全状态）：
 *      - -[SAUIElementView layoutSubviews]        布局完成，bounds 已定
 *      - -[SAUIElementView setLayoutMode:]        状态切换时机
 *      - -[SAUIElementView setElementIdentifier:] 身份确立，早于首次布局
 *
 *  【二、录屏：什么时候显示】
 *
 *    没有公开的"正在录屏"API。三条路：
 *      1) SBRecordingIndicatorViewController —— iOS 16 及更早的红点控制器。
 *         iOS 17+ 录屏指示搬进灵动岛，这个类常常已不存在，不可依赖。
 *      2) RPBroadcastController / ReplayKit —— 只能看到"我发起的分发"，
 *         控制中心那个系统录屏不经过它，拿不到。
 *      3) UIScreen.isCaptured + UIScreenCapturedDidChangeNotification
 *         —— 公开 API。本机被录（录屏 / AirPlay 镜像）时为 YES，
 *         状态变化发通知。零私有依赖，兼容性最好。  ← 用这个
 *
 *    判定：UIScreen.mainScreen.isCaptured
 *
 *  【三、隐藏：录屏指示怎么去掉】
 *
 *    两处要藏，藏法不同：
 *
 *    (1) 灵动岛里的系统内容
 *        不删视图，只置 hidden。原因：系统视图会被复用，
 *        removeFromSuperview 会让后续状态还原不回来；hidden 可逆。
 *        范围：SAUIElementView 的子视图，
 *        **但不藏 SAUIElementView 自己**，否则我们的 view 一起没了。
 *        也不藏它的 superview，那是整个岛的容器。
 *        → 藏在元素层，不藏在容器层。
 *
 *    (2) 状态栏的录屏红点
 *        STUIStatusBar 体系里，录屏是 STUIStatusBarIndicatorRecordingItem。
 *        做法：hook -[STUIStatusBarIndicatorRecordingItem
 *                     applyUpdate:toDisplayItem:] 让它不显示，
 *        或者更稳：hook 其 -indicatorEntry 返回 nil。
 *        这里用前者，并在隐藏时保留原逻辑以便随时恢复。
 *
 *  【四、为什么只 hook 一个方法会失败】
 *    灵动岛有展开/收起/极小三套布局，各有独立视图实例和独立 layout 时机。
 *    只 hook 一处，必然有某个状态不生效 —— 这就是"只显示一半"
 *    "某个状态没了"的根源。
 * ==========================================================================
 */

static const void *kTFDPlayerMiniKey     = &kTFDPlayerMiniKey;
static const void *kTFDPlayerTrailingKey = &kTFDPlayerTrailingKey;

#pragma mark - 判定

static BOOL TFDRecordingActive(void) {
    return [UIScreen mainScreen].isCaptured;
}

static BOOL TFDResponds(id o, NSString *sel) {
    return [o respondsToSelector:NSSelectorFromString(sel)];
}

/// 元素是否"活着"（避免往预加载/隐藏实例里塞）
static BOOL TFDIsLive(UIView *el) {
    if (!el.window) return NO;
    if (el.hidden || el.alpha < 0.05) return NO;
    CGSize s = el.bounds.size;
    if (s.width < 8 || s.height < 8) return NO;
    if (s.width > 620 || s.height > 620) return NO;   // 排除全屏容器
    return YES;
}

#pragma mark - 安装 / 卸载

static void TFDDetach(UIView *host, NSString *slot, const void *key, NSString *setter) {
    UIView *old = objc_getAssociatedObject(host, key);
    if (!old) return;
    if (TFDResponds(host, setter)) {
        IMP imp = [host methodForSelector:NSSelectorFromString(setter)];
        void (*fn)(id, SEL, id) = (void *)imp;
        fn(host, NSSelectorFromString(setter), nil);
    }
    if ([old isKindOfClass:[TFDPlayerView class]]) {
        TFDPlayerView *p = (TFDPlayerView *)old;
        p.hideSiblings = NO;
        [p stopPlayback];
        [p removeFromSuperview];
    }
    objc_setAssociatedObject(host, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// 把播放器装到某个槽位
static void TFDApplySlot(UIView *host, NSString *slotName, NSString *setterName,
                         const void *key, NSDictionary *cfg) {
    BOOL enabled = [cfg[@"enabled"] boolValue];
    NSString *asset = cfg[@"asset"];
    BOOL want = enabled && asset.length > 0 && TFDRecordingActive();

    if (!want) { TFDDetach(host, slotName, key, setterName); return; }
    if (!TFDIsLive(host)) { TFDDetach(host, slotName, key, setterName); return; }

    // 没这个槽位的元素直接跳过（不同状态暴露的槽不同）
    BOOL canSet = TFDResponds(host, setterName);

    TFDPlayerView *player = objc_getAssociatedObject(host, key);
    BOOL fresh = NO;
    if (!player) {
        // 槽位视图先给个占位尺寸，系统随后会重新布局
        CGRect f = host.bounds;
        if (f.size.width < 8) f = CGRectMake(0, 0, 60, 30);
        player = [[TFDPlayerView alloc] initWithFrame:f];
        player.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, key, player, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        fresh = YES;
    }

    if (canSet) {
        // 首选：交给系统托管（布局/圆角/遮罩都对）
        if (fresh) {
            IMP imp = [host methodForSelector:NSSelectorFromString(setterName)];
            void (*fn)(id, SEL, id) = (void *)imp;
            fn(host, NSSelectorFromString(setterName), player);
        }
    } else {
        // 兜底：该元素没有这个槽，直接挂到自身（极小态常走这条）
        if (player.superview != host) [host addSubview:player];
        if (!CGRectEqualToRect(player.frame, host.bounds)) player.frame = host.bounds;
        [host bringSubviewToFront:player];
    }

    if (fresh || ![player.assetName isEqualToString:asset]) {
        player.assetName = asset;              // setter 内 reloadAndPlay
    }
    player.fps = [cfg[@"fps"] doubleValue];
    player.rotationEnabled = [cfg[@"rotation"] boolValue];
    player.rotationReverse = [cfg[@"rotationReverse"] boolValue];
    player.rotationSpeed = [cfg[@"rotationSpeed"] doubleValue];
    player.assetScale = [cfg[@"scale"] doubleValue];
    player.offsetX = [cfg[@"offsetX"] doubleValue];
    player.offsetY = [cfg[@"offsetY"] doubleValue];

    // 隐藏系统内容必须在注入之后：否则刚 add 的兄弟会被一起藏掉
    player.hideSiblings = [cfg[@"hideSiblings"] boolValue];
    [player applyTransform];
}

#pragma mark - 元素处理

static NSString *TFDIdentifier(UIView *el) {
    if (!TFDResponds(el, @"elementIdentifier")) return nil;
    id v = [el valueForKey:@"elementIdentifier"];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static void TFDHandleElement(UIView *el, BOOL verbose) {
    if (!el) return;

    NSDictionary *cfg = TFDReadSettings(@"");
    if (![cfg[@"enabled"] boolValue] || !TFDRecordingActive()) {
        // 关掉时把两槽都清掉，确保系统原样回来
        TFDDetach(el, @"mini", kTFDPlayerMiniKey, @"setMiniAnimationView:");
        TFDDetach(el, @"trailing", kTFDPlayerTrailingKey, @"setTrailingAnimationView:");
        return;
    }

    NSString *ident = TFDIdentifier(el);

    if (verbose) {
        NSLog(@"[TFD] 元素 cls=%@ ident=%@ bounds=%@ mini=%d trailing=%d",
              NSStringFromClass([el class]), ident ?: @"(nil)",
              NSStringFromCGRect(el.bounds),
              TFDResponds(el, @"setMiniAnimationView:"),
              TFDResponds(el, @"setTrailingAnimationView:"));
    }

    // 录屏态优先只处理录屏相关元素；识别不出来时退回"全部活跃元素"
    BOOL looksRecording = NO;
    if (ident.length) {
        NSString *low = ident.lowercaseString;
        looksRecording = [low containsString:@"record"] || [low containsString:@"capture"]
                      || [low containsString:@"screen"] || [low containsString:@"mirror"];
    }
    if (ident.length && !looksRecording) {
        // 明确的非录屏元素（比如音乐、来电）不碰
        return;
    }

    // 极小态槽 + 右槽，各装一份；系统会在不同状态显示其中之一
    TFDApplySlot(el, @"mini", @"setMiniAnimationView:", kTFDPlayerMiniKey, cfg);

    NSDictionary *trailCfg = TFDReadSettings(@"Trailing");
    if (![trailCfg[@"asset"] length]) trailCfg = cfg;   // 未单独配置则沿用主配置
    TFDApplySlot(el, @"trailing", @"setTrailingAnimationView:",
                 kTFDPlayerTrailingKey, trailCfg);
}

#pragma mark - 遍历

static void TFDWalk(UIView *v, int depth, BOOL verbose) {
    if (!v || depth > 60) return;
    static Class elCls = nil;
    if (!elCls) elCls = NSClassFromString(@"SAUIElementView");
    if (elCls && [v isKindOfClass:elCls]) TFDHandleElement(v, verbose);
    for (UIView *s in v.subviews) TFDWalk(s, depth + 1, verbose);
}

static void TFDRefreshAll(BOOL verbose) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) TFDWalk(w, 0, verbose);
}

#pragma mark - Hooks: SAUIElementView

static void (*orig_layoutSubviews)(id, SEL);
static void (*orig_setLayoutMode)(id, SEL, NSInteger);
static void (*orig_setElementIdentifier)(id, SEL, id);

static void tfd_layoutSubviews(id self, SEL _cmd) {
    if (orig_layoutSubviews) orig_layoutSubviews(self, _cmd);
    TFDHandleElement((UIView *)self, NO);
}

static void tfd_setLayoutMode(id self, SEL _cmd, NSInteger mode) {
    if (orig_setLayoutMode) orig_setLayoutMode(self, _cmd, mode);
    TFDHandleElement((UIView *)self, NO);
}

static void tfd_setElementIdentifier(id self, SEL _cmd, id ident) {
    if (orig_setElementIdentifier) orig_setElementIdentifier(self, _cmd, ident);
    // 身份确立时还没布局，交给随后的 layoutSubviews；这里只记录
    NSLog(@"[TFD] elementIdentifier -> %@", ident);
}

static void TFDHookElementClass(Class cls) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (m) MSHookMessageEx(cls, @selector(layoutSubviews),
                           (IMP)tfd_layoutSubviews, (IMP *)&orig_layoutSubviews);
    SEL s2 = NSSelectorFromString(@"setLayoutMode:");
    if (class_getInstanceMethod(cls, s2))
        MSHookMessageEx(cls, s2, (IMP)tfd_setLayoutMode, (IMP *)&orig_setLayoutMode);
    SEL s3 = NSSelectorFromString(@"setElementIdentifier:");
    if (class_getInstanceMethod(cls, s3))
        MSHookMessageEx(cls, s3, (IMP)tfd_setElementIdentifier, (IMP *)&orig_setElementIdentifier);
    NSLog(@"[TFD] hooked %@ (layoutSubviews=%d setLayoutMode=%d setIdent=%d)",
          NSStringFromClass(cls),
          m != NULL,
          class_getInstanceMethod(cls, s2) != NULL,
          class_getInstanceMethod(cls, s3) != NULL);
}

#pragma mark - Hooks: 状态栏录屏红点

static void (*orig_applyUpdate)(id, SEL, id, id);

static void tfd_applyUpdate(id self, SEL _cmd, id update, id displayItem) {
    NSDictionary *cfg = TFDReadSettings(@"");
    if ([cfg[@"enabled"] boolValue] && [cfg[@"hideSiblings"] boolValue]) {
        // 藏掉红点：不调用原实现即可（它负责把 indicator 挂上去）
        return;
    }
    if (orig_applyUpdate) orig_applyUpdate(self, _cmd, update, displayItem);
}

static void TFDHookStatusBar(void) {
    Class c = NSClassFromString(@"STUIStatusBarIndicatorRecordingItem");
    if (!c) {
        NSLog(@"[TFD] 未找到 STUIStatusBarIndicatorRecordingItem（该版本可能无红点）");
        return;
    }
    SEL sel = NSSelectorFromString(@"applyUpdate:toDisplayItem:");
    if (class_getInstanceMethod(c, sel))
        MSHookMessageEx(c, sel, (IMP)tfd_applyUpdate, (IMP *)&orig_applyUpdate);
    NSLog(@"[TFD] hooked 状态栏录屏红点");
}

#pragma mark - 录屏状态变化

static void TFDOnCaptureChanged(CFNotificationCenterRef c, void *obs,
                                CFStringRef name, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL on = TFDRecordingActive();
        NSLog(@"[TFD] 录屏状态变化 captured=%d", on);
        TFDRefreshAll(on);      // 开启时打印元素详情，方便排错
    });
}

#pragma mark - 入口

__attribute__((constructor)) static void TFDInit(void) {
    NSLog(@"[TFD] TFDRecordIsland 加载");
    dispatch_async(dispatch_get_main_queue(), ^{
        Class el = NSClassFromString(@"SAUIElementView");
        if (el) {
            TFDHookElementClass(el);
        } else {
            // SpringBoard 早期可能还没注册这个类，延迟再试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                Class c2 = NSClassFromString(@"SAUIElementView");
                if (c2) TFDHookElementClass(c2);
                else NSLog(@"[TFD] 找不到 SAUIElementView，灵动岛接口不可用");
            });
        }

        TFDHookStatusBar();

        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                       TFDOnCaptureChanged,
                                       (__bridge CFStringRef)UIScreenCapturedDidChangeNotification,
                                       NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        TFDRefreshAll(NO);
        NSLog(@"[TFD] 初始化完成，素材根目录=%@", TFDDefaultAssetRoot);
    });
}
