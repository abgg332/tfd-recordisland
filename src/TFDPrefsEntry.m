#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

/*
 ============================================================================
 设置入口 — 自己往「设置」根列表插一行，不依赖 PreferenceLoader
 ============================================================================

 之前只放了 PreferenceLoader 的 plist。设备上若没装 PreferenceLoader
 （或它没读到 /Library/PreferenceLoader/Preferences），入口就完全消失。
 本文件注入 com.apple.Preferences，程序化插入一行。

 为什么用 detail + bundle 而不是自定义 action：
   PSListController 自己就有「按 specifier 里的 bundle 去
   /Library/PreferenceBundles 找 .bundle 并实例化 principalClass」的逻辑。
   交给它做，比我们手动 dlopen 稳，也和原生设置项行为完全一致。

 两个要点：
 1. -specifiers 被子类各自 override，只 hook 父类没用。必须枚举所有
    PSListController 子类，谁自己实现了 -specifiers 就 hook 谁。
 2. 「设置根列表」判定：specifier 里有 identifier == "General"（通用）。
    只有根列表有这一项。
 ============================================================================
 */

static NSString *const kTFDPrefsTitle = @"录屏岛帧动画";
static NSString *const kTFDPrefsBundleID = @"com.tfd.recordislandprefs";
static BOOL gTFDInserted = NO;

static BOOL TFDIsSettingsRoot(NSArray *specifiers) {
    if (![specifiers isKindOfClass:[NSArray class]]) return NO;
    for (PSSpecifier *s in specifiers) {
        if ([[s identifier] isEqualToString:@"General"]) return YES;
    }
    return NO;
}

static NSArray *TFDInsertEntry(NSArray *orig) {
    if (![orig isKindOfClass:[NSArray class]]) return orig;

    for (PSSpecifier *s in orig) {          // 已存在就不重复插
        if ([[s name] isEqualToString:kTFDPrefsTitle]) return orig;
    }

    NSMutableArray *arr = [orig mutableCopy];
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:kTFDPrefsTitle
                                                       target:nil
                                                          set:NULL
                                                          get:NULL
                                                       detail:Nil
                                                         cell:PSLinkCell
                                                         edit:nil];
    // 这两行让 PSListController 自己去 PreferenceBundles 里找并加载
    [spec setProperty:kTFDPrefsBundleID forKey:@"bundle"];
    [spec setProperty:@"TFDRecordIslandRootListController" forKey:@"detail"];

    NSUInteger at = arr.count;
    for (NSUInteger i = 0; i < arr.count; i++) {
        if ([[arr[i] identifier] isEqualToString:@"General"]) { at = i; break; }
    }
    [arr insertObject:spec atIndex:at];
    NSLog(@"[TFD] 已插入设置入口，位置 %lu/%lu", (unsigned long)at, (unsigned long)arr.count);
    return arr;
}

/// 每个被 hook 的类各自保存原始 IMP
static NSMutableDictionary<NSString *, id> *gPrefsOrig;

static NSArray *TFDHookedSpecifiers(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    id boxed = gPrefsOrig[NSStringFromClass(cls)];
    IMP orig = boxed ? (IMP)[boxed pointerValue] : NULL;
    NSArray *arr = orig ? ((NSArray *(*)(id, SEL))orig)(self, _cmd) : nil;

    if (!TFDIsSettingsRoot(arr)) return arr;
    if (gTFDInserted) return arr;

    NSArray *out = TFDInsertEntry(arr);
    gTFDInserted = YES;
    return out;
}

static BOOL TFDClassOwnsSel(Class cls, SEL s) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(ms[i]) == s) { own = YES; break; }
    }
    if (ms) free(ms);
    return own;
}

static BOOL TFDIsPSListSubclass(Class c, Class psList) {
    for (Class k = c; k; k = class_getSuperclass(k)) {
        if (k == psList) return YES;
    }
    return NO;
}

__attribute__((constructor)) static void TFDInstallPrefsEntry(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (![bid isEqualToString:@"com.apple.Preferences"]) return;

    NSLog(@"[TFD] 设置入口注入 pid=%d", getpid());

    Class psList = NSClassFromString(@"PSListController");
    if (!psList) { NSLog(@"[TFD] 没有 PSListController，放弃"); return; }

    gPrefsOrig = [NSMutableDictionary dictionary];
    SEL sel = @selector(specifiers);
    int hooked = 0;

    int n = objc_getClassList(NULL, 0);
    if (n > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)n);
        if (classes) {
            n = objc_getClassList(classes, n);
            for (int i = 0; i < n; i++) {
                Class c = classes[i];
                if (!TFDIsPSListSubclass(c, psList)) continue;
                if (!TFDClassOwnsSel(c, sel)) continue;   // 只 hook 自己实现了的

                IMP orig = NULL;
                MSHookMessageEx(c, sel, (IMP)&TFDHookedSpecifiers, &orig);
                if (orig) gPrefsOrig[NSStringFromClass(c)] = [NSValue valueWithPointer:orig];
                hooked++;
            }
            free(classes);
        }
    }

    if (TFDClassOwnsSel(psList, sel)) {
        IMP orig = NULL;
        MSHookMessageEx(psList, sel, (IMP)&TFDHookedSpecifiers, &orig);
        if (orig) gPrefsOrig[@"PSListController"] = [NSValue valueWithPointer:orig];
        hooked++;
    }

    NSLog(@"[TFD] 已接管 %d 个 -specifiers", hooked);
}
