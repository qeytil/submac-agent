#!/usr/bin/env bash
# Chat bug hunt 4, BOTS part, on the emulator (2026-10-25). Drives integration_test/chat_bughunt4_bots_test.dart, then the
# force-stop (CB-21) and process-kill cold starts. ADB:<cmd> lines from the harness: front, notif, alarms, doze_on, doze_off.
# Every wait here is bounded; the job also has a hard timeout.
set -u
PKG=com.submac.agent
ACT=$PKG/.MainActivity
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
adb shell date
adb logcat -c; ( adb logcat -v time > out/logs/logcat_debug.txt ) & LOGC=$!
notif() { echo "=== $(date -u +%T) $1" >> out/logs/notifications.txt
  adb shell dumpsys notification --noredact 2>/dev/null | grep -E "pkg=com.submac.agent|android.title=|android.text=|android.bigText=" | head -60 >> out/logs/notifications.txt; }
alarms() { echo "=== $(date -u +%T) $1" >> out/logs/alarms.txt
  adb shell dumpsys alarm 2>/dev/null | grep -B1 -A4 "com.submac.agent" | grep -E "RTC|when|origWhen|com.submac|tag=" | head -40 >> out/logs/alarms.txt; }
set -o pipefail
timeout 6600 flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/chat_bughunt4_bots_test.dart -d emulator-5554 \
  --dart-define=QA_EMAIL="$QA_EMAIL" --dart-define=QA_PW="$QA_PW" 2>&1 | tee out/logs/drive.txt | while IFS= read -r line; do
  case "$line" in
    *SHOT:*) n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/'); adb exec-out screencap -p > "out/shots/$n.png" ;;
    *ADB:front*) adb shell am start -n $ACT >/dev/null 2>&1; echo "$(date -u +%T) front" >> out/logs/net.txt ;;
    *ADB:notif*) notif "harness" ;;
    *ADB:alarms*) alarms "harness" ;;
    *ADB:doze_on*) echo "$(date -u +%T) doze on" >> out/logs/net.txt
                   adb shell dumpsys battery unplug; adb shell dumpsys deviceidle enable; adb shell dumpsys deviceidle force-idle >> out/logs/net.txt 2>&1 ;;
    *ADB:doze_off*) echo "$(date -u +%T) doze off" >> out/logs/net.txt
                   adb shell dumpsys deviceidle unforce; adb shell dumpsys battery reset ;;
  esac
done
DRIVE=$?
notif "after drive"; alarms "after drive"
adb shell dumpsys deviceidle unforce >/dev/null 2>&1; adb shell dumpsys battery reset >/dev/null 2>&1

# ---------------- CB-21: force-stop, let the routine's minute pass, start the app again (phase 2 in the test file)
DUE=$(grep -o "PHASE2_DUE:[0-9]*" out/logs/drive.txt | tail -1 | cut -d: -f2)
if [ -n "$DUE" ]; then
  echo "$(date -u +%T) force-stop (routine due $(date -u -d @$DUE +%T))" | tee -a out/logs/phases.txt
  adb shell am force-stop $PKG
  alarms "after force-stop"
  NOW=$(date +%s); SLEEP=$(( DUE + 100 - NOW )); [ $SLEEP -gt 0 ] && [ $SLEEP -lt 400 ] && sleep $SLEEP
  echo "$(date -u +%T) relaunch after the due minute" | tee -a out/logs/phases.txt
  adb shell am start -n $ACT
  for i in $(seq 1 50); do sleep 8; grep -q "PHASE3_DUE" out/logs/logcat_debug.txt && break; done
  sleep 120
  alarms "phase2 end"
  adb exec-out screencap -p > out/shots/p2_after_relaunch.png
  # ---------------- process kill with the alarm still set (phase 3: the alarm cold-starts the app)
  DUE3=$(grep -o "PHASE3_DUE:[0-9]*" out/logs/logcat_debug.txt | tail -1 | cut -d: -f2)
  if [ -n "$DUE3" ]; then
    adb shell input keyevent KEYCODE_HOME; sleep 5
    PID=$(adb shell pidof $PKG | tr -d '\r')
    adb root >/dev/null 2>&1; sleep 4
    adb shell kill -9 $PID 2>/dev/null || adb shell run-as $PKG kill -9 $PID 2>/dev/null || adb shell am kill $PKG
    sleep 2
    echo "$(date -u +%T) killed pid $PID (now $(adb shell pidof $PKG | tr -d '\r')), rk2 due $(date -u -d @$DUE3 +%T)" | tee -a out/logs/phases.txt
    alarms "after kill"
    NOW=$(date +%s); SLEEP=$(( DUE3 + 240 - NOW )); [ $SLEEP -gt 0 ] && [ $SLEEP -lt 500 ] && sleep $SLEEP
    echo "$(date -u +%T) pid after the alarm: $(adb shell pidof $PKG | tr -d '\r')" | tee -a out/logs/phases.txt
    notif "phase3 end"; alarms "phase3 end"
  fi
fi
kill $LOGC $GRANT 2>/dev/null || true
grep -E "P2:|P3:|flutter.*(Bots|bot)" out/logs/logcat_debug.txt | grep -E "P2:|P3:" > out/logs/phases_app.txt
grep -nE "FATAL EXCEPTION|ANR in|E/flutter|Unhandled Exception" out/logs/logcat_*.txt | head -300 > out/logs/crashes.txt
grep -E "QA:|QAERR:|CB:|MSGS:|T:|ADB:|PHASE" out/logs/drive.txt > out/logs/summary.txt
ls -la out/shots out/logs
NERR=$(grep -c "QAERR:" out/logs/drive.txt || true)
echo "drive exit=$DRIVE QAERR lines=$NERR"
grep "QAERR:" out/logs/drive.txt | head -40
exit 0
