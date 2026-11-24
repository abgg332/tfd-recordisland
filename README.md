# 录屏岛帧动画 · TFDRecordIsland

原创实现。用自定义 PNG 帧序列替换灵动岛在**录屏状态**下的显示内容。

- 包名 `com.tfd.recordisland` / 作者 tfd
- 架构 arm64e（arm64 设备也可用，CI 出 arm64+arm64e 双架构）
- 支持 rootless / roothide

## 素材路径

```
/var/mobile/灵动岛/帧率素材/<素材名>/1.png 2.png 3.png ...
```

帧按文件名**自然排序**（`2.png` 排在 `10.png` 前面），所以不必补零。支持 png/jpg/jpeg/webp/heic。

目录不存在时插件自动创建根目录。设置面板里「素材名」填子目录名即可。

## 隐藏：录屏指示是怎么被替换掉的

iOS 15+ 的录屏状态显示在灵动岛里，由 SpringBoard 的 `SAUIElementView` 承载，
内容来源是它持有的 `SAUILayoutModePreferringElement` / `SAUIPlatterElement` 之类元素。

**关键接口**（`SAUIElementView` 上的真实属性，来自私有类）：

| 属性 | 作用 |
|---|---|
| `leadingView` | 灵动岛左侧视图（mini 态的主体） |
| `trailingView` | 灵动岛右侧视图（展开态的尾部） |
| `detachedMinimalView` | 脱离状态下的最小视图 |
| `minimalTransformView` / `leadingTransformView` / `trailingTransformView` | 三个容器层，做变换用 |
| `elementHost` | 元素宿主 |
| `elementIdentifier` | 元素标识（区分是录屏还是音乐/通话） |

隐藏的思路不是去删系统视图（会崩，且系统会在 layout 时重建），而是：

1. hook `SAUIElementView` 的 `layoutSubviews`
2. 判断当前 `elementIdentifier` 是否属于录屏元素
3. 若命中且开关打开，遍历 `leadingView` / `trailingView` 的**直接子视图**，把系统自绘的那几层 `hidden = YES`
4. 同时把自己创建的 `TFDPlayerView` 挂到 `leadingView` 上，`bringSubviewToFront:`

为什么必须 hook `layoutSubviews` 而不是 `didMoveToWindow`：
灵动岛在展开/收起/录音切换时会**重建子视图层级**，只在初始时藏一次会被系统覆盖回去。
每次 layout 都重新确认一遍，才是稳定的做法。

另外 `setDisableUpdateMask:` 这个 selector 也存在——那是系统用来禁用更新遮罩的，
用它可以让系统不重绘那块区域，避免和我们的动画打架（本实现里作为可选手段）。

## 显示：帧动画怎么播

自建 `TFDPlayerView : UIView`，内部持有一个 `UIImageView`：

- `+availableAssets` 扫描素材根目录列出子目录
- `reloadAndPlay` 读目录 → 排序 → `UIImage imageWithContentsOfFile:` 逐帧加载
- 用 `CADisplayLink` 按 `fps` 节流推进 `animationImageView.image`（不用 `UIImageView` 自带的
  `animationImages`，因为那个只能整组设帧率，且无法和旋转动画解耦）
- `applyTransform` 做缩放 + XY 偏移；旋转用 `CABasicAnimation` 加在 layer 上（`repeatCount = HUGE_VALF`），
  和帧推进互不干扰

旋转速度映射：`speed 1..10` → 一圈 60s..6s，`reverse` 时 `speed = -speed`。

## Hook 点清单

| 类 | selector | 用途 |
|---|---|---|
| `SAUIElementView` | `layoutSubviews` | 注入/刷新播放器，藏系统内容 |
| `SAUIElementView` | `setElementIdentifier:` | 记录当前元素类型 |
| `SAUIElementView` | `setLeadingView:` / `setTrailingView:` | 系统换视图时重新挂载 |
| `MRUCoverSheetViewController` | `viewDidLayoutSubviews` | 锁屏/媒体远程界面兜底 |

只 hook 类存在时才安装（`objc_getClass` 判空），iOS 版本差异不会崩。

## 已知边界（不吹）

- 只做**录屏**这一个元素；音乐/通话/计时不走这套逻辑
- 系统若在 iOS 18 改了 `SAUIElementView` 的属性名，需按日志重新定位（本实现会在
  找不到属性时打印 `[TFD]` 日志，不静默失败）
- 帧序列全量载入内存；1000 帧 × 200KB 会吃 200MB，建议单素材 ≤ 200 帧
- arm64e 切片由 CI 的 roothide theos 原生编译；本地产物是 arm64（arm64e 设备可加载）

## 调试

```sh
log stream --predicate 'eventMessage CONTAINS "[TFD]"' --level debug
```

会打印：素材目录、识别到的帧数、当前 elementIdentifier、注入是否成功。
