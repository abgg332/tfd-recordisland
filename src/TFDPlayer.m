#import "TFDPlayer.h"
#import <ImageIO/ImageIO.h>

NSString *const TFDDefaultAssetRoot = @"/var/mobile/灵动岛/帧率素材";

/// 素材目录里允许的图片后缀
static NSArray<NSString *> *TFDImageExts(void) {
    return @[ @"png", @"PNG", @"jpg", @"JPG", @"jpeg", @"JPEG", @"webp", @"WEBP", @"heic", @"HEIC" ];
}

/// 自然排序：1.png < 2.png < 10.png（普通字典序会排成 1,10,2）
static NSInteger TFDNaturalCompare(NSString *a, NSString *b, void *ctx) {
    return [a compare:b options:NSNumericSearch | NSCaseInsensitiveSearch];
}

@interface TFDPlayerView ()
@property (nonatomic, strong) UIImageView *frameView;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSMutableArray<UIImage *> *frames;
@property (nonatomic, assign) double lastTick;
@property (nonatomic, assign) NSUInteger frameIndex;
@property (nonatomic, assign) double acc;
@end

@implementation TFDPlayerView {
    CADisplayLink *_link;
}

+ (NSArray<NSString *> *)availableAssets {
    NSError *err = nil;
    NSArray *names = [[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:TFDDefaultAssetRoot error:&err];
    if (!names) return @[];
    NSMutableArray *dirs = [NSMutableArray array];
    for (NSString *n in names) {
        if ([n hasPrefix:@"."]) continue;
        NSString *full = [TFDDefaultAssetRoot stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [dirs addObject:n];
        }
    }
    [dirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return TFDNaturalCompare(a, b, NULL);
    }];
    return dirs;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        _frameView = [[UIImageView alloc] initWithFrame:self.bounds];
        _frameView.contentMode = UIViewContentModeScaleAspectFit;
        _frameView.clipsToBounds = YES;
        _frameView.backgroundColor = [UIColor clearColor];
        [self addSubview:_frameView];
        _fps = 60;
        _assetScale = 1.0;
        _rotationSpeed = 5;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _frameView.frame = self.bounds;
    [self applyTransform];
}

#pragma mark - 素材加载

/// 读一个目录下的图片序列。为控制内存，按长边 240px 生成缩略图后解码。
- (NSMutableArray<UIImage *> *)loadFramesFrom:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:NULL];
    if (!files.count) return nil;
    NSMutableArray<NSString *> *imgs = [NSMutableArray array];
    NSArray *exts = TFDImageExts();
    for (NSString *f in files) {
        if ([f hasPrefix:@"."]) continue;
        if ([exts containsObject:[f pathExtension]]) [imgs addObject:f];
    }
    if (!imgs.count) return nil;
    [imgs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return TFDNaturalCompare(a, b, NULL);
    }];
    NSMutableArray<UIImage *> *out = [NSMutableArray arrayWithCapacity:imgs.count];
    for (NSString *f in imgs) {
        NSString *p = [dir stringByAppendingPathComponent:f];
        UIImage *img = [self thumbnailOfFile:p maxPixel:240];
        if (img) [out addObject:img];
    }
    return out.count ? out : nil;
}

