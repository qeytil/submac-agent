#!/usr/bin/env python3
"""Copies tools/browser_page.js into lib/services/browser/page_script.dart (run after editing the JS)."""
import re, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
js = (root / 'tools/browser_page.js').read_text()
assert "'''" not in js
v = re.search(r'var VERSION = (\d+);', js).group(1)
out = f"""// GENERATED from tools/browser_page.js by tools/gen_page_script.py. Do not edit by hand.
// ignore_for_file: lines_longer_than_80_chars

/// The page script of browser-use v2: snapshot with stable numbers, hit-tested clicks, typing, smart waits.
class PageScript {{
  PageScript._();

  /// Bumped whenever the script changes; a page holding an older copy gets the new one.
  static const version = {v};

  static const source = r'''
{js}''';
}}
"""
(root / 'lib/services/browser/page_script.dart').write_text(out)
print('wrote', len(out))
