#!/bin/bash
# Starts a throw-away headless host (test pattern, loopback only) for tools/pmtest.
# Usage: tools/test-host.sh <scratch-dir> [port]
set -euo pipefail
cd "$(dirname "$0")/.."
T="$1"; PORT="${2:-47811}"
# Stop only a previous *test* host (by its saved pid / test port) — never the real app.
[ -f "$T/host.pid" ] && kill "$(cat "$T/host.pid")" 2>/dev/null || true
OLD=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null || true); [ -n "$OLD" ] && kill $OLD 2>/dev/null || true
sleep 0.3
mkdir -p "$T/cfg"
POCKETMAC_CONFIG_DIR="$T/cfg" POCKETMAC_SET_PASSWORD=testpass123 POCKETMAC_PORT=$PORT POCKETMAC_LOOPBACK=1 \
POCKETMAC_HEADLESS=1 POCKETMAC_TEST_PATTERN=1 POCKETMAC_PRIVACY_DRYRUN=1 POCKETMAC_LOCK_GRACE=4 "build/PocketMac Host.app/Contents/MacOS/PocketMacHost" > "$T/host.log" 2>&1 &
echo $! > "$T/host.pid"
for i in $(seq 1 100); do grep -q "Listening on port" "$T/host.log" && break; sleep 0.1; done
grep -o "ID [0-9A-Z-]*" "$T/host.log" | head -1
