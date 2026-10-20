#!/bin/bash
# Builds the iPhone app as a Mac Catalyst app, connects it to a throw-away test
# host and saves the frame it is displaying. Usage: tools/test-catalyst.sh <scratch-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
T="$1"; mkdir -p "$T"
SDK=$(xcrun --sdk macosx --show-sdk-path)
APP=build/PocketMacCatalyst.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-ios17.0-macabi -sdk "$SDK" \
  -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" -I "$SDK/System/iOSSupport/usr/lib/swift" \
  -L "$SDK/System/iOSSupport/usr/lib/swift" -Xlinker -rpath -Xlinker /System/iOSSupport/usr/lib/swift \
  Shared/*.swift iOS/PocketMac/*.swift -o "$APP/Contents/MacOS/PocketMac"
cp tools/catalyst-Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
rm -rf "$T/cfg"
ID=$(tools/test-host.sh "$T" 47811 | awk '{print $2}')
rm -f "$T/catalyst.png"
POCKETMAC_AUTOCONNECT="$ID|testpass123|127.0.0.1|47811" POCKETMAC_DUMP="$T/catalyst.png" \
  "$APP/Contents/MacOS/PocketMac" 2>&1 | grep PMDEBUG || true
kill "$(cat "$T/host.pid")" 2>/dev/null || true
ls -la "$T/catalyst.png"
