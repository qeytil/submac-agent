#!/usr/bin/env bash
# QA run on the emulator: real flows (integration_test/qa_test.dart) with a screencap on every SHOT, the whole run
# filmed, logcat kept, then a monkey (random taps) pass on the normal app for crashes and ANRs.
set -u
PKG=com.telesia.app
mkdir -p out/shots out/rec out/logs
TS=$(date +%s)
QA_EMAIL="${QA_EMAIL:-qa.emu.$TS@example.com}"
QA_PW="${QA_PW:-QaPass!$TS}"
echo "QA account: $QA_EMAIL" | tee out/logs/account.txt
adb logcat -c
( adb logcat -v time > out/logs/logcat.txt ) &
LOGC=$!
( for i in $(seq 1 400); do
    for perm in POST_NOTIFICATIONS RECORD_AUDIO READ_CONTACTS READ_CALENDAR WRITE_CALENDAR CAMERA ACCESS_FINE_LOCATION READ_SMS; do
      adb shell pm grant $PKG android.permission.$perm >/dev/null 2>&1
    done
    sleep 5
  done ) &
GRANT=$!
rm -f /tmp/stoprec
adb wait-for-device
sleep 20
( n=0; fails=0; while [ ! -f /tmp/stoprec ] && [ $fails -lt 5 ]; do n=$((n+1)); t0=$(date +%s)
    adb shell screenrecord --bit-rate 4000000 --time-limit 175 /data/local/tmp/rec_$(printf %02d $n).mp4
    if [ $(( $(date +%s) - t0 )) -lt 10 ]; then fails=$((fails+1)); sleep 5; else fails=0; fi
  done ) &
REC=$!
flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/qa_test.dart -d emulator-5554 \
  --dart-define=QA_EMAIL="$QA_EMAIL" --dart-define=QA_PW="$QA_PW" 2>&1 | tee out/logs/drive.txt | while IFS= read -r line; do
  case "$line" in
    *SHOT:*)
      n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/')
      adb exec-out screencap -p > "out/shots/$n.png"
      ;;
  esac
done
touch /tmp/stoprec
adb shell pkill -INT screenrecord || true
sleep 6
kill $GRANT 2>/dev/null || true
for f in $(adb shell ls /data/local/tmp/ | tr -d '\r' | grep '^rec_.*mp4$'); do adb pull /data/local/tmp/$f out/rec/ >/dev/null; adb shell rm /data/local/tmp/$f; done

echo "=== monkey: normal app, same data (signed in) ==="
if [ -f /tmp/app-debug-main.apk ]; then
  adb install -r /tmp/app-debug-main.apk > out/logs/install.txt 2>&1
  adb logcat -c
  adb shell monkey -p $PKG --pct-syskeys 0 --ignore-timeouts --ignore-crashes --monitor-native-crashes --throttle 400 -s 42 -v 2500 > out/logs/monkey.txt 2>&1
  adb exec-out screencap -p > out/shots/99_after_monkey.png
  adb logcat -d -v time > out/logs/logcat_monkey.txt
fi
kill $LOGC 2>/dev/null || true
grep -nE "FATAL EXCEPTION|ANR in|E/flutter|Unhandled Exception|CRASH" out/logs/logcat.txt out/logs/logcat_monkey.txt 2>/dev/null | head -200 > out/logs/crashes.txt
grep -E "QA:|QAERR:|REPLY:|SEE:" out/logs/drive.txt > out/logs/qa_steps.txt
ls -la out/shots out/rec out/logs
