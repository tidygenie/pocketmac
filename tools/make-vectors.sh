#!/bin/bash
# Regenerates the Android protocol fixtures from the Swift code:
#  - known-answer vectors (handshake, crypto, every message type)
#  - short recorded HEVC and H.264 streams from a test-pattern host, plus the demo desktop
# Usage: tools/make-vectors.sh <scratch-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
T="$1"; mkdir -p "$T"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Shared/*.swift tools/vectors/main.swift -o build/vectors
build/vectors android/app/src/test/resources/vectors.txt
tools/build-pmtest.sh > /dev/null
[ -x "build/PocketMac Host.app/Contents/MacOS/PocketMacHost" ] || tools/build-host.sh > /dev/null
ID=$(tools/test-host.sh "$T" 47811 | awk '{print $2}')
A=android/app/src/androidTest/assets; mkdir -p "$A"
build/pmtest --id "$ID" --password testpass123 --port 47811 --identity "$T/A.key" --seconds 3 --codec hevc --dump "$A/stream-hevc.bin" | tail -1
build/pmtest --id "$ID" --password testpass123 --port 47811 --identity "$T/A.key" --seconds 3 --codec h264 --dump "$A/stream-h264.bin" | tail -1
kill "$(cat "$T/host.pid")" 2>/dev/null || true
# The made-up demo desktop (Host/DemoDesktop.swift) for the screenshot test — never a real screen.
ID=$(POCKETMAC_TEST_PATTERN=desktop tools/test-host.sh "$T" 47811 | awk '{print $2}')
build/pmtest --id "$ID" --password testpass123 --port 47811 --identity "$T/A.key" --seconds 5 --codec hevc --quality 2 --dump "$A/demo-hevc.bin" | tail -1
kill "$(cat "$T/host.pid")" 2>/dev/null || true
ls -la "$A"
