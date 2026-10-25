#!/usr/bin/env bash
# Chat bug hunt on the emulator (2026-10-25). Phase 1: the RELEASE build-62 APK driven over adb (tools/chatbug_adb.py).
# Phase 2: the debug app driven by integration_test/chat_bughunt_test.dart. Screens, recordings and logcat go to out/.
set -u
PKG=com.submac.agent
mkdir -p out/shots out/rec out/logs
echo "account: $QA_EMAIL" > out/logs/account.txt
( for i in $(seq 1 600); do
    for perm in POST_NOTIFICATIONS RECORD_AUDIO READ_CONTACTS READ_CALENDAR CAMERA ACCESS_FINE_LOCATION READ_SMS SEND_SMS; do
      adb shell pm grant $PKG android.permission.$perm >/dev/null 2>&1
    done
    sleep 5
  done ) &
GRANT=$!
record() { # $1 = prefix
  rm -f /tmp/stoprec
  ( n=0; fails=0; while [ ! -f /tmp/stoprec ] && [ $fails -lt 5 ]; do n=$((n+1)); t0=$(date +%s)
      adb shell screenrecord --bit-rate 3000000 --time-limit 175 /data/local/tmp/${1}_$(printf %02d $n).mp4
      if [ $(( $(date +%s) - t0 )) -lt 10 ]; then fails=$((fails+1)); sleep 5; else fails=0; fi
    done ) &
}
stoprec() {
  touch /tmp/stoprec; adb shell pkill -INT screenrecord || true; sleep 6
  for f in $(adb shell ls /data/local/tmp/ | tr -d '\r' | grep '\.mp4$'); do adb pull /data/local/tmp/$f out/rec/ >/dev/null; adb shell rm /data/local/tmp/$f; done
}
adb wait-for-device; sleep 15

echo "=== phase 1: release build-62 over adb ==="
APK=$(ls /tmp/rel/*.apk | head -1)
adb install -r "$APK" > out/logs/install_release.txt 2>&1
adb logcat -c; ( adb logcat -v time > out/logs/logcat_release.txt ) & LOGC=$!
record rel
timeout 1800 python3 tools/chatbug_adb.py "$QA_EMAIL" "$QA_PW" 2>&1 | tee out/logs/adb_release.txt
stoprec; kill $LOGC 2>/dev/null || true
adb uninstall $PKG >/dev/null 2>&1 || true

echo "=== phase 2: debug app, integration_test ==="
adb logcat -c; ( adb logcat -v time > out/logs/logcat_debug.txt ) & LOGC=$!
record dbg
flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/chat_bughunt_test.dart -d emulator-5554 \
  --dart-define=QA_EMAIL="$QA_EMAIL" --dart-define=QA_PW="$QA_PW" 2>&1 | tee out/logs/drive.txt | while IFS= read -r line; do
  case "$line" in
    *SHOT:*) n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/'); adb exec-out screencap -p > "out/shots/dbg_$n.png" ;;
  esac
done
stoprec; kill $LOGC $GRANT 2>/dev/null || true
grep -nE "FATAL EXCEPTION|ANR in|E/flutter|Unhandled Exception" out/logs/logcat_*.txt | head -300 > out/logs/crashes.txt
grep -E "QA:|QAERR:|CB:|MSGS:|SEE:" out/logs/drive.txt > out/logs/summary_debug.txt
grep -E "ADB:" out/logs/adb_release.txt > out/logs/summary_release.txt
ls -la out/shots out/rec out/logs
