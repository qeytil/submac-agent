#!/usr/bin/env bash
# Runs inside android-emulator-runner. Never let one failed capture stop the rest.
set -u
OUT=${OUT:-emu-out}; PKG=${PKG:-com.submac.agent}; mkdir -p "$OUT"
shot() { adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; echo "shot $1 ($(stat -c%s "$OUT/$1.png" 2>/dev/null) bytes)"; }
dumpui() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb pull /sdcard/ui.xml "$OUT/$1.xml" >/dev/null 2>&1; }
export -f shot dumpui 2>/dev/null || true

adb wait-for-device
adb shell getprop ro.product.cpu.abilist | tee "$OUT/device_abis.txt"
adb shell getprop ro.build.version.sdk >> "$OUT/device_abis.txt"
adb logcat -c || true
shot 00-home

echo "== install"; adb install -r -g "$APK" 2>&1 | tee "$OUT/install.txt"
adb shell dumpsys package "$PKG" | grep -E 'primaryCpuAbi|versionName|versionCode' | tee -a "$OUT/install.txt"

echo "== grant"
for p in POST_NOTIFICATIONS RECORD_AUDIO READ_CONTACTS READ_CALENDAR WRITE_CALENDAR READ_SMS READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
  adb shell pm grant "$PKG" android.permission.$p 2>&1 | sed "s/^/$p: /"
done
for op in MANAGE_EXTERNAL_STORAGE SYSTEM_ALERT_WINDOW SCHEDULE_EXACT_ALARM REQUEST_INSTALL_PACKAGES WRITE_SETTINGS; do
  adb shell appops set "$PKG" $op allow 2>&1 | sed "s/^/$op: /"
done
adb shell dumpsys deviceidle whitelist +"$PKG" >/dev/null 2>&1 || true

echo "== launch"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 2>&1 | tail -2
sleep 5; shot 01-launch; dumpui 01-launch
sleep 15; shot 02-after20s; dumpui 02-after20s
sleep 40; shot 03-after60s; dumpui 03-after60s
adb shell pidof "$PKG" > "$OUT/pid.txt" 2>&1 || echo "NOT RUNNING" > "$OUT/pid.txt"

if [ "${RUN_FLOW:-1}" = "1" ] && [ -f ci/emu_flow.sh ]; then
  echo "== flow"; OUT="$OUT" PKG="$PKG" bash ci/emu_flow.sh 2>&1 | tee "$OUT/flow.txt"
fi

adb shell dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' > "$OUT/activity.txt" 2>&1
adb logcat -d > "$OUT/logcat_full.txt" 2>&1
grep -iE 'submac|flutter|opencode|AndroidRuntime|FATAL|ANR in' "$OUT/logcat_full.txt" > "$OUT/logcat_filtered.txt"
adb logcat -d -b crash > "$OUT/logcat_crash.txt" 2>&1
echo "== done"; ls -l "$OUT"
exit 0
