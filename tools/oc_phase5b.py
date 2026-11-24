#!/usr/bin/env python3
"""Investigation phase 5 fix: the case room route in home_screen needs the Cases import."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


sub('lib/screens/home_screen.dart',
    "import '../services/offices.dart';\nimport '../app_state.dart';",
    "import '../services/offices.dart';\nimport '../services/cases.dart';\nimport '../app_state.dart';")

print('phase 5 fix applied')
