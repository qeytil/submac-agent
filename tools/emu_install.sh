#!/usr/bin/env bash
# Install + launch APKs on the running emulator. Usage: tools/emu_install.sh label apk...
set -u
PKG=com.telesia.app
echo "page size: $(adb shell getconf PAGE_SIZE)  sdk: $(adb shell getprop ro.build.version.sdk)  abi: $(adb shell getprop ro.product.cpu.abilist)"
RC=0
for APK in "$@"; do
  echo "================ install $APK"
  adb uninstall $PKG >/dev/null 2>&1
  adb logcat -c
  OUT=$(adb install -r "$APK" 2>&1); echo "$OUT"
  adb logcat -d | grep -iE "PackageManager|PackageInstaller|INSTALL_|NativeLibraryHelper|apk.*invalid|ParsingPackage" | tail -40
  if echo "$OUT" | grep -q Success; then
    adb logcat -c
    adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 20
    PID=$(adb shell pidof $PKG | tr -d '\r')
    if [ -n "$PID" ]; then echo "LAUNCH OK pid=$PID"; else echo "!! LAUNCH: process not running"; RC=1; fi
    adb logcat -d | grep -E "FATAL EXCEPTION|AndroidRuntime|UnsatisfiedLink|dlopen|page size|16 KB|16KB|compat" | head -40
    adb shell dumpsys activity activities | grep -E "mResumedActivity|topResumedActivity" | head -3
    adb exec-out screencap -p > "/tmp/shot_$(basename $(dirname $APK)).png" || true
  else
    RC=1
  fi
done
exit $RC
