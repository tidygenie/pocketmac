#!/bin/bash
# Runs inside the CI emulator: installs the app + tests, runs them, collects screenshots and logs.
set -uo pipefail
PKG=com.nareshchoudhary.pocketmac
B=android/app/build/outputs/apk
adb install -r -g "$B/debug/app-debug.apk"
adb install -r -g "$B/androidTest/debug/app-debug-androidTest.apk"
adb logcat -c || true
# Clean status bar for the screenshots (Android's demo mode: 9:41, full signal, no notifications).
adb shell settings put global sysui_demo_allowed 1 || true
for c in "clock -e hhmm 0941" "battery -e level 100 -e plugged false" "network -e wifi show -e level 4 -e fully true" \
         "network -e mobile show -e level 4 -e datatype none" "notifications -e visible false"; do
  adb shell am broadcast -a com.android.systemui.demo -e command $c > /dev/null || true
done
OUT=$(adb shell am instrument -w $PKG.test/androidx.test.runner.AndroidJUnitRunner 2>&1)
echo "$OUT" | tail -80
mkdir -p device-results
adb exec-out run-as $PKG tar cf - files/screens 2>/dev/null | tar xf - -C device-results 2>/dev/null || true
adb logcat -d > device-results/logcat-full.txt 2>&1 || true
grep -E "PocketMacTest|AndroidRuntime|MediaCodec|CCodec|pocketmac" device-results/logcat-full.txt | tail -300 > device-results/logcat.txt || true
echo "$OUT" > device-results/instrumentation.txt
echo "$OUT" | grep -q "^OK (" || { echo "Device tests FAILED"; exit 1; }
