#!/usr/bin/env bash
# Chat bug hunt 2 on the emulator (2026-10-25): the debug app driven by integration_test/chat_bughunt2_test.dart
# (real tasks, bots, routines, a team). Screens and logs go to out/.
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
flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/chat_bughunt2_test.dart -d emulator-5554 \
  --dart-define=QA_EMAIL="$QA_EMAIL" --dart-define=QA_PW="$QA_PW" 2>&1 | tee out/logs/drive.txt | while IFS= read -r line; do
  case "$line" in
    *SHOT:*) n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/'); adb exec-out screencap -p > "out/shots/$n.png" ;;
  esac
done
adb shell dumpsys notification --noredact 2>/dev/null | grep -E "pkg=com.submac.agent|android.title|android.text" | head -80 > out/logs/notifications.txt
kill $LOGC $GRANT $ALM 2>/dev/null || true
grep -nE "FATAL EXCEPTION|ANR in|E/flutter|Unhandled Exception" out/logs/logcat_*.txt | head -300 > out/logs/crashes.txt
grep -E "QA:|QAERR:|CB:|MSGS:|SEE:|T:" out/logs/drive.txt > out/logs/summary.txt
ls -la out/shots out/logs
