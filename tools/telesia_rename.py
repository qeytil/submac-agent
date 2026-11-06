#!/usr/bin/env python3
"""Telesia rename, layer R1: user-visible brand words only.

Replaces the word SubMac (whole word, case-sensitive) with Telesia in code lines (not comment-only lines) of
lib/, test/, android_native/*.kt, android_native/res/values/*.xml and tools/patch_android.py.

Kept on purpose (need the owner / a device first):
  - identifiers (SubMacGateway, SubMacApp...): whole-word match never touches them
  - lowercase ids: submac model alias, submac_ tool prefix, submac:// scheme, com.submac.agent, submac.site
  - the wake word: "Hello SubMac" and the Vosk phrases (WakeService.kt) until a new phrase is tested on clips
  - User-Agent strings (SubMacAgent/1.6)
"""
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
WORD = re.compile(r'(?<![A-Za-z0-9_])(?<!Hello )(?<!“Hello )SubMac(?![A-Za-z0-9_])')
files = []
for pat in ['lib/**/*.dart', 'test/**/*.dart', 'android_native/*.kt', 'android_native/res/values/*.xml', 'tools/patch_android.py']:
    files += list(root.glob(pat))
skip_files = {'WakeService.kt'}
changed = 0
for f in files:
    if f.name in skip_files:
        continue
    src = f.read_text(encoding='utf-8')
    out = []
    n = 0
    for line in src.split('\n'):
        s = line.lstrip()
        if s.startswith('//') or s.startswith('*') or s.startswith('/*') or s.startswith('#'):
            out.append(line)
            continue
        # Leave the trailing comment of a code line alone too.
        new, k = WORD.subn('Telesia', line)
        out.append(new)
        n += k
    if n:
        f.write_text('\n'.join(out), encoding='utf-8')
        changed += 1
        print(f'{n:4d} {f.relative_to(root)}')
print('files changed:', changed)
