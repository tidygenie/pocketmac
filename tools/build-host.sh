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
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Host/LaunchAgent.plist "$APP/Contents/Library/LaunchAgents/com.nareshchoudhary.pocketmac.host.plist"
[ -f Host/AppIcon.icns ] && cp Host/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Stable local identity (tools/setup-signing.sh) keeps macOS permissions across rebuilds; ad-hoc otherwise.
KC="$HOME/Library/PocketMacSigning/pocketmac-signing.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$HOME/Library/PocketMacSigning/keychain-password")" "$KC"
  codesign --force --sign "PocketMac Local Signing" --keychain "$KC" --identifier com.nareshchoudhary.pocketmac.host "$APP"
else
  echo "warning: no stable signing identity (run tools/setup-signing.sh) — macOS will ask for permissions again"
  codesign --force --sign - --identifier com.nareshchoudhary.pocketmac.host "$APP"
fi
echo "Built: $APP"
