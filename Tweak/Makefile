# Jev ScreenReader —— 越狱插件（Dopamine rootless / ellekit）
# 云编译：GitHub Actions 见 .github/workflows/build-tweak.yml

THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = jev-screenreader
jev-screenreader_FILES = Tweak.xm JevFloaty.m
jev-screenreader_CFLAGS = -fobjc-arc
jev-screenreader_LDFLAGS = -framework Vision

include $(THEOS_MAKE_PATH)/tweak.mk
