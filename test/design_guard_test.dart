import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Design guard: the UI layer may not drift further from the shared system.
///
/// test/design_budget.json is a snapshot of every raw value in lib/screens and
/// lib/widgets: font sizes, corner radii, hex colours, and Material icons in the
/// chrome files. The snapshot is a ceiling, not a target. It may only ever be
/// lowered. A new literal of any kind fails here, so a screen cannot quietly
/// reintroduce its own scale, palette or icon language.
///
/// It also caps three consistency rules (PLAN.md 3.1): brand red (`.accent`) is
/// only for danger or delete, section headers use AppText.sectionStyle instead
/// of their own `letterSpacing`, and rows are separated by spacing, not
/// `Divider`s.
///
/// When you legitimately remove a literal, lower its count in the JSON.
/// New code should use lib/ui/tokens.dart (AppText, Radii, Space, IconSize)
/// and Palette instead.
void main() {
  test('UI layer stays inside the design budget', () {
    const uiDirs = ['lib/screens', 'lib/widgets'];
    const chromeFiles = {
      'lib/screens/home_screen.dart',
      'lib/screens/bots_screen.dart',
      'lib/widgets/composer.dart',
      'lib/widgets/sidebar.dart',
    };

    final budgetFile = File('test/design_budget.json');
    expect(budgetFile.existsSync(), isTrue, reason: 'Missing test/design_budget.json');
    final budget = jsonDecode(budgetFile.readAsStringSync()) as Map<String, dynamic>;

    Map<String, Map<String, int>> section(String name) {
      final raw = budget[name];
      if (raw is! Map) return const <String, Map<String, int>>{};
      return raw.map((file, counts) => MapEntry(
            file as String,
            Map<String, int>.from(
              (counts as Map).map((key, value) => MapEntry(key as String, value as int)),
            ),
          ));
    }

    final fontSizes = section('fontSizes');
    final radii = section('radii');
    final colors = section('colors');
    final icons = section('icons');
    final brandSerif = section('brandSerif');
    final accent = section('accent');
    final letterSpacing = section('letterSpacing');
    final dividers = section('dividers');

    final files = <String>[];
    for (final dir in uiDirs) {
      final directory = Directory(dir);
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          files.add(entity.path.replaceAll(Platform.pathSeparator, '/'));
        }
      }
    }
    expect(files, isNotEmpty, reason: 'No UI files found to guard.');

    Map<String, int> counts(String source, RegExp pattern) {
      final out = <String, int>{};
      for (final match in pattern.allMatches(source)) {
        final key = match.groupCount >= 1 ? match.group(1)! : match.group(0)!;
        out[key] = (out[key] ?? 0) + 1;
      }
      return out;
    }

    final problems = <String>[];

    void compare(String kind, String file, Map<String, int> actual, Map<String, int> allowed) {
      actual.forEach((value, count) {
        final cap = allowed[value] ?? 0;
        if (count > cap) {
          problems.add('$file: $kind $value used $count time(s), budget $cap');
        }
      });
    }

    final fontSizePattern = RegExp(r'fontSize:\s*([0-9]+(?:\.[0-9]+)?)');
    final radiusPattern = RegExp(r'BorderRadius\.circular\(\s*([0-9]+(?:\.[0-9]+)?)');
    final colorPattern = RegExp(r'Color\(0x([0-9A-Fa-f]{8})\)');
    final iconPattern = RegExp(r'Icons\.[A-Za-z0-9_]+');
    final serifPattern = RegExp(r'Brand\.serif\(size:\s*([0-9]+(?:\.[0-9]+)?)');
    final accentPattern = RegExp(r'\.accent(?![A-Za-z0-9_])');
    final letterSpacingPattern = RegExp(r'letterSpacing:');
    final dividerPattern = RegExp(r'\b(?:Vertical)?Divider\(');

    for (final file in files) {
      final source = File(file).readAsStringSync();
      compare('fontSize', file, counts(source, fontSizePattern), fontSizes[file] ?? const <String, int>{});
      compare('radius', file, counts(source, radiusPattern), radii[file] ?? const <String, int>{});
      compare('colour', file, counts(source, colorPattern), colors[file] ?? const <String, int>{});
      compare('serif size', file, counts(source, serifPattern), brandSerif[file] ?? const <String, int>{});
      compare('brand red', file, counts(source, accentPattern), accent[file] ?? const <String, int>{});
      compare('letterSpacing', file, counts(source, letterSpacingPattern), letterSpacing[file] ?? const <String, int>{});
      compare('divider', file, counts(source, dividerPattern), dividers[file] ?? const <String, int>{});
      if (chromeFiles.contains(file)) {
        compare('icon', file, counts(source, iconPattern), icons[file] ?? const <String, int>{});
      }
    }

    expect(
      problems,
      isEmpty,
      reason: 'Design guard: values outside the budget.\n'
          'Use lib/ui/tokens.dart and Palette, or lower the matching entry in\n'
          'test/design_budget.json when you remove a literal.\n\n' +
          problems.join('\n'),
    );
  });
}
