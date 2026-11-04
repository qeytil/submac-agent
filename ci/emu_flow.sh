#!/usr/bin/env bash
# Scripted UI flow, run after the launch screenshots. Extend with steps below.
# Screen is 1080x2400 on the default API 34 AVD (check device_abis/ui xml for bounds).
# Helpers: tap X Y | text "str" | key KEYCODE | shot NAME | ui NAME | tap_text "Label" (taps a node by its text via uiautomator)
set -u
OUT=${OUT:-emu-out}; PKG=${PKG:-com.submac.agent}
tap()  { adb shell input tap "$1" "$2"; sleep "${3:-2}"; }
text() { adb shell input text "$(printf '%s' "$1" | sed 's/ /%s/g')"; sleep 1; }
key()  { adb shell input keyevent "$1"; sleep 1; }
shot() { adb exec-out screencap -p > "$OUT/flow-$1.png"; echo "flow shot $1"; }
ui()   { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb pull /sdcard/ui.xml "$OUT/flow-$1.xml" >/dev/null 2>&1; }
tap_text() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1
  b=$(python3 - "$1" <<'PY'
import re,sys
s=open('/tmp/ui.xml',encoding='utf-8',errors='ignore').read(); t=sys.argv[1]
for m in re.finditer(r'<node [^>]*>',s):
    n=m.group(0)
    if re.search(r'(text|content-desc)="[^"]*%s'%re.escape(t),n):
        x1,y1,x2,y2=map(int,re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',n).groups()); print((x1+x2)//2,(y1+y2)//2); break
PY
)
  if [ -n "$b" ]; then echo "tap_text '$1' at $b"; tap $b; else echo "tap_text '$1': not found"; fi
}

# --- steps (safe defaults: dismiss any system dialog, then capture) ---
tap_text "Allow"
tap_text "OK"
shot 01-after-dialogs; ui 01-after-dialogs
# Example: tap_text "Sign in"; shot 02-signin
