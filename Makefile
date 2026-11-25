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
TFDRecordIsland_LDFLAGS = -fuse-ld=lld -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

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
	@echo "==> 校验产物"
	@ls -la "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/TFDRecordIslandPrefs.bundle/" 2>/dev/null || (echo "错误: PreferenceBundle 未生成"; exit 1)

after-install::
	install.exec "killall -9 SpringBoard Preferences || true"
