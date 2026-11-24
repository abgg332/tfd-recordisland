#import <UIKit/UIKit.h>

/// 设置 key（NSUserDefaults 域 com.tfd.recordisland）
#define TFD_PREF_DOMAIN    @"com.tfd.recordisland"

#define TFD_KEY_ENABLED         @"Enabled"
#define TFD_KEY_ASSET           @"AssetName"
#define TFD_KEY_FPS             @"FPS"
#define TFD_KEY_ROTATION        @"AssetRotation"
#define TFD_KEY_ROTATION_REV    @"AssetReverseRotation"
#define TFD_KEY_ROTATION_FPS    @"AssetRotationSpeed"
#define TFD_KEY_SCALE           @"AssetScale"
#define TFD_KEY_OFFSET_X        @"AssetOffsetX"
#define TFD_KEY_OFFSET_Y        @"AssetOffsetY"
#define TFD_KEY_HIDE_SIBLINGS   @"HideSystemContent"

/// 按前缀读一组设置（prefix 用来区分 mini / trailing / recording 等不同位置）
NSDictionary *TFDReadSettings(NSString *prefix);
