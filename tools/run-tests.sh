#!/bin/bash
# End-to-end tests: starts a throw-away test-pattern host, then exercises login,
# pairing policy, brute-force lockout and both codecs with tools/pmtest.
# Usage: tools/run-tests.sh <scratch-dir>
set -u
cd "$(dirname "$0")/.."
T="$1"; rm -rf "$T"; mkdir -p "$T"
ID=$(tools/test-host.sh "$T" 47811 | awk '{print $2}')
P=(--port 47811)
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "   ^^^ FAILED"; fi; }
t() { echo "== $1"; shift; check "$@"; }

t "first login pairs this phone, HEVC stream decodes" build/pmtest --id "$ID" --password testpass123 "${P[@]}" --identity "$T/A.key" --seconds 5 --png "$T/hevc.png"
t "H.264 stream decodes" build/pmtest --id "$ID" --password testpass123 "${P[@]}" --identity "$T/A.key" --seconds 4 --codec h264 --png "$T/h264.png"
t "sharp quality, 60 fps" build/pmtest --id "$ID" --password testpass123 "${P[@]}" --identity "$T/A.key" --seconds 4 --quality 2 --fps 60
# Privacy while remote (host runs in dry-run: actions are only logged; grace shortened to 4 s)
L="$T/host.log"
n() { grep -c "$1" "$L"; }
q() { build/pmtest --id "$ID" --password testpass123 "${P[@]}" --identity "$T/A.key" --seconds 1 "$@" > /dev/null 2>&1; }
dark0=$(n "Mac screen dark"); lock0=$(n "locking Mac"); q; sleep 1
t "connect darkens the Mac screen" [ "$(n "Mac screen dark")" -gt "$dark0" ]
t "tapping ✕ on the phone locks the Mac right away" [ "$(n "locking Mac")" -gt "$lock0" ]
lock1=$(n "locking Mac"); drop1=$(n "connection dropped"); q --pause-before-close; sleep 0.5
t "phone app going to background is treated as a drop (grace period)" [ "$(n "connection dropped")" -gt "$drop1" ]
t "…and does not lock immediately" [ "$(n "locking Mac")" -eq "$lock1" ]
q; lockA=$(n "locking Mac"); sleep 5
t "reconnecting within the grace period cancels the pending lock" [ "$(n "locking Mac")" -eq "$lockA" ]
lock2=$(n "locking Mac"); q --pause-before-close; sleep 6
t "no reconnect → Mac locks after the grace period" [ "$(n "locking Mac")" -gt "$lock2" ]
t "brightness restored after every lock" [ "$(n "brightness restored")" -ge "$(n "locking Mac")" ]
t "paired phone + wrong password is refused" build/pmtest --id "$ID" --password nope "${P[@]}" --identity "$T/A.key" --expect-fail badCredentials
t "a second phone is refused once one is paired (even with right password)" build/pmtest --id "$ID" --password testpass123 "${P[@]}" --identity "$T/B.key" --expect-fail notAuthorized
t "fake Mac (ID doesn't match key) is detected" build/pmtest --id "1N81-1EPB-JZXA" --password testpass123 "${P[@]}" --identity "$T/A.key" --expect-fail protocolError
for i in 2 3 4; do t "wrong guess $i" build/pmtest --id "$ID" --password guess$i "${P[@]}" --identity "$T/A.key" --expect-fail badCredentials; done
t "5th wrong guess → locked out (30 s, doubling)" build/pmtest --id "$ID" --password guess5 "${P[@]}" --identity "$T/A.key" --expect-fail lockedOut
t "even the right password is refused during lockout" build/pmtest --id "$ID" --password testpass123 "${P[@]}" --identity "$T/A.key" --expect-fail lockedOut
pkill -f "PocketMacHost" 2>/dev/null
echo; echo "PASSED $pass  FAILED $fail"
[ $fail -eq 0 ]
