#!/usr/bin/env bash
# Chat bug hunt 4, TEAMS part, on the emulator (2026-10-25): the debug app driven by
# integration_test/chat_bughunt4_teams_test.dart. Screens and logs go to out/. ADB:<cmd> lines from the harness cut or
# restore the network, send the app to the background and bring it back, or dump notifications.
# The drive has a hard timeout; the job fails when the drive fails or the harness printed any QAERR line.
set -u
PKG=com.submac.agent
mkdir -p out/shots out/logs
echo "account: $QA_EMAIL" > out/logs/account.txt
( for i in $(seq 1 1500); do
    for perm in POST_NOTIFICATIONS RECORD_AUDIO READ_CONTACTS READ_CALENDAR CAMERA ACCESS_FINE_LOCATION; do
      adb shell pm grant $PKG android.permission.$perm >/dev/null 2>&1
    done
    sleep 5
  done ) &
GRANT=$!
adb wait-for-device; sleep 15
adb logcat -c; ( adb logcat -v time > out/logs/logcat_debug.txt ) & LOGC=$!
notif() { echo "=== $(date -u +%T) $1" >> out/logs/notifications.txt
  adb shell dumpsys notification --noredact 2>/dev/null | grep -E "pkg=com.submac.agent|android.title=|android.text=" | head -60 >> out/logs/notifications.txt; }
front() { adb shell am start -n $PKG/.MainActivity >/dev/null 2>&1 || adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; }
set -o pipefail
timeout 100m flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/chat_bughunt4_teams_test.dart -d emulator-5554 \
  --dart-define=QA_EMAIL="$QA_EMAIL" --dart-define=QA_PW="$QA_PW" 2>&1 | tee out/logs/drive.txt | while IFS= read -r line; do
  case "$line" in
    *SHOT:*) n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/'); adb exec-out screencap -p > "out/shots/$n.png" ;;
    *ADB:net_off*) echo "$(date -u +%T) net off" >> out/logs/net.txt
                   adb shell cmd connectivity airplane-mode enable; adb shell svc wifi disable; adb shell svc data disable ;;
    *ADB:net_on*)  echo "$(date -u +%T) net on" >> out/logs/net.txt
                   adb shell cmd connectivity airplane-mode disable; adb shell svc wifi enable; adb shell svc data enable ;;
    *ADB:bg_60*)   echo "$(date -u +%T) home" >> out/logs/net.txt
                   ( adb shell input keyevent KEYCODE_HOME; sleep 30; notif "background +30s"; adb exec-out screencap -p > out/shots/c5_home_30s.png
                     sleep 30; notif "background +60s"; adb exec-out screencap -p > out/shots/c5_home_60s.png
                     front; echo "$(date -u +%T) front" >> out/logs/net.txt ) & ;;
    *ADB:notif_dump*) notif "harness dump" ;;
  esac
done
DRIVE=$?
# Never leave the app in the background: if a background step is still pending, bring it back.
front
notif "end"
kill $LOGC $GRANT 2>/dev/null || true
grep -nE "FATAL EXCEPTION|ANR in|E/flutter|Unhandled Exception" out/logs/logcat_*.txt | head -300 > out/logs/crashes.txt
grep -E "QA:|QAERR:|CB:|T:|POSTS:|ANSWER:|PART:|LLM:|TOOL:|SEE:|ADB:" out/logs/drive.txt > out/logs/summary.txt
ls -la out/shots out/logs
NERR=$(grep -c "QAERR:" out/logs/drive.txt || true)
echo "drive exit=$DRIVE QAERR lines=$NERR"
grep "QAERR:" out/logs/drive.txt | head -40
if [ "$DRIVE" != "0" ] || [ "$NERR" != "0" ]; then echo "::error::chat bughunt 4 teams harness errors (drive=$DRIVE, QAERR=$NERR)"; exit 1; fi
