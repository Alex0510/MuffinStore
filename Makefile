# Makefile
ARCHS = arm64
TARGET = iphone:clang:14.5:11.0

include $(THEOS)/makefiles/common.mk

# Tweak 配置（注入到所有应用）
TWEAK_NAME = MuffinStoreTweak
MuffinStoreTweak_FILES = Tweak.xm
MuffinStoreTweak_CFLAGS = -fobjc-arc
MuffinStoreTweak_FRAMEWORKS = UIKit Security

include $(THEOS_MAKE_PATH)/tweak.mk

# 主应用配置
APPLICATION_NAME = MuffinStore
MuffinStore_FILES = main.m MFSAppDelegate.m MFSRootViewController.m
MuffinStore_FRAMEWORKS = UIKit Foundation CoreGraphics Security
MuffinStore_CFLAGS = -fobjc-arc
MuffinStore_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

# 安装后操作
after-install::
	install.exec "killall -9 MuffinStore 2>/dev/null || true"