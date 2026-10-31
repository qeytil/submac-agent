// P5: the browser fleet — six jobs at once under one shared step budget, many pages in one table,
// and browser work that runs unattended inside a scheduled task.
import 'dart:async';
import 'dart:convert';

import 'package:agent/models.dart';
import 'package:agent/services/browser/extract.dart';
import 'package:agent/services/browser/loop_guard.dart';
import 'package:agent/services/browser_agent.dart';
import 'package:agent/services/browser_jobs.dart';
import 'package:agent/services/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCall _call(String name, Map<String, dynamic> args, String id) => ToolCall(id: id, name: name, arguments: jsonEncode(args));

void main() {
  group('the fleet', () {
    setUp(() {
      BrowserJobs.I.jobs.clear();
      BrowserJobs.I.canSee = () => true;
      BrowserJobs.I.say = null;
      BrowserJobs.I.onEnded = null;
      BrowserJobs.keepAwake = null;
      BrowserJobs.I.setFleetForTest(0);
    });
    tearDown(() {
      BrowserJobs.I.jobs.clear();
      BrowserJobs.I.llm = null;
      BrowserJobs.I.runTool = null;
      BrowserJobs.keepAwake = null;
      BrowserJobs.I.setFleetForTest(0);
    });

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 400 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('six browser tasks run at once, and the seventh is refused with what is already running', () async {
      expect(BrowserJobs.maxParallel, 6);
      final hang = <String, Completer<LlmResult>>{};
      BrowserJobs.I.llm = (j, p, t) => (hang[j.id] ??= Completer<LlmResult>()).future;
      for (var i = 0; i < 6; i++) {
        final out = await BrowserJobs.I.execute('browser_task', {'goal': 'job $i', 'wait': false}, 'chatF');
        expect(out, contains('Started browser task'));
      }
      expect(BrowserJobs.I.running.length, 6);
      final refused = await BrowserJobs.I.execute('browser_task', {'goal': 'one too many'}, 'chatF');
      expect(refused, contains('6 browser tasks are already running'));
      expect(refused, contains('b1'));
      for (final j in BrowserJobs.I.running.toList()) {
        BrowserJobs.I.stop(j);
      }
      await until(() => BrowserJobs.I.running.isEmpty);
    });

    test('the fleet shares one step budget, so six jobs cannot spend the user\'s day', () async {
      expect(BrowserJobs.fleetSteps, 400);
      var n = 0;
      BrowserJobs.I.llm = (j, p, t) async => LlmResult('', [_call('browser_scroll', {'direction': 'down'}, 's${n++}')], 'tool_calls');
      BrowserJobs.I.runTool = (j, name, a, id) async => 'Effect: the view scrolled.\nPage: Feed — https://feed.test/$n';
      BrowserJobs.I.setFleetForTest(BrowserJobs.fleetSteps);
      final j = BrowserJob('f1', 'read all', '', 'chatF', 20);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await until(() => j.finished);
      expect(j.status, 'failed');
      expect(j.result, contains('shared step budget'));
      expect(n, lessThan(5), reason: 'it stops at the first step past the fleet budget');
    });

    test('a job that ends lets the fleet count and the wake lock go', () async {
      final awake = <bool>[];
      BrowserJobs.keepAwake = (on) async {
        awake.add(on);
      };
      BrowserJobs.I.llm = (j, p, t) async => LlmResult('', [_call('finish', {'success': true, 'result': 'done'}, 'f1')], 'tool_calls');
      final out = await BrowserJobs.I.execute('browser_task', {'goal': 'x', 'wait': false}, 'chatF', unattended: true);
      expect(out, contains('Started browser task'));
      await until(() => BrowserJobs.I.running.isEmpty);
      expect(awake, [true, false]);
      expect(BrowserJobs.I.jobs.single.unattended, isTrue);
    });
  });

  group('unattended runs (a scheduled task)', () {
    setUp(() {
      BrowserJobs.I.jobs.clear();
      BrowserJobs.I.canSee = () => true;
      BrowserJobs.I.say = null;
      BrowserJobs.I.onEnded = null;
      BrowserJobs.I.setFleetForTest(0);
    });
    tearDown(() {
      BrowserJobs.I.jobs.clear();
      BrowserJobs.I.llm = null;
      BrowserJobs.I.runTool = null;
    });

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 400 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('it never pauses for a check-in: nobody is watching', () {
      final j = BrowserJob('u1', 'x', '', 'chatU', 0);
      expect(BrowserJobs.shouldCheckIn(j, DateTime.now().add(const Duration(minutes: 1))), isTrue);
      final away = BrowserJob('u2', 'x', '', 'chatU', 0, unattended: true);
      expect(BrowserJobs.shouldCheckIn(away, DateTime.now().add(const Duration(minutes: 1))), isFalse);
    });

    test('a scheduled run keeps working instead of handing back at the time box', () async {
      var n = 0;
      BrowserJobs.I.llm = (j, p, t) async => LlmResult('', [_call('browser_scroll', {'direction': 'down'}, 's${n++}')], 'tool_calls');
      BrowserJobs.I.runTool = (j, name, a, id) async => 'Effect: the view scrolled.\nPage: Feed — https://feed.test/$n';
      final j = BrowserJob('u3', 'read all', '', 'chatU', 0, unattended: true)..budget = StepBudget(maxSteps: 4);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await until(() => j.finished);
      expect(j.status, 'failed', reason: 'its own budget ends it, not a check-in');
      expect(j.result, contains('budget'));
    });

    test('a run with a user still checks in at the time box', () async {
      BrowserJobs.I.llm = (j, p, t) async => LlmResult('', [_call('browser_scroll', {'direction': 'down'}, 's${j.steps.length}')], 'tool_calls');
      BrowserJobs.I.runTool = (j, name, a, id) async => 'Effect: the view scrolled.\nPage: Feed — https://feed.test/';
      final j = BrowserJob('u4', 'read all', '', 'chatU', 0);
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.runForTest(j);
      await until(() => j.status == 'checkin');
      expect(j.status, 'checkin');
      expect(j.report(), contains('CHECK-IN'));
    });

    test('an unanswerable question ends the run cleanly instead of waiting for nobody', () async {
      final away = BrowserJob('u5', 'x', '', 'chatU', 20, unattended: true);
      BrowserJobs.I.jobs.add(away);
      final out = await BrowserJobs.I.ownToolForTest(away, 'ask', {'question': 'Pay 5 USD for the ticket?'});
      expect(out, contains('No one is watching'));
      expect(away.status, 'failed');
      expect(away.result, contains('Pay 5 USD for the ticket?'));
      final normal = BrowserJob('u6', 'x', '', 'chatU', 20);
      BrowserJobs.I.jobs.add(normal);
      await BrowserJobs.I.ownToolForTest(normal, 'ask', {'question': 'Which size?'});
      expect(normal.status, 'needs', reason: 'a run with a user still pauses and asks');
    });

    test('the prompt tells a background run never to ask or wait', () {
      final normal = BrowserJobs.I.systemFor(BrowserJob('p1', 'Check the price', '', 'c', 20));
      expect(normal, isNot(contains('THIS RUN IS IN THE BACKGROUND')));
      final away = BrowserJobs.I.systemFor(BrowserJob('p2', 'Check the price', '', 'c', 20, unattended: true));
      expect(away, contains('THIS RUN IS IN THE BACKGROUND'));
      expect(away, contains('Never wait for an answer'));
      expect(away, contains('one plain line'));
      expect(away, contains('Check the price'));
    });
  });

  group('many pages, one table', () {
    ExtractPage page(String url, List<Map<String, dynamic>> rows) => ExtractPage(url, rows: rows);

    test('rows from every page land in one table, each with the page it came from', () {
      final out = formatManyExtract([
        page('https://shop.test/a', [
          {'name': 'Red shoes', 'price': '\$19.99'},
          {'name': 'Blue hat', 'price': '\$9.99'},
        ]),
        page('https://shop.test/b', [
          {'name': 'Green bag', 'price': '\$29.99'},
        ]),
      ]);
      expect(out, contains('3 rows from 2 pages'));
      expect(out, contains('```data card'));
      final json = jsonDecode(out.substring(out.indexOf('['))) as List;
      expect(json.length, 3);
      expect(json.first['source'], 'shop.test/a');
      expect(json.last['source'], 'shop.test/b');
      expect(json.last['name'], 'Green bag');
    });

    test('a page cannot fake the source column, and the same row twice is kept once', () {
      final out = formatManyExtract([
        page('https://a.test/x', [
          {'name': 'one', 'source': 'somewhere else'},
          {'name': 'one', 'source': 'somewhere else'},
        ]),
      ]);
      final json = jsonDecode(out.substring(out.indexOf('['))) as List;
      expect(json.length, 1, reason: 'the duplicate row is dropped');
      expect(json.single['source'], 'a.test/x');
    });

    test('pages that were not read are named, with the way forward', () {
      final out = formatManyExtract([
        page('https://a.test/x', [
          {'name': 'one'},
        ]),
        const ExtractPage('https://b.test/y', error: 'needs a render'),
      ]);
      expect(out, contains('1 rows from 1 page'));
      expect(out, contains('Not read (1)'));
      expect(out, contains('b.test/y — needs a render'));
      expect(out, contains('browser_open'));
    });

    test('nothing at all says why, not an empty table', () {
      final out = formatManyExtract(const [ExtractPage('https://a.test/x', error: 'could not be fetched')]);
      expect(out, contains('Nothing came back'));
      expect(out, contains('could not be fetched'));
      expect(out, contains('browser_extract'));
    });

    test('the table is capped so eight pages cannot flood the chat', () {
      final out = formatManyExtract([
        page('https://a.test/x', [for (var i = 0; i < 250; i++) {'name': 'item $i'}]),
        page('https://b.test/y', [for (var i = 0; i < 250; i++) {'name': 'other $i'}]),
      ]);
      expect(out, contains('400 rows'), reason: 'hard cap, not all 500');
    });

    test('a page answer that is not a table becomes a readable error', () {
      expect(parseExtractPage('https://a.test', 'not json').error, 'no readable answer');
      expect(parseExtractPage('https://a.test', '{"err":"bad rows selector: x"}').error, 'bad rows selector: x');
      expect(parseExtractPage('https://a.test', '{"n":0,"rows":[]}').ok, isTrue);
      final p = parseExtractPage('https://a.test', '{"n":2,"rows":[{"a":1},{"a":2}]}');
      expect(p.rows.length, 2);
      expect(p.error, isNull);
    });

    test('a long source is shortened for the column', () {
      expect(shortSource('https://www.shop.test/'), 'shop.test');
      expect(shortSource('https://shop.test/a/b?c=1').length, lessThanOrEqualTo(48));
      expect(shortSource('https://shop.test/${'x' * 80}'), endsWith('…'));
    });
  });

  group('the tool surface', () {
    Map<String, dynamic> fnOf(List<Map<String, dynamic>> defs, String name) =>
        defs.map((d) => d['function'] as Map<String, dynamic>).firstWhere((f) => f['name'] == name);

    test('browser_extract_many is offered, with rows, fields and links', () {
      expect(BrowserAgent.names, contains('browser_extract_many'));
      final fn = fnOf(BrowserAgent.definitions, 'browser_extract_many');
      final params = (fn['parameters'] as Map)['properties'] as Map;
      expect(params.keys, containsAll(['links', 'from', 'rows', 'fields', 'limit', 'max_pages']));
      expect('${fn['description']}', contains('source column'));
    });

    test('the browser agent is taught to use it', () {
      final s = BrowserJobs.I.systemFor(BrowserJob('t1', 'Compare prices', '', 'c', 20));
      expect(s, contains('browser_extract_many'));
      expect(s, contains('Many pages, one table'));
    });

    test('the parallel hint in the tool description matches the cap', () {
      final fn = fnOf(BrowserJobs.definitions, 'browser_task');
      expect('${fn['description']}', contains('6 jobs in parallel'));
    });
  });
}
