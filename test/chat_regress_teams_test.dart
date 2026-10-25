// PR-6 fix/teams: regression tests for CB-19, CB-34, CB-36, CB-37 and CB-60 to CB-65 (chat bug hunt round 4, teams).
import 'dart:async';
import 'dart:convert';

import 'package:agent/agent/core.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lead = Bot(id: 'rtl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final nova = Bot(id: 'rtn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  final amal = Bot(id: 'rta', name: 'Amal', role: 'Analyst', persona: 'Careful.');
  final calls = <String>[];
  var floor = '{"speaker":"Hodan","team_task":true}';
  var withQuestions = false;
  var planFails = false;
  Completer<String>? partGate; // holds Nova's part until the test releases it
  Completer<void>? planGate; // holds the lead's plan until the test releases it
  final notes = <String>[];
  final awake = <bool>[];
  final stoppedOffices = <String>[];
  var runningJobs = <String>{};

  Future<String> fakeAsk(Bot b, String system, String user, {int maxTokens = 0}) async {
    if (system.contains('# Who speaks')) {
      calls.add('floor');
      return floor;
    }
    if (system.contains('# Plan for the owner')) {
      calls.add('plan');
      if (planGate != null) await planGate!.future;
      if (planFails) throw 'model down';
      final q = withQuestions ? '"Which city?"' : '';
      return '{"reply":"You want the cheapest coffee suppliers.","questions":[$q],'
          '"parts":[{"bot":"Nova","ask":"Find suppliers and prices"},{"bot":"Amal","ask":"Compare the prices"}]}';
    }
    if (system.contains('# Your part')) {
      calls.add('part:${b.name}');
      if (b.id == 'rtn' && partGate != null) return partGate!.future;
      return 'Hodan, my part is done.\n---\nFull result from ${b.name}.';
    }
    if (system.contains('# Combine')) {
      calls.add('combine');
      return 'Here are the cheapest suppliers.';
    }
    calls.add('other');
    return '';
  }

  Office team() {
    final o = Office(id: 'ort${DateTime.now().microsecondsSinceEpoch}', name: 'Coffee', members: ['rtl', 'rtn', 'rta'], chiefId: 'rtl');
    Offices.I.offices.add(o);
    return o;
  }

  Future<void> until(bool Function() ok, {String why = ''}) async {
    for (var i = 0; i < 400 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ok(), isTrue, reason: 'timed out waiting: $why');
  }

  List<String> said(Office o) => [for (final p in o.posts) '${p.from}|${p.kind}|${p.text}'];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Bots.I.bots.addAll([lead, nova, amal]);
    TeamRun.I
      ..reset()
      ..ask = fakeAsk
      ..llm = null
      ..toolsFor = null
      ..runTool = null
      ..keepAlive = ((on, {String text = ''}) async => awake.add(on))
      ..promptOf = (b) => 'You are ${b.name}.';
    calls.clear();
    notes.clear();
    awake.clear();
    stoppedOffices.clear();
    runningJobs = {};
    floor = '{"speaker":"Hodan","team_task":true}';
    withQuestions = false;
    planFails = false;
    partGate = null;
    planGate = null;
    Offices.I.queue.clear();
    Offices.I.approvals.clear();
    Offices.I.notify = (o, b, text) async => notes.add('${b.name}: $text');
    Offices.I.jobsRunning = (id) => runningJobs.contains(id);
    Offices.I.stopRunning = (id) {
      stoppedOffices.add(id);
      runningJobs.remove(id);
    };
  });
  tearDown(() {
    if (partGate != null && !partGate!.isCompleted) partGate!.complete('');
    if (planGate != null && !planGate!.isCompleted) planGate!.complete();
    Bots.I.bots.removeWhere((b) => b.id.startsWith('rt'));
    Offices.I.offices.clear();
    Offices.I.queue.clear();
    Offices.I.approvals.clear();
    Offices.I
      ..notify = null
      ..jobsRunning = null
      ..stopRunning = null;
    TeamRun.I
      ..reset()
      ..llm = null
      ..keepAlive = null;
  });

  group('CB-19 / CB-34 stop', () {
    test('CB-19: a member cut off by Stop posts nothing after it (no "could not finish my part")', () async {
      final o = team();
      partGate = Completer<String>();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      final w = TeamRun.I.work;
      await until(() => calls.contains('part:Nova'), why: 'Nova starts');
      TeamRun.I.send(o, 'stop');
      partGate!.complete('Hodan, late.\n---\nLate result.');
      await w;
      final s = said(o);
      expect(s.where((x) => x.startsWith('rtn|')), isEmpty, reason: s.join('\n'));
      expect(s.any((x) => x.contains(BotManner.partFailed())), isFalse, reason: s.join('\n'));
      expect(s.any((x) => x.contains('|answer|')), isFalse);
      expect(s.last, 'system|system|${BotManner.stopped()}');
      expect(calls, isNot(contains('part:Amal')));
      expect(TeamRun.I.running, isEmpty);
    });

    test('CB-34: "stop" during a member reply (askBot) cancels the job and says so; no floor call wakes anyone', () async {
      final o = team();
      TeamRun.I.send(o, '@Nova what did you find on prices?');
      expect(Offices.I.queue.where((j) => j.officeId == o.id && j.kind == 'reply'), isNotEmpty);
      expect(TeamRun.I.busy(o), isTrue, reason: 'a queued member reply makes the team busy');
      TeamRun.I.send(o, 'stop');
      await TeamRun.I.work;
      expect(calls, isEmpty, reason: 'stop never goes to the "who speaks" decision');
      expect(Offices.I.queue.where((j) => j.officeId == o.id), isEmpty, reason: 'the reply job is cancelled');
      expect(stoppedOffices, [o.id], reason: 'running member jobs are stopped');
      expect(o.posts.last.kind, 'system');
      expect(o.posts.last.text, BotManner.stopped());
    });

    test('CB-34: a member reply running now (not queued) also makes the team busy, and stop reaches it', () async {
      final o = team();
      runningJobs = {o.id};
      expect(TeamRun.I.busy(o), isTrue);
      TeamRun.I.send(o, 'jooji');
      expect(stoppedOffices, [o.id]);
      expect(TeamRun.I.busy(o), isFalse);
      expect(o.posts.last.text, BotManner.stopped(lang: 'so'));
      expect(Offices.I.stoppedSince(o.id, DateTime.now().subtract(const Duration(seconds: 5))), isTrue,
          reason: 'a reply that lands after the stop is not posted');
    });

    test('CB-34: stop when nothing runs still never wakes a member', () async {
      final o = team();
      floor = '{"speaker":"Hodan","team_task":false}';
      TeamRun.I.send(o, 'stop');
      await TeamRun.I.work;
      expect(calls, isEmpty);
      expect(Offices.I.queue, isEmpty);
    });
  });

  group('CB-36 the intro and team jobs', () {
    test('the intro no longer promises a go-ahead wait; it says the team starts after the plan', () async {
      final o = await Offices.I.create(name: 'Coffee', members: ['rtl', 'rtn', 'rta'], chiefId: 'rtl');
      final intro = o.posts.last.text;
      expect(intro, isNot(contains('go-ahead')));
      expect(intro, isNot(contains('wait for your')));
      expect(intro, contains('Hodan posts a plan and the team starts right away'));
      expect(intro, contains('only if something is unclear'));
      expect(intro, contains('waits for you'), reason: 'a new team still runs nothing until the owner writes');
    });

    test('two or more listed deliverables = a team task (English, Somali, Arabic)', () {
      for (final t in [
        'Compare three laptops under 800 USD, make a table of their specs and draft an email to my boss',
        'Please:\n- find three suppliers\n- compare their prices',
        '1) research coffee prices 2) write a short summary',
        'Raadi saddex laptop oo jaban, samee shax isbarbar dhig ah iyo qor email kooban',
        'قارن بين ثلاثة حواسيب محمولة، واصنع جدولًا بالمواصفات، واكتب رسالة بريد إلى مديري',
        'ابحث عن ثلاثة موردين ثم لخص أسعارهم',
      ]) {
        expect(TeamRun.looksLikeTeamTask(t), isTrue, reason: t);
      }
      for (final t in [
        'What did Nova find on prices?',
        'hi team',
        'Find the cheapest coffee in Hargeisa',
        'FYI I will be offline tomorrow',
        'Maxaad ka heshay qiimaha?',
        'ماذا وجدت نوفا عن الأسعار؟',
        'Compare the two offers',
      ]) {
        expect(TeamRun.looksLikeTeamTask(t), isFalse, reason: t);
      }
    });

    test('an Arabic three-part job goes to the lead\'s plan even when the floor would pick one member', () async {
      final o = team();
      floor = '{"speaker":"Amal","team_task":false}';
      TeamRun.I.send(o, 'قارن بين ثلاثة حواسيب محمولة، واصنع جدولًا بالمواصفات، واكتب رسالة بريد إلى مديري');
      await TeamRun.I.work;
      expect(calls.first, 'plan', reason: 'no single-reply floor decision');
      expect(Offices.I.queue, isEmpty);
      expect(o.posts.last.kind, 'answer');
    });
  });

  group('CB-37 nothing is dropped silently', () {
    test('two requests back to back: the second, sent while the team works, is acknowledged; the first gets its answer', () async {
      final o = team();
      planGate = Completer<void>();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      final w = TeamRun.I.work;
      await until(() => calls.contains('plan'), why: 'the lead plans');
      TeamRun.I.send(o, 'Also check Berbera please');
      expect(o.posts.last.kind, 'system');
      expect(o.posts.last.text, BotManner.noted());
      planGate!.complete();
      await w;
      expect(o.posts.last.kind, 'answer');
      expect(said(o).where((x) => x.startsWith('you|')).length, 2);
    });

    test('a speaker the team does not know: "Nobody picked this up" instead of silence', () async {
      final o = team();
      floor = '{"speaker":"Zed","team_task":false}';
      TeamRun.I.send(o, 'Can someone check the stock?');
      await TeamRun.I.work;
      expect(o.posts.last.text, BotManner.nobody());
      floor = 'I am not sure.';
      TeamRun.I.send(o, 'Anyone?');
      await TeamRun.I.work;
      expect(o.posts.last.text, BotManner.nobody());
    });

    test('a deliberate "none" for an FYI stays silent (owner 2026-10-24: silence is normal)', () async {
      final o = team();
      floor = '{"speaker":"none","team_task":false}';
      TeamRun.I.send(o, 'FYI I will be offline tomorrow');
      await TeamRun.I.work;
      expect(o.posts.where((p) => p.from != 'you'), isEmpty);
    });
  });

  group('CB-60 closing a running team', () {
    test('remove during run leaves no running cores and no asks, and nothing more is posted', () async {
      final o = team();
      nova.convId = 'c-rtn';
      partGate = Completer<String>();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      final w = TeamRun.I.work;
      await until(() => calls.contains('part:Nova'), why: 'Nova starts');
      expect(TeamRun.I.coresFor(o.id), greaterThan(0));
      Offices.I.approvals.addAll([
        Approval(id: Approval.newId(), botId: 'rtn', title: 'Send the email', officeId: o.id),
        Approval(id: Approval.newId(), botId: 'rtn', title: 'Open the site', convId: 'c-rtn'),
      ]);
      Offices.I.askBot(o, 'rta', 'and you?');
      await Offices.I.remove(o);
      final n = o.posts.length;
      partGate!.complete('Hodan, late.\n---\nLate result.');
      await w;
      expect(TeamRun.I.coresFor(o.id), 0);
      expect(TeamRun.I.running, isEmpty);
      expect(Offices.I.pending, isEmpty, reason: Offices.I.approvals.map((a) => a.status).join(','));
      expect(Offices.I.queue.where((j) => j.officeId == o.id), isEmpty);
      expect(o.posts.length, n, reason: 'no post into the closed team: ${said(o).skip(n).join(' / ')}');
      expect(calls, isNot(contains('part:Amal')));
      expect(calls, isNot(contains('combine')));
      expect(Offices.I.byId(o.id), isNull);
      nova.convId = '';
    });

    test('closing a team with a plan waiting drops the plan', () async {
      withQuestions = true;
      final o = team();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers');
      await TeamRun.I.work;
      expect(TeamRun.I.awaitingGo(o), isTrue);
      await Offices.I.remove(o);
      expect(TeamRun.I.awaitingGo(o), isFalse);
    });
  });

  group('CB-61 / CB-62 notifications and keepAlive', () {
    test('the plan and the final answer notify', () async {
      final o = team();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      await TeamRun.I.work;
      expect(notes.first, 'Hodan: You want the cheapest coffee suppliers.');
      expect(notes.last, 'Hodan: Here are the cheapest suppliers.');
      expect(notes.length, 2);
    });

    test('a question from the lead and a failure notify', () async {
      withQuestions = true;
      final o = team();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers');
      await TeamRun.I.work;
      expect(notes, ['Hodan: Which city?']);
      notes.clear();
      withQuestions = false;
      planFails = true;
      TeamRun.I.send(o, 'Only Hargeisa');
      await TeamRun.I.work;
      expect(o.posts.last.text, BotManner.couldNotFinish());
      expect(notes, ['Hodan: ${BotManner.couldNotFinish()}']);
    });

    test('a stopped job sends no failure notification', () async {
      final o = team();
      partGate = Completer<String>();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      final w = TeamRun.I.work;
      await until(() => calls.contains('part:Nova'));
      notes.clear();
      TeamRun.I.send(o, 'stop');
      partGate!.complete('');
      await w;
      expect(notes, isEmpty);
    });

    test('keepAlive is held for the plan and the run, and released once at the end', () async {
      final o = team();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      await TeamRun.I.work;
      expect(awake.first, isTrue);
      expect(awake.last, isFalse);
      expect(awake.where((x) => !x).length, 1, reason: 'no drop between the plan and the run: $awake');
    });

    test('keepAlive is released when the plan fails', () async {
      planFails = true;
      final o = team();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers');
      await TeamRun.I.work;
      expect(awake, [true, false]);
    });
  });

  group('CB-63 Arabic', () {
    test('Arabic is detected and every fixed phrase has Arabic', () {
      expect(BotManner.langOf('قارن الأسعار من فضلك'), 'ar');
      expect(BotManner.langOf('Fadlan raadi qiimaha bariiska maanta'), 'so');
      expect(BotManner.langOf('Please compare the prices'), 'en');
      final ar = RegExp(r'[\u0600-\u06FF]');
      for (final p in [
        BotManner.handOff('Nova', 'x', lang: 'ar'),
        BotManner.stopped(lang: 'ar'),
        BotManner.planCancelled(lang: 'ar'),
        BotManner.startingNow(lang: 'ar'),
        BotManner.askGo(lang: 'ar'),
        BotManner.couldNotFinish(lang: 'ar'),
        BotManner.partFailed(lang: 'ar'),
        BotManner.planHeader(lang: 'ar'),
        BotManner.noted(lang: 'ar'),
        BotManner.nobody(lang: 'ar'),
        BotManner.interrupted(lang: 'ar'),
      ]) {
        expect(ar.hasMatch(p), isTrue, reason: p);
      }
      expect(BotManner.phrases.length, 33);
    });

    test('an Arabic team job gets the plan header, start line and hand-offs in Arabic', () async {
      final o = team();
      TeamRun.I.send(o, 'ابحث عن أرخص موردي القهوة في هرجيسا');
      await TeamRun.I.work;
      final plan = o.posts.firstWhere((p) => p.from == 'rtl');
      expect(plan.text, contains(BotManner.planHeader(lang: 'ar')));
      expect(plan.text, contains(BotManner.startingNow(lang: 'ar')));
      expect(plan.text, isNot(contains('The plan:')));
      expect(o.posts.any((p) => p.text.startsWith('Nova، هل يمكنك')), isTrue, reason: said(o).join('\n'));
      expect(o.posts.any((p) => p.text.contains('could you please take this part')), isFalse);
    });
  });

  group('CB-64 a job interrupted by a process kill', () {
    test('a running job is journaled, and the journal goes when it ends', () async {
      final o = team();
      partGate = Completer<String>();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      final w = TeamRun.I.work;
      await until(() => calls.contains('part:Nova'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final p = await SharedPreferences.getInstance();
      final j = jsonDecode(p.getString('team_runs_v1') ?? '{}') as Map;
      expect(j[o.id]?['job'], 'Find the cheapest coffee suppliers in Hargeisa');
      expect((j[o.id]?['parts'] as List).length, 2);
      partGate!.complete('Hodan, done.\n---\nResult.');
      await w;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(jsonDecode(p.getString('team_runs_v1') ?? '{}'), isEmpty);
    });

    test('a persisted running plan produces the interruption post on start, and "go" restarts it', () async {
      final o = team();
      SharedPreferences.setMockInitialValues({
        'team_runs_v1': jsonEncode({
          o.id: {
            'job': 'Find suppliers',
            'lang': 'en',
            'planned': true,
            'parts': [
              {'bot': 'rtn', 'ask': 'Find suppliers and prices'},
              {'bot': 'rta', 'ask': 'Compare the prices'},
            ],
          },
        }),
      });
      await TeamRun.I.restore();
      expect(o.posts.last.kind, 'system');
      expect(o.posts.last.text, BotManner.interrupted());
      expect(TeamRun.I.awaitingGo(o), isTrue);
      expect(calls, isEmpty, reason: 'nothing resumes by itself');
      final p = await SharedPreferences.getInstance();
      expect(p.getString('team_runs_v1'), isNull, reason: 'said once');
      TeamRun.I.send(o, 'go');
      await TeamRun.I.work;
      expect(calls, ['part:Nova', 'part:Amal', 'combine']);
      expect(o.posts.last.kind, 'answer');
    });

    test('interrupted before the plan: "go" plans again', () async {
      final o = team();
      SharedPreferences.setMockInitialValues({
        'team_runs_v1': jsonEncode({
          o.id: {'job': 'Find suppliers', 'lang': 'so', 'planned': false, 'parts': []},
        }),
      });
      await TeamRun.I.restore();
      expect(o.posts.last.text, BotManner.interrupted(lang: 'so'));
      TeamRun.I.send(o, 'go');
      await TeamRun.I.work;
      expect(calls.first, 'plan');
      expect(o.posts.last.kind, 'answer');
    });
  });

  group('CB-65 the member step cap', () {
    LlmResult say(String s) => LlmResult(s, const [], 'stop', 10, 5, 5);
    String sys(Turn t) => t.payload.where((m) => m['role'] == 'system').map((m) => '${m['content']}').join();

    test('a halted member with tool results posts a summary, not "could not finish my part"', () async {
      var step = 0;
      var summary = '';
      TeamRun.I
        ..ask = null
        ..toolsFor = ((b) => [
              {
                'type': 'function',
                'function': {
                  'name': 'web_search',
                  'description': 'Search the web.',
                  'parameters': {'type': 'object', 'properties': {'q': {'type': 'string'}}},
                },
              },
            ])
        ..runTool = ((b, c, a, {Object? approved}) async => 'Supplier ${a['q']}: 4 USD/kg')
        ..llm = (b, t, {int maxTokens = 0}) async {
          final s = sys(t);
          if (s.contains('# Who speaks')) return say('{"speaker":"Hodan","team_task":true}');
          if (s.contains('# Plan for the owner')) {
            return say('{"reply":"Cheapest suppliers.","questions":[],"parts":[{"bot":"Nova","ask":"Find suppliers"}]}');
          }
          if (s.contains('# Lead the work')) return say('Hodan here.');
          if (s.contains('# Your part')) {
            if (t.tools == null) {
              summary = '${t.payload.last['content']}';
              calls.add('summary');
              return say('Hodan, I ran out of steps; here is what I found.\n---\nSupplier A: 4 USD/kg (from my searches).');
            }
            step++;
            return LlmResult('', [ToolCall(id: 'c$step', name: 'web_search', arguments: jsonEncode({'q': 'q$step'}))], 'tool_calls', 10, 5, 5);
          }
          if (s.contains('# Combine')) return say('Combined.');
          return say('');
        };
      final o = team();
      TeamRun.I.send(o, 'Find the cheapest coffee suppliers in Hargeisa');
      await TeamRun.I.work;
      expect(step, TeamRun.memberSteps);
      expect(calls, ['summary'], reason: 'one extra call, with no tools');
      expect(summary, contains('Tool result: Supplier q1: 4 USD/kg'));
      final post = o.posts.firstWhere((p) => p.from == 'rtn');
      expect(post.text, 'Hodan, I ran out of steps; here is what I found.');
      expect(post.parts.single.text, contains('Supplier A: 4 USD/kg'));
      expect(said(o).any((x) => x.contains(BotManner.partFailed())), isFalse);
    });
  });
}
