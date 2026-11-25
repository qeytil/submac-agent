import io

# `schemantic` only publishes up to 1.0.0 on pub.dev; ^1.1.0 resolves to nothing, so `flutter pub get` (which
# `flutter create` runs) fails and the APK build dies at "Generate platform folders" (owner 2026-11-25).
P = 'pubspec.yaml'
s = io.open(P, encoding='utf-8').read()
assert s.count('  schemantic: ^1.1.0') == 1, 'schemantic ^1.1.0 not found exactly once'
io.open(P, 'w', encoding='utf-8').write(s.replace('  schemantic: ^1.1.0', '  schemantic: ^1.0.0'))
print('pubspec: schemantic ^1.1.0 -> ^1.0.0 (1.1.0 does not exist on pub.dev)')
