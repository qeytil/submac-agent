#!/usr/bin/env python3
"""Telesia rename follow-up fixes (2026-11-10). Run from the repo root.

1. TelesiaGateway.bare() still stripped 7 characters -- the length of the old
   "submac_" prefix -- while the prefix itself became "telesia_" (8). Every
   prefixed MCP name lost only "telesia", so "telesia_run_tool" routed as
   "_run_tool" and missed. That is the cause of the 10 gateway/routing failures.
2. The intro wordmark is now 7 letters ("Telesia"), the test still bounded it at 6.
3. CI still generates the Android project with --org com.submac, so gradle
   stamps applicationId/namespace com.submac.agent instead of com.telesia.app,
   and apk.yml still points at the renamed resource / release names.
4. patch_android.py copies the Kotlin package into com/telesia/agent while the
   files declare package com.telesia.app.
"""
import sys

fails = []


def edit(path, old, new, count):
    try:
        s = open(path).read()
    except FileNotFoundError:
        fails.append("%s: file not found" % path)
        return
    n = s.count(old)
    if n != count:
        fails.append("%s: found %d copies of %r, want %d" % (path, n, old[:80], count))
        return
    open(path, "w").write(s.replace(old, new))
    print("ok  %-40s %r" % (path, old[:60]))


# 1. the prefix length bug
edit(
    "lib/services/telesia_gateway.dart",
    "static String bare(String name) => name.startsWith('telesia_') ? name.substring(7) : name;",
    "static String bare(String name) => name.startsWith('telesia_') ? name.substring('telesia_'.length) : name;",
    1,
)

# 2. intro letter counts (Telesia is 7 letters)
edit(
    "test/intro_auth_flow_test.dart",
    "// The draw is done: one tick per letter of \"Telesia\", at most six.",
    "// The draw is done: one tick per letter of \"Telesia\", at most seven.",
    1,
)
edit(
    "test/intro_auth_flow_test.dart",
    "expect(IntroMotion.word.length, lessThanOrEqualTo(6));",
    "expect(IntroMotion.word.length, lessThanOrEqualTo(7));",
    1,
)
edit(
    "test/intro_auth_flow_test.dart",
    "expect(find.byType(IntroScreen), findsNothing);\n      expect(count('selectionClick'), 6);",
    "expect(find.byType(IntroScreen), findsNothing);\n      expect(count('selectionClick'), 7);",
    1,
)

# 3. CI: generate the Android project as com.telesia.*
for f, submac_step in (
    (".github/workflows/analyze-test.yml", "Make it SubMac"),
    (".github/workflows/oc-testrep.yml", None),
    (".github/workflows/apk.yml", "Make it SubMac"),
):
    edit(f, "flutter create --org com.submac", "flutter create --org com.telesia", 1)
    if submac_step:
        edit(f, submac_step, "Make it Telesia", 1)

# 3b. apk.yml: resources, artifact and release naming (the 1.3/1.4 warning keeps
# the old name on purpose -- those builds really were called SubMac Agent).
edit(".github/workflows/apk.yml", "submac_chime", "telesia_chime", 2)
edit(".github/workflows/apk.yml", 'OUT="submac-${VER}', 'OUT="telesia-${VER}', 1)
edit(".github/workflows/apk.yml", "SubMac Agent ${{", "Telesia ${{", 2)
edit(".github/workflows/apk.yml", "### SubMac ${{ inputs.variant }} APK", "### Telesia ${{ inputs.variant }} APK", 1)
edit(".github/workflows/apk.yml", "pinned SubMac key", "pinned Telesia key", 2)
edit(".github/workflows/apk.yml", "# The SubMac launcher icon", "# The Telesia launcher icon", 1)
edit(".github/workflows/apk.yml", "App icon (the SubMac logo", "App icon (the Telesia logo", 1)
edit(
    ".github/workflows/apk.yml",
    "**If SubMac Agent 1.3.0 or 1.4.0 is on your phone",
    "**If SubMac Agent (now Telesia) 1.3.0 or 1.4.0 is on your phone",
    1,
)

# 4. patch_android.py: Kotlin package dir matches the declared package, and the
#    applicationId/namespace flutter create stamped in become com.telesia.app.
edit(
    "tools/patch_android.py",
    'kdir = "android/app/src/main/kotlin/com/telesia/agent"',
    'kdir = "android/app/src/main/kotlin/com/telesia/app"',
    1,
)

header = '''APP_ID = "com.telesia.app"
g = open(G).read()
for wrong in ("com.submac.agent", "com.telesia.agent"):
    g = g.replace('"%s"' % wrong, '"%s"' % APP_ID)
assert '"com.telesia.app"' in g, "gradle identity not found (namespace/applicationId)"
'''
s = open("tools/patch_android.py").read()
if "APP_ID" in s:
    print("ok  tools/patch_android.py               identity rewrite already present")
elif "g = open(G).read()" in s:
    s = s.replace("g = open(G).read()", header, 1)
    open("tools/patch_android.py", "w").write(s)
    print("ok  tools/patch_android.py               identity rewrite added")
else:
    fails.append("tools/patch_android.py: could not find 'g = open(G).read()'")

if fails:
    print("\nFAILED:")
    for f in fails:
        print(" - " + f)
    sys.exit(1)
print("\nall patches applied")