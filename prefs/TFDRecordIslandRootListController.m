#import "TFDRecordIslandRootListController.h"
#import "TFDConfig.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

/// 面板自带的「查看日志」页：直接从 /var/mobile/Library/Logs/TFDRecordIsland.log 读
@interface TFDLogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@end

@implementation TFDLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:_textView];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                            target:self action:@selector(doRefresh)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(doClear)];
    self.navigationItem.rightBarButtonItems = @[refresh, clear];
    [self doRefresh];
}

- (NSString *)logPath {
    return @"/var/mobile/Library/Logs/TFDRecordIsland.log";
}

- (void)doRefresh {
    NSString *s = [NSString stringWithContentsOfFile:[self logPath]
                                            encoding:NSUTF8StringEncoding error:NULL];
    if (!s.length) {
        s = [NSString stringWithFormat:
             @"日志为空或还没生成。\n\n路径：%@\n\n"
             @"提示：\n"
             @"1. 录屏一次之后再看这里\n"
             @"2. 若仍为空，说明插件没被注入（检查是否 rootless 装了 rootful 包）\n"
             @"3. 也可以命令行跑：\n   log stream --predicate 'eventMessage CONTAINS \"[TFD]\"' --level debug",
             [self logPath]];
    } else {
        // 只显示最后 200KB，避免大日志卡死
        if (s.length > 200 * 1024) s = [s substringFromIndex:s.length - 200 * 1024];
    }
    _textView.text = s;
    if (_textView.text.length) {
        [_textView scrollRangeToVisible:NSMakeRange(_textView.text.length - 1, 1)];
    }
}

- (void)doClear {
    [[NSFileManager defaultManager] removeItemAtPath:[self logPath] error:NULL];
    [self doRefresh];
}
@end

@implementation TFDRecordIslandRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"日志" style:UIBarButtonItemStylePlain
               target:self action:@selector(showLogs)];
}

- (void)showLogs {
    TFDLogViewController *vc = [[TFDLogViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

/// 素材目录列表：把 /var/mobile/灵动岛/帧率素材 下的子目录填进下拉
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:TFD_PREF_DOMAIN];
    id v = [d objectForKey:key];
    return v ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:TFD_PREF_DOMAIN];
    [d setObject:value forKey:key];
    [d synchronize];
    // 通知 SpringBoard 重新读配置
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.tfd.recordisland/settingschanged"), NULL, NULL, true);
    [super setPreferenceValue:value specifier:specifier];
}

- (void)reloadAssets {
    [self reloadSpecifiers];
}
@end
