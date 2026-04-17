# Makefile
ARCHS = arm64
TARGET = iphone:clang:14.5:11.0

INSTALL_TARGET_PROCESSES = MuffinStore

include $(THEOS)/makefiles/common.mk

# Tweak 配置
TWEAK_NAME = MuffinStoreTweak
MuffinStoreTweak_FILES = Tweak.xm
MuffinStoreTweak_CFLAGS = -fobjc-arc
MuffinStoreTweak_FRAMEWORKS = UIKit Security

include $(THEOS_MAKE_PATH)/tweak.mk

# 主应用配置
APPLICATION_NAME = MuffinStore
MuffinStore_FILES = main.m MFSAppDelegate.m MFSRootViewController.m
MuffinStore_FRAMEWORKS = UIKit Foundation CoreGraphics Security StoreKit
MuffinStore_CFLAGS = -fobjc-arc
MuffinStore_CODESIGN_FLAGS = -Sentitlements.plist
MuffinStore_LDFLAGS = -undefined dynamic_lookup

# 生成 .ipa 而不是 .deb
export TARGET_IPHONEOS_DEPLOYMENT_VERSION = 11.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS_MAKE_PATH)/application.mk

# 安装后操作
after-install::
	install.exec "killall -9 MuffinStore 2>/dev/null || true"

# 添加 .ipa 打包支持
package::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)cp -r $(THEOS_STAGING_DIR)/Applications/MuffinStore.app $(THEOS_STAGING_DIR)/Payload/$(ECHO_END)
	$(ECHO_NOTHING)cd $(THEOS_STAGING_DIR) && zip -qr MuffinStore.ipa Payload$(ECHO_END)
	$(ECHO_NOTHING)mv $(THEOS_STAGING_DIR)/MuffinStore.ipa ./packages/$(ECHO_END)