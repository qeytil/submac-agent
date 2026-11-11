#!/usr/bin/env python3
""%Fix intro_screen.dart comment (owner 2026-11-11)."""
import os
path = "lib/screens/intro_screen.dart"
if not os.path.exists(path):
    print("file missing")
    exit()
with open(path, 'r') as f:
    c = f.read()
old = 'blue "S"'
new = 'blue "T"'
if old not in c:
    print("no match; already fixed?")
    exit()
c = c.replace(old, new)
with open(path, 'w') as f:
    f.write(c)
print(f"fixed {path}")