/// 用 ImageIO 直接生成缩略图：比 imageWithContentsOfFile 省内存（大图序列容易 OOM）
- (UIImage *)thumbnailOfFile:(NSString *)path maxPixel:(CGFloat)maxPx {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(maxPx),
        (id)kCGImageSourceShouldCacheImmediately : @YES,
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg scale:[UIScreen mainScreen].scale
                                       orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

- (void)setAssetName:(NSString *)assetName {
    _assetName = [assetName copy];
    [self reloadAndPlay];
}

- (void)reloadAndPlay {
    [self stopPlayback];
    if (!_assetName.length) return;

    NSString *dir = [TFDDefaultAssetRoot stringByAppendingPathComponent:_assetName];
    NSMutableArray *frames = [self loadFramesFrom:dir];
    if (!frames) {
        NSLog(@"[TFD] 素材读取失败: %@", dir);
        return;
    }
    _frames = frames;

    // 用首帧决定 contentMode 之外的比例：素材按 aspectFit 铺满宿主
    _frameView.animationImages = nil;   // 我们自己做逐帧，不用 animatedImage
    _frameView.image = frames.firstObject;
    _frameIndex = 0;
    [self applyTransform];
    [self start];
}

#pragma mark - 播放

- (void)start {
    if (_link || !_frames.count) return;
    _lastTick = 0;
    _acc = 0;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    // 注意：优先高帧率，但别声明 preferredFrameRateRange 超过屏幕能力
    if (@available(iOS 15.0, *)) {
        _link.preferredFrameRateRange = CAFrameRateRangeMake(10, 120, (float)MAX(10, MIN(120, _fps)));
    }
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _isPlaying = YES;
}

- (void)stopPlayback {
    [_link invalidate];
    _link = nil;
    _isPlaying = NO;
}

/// 逐帧推进：用累加时间而不是「每 tick 换一张」，这样 fps 与刷新率解耦
- (void)tick:(CADisplayLink *)link {
    if (!_frames.count) return;
    double now = link.timestamp;
    if (_lastTick <= 0) { _lastTick = now; return; }
    _acc += (now - _lastTick);
    _lastTick = now;

    double fps = (_fps > 0 ? _fps : 60);
    double period = 1.0 / fps;
    if (_acc < period) return;
    // 掉帧时一次跳过多帧，避免进度落后越拖越多
    NSUInteger step = (NSUInteger)(_acc / period);
    _acc -= step * period;
    _frameIndex = (_frameIndex + step) % _frames.count;
    _frameView.image = _frames[_frameIndex];
    if (_rotationEnabled) [self applyTransform];
}

- (void)setFps:(double)fps {
    _fps = fps;
    if (@available(iOS 15.0, *)) {
        if (_link) _link.preferredFrameRateRange = CAFrameRateRangeMake(10, 120, (float)MAX(10, MIN(120, fps)));
    }
}



#pragma mark - 缩放/偏移/旋转

- (void)applyTransform {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w <= 0 || h <= 0) return;

    CGAffineTransform t = CGAffineTransformIdentity;
    // 素材适配：aspectFit 已经由 contentMode 处理，这里只做用户倍率
    t = CGAffineTransformScale(t, _assetScale, _assetScale);

    if (_rotationEnabled) {
        // 用时间驱动，而不是累积角度：避免掉帧导致转速不稳
        double speed = MAX(0.0, MIN(10.0, _rotationSpeed));
        double period = 12.0 / MAX(0.1, speed);     // speed=5 → 2.4 秒? 见下
        // 设计：speed 5 约 12 秒一圈 → period = 12 * (5/speed)
        period = 12.0 * (5.0 / MAX(0.001, speed));
        double angle = (CACurrentMediaTime() / period) * 2 * M_PI;
        if (_rotationReverse) angle = -angle;
        t = CGAffineTransformRotate(t, angle);
    }
    _frameView.transform = t;
    _frameView.center = CGPointMake(w / 2 + _offsetX, h / 2 + _offsetY);
}

- (void)setRotationEnabled:(BOOL)v { _rotationEnabled = v; [self applyTransform]; }
- (void)setRotationReverse:(BOOL)v { _rotationReverse = v; [self applyTransform]; }
- (void)setRotationSpeed:(double)v { _rotationSpeed = v; [self applyTransform]; }
- (void)setAssetScale:(double)v { _assetScale = v; [self applyTransform]; }
- (void)setOffsetX:(double)v { _offsetX = v; [self applyTransform]; }
- (void)setOffsetY:(double)v { _offsetY = v; [self applyTransform]; }

#pragma mark - 隐藏宿主原有内容

- (void)setHideSiblings:(BOOL)hide {
    _hideSiblings = hide;
    UIView *p = self.superview;
    if (!p) return;
    for (UIView *sib in p.subviews) {
        if (sib == self) continue;
        sib.hidden = hide;
    }
}

- (void)removeFromSuperview {
    [self stopPlayback];
    [super removeFromSuperview];
}

- (void)dealloc {
    [self stopPlayback];
}

@end
