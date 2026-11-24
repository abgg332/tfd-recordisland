TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TFDRecordIsland
TFDRecordIsland_FILES = src/TFDPlayer.m src/TFDConfig.m src/TFDTweak.m
TFDRecordIsland_CFLAGS = -fobjc-arc -O2 -Isrc \
	-Wno-deprecated-declarations -Wno-unused-parameter \
	-Wno-nullability-completeness
TFDRecordIsland_FRAMEWORKS = UIKit Foundation QuartzCore ImageIO CoreGraphics
TFDRecordIsland_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

include $(THEOS)/makefiles/tweak.mk

after-stage::
	@echo "==> 布局文件"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp layout/Library/MobileSubstrate/DynamicLibraries/TFDRecordIsland.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@cp layout/Library/PreferenceLoader/Preferences/TFDRecordIsland.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"
	@cp layout/Library/PreferenceLoader/Preferences/TFDRecordIslandPrefs.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"

after-install::
	install.exec "killall -9 SpringBoard || true"
