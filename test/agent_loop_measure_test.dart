import 'dart:convert';

import 'package:agent/services/agent_loop.dart';
import 'package:flutter_test/flutter_test.dart';

/// Measures what the loop changes do to request size, prefix-cache reuse and waiting time, on a synthetic
/// 12-step task. Numbers are printed (see docs/agent-loop.md); the asserts guard the direction of the effect.
void main() {
  final stable = 'You are SubMac... ${'rule text ' * 1200}'; // ~12k chars of instructions + memory
  const now = '# Right now\nNow: about 2026-10-20 19:00 (phone\'s local time, rounded to the hour).';

  // Occasional one-step notes (steer, keep-the-user-posted, continue nudges) like the real loop produces.
  String? noteAt(int step) => const {3: '# Keep the user in the loop\nsay one line.', 7: '# The user just spoke\n"use Amazon"'}[step];

  List<Map<String, dynamic>> history(int steps) {
    final h = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'Find me three hotels in Nairobi under 100 USD and compare them'},
    ];
    for (var i = 0; i < steps; i++) {
      h.add({
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {'id': 'c$i', 'type': 'function', 'function': {'name': 'web_search', 'arguments': '{"q":"hotel $i"}'}},
        ],
      });
      h.add({'role': 'tool', 'tool_call_id': 'c$i', 'content': 'result $i ${'x' * 1500}'});
    }
    return h;
  }

  List<Map<String, dynamic>> oldStyle(int step, List<String> todo, Set<int> done) {
    final n = noteAt(step);
    // Before: time and every note lived inside the system prompt (no recitation at all).
    return [
      {'role': 'system', 'content': '$stable\n\n$now${n == null ? '' : '\n\n$n'}'},
      ...history(step),
    ];
  }

  List<Map<String, dynamic>> newStyle(int step, List<String> todo, Set<int> done) {
    final n = noteAt(step);
    final tail = [now, if (n != null) n, Recite.checklist(todo, done)].where((e) => e.isNotEmpty).join('\n\n');
    return TailNote.attach([
      {'role': 'system', 'content': stable},
      ...history(step),
    ], tail);
  }

  test('prefix cache reuse across steps', () {
    final todo = ['search', 'open the best three', 'compare', 'answer'];
    var oldShared = 0, oldTotal = 0, newShared = 0, newTotal = 0;
    for (var s = 1; s < 12; s++) {
      final done = {for (var i = 0; i < (s ~/ 3).clamp(0, 4); i++) i};
      final o0 = oldStyle(s - 1, todo, done), o1 = oldStyle(s, todo, done);
      final n0 = newStyle(s - 1, todo, done), n1 = newStyle(s, todo, done);
      oldShared += PayloadStats.sharedPrefix(o0, o1);
      oldTotal += PayloadStats.chars(o1);
      newShared += PayloadStats.sharedPrefix(n0, n1);
      newTotal += PayloadStats.chars(n1);
    }
    final oldPct = 100 * oldShared / oldTotal, newPct = 100 * newShared / newTotal;
    // ignore: avoid_print
    print('prefix reuse over 11 steps: before ${oldPct.toStringAsFixed(1)}% (${(oldTotal - oldShared) ~/ 4} uncached tokens), '
        'after ${newPct.toStringAsFixed(1)}% (${(newTotal - newShared) ~/ 4} uncached tokens); '
        'request size before ${oldTotal ~/ 4} tok, after ${newTotal ~/ 4} tok (checklist recitation included)');
    expect(newPct, greaterThan(oldPct));
    expect(newTotal - newShared, lessThan(oldTotal - oldShared));
  });

  test('parallel reads: waiting time', () async {
    Future<String> slowRead(int i) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return 'r$i';
    }

    final names = ['web_search', 'web_search', 'fetch_url'];
    final sw = Stopwatch()..start();
    for (var i = 0; i < names.length; i++) {
      await slowRead(i);
    }
    final seq = sw.elapsedMilliseconds;
    sw.reset();
    for (final b in ParallelPlan.batches(names)) {
      await ParallelPlan.runBatch(b, slowRead);
    }
    final par = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('3 reads of 300 ms: one after another $seq ms, together $par ms');
    expect(par, lessThan(seq * 0.6));
  });

  test('big results: tokens re-sent over the next steps', () {
    final page = List.generate(1200, (i) => 'Paragraph $i of a long hotel page with prices and reviews.').join('\n'); // ~70k chars
    final capped = page.length > 30000 ? '${page.substring(0, 30000)}…[truncated]' : page; // what fetch_url returned before
    // Before: whole while among the last 3 results (sent 3 times), then the first 500 chars.
    final before = capped.length * 3 + 520 * 8;
    final after = ResultClip.fresh(capped).length * 3 + ResultClip.old(capped).length * 8;
    // ignore: avoid_print
    print('one 30k-char page over 11 steps: before ~${before ~/ 4} tok, after ~${after ~/ 4} tok');
    expect(after, lessThan(before));
  });

  test('tail note is small', () {
    final tail = '${TailNote.open}$now\n\n${Recite.checklist(['a', 'b', 'c', 'd', 'e'], {0, 1})}${TailNote.close}';
    // ignore: avoid_print
    print('tail note with a 5-step checklist: ~${jsonEncode(tail).length ~/ 4} tok; final check: ~${Recite.finalCheck().length ~/ 4} tok');
    expect(tail.length, lessThan(1200));
  });
}
