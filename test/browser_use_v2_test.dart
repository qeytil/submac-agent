import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/models.dart';
import 'package:agent/services/browser/loop_guard.dart';
import 'package:agent/services/browser/page_script.dart';
import 'package:agent/services/browser/shots.dart';
import 'package:agent/services/browser_agent.dart';
import 'package:agent/services/browser_jobs.dart';
import 'package:agent/services/full_access.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/trust.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Map<String, dynamic> _el(int i, String k, String t, {double x = .5, double y = .5, bool off = false, String h = ''}) =>
    {'i': i, 'k': k, 't': t, 'c': [x, y], 'b': [x - .05, y - .02, .1, .04], 'o': off ? 1 : 0, 'h': h};

PageSnapshot _page({String url = 'https://shop.test/search', String title = 'Shop', List<Map<String, dynamic>>? els, String text = '', bool card = false, Map? banner}) =>
    PageSnapshot.fromJson({
      'url': url,
      'title': title,
      'els': els ?? [_el(1, 'field(search)', 'Search'), _el(2, 'button', 'Go')],
      'text': text,
      'card': card,
      'fp': '${url.hashCode}${text.hashCode}',
      if (banner != null) 'banner': banner,
    });

ToolCall _call(String name, Map<String, dynamic> args, String id) => ToolCall(id: id, name: name, arguments: jsonEncode(args));

void main() {
  group('element snapshot and indexing', () {
    test('parses numbered elements with screen-fraction positions', () {
      final s = _page(els: [_el(4, 'button', 'Add to cart', x: .64, y: .71), _el(9, 'link', 'More', off: true, h: 'https://shop.test/more')]);
      expect(s.elements.map((e) => e.id), [4, 9]);
      final add = s.byId(4)!;
      expect(add.line(), '[4] button "Add to cart" @64,71');
      expect(s.byId(9)!.line(), contains('(below, scrolls in)'));
      expect(s.labels, {4: 'Add to cart', 9: 'More'});
    });

    test('new elements since the last step are starred; a new page stars nothing', () {
      final a = _page(els: [_el(1, 'field', 'Search')]);
      final b = _page(els: [_el(1, 'field', 'Search'), _el(7, 'option', 'Red shoes')]);
      final d = b.describe(before: a);
      expect(d, contains('*[7] option "Red shoes"'));
      expect(d, isNot(contains('*[1]')));
      final c = _page(url: 'https://other.test/', els: [_el(7, 'option', 'Red shoes')]);
      expect(c.describe(before: a), isNot(contains('*[7]')));
    });

    test('notices: cookie banner, sign-in and cross-site frames', () {
      final s = PageSnapshot.fromJson({
        'url': 'https://x.test/login',
        'title': 'Log in',
        'els': [_el(3, 'field(password)', 'Password')],
        'pw': true,
        'banner': {'id': 12, 'name': 'Reject all', 'kind': 'reject'},
        'frames': [
          {'host': 'js.stripe.com', 'b': [0.1, 0.5, 0.8, 0.1]}
        ],
      });
      final d = s.describe();
      expect(d, contains('[12] "Reject all"'));
      expect(d, contains('browser_login'));
      expect(d, contains('js.stripe.com @50,55'));
    });

    test('a payment page is recognised from card fields, URL or words', () {
      expect(_page(card: true).moneyPage, isTrue);
      expect(_page(url: 'https://shop.test/checkout/step2').moneyPage, isTrue);
      expect(_page(text: 'Review and Place your order now').moneyPage, isTrue);
      expect(_page(url: 'https://news.test/article', text: 'Today in sport').moneyPage, isFalse);
    });

    test('the page script is generated from tools/browser_page.js and keeps the click fixes', () {
      final js = File('tools/browser_page.js').readAsStringSync();
      expect(PageScript.source.trim(), js.trim(), reason: 'run tools/gen_page_script.py after editing the JS');
      final v = RegExp(r'var VERSION = (\d+);').firstMatch(js)!.group(1);
      expect('${PageScript.version}', v);
      // Instant scrolling (smooth scrolling moved the element while it was being tapped).
      expect(js, contains("behavior: 'instant'"));
      // Hit testing: the pressed point must reach the element itself.
      expect(js, contains('function hitPoint('));
      expect(js, contains('deepContains(el, top)'));
      // Coordinates are fractions of the visual viewport (what the screenshot shows).
      expect(js, contains('window.visualViewport'));
      // The page DOM is never touched for marks (the old overlay was drawn into the page).
      expect(js, isNot(contains('__sm_ov')));
    });

    test('addresses and words become the right URL', () {
      expect(BrowserAgent.toUrl('amazon.com/s?k=red shoes'), 'https://amazon.com/s?k=red%20shoes');
      expect(BrowserAgent.toUrl('red running shoes'), startsWith('https://duckduckgo.com/?q=red%20running%20shoes'));
      expect(BrowserAgent.toUrl('localhost:3000/app'), 'https://localhost:3000/app');
      expect(BrowserAgent.toUrl('https://x.test/a b'), 'https://x.test/a%20b');
    });
  });

  group('actions', () {
    test('a batch is validated before anything runs', () {
      final (ok, err) = BrowserAction.parseBatch([
        {'do': 'type', 'id': 1, 'text': 'red shoes'},
        {'do': 'click', 'id': 2},
      ]);
      expect(err, isNull);
      expect(ok.map((a) => a.kind), ['type', 'click']);
      expect(ok[1].mayChangePage, isTrue);
      expect(ok[0].mayChangePage, isFalse);
      expect(BrowserAction.parseBatch([{'do': 'fly'}]).$2, contains('unknown'));
      expect(BrowserAction.parseBatch([{'do': 'click'}]).$2, contains('"id"'));
      expect(BrowserAction.parseBatch([{'do': 'type', 'id': 3}]).$2, contains('"text"'));
      expect(BrowserAction.parseBatch(List.generate(7, (i) => {'do': 'scroll'})).$2, contains('at most'));
      expect(BrowserAction.parseBatch('[{"do":"key","key":"Enter"}]').$1.single.mayChangePage, isTrue);
    });

    test('the effect of a step is measured, and "nothing changed" is said plainly', () {
      final b = {'url': 'u', 'mut': 3, 'fp': 'a', 'focus': '', 'sy': 0};
      expect(StepEffect.compare(b, {...b}, pixels: false).describe(), contains('NOTHING changed'));
      expect(StepEffect.compare(b, {...b, 'mut': 9}).any, isTrue);
      expect(StepEffect.compare(b, {...b, 'url': 'v'}).describe(), 'Effect: moved to v.');
      expect(StepEffect.compare(b, {...b}, pixels: true).any, isTrue);
    });
  });

  group('approval gating (decision; the asking stays in the app approval flow)', () {
    final labels = {1: 'Search', 2: 'Go', 5: 'Place your order', 6: 'Continue', 7: ''};
    final normal = _page(els: [_el(1, 'field', 'Search'), _el(2, 'button', 'Go'), _el(6, 'button', 'Continue')]);
    final pay = _page(url: 'https://shop.test/checkout', card: true, els: [_el(5, 'button', 'Place your order'), _el(6, 'button', 'Continue'), _el(7, 'button', '')]);

    test('risky words always ask', () {
      expect(BrowserGate.check('browser_click', {'id': 5}, labels, normal), isNotNull);
      expect(BrowserGate.check('browser_click', {'id': 2}, labels, normal), isNull);
    });

    test('on a payment page any button that moves on asks, even "Continue" or an icon', () {
      expect(BrowserGate.check('browser_click', {'id': 6}, labels, pay), isNotNull);
      expect(BrowserGate.check('browser_click', {'id': 6}, labels, normal), isNull);
      expect(BrowserGate.check('browser_click', {'id': 7}, labels, pay), isNotNull);
    });

    test('Enter and submit cannot sneak past it', () {
      expect(BrowserGate.check('browser_type', {'id': 1, 'text': 'x', 'submit': true}, labels, pay), isNotNull);
      expect(BrowserGate.check('browser_press', {'key': 'Enter'}, labels, pay), isNotNull);
      expect(BrowserGate.check('browser_type', {'id': 1, 'text': 'x', 'submit': true}, labels, normal), isNull);
      expect(BrowserGate.check('browser_tap_at', {'x': 50, 'y': 50}, labels, pay), isNotNull);
    });

    test('a batch asks once for its risky part', () {
      final g = BrowserGate.check(
          'browser_act',
          {
            'actions': [
              {'do': 'type', 'id': 1, 'text': 'a'},
              {'do': 'click', 'id': 5},
            ]
          },
          labels,
          normal);
      expect(g, isNotNull);
      expect(g!.title, contains('Place your order'));
      expect(BrowserGate.check('browser_act', {'actions': [{'do': 'click', 'id': 2}]}, labels, normal), isNull);
    });

    test('a payment always asks, even with Full access on', () {
      expect(BotTrust.kindOf('browser_click', 'Tap "Place your order" on shop.test?'), 'money');
      expect(FullAccess.shouldAsk(level: BotTrust.levelTrusted, kind: 'money', tool: 'browser_act', fullAccess: true), isTrue);
    });

    test('a page confirm() that sends or deletes is flagged', () {
      expect(PageRisk.dialogNeedsOk('Delete this account?'), isTrue);
      expect(PageRisk.dialogNeedsOk('Leave this page?'), isFalse);
    });

    test('inline approval on the card answers, and Stop or a timeout means no', () async {
      final f = BrowserJobs.I.askInline('chatQ', title: 'Pay now?', detail: '', money: true);
      expect(BrowserJobs.I.inline['chatQ'], isNotNull);
      BrowserJobs.I.inline['chatQ']!.answer(true, always: true);
      final r = await f;
      expect(r.ok, isTrue);
      expect(r.always, isFalse, reason: 'never "always" for money');
      final late = await BrowserJobs.I.askInline('chatQ', title: 'Send?', detail: '', money: false, limit: const Duration(milliseconds: 30));
      expect(late.ok, isFalse);
      expect(BrowserJobs.I.inline.containsKey('chatQ'), isFalse);
    });
  });

  group('loop detection', () {
    StepTrace st(String a, {String page = 'p1', String url = 'u1', bool changed = false, bool failed = false}) =>
        StepTrace(action: a, page: page, url: url, changed: changed, failed: failed);

    test('the same action on the same page: nudge, then re-plan, then a clean stop', () {
      final g = LoopGuard();
      expect(g.record(st('click 3', changed: true)), GuardVerdict.ok);
      expect(g.record(st('click 3', changed: true)), GuardVerdict.ok);
      expect(g.record(st('click 3', changed: true)), GuardVerdict.nudge);
      // The window starts over after a warning: one old repeat is not counted twice.
      expect(g.record(st('click 3', changed: true)), GuardVerdict.ok);
      expect(g.record(st('click 3', changed: true)), GuardVerdict.ok);
      expect(g.record(st('click 3', changed: true)), GuardVerdict.replan);
      for (var i = 0; i < 2; i++) {
        g.record(st('click 3', changed: true));
      }
      expect(g.record(st('click 3', changed: true)), GuardVerdict.stop);
      expect(g.message(GuardVerdict.stop), startsWith('Stopped:'));
    });

    test('a stall: actions that change nothing', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        expect(g.record(st('click $i', page: 'p$i')), GuardVerdict.ok);
      }
      expect(g.record(st('click 9', page: 'p9')), GuardVerdict.nudge);
      expect(g.reason, contains('changed nothing'));
    });

    test('failures in a row, and bouncing between two pages', () {
      final g = LoopGuard();
      g.record(st('a', page: '1', changed: true, failed: true));
      g.record(st('b', page: '2', changed: true, failed: true));
      expect(g.record(st('c', page: '3', changed: true, failed: true)), GuardVerdict.nudge);
      final h = LoopGuard();
      h.record(st('a', url: 'A', page: '1', changed: true));
      h.record(st('b', url: 'B', page: '2', changed: true));
      h.record(st('c', url: 'A', page: '3', changed: true));
      expect(h.record(st('d', url: 'B', page: '4', changed: true)), GuardVerdict.nudge);
      expect(h.reason, contains('back and forth'));
    });

    test('real progress clears the warnings', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        g.record(st('x'));
      }
      expect(g.warnings, 1);
      g.record(st('open page', page: 'new', url: 'u2', changed: true));
      expect(g.warnings, 0);
    });
  });

  group('step and time limits', () {
    test('the budget is hard and says when it is nearly spent', () {
      final t0 = DateTime(2026, 1, 1, 12);
      final b = StepBudget(maxSteps: 8, maxTime: const Duration(minutes: 10), start: t0);
      b.steps = 5;
      expect(b.nearlySpent(now: t0), isFalse);
      b.steps = 6;
      expect(b.nearlySpent(now: t0), isTrue);
      expect(b.spent(now: t0), isFalse);
      b.steps = 8;
      expect(b.spent(now: t0), isTrue);
      b.steps = 0;
      expect(b.spent(now: t0.add(const Duration(minutes: 10))), isTrue);
    });

    test('bounded waits end on cancel and on their limit', () async {
      final never = Completer<int>().future;
      final cancel = Completer<void>();
      final f = Bounded.orCancel<int>(never, cancel.future);
      cancel.complete();
      expect(await f, isNull);
      expect(await Bounded.orCancel<int>(never, Completer<void>().future, limit: const Duration(milliseconds: 20)), isNull);
      expect(await Bounded.run<int>(never, const Duration(milliseconds: 20), 7), 7);
      var stopped = false;
      final sw = Stopwatch()..start();
      Timer(const Duration(milliseconds: 30), () => stopped = true);
      await Bounded.sleep(const Duration(seconds: 5), () => stopped);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('the browser agent loop', () {
    late List<String> ran;
    setUp(() {
      ran = [];
      BrowserJobs.I.jobs.clear();
      BrowserJobs.I.canSee = () => true;
      BrowserJobs.I.say = null;
      BrowserJobs.I.onEnded = null;
    });
    tearDown(() {
      BrowserJobs.I.jobs.clear();
      BrowserJobs.I.llm = null;
      BrowserJobs.I.runTool = null;
      BrowserJobs.modelLimit = const Duration(seconds: 150);
    });

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 400 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('a click that keeps missing ends cleanly with a clear message (no endless loop)', () async {
      var n = 0;
      BrowserJobs.I.llm = (j, p, t) async => LlmResult('', [_call('browser_click', {'id': 3}, 'c${n++}')], 'tool_calls');
      BrowserJobs.I.runTool = (j, name, a, id) async {
        ran.add(name);
        return 'Tapped [3], but nothing visible changed.\nEffect: NOTHING changed on the page.\nPage: Shop — https://shop.test/';
      };
      final j = BrowserJob('t1', 'buy', '', 'chatL', 20);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await until(() => j.finished);
      expect(j.status, 'failed');
      expect(j.result, contains('kept getting stuck'));
      expect(ran.length, lessThan(20));
    });

    test('the step budget ends a task that never finishes', () async {
      var n = 0;
      BrowserJobs.I.llm = (j, p, t) async => LlmResult('', [_call('browser_scroll', {'direction': 'down'}, 's${n++}')], 'tool_calls');
      BrowserJobs.I.runTool = (j, name, a, id) async => 'Effect: the view scrolled.\nPage: Feed — https://feed.test/$n';
      final j = BrowserJob('t2', 'read all', '', 'chatL', 20)..budget = StepBudget(maxSteps: 5);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await until(() => j.finished);
      expect(j.status, 'failed');
      expect(j.result, contains('budget'));
      expect(n, lessThanOrEqualTo(7));
    });

    test('Stop ends a task at once, even while the model is thinking', () async {
      final hang = Completer<LlmResult>();
      BrowserJobs.I.llm = (j, p, t) => hang.future;
      final j = BrowserJob('t3', 'x', '', 'chatL', 20);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      BrowserJobs.I.stop(j);
      expect(j.status, 'stopped');
      final out = await BrowserJobs.I.execute('browser_task_wait', {'id': 't3'}, 'chatL').timeout(const Duration(seconds: 2));
      expect(out, contains('STOPPED'));
    });

    test('a model that never answers ends the task cleanly instead of hanging', () async {
      BrowserJobs.modelLimit = const Duration(milliseconds: 30);
      BrowserJobs.I.llm = (j, p, t) => Completer<LlmResult>().future;
      final j = BrowserJob('t4', 'x', '', 'chatL', 20);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await until(() => j.finished);
      expect(j.status, 'failed');
      expect(j.result, contains('did not answer in time'));
    });

    test('finish is checked against the checklist', () async {
      var step = 0;
      BrowserJobs.I.llm = (j, p, t) async {
        step++;
        if (step == 1) return LlmResult('', [_call('plan', {'steps': ['search', 'add to cart']}, 'p1')], 'tool_calls');
        return LlmResult('', [_call('finish', {'success': true, 'result': 'done'}, 'f$step')], 'tool_calls');
      };
      final j = BrowserJob('t5', 'x', '', 'chatL', 20);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await until(() => j.finished);
      expect(j.steps.any((s) => s.result.startsWith('Unticked steps')), isTrue);
      expect(j.status, 'done');
    });

    test('the newest screenshot always reaches the model, even after a plan or note call', () {
      final j = BrowserJob('t6', 'x', '', 'chatL', 20);
      BrowserAgent.I.shotsByCall['shotA'] = Uint8List.fromList([1, 2, 3]);
      j.steps.add(BrowserJobs.stepForTest(_call('browser_click', {'id': 1}, 'shotA'), 'Effect: the page changed.', shot: 'shotA'));
      j.steps.add(BrowserJobs.stepForTest(_call('note', {'fact': 'price 20'}, 'n1'), 'Noted.'));
      final payload = BrowserJobs.I.payloadFor(j);
      final last = payload.last;
      expect(last['content'], isA<List>());
      final parts = last['content'] as List;
      expect((parts.first as Map)['text'], contains('Screenshot now'));
      expect(((parts.last as Map)['image_url'] as Map)['url'], startsWith('data:image/jpeg;base64,'));
      // Only one picture is sent per step.
      expect(payload.where((m) => m['content'] is List).length, 1);
      BrowserAgent.I.shotsByCall.remove('shotA');
    });

    test('the system prompt teaches the hybrid view, batching and verification', () {
      final s = BrowserJobs.I.systemFor(BrowserJob('t7', 'Book a table', '', 'c', 20));
      expect(s, contains('browser_act'));
      expect(s, contains('screenshot'));
      expect(s, contains('NOTHING changed'));
      expect(s, contains('Book a table'));
    });

    test('a finished task leaves one compact result card', () {
      final said = <String>[];
      BrowserJobs.I.say = (c, t) => said.add(t);
      final j = BrowserJob('t8', 'Find the price', '', 'chatR', 20);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.stop(j);
      expect(said.single, startsWith('```browser\n'));
      final json = jsonDecode(said.single.split('\n')[1]) as Map;
      expect(json['status'], 'stopped');
    });
  });

  group('screenshots with numbered marks', () {
    Uint8List jpg(int shade) {
      final im = img.Image(width: 400, height: 800);
      img.fill(im, color: img.ColorRgb8(shade, shade, shade));
      return Uint8List.fromList(img.encodeJpg(im));
    }

    test('marks are drawn on a copy; the page picture stays clean; the screen-change check works', () {
      final els = [PageElement(id: 3, kind: 'button', label: 'Go', box: const [0.25, 0.25, 0.5, 0.1])];
      final s = Shots.processSync(jpg(240), [for (final e in els) [e.id, ...e.box]])!;
      expect(s.width, lessThanOrEqualTo(Shots.modelWidth));
      expect(s.marked, isNot(equals(s.clean)));
      final marked = img.decodeJpg(s.marked)!;
      final clean = img.decodeJpg(s.clean)!;
      // In the number's label tab (just above the box's top-left corner) the marked picture is clearly blue; the clean
      // one is still light grey there.
      final px = marked.getPixel((0.25 * marked.width).round() + 11, (0.25 * marked.height).round() - 13);
      final pc = clean.getPixel((0.25 * clean.width).round() + 11, (0.25 * clean.height).round() - 13);
      num spread(img.Pixel q) => [q.r, q.g, q.b].reduce((a, b) => a > b ? a : b) - [q.r, q.g, q.b].reduce((a, b) => a < b ? a : b);
      expect(spread(px), greaterThan(60), reason: 'a coloured mark');
      expect(spread(pc), lessThan(20), reason: 'still grey');
      final other = Shots.processSync(jpg(20), const [])!;
      expect(Shots.changed(s.signature, s.signature), isFalse);
      expect(Shots.changed(s.signature, other.signature), isTrue);
    });
  });
}
