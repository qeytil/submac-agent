#!/usr/bin/env bash
# Reproduce leftover-install scenarios: OLD then NEW apk (different signing keys / versions).
# Usage: tools/emu_conflicts.sh old.apk new.apk
set -u
PKG=com.submac.agent; OLD=$1; NEW=$2
st(){ echo "---- $1"; }
clean(){ adb shell pm uninstall $PKG >/dev/null 2>&1; adb shell pm uninstall --user 10 $PKG >/dev/null 2>&1; true; }
pushapk(){ adb push "$1" /data/local/tmp/$2.apk >/dev/null; }
pushapk "$OLD" old; pushapk "$NEW" new
st "A: OLD installed, then NEW over it (no uninstall)"; clean
adb shell pm install -r /data/local/tmp/old.apk; adb shell pm install -r /data/local/tmp/new.apk
st "B: NEW installed, then OLD over it (downgrade)"; clean
adb shell pm install -r /data/local/tmp/new.apk; adb shell pm install -r /data/local/tmp/old.apk
st "C: OLD uninstalled with keep-data (-k), then NEW"; clean
adb shell pm install -r /data/local/tmp/old.apk; adb shell pm uninstall -k $PKG; adb shell pm install -r /data/local/tmp/new.apk
st "D: OLD left in a second user/profile, removed from main user, then NEW"; clean
U=$(adb shell pm create-user leftover | grep -o '[0-9]*$' | tr -d '\r'); echo "user=$U"
adb shell pm install -r /data/local/tmp/old.apk >/dev/null; adb shell pm uninstall --user 0 $PKG
adb shell pm list packages --user $U | grep $PKG || echo "(not in user $U)"
adb shell pm install -r --user 0 /data/local/tmp/new.apk
adb shell pm uninstall $PKG >/dev/null 2>&1; adb shell pm remove-user $U >/dev/null 2>&1
st "E: truncated download of NEW (first 60%)"; clean
SZ=$(stat -c %s "$NEW"); head -c $((SZ*6/10)) "$NEW" > /tmp/trunc.apk; adb push /tmp/trunc.apk /data/local/tmp/t.apk >/dev/null
adb shell pm install -r /data/local/tmp/t.apk
st "F: clean install of NEW"; clean
adb shell pm install -r /data/local/tmp/new.apk
exit 0
