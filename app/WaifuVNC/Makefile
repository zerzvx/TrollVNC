ARCHS := arm64
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = WaifuVNC

WaifuVNC_FILES = main.m WFAppDelegate.m
WaifuVNC_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
WaifuVNC_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk
