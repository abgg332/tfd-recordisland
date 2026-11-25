TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TFDRecordIsland
TFDRecordIsland_FILES = src/TFDPlayer.m src/TFDConfig.m src/TFDTweak.m
TFDRecordIsland_CFLAGS = -fobjc-arc -O2 -Isrc \
	-Wno-deprecated-declarations -Wno-unused-parameter \
	-Wno-nullability-completeness
TFDRecordIsland_FRAMEWORKS = UIKit Foundation QuartzCore ImageIO CoreGraphics
TFDRecordIsland_PRIVATE_FRAMEWORKS = Preferences
TFDRecordIsland_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

# 只有 Linux 本机编译才需要指定 lld；macOS runner 上的 clang 不认这个参数
ifeq ($(shell uname),Linux)
TFDRecordIsland_LDFLAGS += -fuse-ld=lld
endif

include $(THEOS)/makefiles/tweak.mk

BUNDLE_NAME = TFDRecordIslandPrefs
TFDRecordIslandPrefs_INSTALL_PATH = /Library/PreferenceBundles
TFDRecordIslandPrefs_FILES = prefs/TFDRecordIslandRootListController.m
TFDRecordIslandPrefs_CFLAGS = -fobjc-arc -O2 -Isrc -Iprefs \
	-Wno-deprecated-declarations -Wno-unused-parameter \
	-Wno-nullability-completeness
TFDRecordIslandPrefs_FRAMEWORKS = UIKit Foundation QuartzCore
TFDRecordIslandPrefs_PRIVATE_FRAMEWORKS = Preferences
TFDRecordIslandPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS)/makefiles/bundle.mk

after-stage::
	@echo "==> 安装 PreferenceLoader 入口"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp layout/Library/PreferenceLoader/Preferences/TFDRecordIsland.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"
	@echo "==> 校验 PreferenceBundle 是否真的产出了"
	@test -d "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/TFDRecordIslandPrefs.bundle" || \
		{ echo "错误: PreferenceBundle 未生成，设置里不会有入口"; exit 1; }
	@ls "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/TFDRecordIslandPrefs.bundle/"

after-install::
	install.exec "killall -9 SpringBoard Preferences || true"
