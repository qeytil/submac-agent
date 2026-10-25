#!/usr/bin/env bash
# Inspect one APK: manifest, badging, signature, zip alignment, native libs, ELF page alignment.
# Usage: tools/verify_apk.sh path/to/app.apk   (exit 1 if a hard check fails)
set -u
APK="$1"
BT=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)
FAIL=0
echo "================ $APK  (build-tools $(basename $BT))"
ls -l "$APK"; sha256sum "$APK"
echo "---- badging"
"$BT/aapt2" dump badging "$APK" | grep -E "^(package|sdkVersion|minSdkVersion|targetSdkVersion|native-code|alt-native-code|application:|launchable-activity|application-debuggable|testOnly|uses-library)" 
echo "---- manifest (key attrs)"
"$BT/aapt2" dump xmltree --file AndroidManifest.xml "$APK" > /tmp/manifest.txt
grep -nE "E: (manifest|uses-sdk|application|activity|activity-alias|service|receiver|provider)|testOnly|debuggable|extractNativeLibs|exported|sharedUserId|installLocation|android:name\(0x01010003\)=\"[^\"]*MainActivity|package=|platformBuild" /tmp/manifest.txt | sed 's/^/  /' | head -150
if grep -q 'testOnly(0x0101054b)=(type 0x12)0xffffffff' /tmp/manifest.txt; then echo "!! testOnly=true"; FAIL=1; fi
echo "---- signature"
"$BT/apksigner" verify --verbose --print-certs "$APK" > /tmp/sig.txt 2>&1 || FAIL=1
grep -v '^WARNING' /tmp/sig.txt
grep -q "Verified using v2 scheme (APK Signature Scheme v2): true" /tmp/sig.txt || { echo "!! no v2 signature"; FAIL=1; }
# The signing key must never change: Android refuses an update signed by a different key, and phones
# (HyperOS/MIUI and others) report that as "App not installed as package appears to be invalid".
# 1.3.0 (build-12) and 1.4.0 (build-15) were signed by throwaway CI debug keys; from 1.4.1 on only this key.
EXPECT_CERT="${EXPECT_CERT:-4d6d116e553c85aa25cd459a02026fcacfd1d2762ca27c0cbd3f9c25b3150354}"
GOT_CERT=$(grep -m1 -E "certificate SHA-256 digest:" /tmp/sig.txt | awk '{print $NF}')
if [ "$GOT_CERT" = "$EXPECT_CERT" ]; then echo "signing cert: pinned key OK"; else echo "!! signing cert $GOT_CERT != pinned $EXPECT_CERT (updates over existing installs would fail)"; FAIL=5; fi
echo "---- zip structure (names, duplicates, headers, arsc stored+aligned)"
python3 "$(dirname "$0")/zip_audit.py" "$APK" || FAIL=6
echo "---- zipalign -c -P 16 4"
if "$BT/zipalign" -c -P 16 -v 4 "$APK" > /tmp/za.txt 2>&1; then echo "zipalign 16KB: OK"; else echo "!! zipalign 16KB: FAILED"; grep -E "BAD|lib/" /tmp/za.txt | head -60; FAIL=2; fi
grep -E "Verification" /tmp/za.txt
echo "---- native libs (Stored = uncompressed)"
unzip -lv "$APK" | grep -E " lib/" | awk '{print $2, $1, $8}'
rm -rf /tmp/x && mkdir -p /tmp/x && unzip -q -o "$APK" 'lib/*' -d /tmp/x 2>/dev/null
echo "---- ELF LOAD alignment (need >= 0x4000 for 16 KB pages)"
for f in /tmp/x/lib/*/*.so; do
  [ -f "$f" ] || continue
  al=$(readelf -lW "$f" 2>/dev/null | awk '$1=="LOAD"{print $NF}' | sort -u | tr '\n' ' ')
  ok=OK; for a in $al; do [ $((a)) -lt 16384 ] && ok=4KB-ALIGNED; done
  case "$f" in */arm64-v8a/*|*/x86_64/*) [ "$ok" != OK ] && FAIL=3;; esac
  echo "  ${f#/tmp/x/} : $al $ok"
done
grep -q " lib/arm64-v8a/libflutter.so" <(unzip -l "$APK") || { echo "!! no arm64-v8a libflutter.so"; FAIL=4; }
echo "RESULT $APK fail=$FAIL"
if [ "${STRICT:-0}" = 1 ]; then exit $FAIL; fi
exit 0
