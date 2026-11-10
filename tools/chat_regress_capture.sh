#!/usr/bin/env bash
# Chat regression harness on the emulator (PR-H). Drives integration_test/chat_regress_test.dart (phases A, B, C), then
# the cold-start phases: P2 force-stop + relaunch (CB-21) and P3 process kill while a routine is due (CB-46).
# ADB:<cmd> lines from the harness: front, notif, alarms, net_off, net_on, bg_60, doze_on, doze_off.
# Every wait here is bounded. This script always exits 0; it writes out/logs/verdict.env and the workflow's Verdict
# step fails the job on: drive exit != 0, any QAERR line, any STEPFAIL, a logcat FATAL EXCEPTION in Telesia, an
# uncaught Flutter exception in logcat, or a missing "QA: done".
set -u
PKG=com.telesia.app
ACT=$PKG/.MainActivity
DRIVE_MIN=${DRIVE_MIN:-110}
mkdir -p out/shots out/logs
echo "account: $QA_EMAIL" > out/logs/account.txt
( for i in $(seq 1 2000); do
    for perm in POST_NOTIFICATIONS RECORD_AUDIO READ_CONTACTS READ_CALENDAR CAMERA ACCESS_FINE_LOCATION; do
      adb shell pm grant $PKG android.permission.$perm >/dev/null 2>&1
    done
    adb shell appops set $PKG SCHEDULE_EXACT_ALARM allow >/dev/null 2>&1
    sleep 5
  done ) &
GRANT=$!
adb wait-for-device; sleep 15
adb shell date
adb logcat -c; ( adb logcat -v time > out/logs/logcat.txt ) & LOGC=$!
note() { echo "$(date -u +%T) $*" | tee -a out/logs/phases.txt; }
front() { adb shell am start -n $ACT >/dev/null 2>&1 || adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; }
notif() { echo "=== $(date -u +%T) $1" >> out/logs/notifications.txt
  adb shell dumpsys notification --noredact 2>/dev/null | grep -E "pkg=com.telesia.app|android.title=|android.text=|android.bigText=" | head -60 >> out/logs/notifications.txt; }
alarms() { echo "=== $(date -u +%T) $1" >> out/logs/alarms.txt
  adb shell dumpsys alarm 2>/dev/null | grep -B1 -A4 "com.telesia.app" | grep -E "RTC|when|origWhen|com.telesia|tag=" | head -40 >> out/logs/alarms.txt; }
net() { if [ "$1" = off ]; then adb shell cmd connectivity airplane-mode enable; adb shell svc wifi disable; adb shell svc data disable
        else adb shell cmd connectivity airplane-mode disable; adb shell svc wifi enable; adb shell svc data enable; fi; note "net $1"; }

set -o pipefail
# --keep-app-running: without it flutter drive UNINSTALLS the app at the end (drive_service.dart), which wiped the
# P2/P3 marker and the app in run 40207082061.
timeout ${DRIVE_MIN}m flutter drive --no-pub --keep-app-running --driver=test_driver/integration_test.dart --target=integration_test/chat_regress_test.dart -d emulator-5554 \
  --dart-define=QA_EMAIL="$QA_EMAIL" --dart-define=QA_PW="$QA_PW" --dart-define=QA_PHASES="${QA_PHASES:-ABC}" 2>&1 | tee out/logs/drive.txt | while IFS= read -r line; do
  # Progress and results also go to the job log (screens and full dumps stay in out/logs/drive.txt).
  case "$line" in *QA:*|*QAWARN*|*QAERR*|*PHASE*|*CB-[0-9]*" PASS|"*|*CB-[0-9]*" FAIL|"*|*CB-[0-9]*" SKIP|"*) echo "$line" | cut -c1-300 ;; esac
  case "$line" in
    *SHOT:*) n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/'); timeout 20 adb exec-out screencap -p > "out/shots/$n.png" ;;
    *ADB:front*) front; note "front" ;;
    *ADB:notif*) notif "harness" ;;
    *ADB:alarms*) alarms "harness" ;;
    *ADB:net_off*) net off ;;
    *ADB:net_on*) net on ;;
    *ADB:bg_60*) note "home (60 s in background)"
                 ( adb shell input keyevent KEYCODE_HOME; sleep 30; notif "background +30s"; timeout 20 adb exec-out screencap -p > out/shots/bg_30s.png
                   sleep 30; notif "background +60s"; front; note "front after background" ) & ;;
    *ADB:doze_on*) note "doze on"; adb shell dumpsys battery unplug; adb shell dumpsys deviceidle enable; adb shell dumpsys deviceidle force-idle >> out/logs/phases.txt 2>&1 ;;
    *ADB:doze_off*) note "doze off"; adb shell dumpsys deviceidle unforce; adb shell dumpsys battery reset ;;
  esac
done
DRIVE=$?
note "drive exit=$DRIVE"
# Never leave the device in a test state.
net on >/dev/null 2>&1; adb shell dumpsys deviceidle unforce >/dev/null 2>&1; adb shell dumpsys battery reset >/dev/null 2>&1
notif "after drive"; alarms "after drive"

