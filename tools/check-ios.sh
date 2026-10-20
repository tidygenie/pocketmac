#!/bin/bash
# Type-checks the iPhone app against Mac Catalyst's UIKit (no Xcode / iOS SDK needed).
# Catches almost every compile error before the GitHub cloud build.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-ios17.0-macabi -sdk "$SDK" \
  -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -I "$SDK/System/iOSSupport/usr/lib/swift" -L "$SDK/System/iOSSupport/usr/lib/swift" \
  Shared/*.swift iOS/PocketMac/*.swift "$@"
echo "iOS type-check OK"
