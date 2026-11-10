#!/bin/bash
# Makes dist/PocketMac-Host.dmg: the Mac app for Apple Silicon and Intel Macs, with an
# Applications shortcut so it installs by drag and drop.
# Usage: tools/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
UNIVERSAL=1 tools/build-host.sh
D=build/dmg
rm -rf "$D" && mkdir -p "$D" dist
cp -R "build/PocketMac Host.app" "$D/"
ln -s /Applications "$D/Applications"
hdiutil create -volname "PocketMac Host" -srcfolder "$D" -ov -format UDZO dist/PocketMac-Host.dmg > /dev/null
rm -rf "$D"
echo "Built: dist/PocketMac-Host.dmg"
