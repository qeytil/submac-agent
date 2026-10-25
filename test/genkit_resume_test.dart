// v1.14 agent core: the run journal and resume after Android kills the app, the reply-format check, and team hand-offs
// on the core (the lead hands each member its part with a tool, then answers once).
import 'dart:convert';
import 'dart:io';

import 'package:agent/agent/core.dart';
import 'package:agent/agent/reply_schema.dart';
import 'package:agent/agent/run_journal.dart';
import 'package:agent/agent/tool_effects.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCall tc(String id, String name, [Map<String, dynamic> args = const {}]) => ToolCall(id: id, name: name, arguments: jsonEncode(args));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('run journal', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('runs'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<RunJournal> killedRun() async {
      final j = (await RunJournal.open(runId: 'r1', convId: 'c1', dir: dir, meta: {'title': 'Book it'}))!;
      final calls = [tc('a', 'web_search', {'q': 'x'}), tc('b', 'send_sms', {'to': '1'}), tc('c', 'pay_bill')];
      await j.modelStep(Reply(text: '', calls: calls, step: 0));
      await j.toolStart(calls[0]);
      await j.toolEnd(calls[0], 'results');
      await j.toolStart(calls[0]..id = 'a2');
      await j.toolStart(calls[1]);
      await j.interrupt(calls[2], {'kind': 'money'});
      return j; // never closed: the app died here
    }

    test('a killed run is found once its heartbeat is stale, with what was cut off', () async {
      final j = await killedRun();
      expect(await RunJournal.pending(dir: dir), isEmpty, reason: 'a fresh heartbeat means it may still be running');
      final later = DateTime.now().toUtc().add(const Duration(minutes: 1));
      final p = (await RunJournal.pending(dir: dir, now: later)).single;
      expect(p.runId, 'r1');
      expect(p.convId, 'c1');
      expect(p.kind, 'main');
      expect(p.steps, 1);
      expect(p.meta['title'], 'Book it');
      expect(p.unfinished.map((c) => c.id), ['a2', 'b']);
      expect(p.waiting.map((c) => c.id), ['c']);
      j.beat(); // keep analyzer quiet about the open journal
    });

    test('resume plan: never re-runs a side effect; a read is safe to call again; a waiting approval is not done', () async {
      await killedRun();
      final p = (await RunJournal.pending(dir: dir, now: DateTime.now().toUtc().add(const Duration(minutes: 1)))).single;
      final plan = p.plan();
      expect(plan.rerun.map((c) => c.name), ['web_search']);
      expect(plan.settle.keys, containsAll(['b', 'c']));
      expect(plan.textFor(tc('b', 'send_sms')), ToolEffects.interrupted('send_sms'));
      expect(plan.textFor(tc('b', 'send_sms')), contains('unknown whether it happened'));
      expect(plan.textFor(tc('c', 'pay_bill')), ToolEffects.approvalLost);
      expect(plan.textFor(tc('a2', 'web_search')), ToolEffects.cutOffSafe('web_search'));
      expect(plan.textFor(tc('zz', 'send_email')), ToolEffects.notStarted, reason: 'never started = nothing happened');
    });

    test('a handled or closed run is never picked up again; a line cut by the kill is skipped', () async {
      await killedRun();
      final later = DateTime.now().toUtc().add(const Duration(minutes: 1));
      File('${dir.path}/r1.jsonl').writeAsStringSync('{"t":"tool_end","id":', mode: FileMode.append);
      final p = (await RunJournal.pending(dir: dir, now: later)).single;
      expect(p.unfinished.map((c) => c.id), ['a2', 'b']);
      await p.markHandled('resumed');
      expect(await RunJournal.pending(dir: dir, now: later), isEmpty);

      final j2 = (await RunJournal.open(runId: 'r2', convId: 'c2', dir: dir))!;
      await j2.close('done');
      expect(await RunJournal.pending(dir: dir, now: later), isEmpty);
    });

    test('no folder set: no journal, no pending runs (tests and first start)', () async {
      RunJournal.root = null;
      expect(await RunJournal.open(runId: 'x', convId: 'y'), isNull);
      expect(await RunJournal.pending(), isEmpty);
    });

    test('tool effects: unknown tools are side effects (the safe default)', () {
      expect(ToolEffects.of('read_file'), ToolEffect.read);
      expect(ToolEffects.of('write_file'), ToolEffect.idempotent);
      expect(ToolEffects.of('send_whatsapp'), ToolEffect.sideEffect);
      expect(ToolEffects.of('some_new_tool'), ToolEffect.sideEffect);
      expect(ToolEffects.rerunnable('some_new_tool'), isFalse);
    });
  });

  group('resume settle in the chat', () {
    test('only the last turn\'s calls without an answer are settled', () {
      final list = [
        ChatMessage(id: '1', role: 'user', content: 'old'),
        ChatMessage(id: '2', role: 'assistant', content: '')..toolCalls = [tc('old', 'send_sms')],
        ChatMessage(id: '3', role: 'user', content: 'book it'),
        ChatMessage(id: '4', role: 'assistant', content: '')..toolCalls = [tc('x', 'web_search'), tc('y', 'send_sms')],
        ChatMessage(id: '5', role: 'tool', content: 'ok', toolCallId: 'x', name: 'web_search'),
      ];
      expect(ResumeSettle.unanswered(list).map((c) => c.id), ['y']);
      list.add(ChatMessage(id: '6', role: 'tool', content: 'sent', toolCallId: 'y', name: 'send_sms'));
      expect(ResumeSettle.unanswered(list), isEmpty);
    });

    test('the resume note tells the model to carry on and never repeat an unknown side effect', () {
      final n = ResumeSettle.note(2);
      expect(n, contains('Resumed after the app closed'));
      expect(n, contains('2 tool call(s) were cut off'));
      expect(n, contains('never repeat'));
      expect(ResumeSettle.note(0), isNot(contains('cut off')));
    });
  });

  group('reply schema check', () {
    test('a clean reply with valid cards passes', () {
      const r = 'Here it is.\n\n```table\n{"title":"Prices","columns":["Item","Price"],"rows":[["Tea","1"],["Rice","2"]]}\n```';
      expect(ReplySchema.problems(r), isEmpty);
      expect(ReplySchema.problems('Just words, no cards.'), isEmpty);
    });

    test('markdown tables, unclosed cards, bad JSON and wrong row sizes are sent back with plain fixes', () {
      expect(ReplySchema.problems('| a | b |\n|---|---|\n| 1 | 2 |').single, contains('markdown table'));
      expect(ReplySchema.problems('```table\n{"columns":["a"],"rows":[["1"]]}').single, contains('not closed'));
      expect(ReplySchema.problems('```table\n{columns: [a]}\n```').first, contains('not valid JSON'));
      final rows = ReplySchema.problems('```table\n{"columns":["a","b"],"rows":[["1","2"],["3"]]}\n```');
      expect(rows.first, contains('row 2'));
    });

    test('choices, links, events and files have their own rules', () {
      // v1.13.101: one suggestion is a valid card (it draws, with "Something else" under it); an empty one is not.
      expect(ReplySchema.problems('```choices\n["Only one"]\n```'), isEmpty);
      expect(ReplySchema.problems('```choices\n[]\n```'), isNotEmpty);
      expect(ReplySchema.problems('```links\n[{"title":"x","url":"example.com"}]\n```').first, contains('http(s)'));
      expect(ReplySchema.problems('```event\n{"title":"Dinner","start":"tomorrow"}\n```').first, contains('"start"'));
      expect(ReplySchema.problems('```file\n{"path":"out.pdf"}\n```').join(), contains('full path'));
    });

    test('the fix note lists each problem and asks for the same reply again', () {
      final n = ReplySchema.fixNote(['A', 'B']);
      expect(n, contains('- A'));
      expect(n, contains('- B'));
      expect(n, contains('same final reply again'));
    });
  });

  group('team hand-offs on the core', () {
    final lead = Bot(id: 'ghl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
    final nova = Bot(id: 'ghn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
    final amal = Bot(id: 'gha', name: 'Amal', role: 'Analyst', persona: 'Careful.');
    final seen = <String>[];
    var leadSkipsAmal = false;

    String sys(Turn t) => t.payload.where((m) => m['role'] == 'system').map((m) => '${m['content']}').join();
    LlmResult say(String s) => LlmResult(s, const [], 'stop', 10, 5, 5);

    Future<LlmResult> fakeLlm(Bot b, Turn t, {int maxTokens = 0}) async {
      final s = sys(t);
      if (s.contains('# Who speaks')) return say('{"speaker":"Hodan","team_task":true}');
      if (s.contains('# Plan for the owner')) {
        return say('{"reply":"Cheapest suppliers.","questions":[],"parts":[{"bot":"Nova","ask":"Find suppliers"},{"bot":"Amal","ask":"Compare"}]}');
      }
      if (s.contains('# Lead the work')) {
        final offs = [for (final d in t.tools ?? const <Map<String, dynamic>>[]) '${(d['function'] as Map)['name']}'];
        final done = t.payload.where((m) => m['role'] == 'tool').length;
        if (done == 0) {
          seen.add('lead→Nova');
          return LlmResult('', [tc('h1', offs.firstWhere((n) => n.contains('nova')), {'ask': 'Find three suppliers'})], 'tool_calls', 10, 5, 5);
        }
        if (done == 1 && !leadSkipsAmal) {
          final got = '${t.payload.lastWhere((m) => m['role'] == 'tool')['content']}';
          seen.add('lead→Amal (saw: $got)');
          return LlmResult('', [tc('h2', offs.firstWhere((n) => n.contains('amal')), {'ask': 'Compare them'})], 'tool_calls', 10, 5, 5);
        }
        seen.add('lead answers');
        return say('Lead: here are the three cheapest.');
      }
      if (s.contains('# Your part')) {
        seen.add('part:${b.name}:${t.payload.firstWhere((m) => m['role'] == 'user')['content']}');
        return say('Hodan, done.\n---\nFull result from ${b.name}.');
      }
      if (s.contains('# Combine')) {
        seen.add('combine');
        return say('Combined answer.');
      }
      return say('');
    }

    setUp(() {
      Bots.I.bots.addAll([lead, nova, amal]);
      TeamRun.I
        ..reset()
        ..ask = null
        ..llm = fakeLlm
        ..promptOf = (b) => 'You are ${b.name}.';
      seen.clear();
      leadSkipsAmal = false;
      Offices.I.queue.clear();
    });
    tearDown(() {
      Bots.I.bots.removeWhere((b) => b.id.startsWith('gh'));
      Offices.I.offices.clear();
      Offices.I.queue.clear();
      TeamRun.I
        ..reset()
        ..llm = null;
    });

    Office team() => Office(id: 'ogh${DateTime.now().microsecondsSinceEpoch}', name: 'Coffee', members: ['ghl', 'ghn', 'gha'], chiefId: 'ghl');

    test('the lead hands each part off with a tool, sees the result, and its own answer is the one posted', () async {
      final o = team();
      TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
      await TeamRun.I.work;
      expect(seen, [
        'lead→Nova',
        'part:Nova:Find three suppliers',
        'lead→Amal (saw: Full result from Nova.)',
        'part:Amal:Compare them',
        'lead answers',
      ]);
      final answer = o.posts.last;
      expect(answer.kind, 'answer');
      expect(answer.text, 'Lead: here are the three cheapest.');
      expect(answer.parts.map((x) => x.from), ['ghn', 'gha']);
      expect(TeamRun.I.running, isEmpty);
    });

    test('a part the lead did not hand off still runs, then the parts are combined', () async {
      leadSkipsAmal = true;
      final o = team();
      TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
      await TeamRun.I.work;
      expect(seen, ['lead→Nova', 'part:Nova:Find three suppliers', 'lead answers', 'part:Amal:Compare', 'combine']);
      expect(o.posts.last.text, 'Combined answer.');
      expect(o.posts.last.parts.map((x) => x.from), ['ghn', 'gha']);
    });
  });
}
