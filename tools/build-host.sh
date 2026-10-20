#!/bin/bash
# Builds "PocketMac Host.app" with only the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/PocketMac Host.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
  -import-objc-header Host/PrivateAPI.h \
  Shared/*.swift Host/*.swift -o "$APP/Contents/MacOS/PocketMacHost"
cp Host/Info.plist "$APP/Contents/Info.plist"
[ -f Host/AppIcon.icns ] && cp Host/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.nareshchoudhary.pocketmac.host "$APP"
echo "Built: $APP"
