APP_NAME := SlipBar
SRC      := Sources/main.swift
BUILD    := build
APP      := $(BUILD)/$(APP_NAME).app
MACOS    := $(APP)/Contents/MacOS
RES      := $(APP)/Contents/Resources
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
ZIP      := $(BUILD)/$(APP_NAME)-$(VERSION).zip

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SWIFTC   := $(DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK      := $(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
# Pin the deployment target; the default toolchain may stamp a newer minimum OS.
MIN_OS   := 26.0
ARCHS    := arm64 x86_64

.PHONY: all clean run kill dist

all: $(APP)

$(APP): $(SRC) Info.plist Resources/AppIcon.icns
	mkdir -p "$(MACOS)" "$(RES)"
	for arch in $(ARCHS); do \
		"$(SWIFTC)" -O -parse-as-library \
			-sdk "$(SDK)" \
			-target $$arch-apple-macos$(MIN_OS) \
			-framework AppKit \
			-framework ServiceManagement -framework Carbon \
			-o "$(BUILD)/$(APP_NAME)-$$arch" \
			$(SRC) || exit 1; \
	done
	lipo -create $(foreach arch,$(ARCHS),"$(BUILD)/$(APP_NAME)-$(arch)") -output "$(MACOS)/$(APP_NAME)"
	rm -f $(foreach arch,$(ARCHS),"$(BUILD)/$(APP_NAME)-$(arch)")
	cp Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	cp -f Resources/AppIcon.icns "$(RES)/"
	codesign --force --sign - "$(APP)"
	@echo "Built $(APP)"

run: all kill
	open "$(APP)"

kill:
	-pkill -x $(APP_NAME) 2>/dev/null || true

dist: all
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	@echo "Packaged $(ZIP)"

clean:
	rm -rf "$(BUILD)"
