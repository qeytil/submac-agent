import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/agent_loop.dart';
import 'package:agent/services/constraints.dart';
import 'package:agent/services/quick_lane.dart';
import 'package:agent/services/tool_scope.dart';

/// Prompt-understanding eval: 24 English and Somali messages run through the pure parts of the request builder
/// (lane, tool groups, Must line, what the model reads last). One model since PLAN 1.1: nothing here picks a model. Each case scores the checks it passes; the
/// snapshot (test/goldens/prompt_eval.json) catches any silent change. Regenerate with UPDATE_GOLDENS=1.
/// Before/after numbers are in docs/agent-loop.md.
class Case {
  const Case(this.text,
      {this.asked = false, this.lane, this.fastStart, this.groups = const {}, this.must = const [], this.parts = 0});
  final String text;

  /// SubMac's last reply asked the user something.
  final bool asked;
  final String? lane;

  /// Whether the first step starts light (a tiny prompt, or only the core tools) instead of the full toolbox.
  final bool? fastStart;
  final Set<String> groups;

  /// Substrings the Must line has to carry.
  final List<String> must;
  final int parts;
}

const taskBefore = 'Book me a table for two at a seafood place in Mogadishu tonight';

const cases = <Case>[
  Case('hi', lane: QuickLane.quick, fastStart: true),
  Case('Iska warran', lane: QuickLane.quick, fastStart: true),
  Case('no', asked: true, lane: QuickLane.full, fastStart: false),
  Case('nope', asked: true, lane: QuickLane.full, fastStart: false),
  Case('maya', asked: true, lane: QuickLane.full, fastStart: false),
  Case('no thanks', asked: true, lane: QuickLane.full, fastStart: false),
  Case('thanks!', lane: QuickLane.quick, fastStart: true),
  Case('Give me 3 ideas for a coffee shop name, no emoji', fastStart: false, must: ['3 ideas', 'no emoji']),
  Case('Translate this to Somali: good morning', fastStart: false, must: ['Somali']),
  Case('Write a short email to my landlord in English, don\'t mention the rent',
      fastStart: false, must: ['English', 'short email', 'mention the rent']),
  Case('Saddex fikradood ii soo qor oo af Soomaali ah', fastStart: false, groups: {ToolScope.files}, must: ['af Soomaali', 'Saddex fikradood']),
  Case('Warqad codsi shaqo ii qor, ha ku darin lambarkayga', fastStart: false, groups: {ToolScope.files}, must: ['ha ku darin']),
  Case('Only the price please', fastStart: false, must: ['Only the price']),
  Case('Make a table of 5 phones under \$300', fastStart: false, must: ['5 phones', 'under \$300']),
  Case('summarize this in 2 lines', fastStart: false, must: ['2 lines']),
  Case('What is the capital of Kenya? And also what is its population?', fastStart: false, parts: 2),
  Case('Find flights to Nairobi then book the cheapest one without bags',
      fastStart: false, groups: {ToolScope.browser}, must: ['without bags'], parts: 2),
  Case('kaliya magaca ii sheeg', fastStart: false, must: ['kaliya']),
  Case('Hotel Mogadishu raadi', groups: {ToolScope.browser}),
  Case('faylka PDF-ka ah ii fur', groups: {ToolScope.files}),
  Case('sawir gaari ah ii samee', groups: {ToolScope.media}),
  Case('fariintan Axmed u dir', groups: {ToolScope.phone}),
  Case('xisaabi 15% of 2400', groups: {ToolScope.cards}),
  Case('bog ganacsi ii samee', groups: {ToolScope.browser, ToolScope.files}),
  // One model (PLAN 1.1): "today" needs fresh facts, so it starts with the full toolbox (weather), not a fast model.
  Case('Is it hot in Hargeisa today?', fastStart: false),
  Case('Explain photosynthesis without using jargon, in 3 sentences', fastStart: false, must: ['3 sentences', 'without using jargon']),
];

Map<String, dynamic> run(Case c) {
  final lane = QuickLane.laneFor(c.text, answeringQuestion: c.asked);
  final must = ConstraintReader.read(c.text);
  // The loop: "yes"/"no" after a question is full; a greeting or a short everyday message without constraints starts light.
  final fastStart = lane == QuickLane.quick || (lane == QuickLane.light && !must.any);
  final groups = ToolScope.hinted(c.text).toList()..sort();
  const sys = {'role': 'system', 'content': 'S'};
  final step0 = TailNote.attach([sys, {'role': 'user', 'content': c.text}], '# Right now\nThu 10:00\n\n${must.mustLine()}');
  final step1 = TailNote.attach([
    sys,
    {'role': 'user', 'content': c.text},
    {'role': 'assistant', 'content': null, 'tool_calls': []},
    {'role': 'tool', 'tool_call_id': '1', 'content': 'result'},
  ], '# Right now\nThu 10:01\n\n${must.mustLine()}', request: TaskBrief(c.text).recital());
  return {
    'text': c.text,
    'lane': lane,
    'fastStart': fastStart,
    'groups': groups,
    'must': must.mustLine(),
    'parts': must.parts,
    'userLastStep0': TailNote.lastText(step0).endsWith(c.text),
    'userLastStep1': TailNote.lastText(step1).trim().endsWith('"${c.text}"'),
  };
}

/// Checks passed / checks run for one case.
/// Passed / run per kind of check, for the report.
final tally = <String, List<int>>{};

(int, int) score(Case c, Map<String, dynamic> r) {
  var ok = 0, all = 0;
  var kind = '';
  void check(bool v) {
    all++;
    if (v) ok++;
    final t = tally.putIfAbsent(kind, () => [0, 0]);
    t[1]++;
    if (v) t[0]++;
  }

  kind = 'lane';
  if (c.lane != null) check(r['lane'] == c.lane);
  kind = 'fastStart';
  if (c.fastStart != null) check(r['fastStart'] == c.fastStart);
  kind = 'groups';
  for (final g in c.groups) {
    check((r['groups'] as List).contains(g));
  }
  kind = 'must';
  for (final m in c.must) {
    check((r['must'] as String).toLowerCase().contains(m.toLowerCase()));
  }
  kind = 'parts';
  if (c.parts > 0) check(r['parts'] == c.parts);
  kind = 'userWordsLast';
  check(r['userLastStep0'] == true);
  check(r['userLastStep1'] == true);
  return (ok, all);
}

void main() {
  test('prompt eval: at least 20 English and Somali prompts', () {
    expect(cases.length, greaterThanOrEqualTo(20));
  });

  test('prompt eval: every check passes and the payload snapshot is unchanged', () {
    final rows = [for (final c in cases) run(c)];
    var ok = 0, all = 0;
    final misses = <String>[];
    for (var i = 0; i < cases.length; i++) {
      final (o, a) = score(cases[i], rows[i]);
      ok += o;
      all += a;
      if (o < a) misses.add('${cases[i].text} -> ${jsonEncode(rows[i])}');
    }
    // ignore: avoid_print
    print('prompt eval: $ok/$all checks ${tally.map((k, v) => MapEntry(k, '${v[0]}/${v[1]}'))}');
    expect(misses, isEmpty, reason: misses.join('\n'));
    final golden = File('test/goldens/prompt_eval.json');
    final now = const JsonEncoder.withIndent('  ').convert(rows);
    if (Platform.environment['UPDATE_GOLDENS'] == '1' || !golden.existsSync()) {
      golden.createSync(recursive: true);
      golden.writeAsStringSync('$now\n');
    }
    expect(now, golden.readAsStringSync().trim());
  });
}
