#!/usr/bin/env bash
# Chat bug hunt 3 on the emulator (2026-10-25): the debug app driven by integration_test/chat_bughunt3_test.dart
# (real tasks, bots, routines, a team). Screens and logs go to out/. ADB:<cmd> lines from the harness cut or restore
# the network. The job FAILS when the drive fails or the harness printed any QAERR line.
set -u
PKG=com.submac.agent
mkdir -p out/shots out/logs
echo "account: $QA_EMAIL" > out/logs/account.txt
( for i in $(seq 1 1500); do
    for perm in POST_NOTIFICATIONS RECORD_AUDIO READ_CONTACTS READ_CALENDAR CAMERA ACCESS_FINE_LOCATION; do
      adb shell pm grant $PKG android.permission.$perm >/dev/null 2>&1
    done
    adb shell appops set $PKG SCHEDULE_EXACT_ALARM allow >/dev/null 2>&1
    sleep 5
  done ) &
GRANT=$!
adb wait-for-device; sleep 15
adb logcat -c; ( adb logcat -v time > out/logs/logcat_debug.txt ) & LOGC=$!
( while true; do adb shell dumpsys alarm 2>/dev/null | grep -A3 "com.submac.agent" | head -40 > out/logs/alarms_last.txt; sleep 30; done ) & ALM=$!
set -o pipefail
flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/chat_bughunt3_test.dart -d emulator-5554 \
  --dart-define=QA_EMAIL="$QA_EMAIL" --dart-define=QA_PW="$QA_PW" --dart-define=QA_EMAIL2="$QA_EMAIL2" 2>&1 | tee out/logs/drive.txt | while IFS= read -r line; do
  case "$line" in
    *SHOT:*) n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/'); adb exec-out screencap -p > "out/shots/$n.png" ;;
    *ADB:net_off*) echo "$(date -u +%T) net off" >> out/logs/net.txt
                   adb shell cmd connectivity airplane-mode enable; adb shell svc wifi disable; adb shell svc data disable ;;
    *ADB:net_on*)  echo "$(date -u +%T) net on" >> out/logs/net.txt
                   adb shell cmd connectivity airplane-mode disable; adb shell svc wifi enable; adb shell svc data enable ;;
  esac
done
DRIVE=$?
adb shell dumpsys notification --noredact 2>/dev/null | grep -E "pkg=com.submac.agent|android.title|android.text" | head -80 > out/logs/notifications.txt
kill $LOGC $GRANT $ALM 2>/dev/null || true
grep -nE "FATAL EXCEPTION|ANR in|E/flutter|Unhandled Exception" out/logs/logcat_*.txt | head -300 > out/logs/crashes.txt
grep -E "QA:|QAERR:|CB:|MSGS:|SEE:|T:|ADB:" out/logs/drive.txt > out/logs/summary.txt
ls -la out/shots out/logs
NERR=$(grep -c "QAERR:" out/logs/drive.txt || true)
echo "drive exit=$DRIVE QAERR lines=$NERR"
grep "QAERR:" out/logs/drive.txt | head -40
if [ "$DRIVE" != "0" ] || [ "$NERR" != "0" ]; then echo "::error::chat bughunt 3 harness errors (drive=$DRIVE, QAERR=$NERR)"; exit 1; fi
