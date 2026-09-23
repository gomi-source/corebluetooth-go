HELPER_DIR := helper
HELPER_BUILD_BIN := $(HELPER_DIR)/.build/release/corebluetoothd
APP_BUNDLE := $(HELPER_DIR)/.build/corebluetoothd.app
BIN_DIR := bin

.PHONY: all helper go-build example clean

all: helper go-build

## Build the Swift helper (macOS only) and package it as a minimal .app
## bundle. This isn't cosmetic: modern macOS ties CoreBluetooth's privacy
## authorization to a bundle identity read from Info.plist. A bare,
## un-bundled Mach-O binary gets silently SIGKILLed the moment it touches
## CBCentralManager instead of just being denied - see README.md.
helper:
	cd $(HELPER_DIR) && swift build -c release --disable-sandbox
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp $(HELPER_DIR)/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(HELPER_BUILD_BIN) $(APP_BUNDLE)/Contents/MacOS/corebluetoothd
	codesign --force --deep --sign - $(APP_BUNDLE)

## Build the Go client library and example.
go-build:
	go build ./...

## Build the helper + the example scanner into bin/, ready to run.
example: helper
	mkdir -p $(BIN_DIR)
	go build -o $(BIN_DIR)/scan ./example/scan
	rm -rf $(BIN_DIR)/corebluetoothd.app
	cp -R $(APP_BUNDLE) $(BIN_DIR)/corebluetoothd.app

clean:
	rm -rf $(HELPER_DIR)/.build $(BIN_DIR)
