#!/usr/bin/env bash
# Marketing capture on the emulator: clean status bar, film the whole run, a screencap on every SHOT.
set -u
PKG=com.submac.agent
mkdir -p out/shots out/rec
adb shell settings put global sysui_demo_allowed 1
adb shell am broadcast -a com.android.systemui.demo -e command enter >/dev/null
adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0941 >/dev/null
adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false >/dev/null
adb shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 >/dev/null
adb shell am broadcast -a com.android.systemui.demo -e command network -e mobile show -e datatype none -e level 4 >/dev/null
adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false >/dev/null
adb shell settings put global window_animation_scale 1
adb shell settings put global transition_animation_scale 1
adb shell settings put global animator_duration_scale 1
# Say yes to the app's permission prompts as soon as it is installed.
( for i in $(seq 1 200); do
    for perm in POST_NOTIFICATIONS RECORD_AUDIO READ_CONTACTS READ_CALENDAR WRITE_CALENDAR CAMERA ACCESS_FINE_LOCATION READ_SMS; do
      adb shell pm grant $PKG android.permission.$perm >/dev/null 2>&1
    done
    sleep 3
  done ) &
GRANT=$!
rm -f /tmp/stoprec
( n=0; while [ ! -f /tmp/stoprec ]; do n=$((n+1)); adb shell screenrecord --bit-rate 20000000 --time-limit 175 /sdcard/rec_$(printf %02d $n).mp4; done ) &
REC=$!
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/reel_test.dart -d emulator-5554 \
  --dart-define=DEMO_EMAIL="$DEMO_EMAIL" --dart-define=DEMO_PW="$DEMO_PW" 2>&1 | while IFS= read -r line; do
  echo "$line"
  case "$line" in
    *SHOT:*)
      n=$(echo "$line" | sed 's/.*SHOT:\([A-Za-z0-9_-]*\).*/\1/')
      adb exec-out screencap -p > "out/shots/$n.png"
      echo "   captured $n ($(stat -c %s out/shots/$n.png) bytes)"
      ;;
  esac
done
touch /tmp/stoprec
adb shell pkill -INT screenrecord || true
sleep 6
kill $GRANT 2>/dev/null || true
wait $REC 2>/dev/null || true
for f in $(adb shell ls /sdcard/ | tr -d '\r' | grep '^rec_.*mp4$'); do adb pull /sdcard/$f out/rec/ >/dev/null && echo "pulled $f"; done
ls -la out/shots out/rec
