#import <UIKit/UIKit.h>

/// 素材根目录：/var/mobile/灵动岛/帧率素材/<素材名>/
extern NSString *const TFDDefaultAssetRoot;

@interface TFDPlayerView : UIView

/// 素材名（对应 帧率素材/ 下的子目录名）
@property (nonatomic, copy) NSString *assetName;
/// 播放帧率（fps），<=0 时用 60
@property (nonatomic, assign) double fps;
/// 播放中
@property (nonatomic, readonly) BOOL isPlaying;

@property (nonatomic, assign) BOOL  rotationEnabled;
@property (nonatomic, assign) BOOL  rotationReverse;
@property (nonatomic, assign) double rotationSpeed;   // 0..10，5 约 12 秒一圈
@property (nonatomic, assign) double assetScale;      // 0.5..2
@property (nonatomic, assign) double offsetX;         // -10..10 pt
@property (nonatomic, assign) double offsetY;

/// 是否把宿主里的系统自带子视图藏起来（只留我们的动画）
@property (nonatomic, assign) BOOL hideSiblings;

/// 重新读盘并开始播放
- (void)reloadAndPlay;
- (void)stopPlayback;
/// 宿主 bounds 变化后由外部调用
- (void)applyTransform;

/// 列出可用素材名
+ (NSArray<NSString *> *)availableAssets;

@end
