DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
BUILD_DIR := .local/player-build
APP := $(BUILD_DIR)/Build/Products/Debug/Ipple Music.app
.DEFAULT_GOAL := mac-build

.PHONY: mac-build mac-run mac-test mac-package
mac-build:
	xcrun xcodebuild -quiet -project IppleMusicMac.xcodeproj -scheme IppleMusicMac -configuration Debug -destination 'platform=macOS' -derivedDataPath "$(BUILD_DIR)" build

mac-run: mac-build
	open "$(APP)"

mac-package:
	xcrun xcodebuild -quiet -project IppleMusicMac.xcodeproj -scheme IppleMusicMac -configuration Release -destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath "$(BUILD_DIR)" build
	/usr/bin/python3 scripts/package-dmg.py "$(BUILD_DIR)/Build/Products/Release/Ipple Music.app"

mac-test:
	xcrun swift test

.PHONY: qq-test
qq-test:
	/usr/bin/python3 scripts/prepare-mac-qq.py
	.local/build/mac-qq-runtime/node --test QQMusicRuntime/upstream/*.test.cjs