# ---------------- P2 (CB-21): force-stop, let the routine's minute pass, start the app again
DUE=$(grep -o "PHASE2_DUE:[0-9]*" out/logs/drive.txt | tail -1 | cut -d: -f2)
if [ -n "$DUE" ]; then
  note "P2 force-stop (routine due $(date -u -d @$DUE +%T))"
  adb shell am force-stop $PKG
  alarms "after force-stop"
  NOW=$(date +%s); SLEEP=$(( DUE + 100 - NOW )); [ $SLEEP -gt 0 ] && [ $SLEEP -lt 400 ] && sleep $SLEEP
  note "P2 relaunch after the due minute"; front
  for i in $(seq 1 50); do sleep 8; grep -q "PHASE3_DUE" out/logs/logcat.txt && break; done
  timeout 20 adb exec-out screencap -p > out/shots/p2_after_relaunch.png
  # ---------------- P3 (CB-46): kill the process with a routine still due; it should run when the alarm fires
  DUE3=$(grep -o "PHASE3_DUE:[0-9]*" out/logs/logcat.txt | tail -1 | cut -d: -f2)
  if [ -n "$DUE3" ]; then
    sleep 20
    adb shell input keyevent KEYCODE_HOME; sleep 5
    PID=$(adb shell pidof $PKG | tr -d '\r')
    adb root >/dev/null 2>&1; sleep 4
    # adb root restarts adbd, which ends the logcat capture: in run 40222543795 every P3 line (CB-46) was lost.
    # Start it again, appending, from the newest line on.
    adb wait-for-device; kill $LOGC 2>/dev/null || true
    ( adb logcat -v time -T 1 >> out/logs/logcat.txt ) & LOGC=$!
    note "P3 logcat capture restarted after adb root"
    adb shell kill -9 $PID 2>/dev/null || adb shell am kill $PKG
    sleep 2
    note "P3 killed pid $PID (now '$(adb shell pidof $PKG | tr -d '\r')'), rk2 due $(date -u -d @$DUE3 +%T)"
    alarms "after kill"
    NOW=$(date +%s); SLEEP=$(( DUE3 + 150 - NOW )); [ $SLEEP -gt 0 ] && [ $SLEEP -lt 500 ] && sleep $SLEEP
    note "P3 pid after the alarm: '$(adb shell pidof $PKG | tr -d '\r')'; opening Telesia to read the result"
    front
    for i in $(seq 1 25); do sleep 8; grep -qE "CB-46 (PASS|FAIL|SKIP)|P3: end of observation" out/logs/logcat.txt && break; done
    notif "P3 end"; alarms "P3 end"
  else
    note "P2 never armed P3 (no PHASE3_DUE in logcat)"
  fi
fi
sleep 3
kill $LOGC $GRANT 2>/dev/null || true

# ---------------- results
grep -E "P2:|P3:" out/logs/logcat.txt > out/logs/phases_app.txt || true
# CB lines: phases A/B/C from the drive output; P2/P3 (CB-21, CB-46) from logcat, where the cold-started app prints.
{ grep -oE "CB-[0-9]+[ab]? (PASS|FAIL|SKIP)\|.*" out/logs/drive.txt; grep -oE "CB-(21|46) (PASS|FAIL|SKIP)\|P[23] .*" out/logs/logcat.txt | awk '!seen[$0]++'; } > out/logs/cb.txt || true
grep -oE "CB-(21|46) (PASS|FAIL|SKIP)" out/logs/cb.txt | awk '{n[$2]++} END {printf "PHASE P: CB pass=%d fail=%d skip=%d\n", n["PASS"], n["FAIL"], n["SKIP"]}' >> out/logs/drive.txt
grep -E "QA:|QAWARN|QAERR:|CB-[0-9]|PHASE|T:|ADB:" out/logs/drive.txt > out/logs/summary.txt || true
# A FATAL EXCEPTION counts only when it is Telesia's process.
grep -A2 "FATAL EXCEPTION" out/logs/logcat.txt | grep -c "Process: $PKG" > out/logs/n_fatal.txt || true
grep -nE "FATAL EXCEPTION|ANR in|E/flutter|Unhandled Exception" out/logs/logcat.txt | head -300 > out/logs/crashes.txt || true
NERR=$(grep -c "QAERR:" out/logs/drive.txt || true)
NSTEP=$(grep -c "QA: STEPFAIL" out/logs/drive.txt || true)
NFATAL=$(cat out/logs/n_fatal.txt 2>/dev/null || echo 0)
NUNC=$(grep -cE "E/flutter.*Unhandled Exception" out/logs/logcat.txt || true)
DONE=$(grep -c "QA: done" out/logs/drive.txt || true)
NPASS=$(grep -c " PASS|" out/logs/cb.txt || true); NFAIL=$(grep -c " FAIL|" out/logs/cb.txt || true); NSKIP=$(grep -c " SKIP|" out/logs/cb.txt || true)
BAD=0
{ [ "$DRIVE" != "0" ] || [ "$NERR" != "0" ] || [ "$NSTEP" != "0" ] || [ "$NFATAL" != "0" ] || [ "$NUNC" != "0" ] || [ "$DONE" = "0" ]; } && BAD=1
[ "${FAIL_ON_CB:-0}" = "1" ] && [ "$NFAIL" != "0" ] && BAD=1
cat > out/logs/verdict.env <<EOF
DRIVE=$DRIVE
QAERR=$NERR
STEPFAIL=$NSTEP
FATAL=$NFATAL
UNCAUGHT=$NUNC
HARNESS_DONE=$DONE
CB_PASS=$NPASS
CB_FAIL=$NFAIL
CB_SKIP=$NSKIP
BAD=$BAD
EOF
cat out/logs/verdict.env
echo "---- per phase"; grep -E "PHASE [ABCKP]:" out/logs/drive.txt | sed 's/.*\(PHASE [ABCKP]:\)/\1/'
echo "---- CB lines"; sed 's/|.*//' out/logs/cb.txt | sort -V | uniq -c
echo "---- QAERR"; grep "QAERR:" out/logs/drive.txt | head -40
ls -la out/shots out/logs | tail -40
exit 0
