// Team chat status and issue lines (owner 2026-11-04): one small live line per bot ("Nova is working…" / "Nova is
// typing…") that goes when its turn ends, and a failure as one small line "Nova · rate limit" instead of an error
// bubble or raw error text. Team chat only, never a private chat.

import 'dart:io';

import 'package:agent/screens/offices_screen.dart' show TeamLiveLines;
import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/opencode.dart' show OpenCodeError;
import 'package:agent/services/team_key.dart';
import 'package:agent/services/team_run.dart';
import 'package:agent/services/team_status.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800), disableAnimations: true),
        child: Scaffold(body: child),
      ),
    );

String _src(String p) => File(p).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lead = Bot(id: 'tsl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final nova = Bot(id: 'tsn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  final amal = Bot(id: 'tsa', name: 'Amal', role: 'Analyst', persona: 'Careful.');
  Bot? byId(String id) => [lead, nova, amal].where((b) => b.id == id).firstOrNull;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TeamStatus.I.reset();
  });

  group('error types: one helper', () {
    final cases = {
      'Paused until tomorrow to save your daily allowance.': TeamStatus.allowanceUsed,
      'background_paused': TeamStatus.allowanceUsed,
      'Nova used today\'s token budget. You can raise it in their settings.': TeamStatus.outOfBudget,
      'LlmException(429): Too Many Requests': TeamStatus.rateLimit,
      'Rate limit reached for gpt-4o': TeamStatus.rateLimit,
      'insufficient_quota: You exceeded your current quota': TeamStatus.outOfCredit,
      'HTTP 402 Payment Required': TeamStatus.outOfCredit,
      '401 Unauthorized: invalid api key': TeamStatus.keyError,
      'Incorrect API key provided': TeamStatus.keyError,
      'Nova ran out of time (30 min).': TeamStatus.timedOut,
      'TimeoutException after 0:00:30': TeamStatus.timedOut,
      'SocketException: Failed host lookup: api.example.com': TeamStatus.noConnection,
      "You're offline": TeamStatus.noConnection,
      'Tool browser_task failed: crashed': TeamStatus.toolFailed,
      '503 Service Unavailable': TeamStatus.providerError,
      'The model is overloaded': TeamStatus.providerError,
      'Something odd': TeamStatus.error,
      '': TeamStatus.error,
    };
    cases.forEach((raw, type) {
      test('"$raw" → $type', () => expect(TeamStatus.typeOf(raw), type));
    });

    test('an exception maps by its text, and every type is a known short label', () {
      expect(TeamStatus.typeOf(OpenCodeError('Nova ran out of time (30 min).')), TeamStatus.timedOut);
      for (final raw in cases.keys) {
        final t = TeamStatus.typeOf(raw);
        expect(TeamStatus.types, contains(t));
        expect(t.length, lessThan(20), reason: 'a small line, never the raw text');
      }
    });
  });

  group('live lines', () {
    final key = TeamKey.of('ots', 'tsn', job: 'j1');

    test('working while it thinks or runs steps, typing while its reply streams', () {
      expect(TeamStatus.phaseOf(), TeamPhase.working);
      expect(TeamStatus.phaseOf(lastKind: 'tool', lastFinished: false), TeamPhase.working);
      expect(TeamStatus.phaseOf(lastKind: 'text', reasoning: true), TeamPhase.working);
      expect(TeamStatus.phaseOf(lastKind: 'text'), TeamPhase.typing);
    });

    test('one line per bot that updates in place and goes when the turn ends', () {
      TeamStatus.I.begin(key);
      var lines = TeamStatus.I.linesFor('ots', bot: byId);
      expect(lines.map((l) => l.line), ['Nova is working…']);
      TeamStatus.I.phase(key, TeamPhase.typing);
      lines = TeamStatus.I.linesFor('ots', bot: byId);
      expect(lines.map((l) => l.line), ['Nova is typing…']);
      TeamStatus.I.end(key);
      expect(TeamStatus.I.linesFor('ots', bot: byId), isEmpty);
    });

    test('several bots at once: one line each; one bot with two turns is still one line', () {
      TeamStatus.I.begin(TeamKey.of('ots', 'tsn', job: 'a'));
      TeamStatus.I.begin(TeamKey.of('ots', 'tsn', job: 'b'));
      TeamStatus.I.begin(TeamKey.of('ots', 'tsa', job: 'c'));
      TeamStatus.I.phase(TeamKey.of('ots', 'tsn', job: 'b'), TeamPhase.typing);
      final lines = TeamStatus.I.linesFor('ots', bot: byId).map((l) => l.line).toList();
      expect(lines, ['Nova is typing…', 'Amal is working…']);
      expect(TeamStatus.I.linesFor('other', bot: byId), isEmpty, reason: 'another team sees nothing of it');
    });

    test('a private chat (no team key) never gets a line', () {
      TeamStatus.I.begin('conv-123');
      TeamStatus.I.fail('conv-123', '429 Too Many Requests');
      TeamStatus.I.begin(nova.convId);
      expect(TeamStatus.I.liveIn(''), isEmpty);
      expect(TeamStatus.I.issuesIn(''), isEmpty);
    });

    test('office jobs not yet in their turn show as working; waiting replies keep their words', () {
      final lines = TeamStatus.I.linesFor('ots', bot: byId, busy: {'tsn': DateTime.now()}, waiting: {'tsa': 'Read your message', 'tsn': 'x'});
      expect(lines.map((l) => l.line), ['Nova is working…', 'Amal · Read your message']);
    });
  });

  group('issue lines', () {
    test('a failed turn leaves "<Bot> · <type>", with the detail kept for a tap', () {
      final key = TeamKey.of('oti', 'tsa', job: 'x');
      TeamStatus.I.begin(key);
      TeamStatus.I.fail(key, OpenCodeError('insufficient_quota: credit balance too low'));
      TeamStatus.I.end(key);
      final lines = TeamStatus.I.linesFor('oti', bot: byId);
      expect(lines, hasLength(1));
      expect(lines.single.line, 'Amal · out of credit');
      expect(lines.single.isIssue, isTrue);
      expect(lines.single.detail, contains('credit balance'));
    });

    test('the issue stays until the bot starts work again; a live line wins over it', () {
      TeamStatus.I.flag('oti', 'tsn', TeamStatus.rateLimit);
      expect(TeamStatus.I.linesFor('oti', bot: byId).single.line, 'Nova · rate limit');
      final key = TeamKey.of('oti', 'tsn', job: 'y');
      TeamStatus.I.begin(key);
      expect(TeamStatus.I.linesFor('oti', bot: byId).single.line, 'Nova is working…');
      TeamStatus.I.end(key);
      expect(TeamStatus.I.linesFor('oti', bot: byId), isEmpty);
    });

    test('a bot that left the team shows nothing', () {
      TeamStatus.I.flag('oti', 'gone', TeamStatus.error);
      expect(TeamStatus.I.linesFor('oti', bot: byId), isEmpty);
    });
  });

  group('team runs', () {
    setUp(() {
      Bots.I.bots.addAll([lead, nova, amal]);
      TeamRun.I
        ..reset()
        ..ask = (b, system, user, {int maxTokens = 0}) async {
          if (system.contains('# Plan for the owner')) {
            return '{"reply":"On it.","questions":[],"parts":[{"bot":"Nova","ask":"Find"},{"bot":"Amal","ask":"Compare"}]}';
          }
          if (system.contains('# Combine')) return 'Combined.';
          return '{"speaker":"Hodan","team_task":true}';
        }
        ..promptOf = (b) => 'You are ${b.name}.';
    });
    tearDown(() {
      Bots.I.bots.removeWhere((b) => b.id.startsWith('ts'));
      Offices.I.offices.clear();
      TeamRun.I
        ..ocTurn = null
        ..reset();
    });

    test('a member whose part fails gets a small line, not a "could not finish" bubble', () async {
      TeamRun.I.ocTurn = (b, key, system, task, {stopped, assign}) async {
        if (assign != null) return '';
        if (b.id == 'tsn') throw OpenCodeError('429 Too Many Requests');
        return 'Hodan, done.\n---\nResult from ${b.name}.';
      };
      final o = Office(id: 'otr', name: 'Coffee', members: ['tsl', 'tsn', 'tsa'], chiefId: 'tsl');
      TeamRun.I.startJob(o, 'Weekly report');
      await TeamRun.I.work;
      expect(o.posts.where((p) => p.from == 'tsn'), isEmpty, reason: 'no error bubble from Nova');
      expect(o.posts.any((p) => p.text.contains(BotManner.partFailed())), isFalse);
      expect(o.posts.any((p) => p.text.contains('429')), isFalse, reason: 'never the raw error text');
      expect(o.posts.where((p) => p.from == 'tsa'), isNotEmpty);
      final lines = TeamStatus.I.linesFor('otr', bot: Bots.I.byId);
      expect(lines.map((l) => l.line), ['Nova · rate limit']);
    });
  });

  group('the team chat shows them', () {
    testWidgets('small muted lines: working, typing, and a tappable issue', (t) async {
      final rows = [
        TeamStatusLine(bot: nova, kind: TeamLineKind.working, since: DateTime.now()),
        TeamStatusLine(bot: amal, kind: TeamLineKind.typing, since: DateTime.now()),
        TeamStatusLine(bot: lead, kind: TeamLineKind.issue, text: TeamStatus.rateLimit, detail: '429 Too Many Requests'),
      ];
      await t.pumpWidget(_host(TeamLiveLines(rows: rows)));
      await t.pumpAndSettle();
      expect(find.text('Nova is working…'), findsOneWidget);
      expect(find.text('Amal is typing…'), findsOneWidget);
      expect(find.text('Hodan · rate limit'), findsOneWidget);
      expect(find.textContaining('429'), findsNothing, reason: 'the raw error only on tap');
      final style = t.widget<Text>(find.text('Nova is working…')).style!;
      expect(style.fontSize, AppText.captionStyle.fontSize, reason: 'a small line, on the shared scale');
      expect(style.fontSize!, lessThan(AppText.bodyStyle.fontSize!));
      await t.tap(find.byKey(const ValueKey('team-issue-tsl')));
      await t.pumpAndSettle();
      expect(find.textContaining('429 Too Many Requests'), findsOneWidget);
    });

    testWidgets('nothing to show: nothing shown', (t) async {
      await t.pumpWidget(_host(const TeamLiveLines(rows: [])));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('source', () {
    test('team turns drive the lines; no raw "hit a problem" posts; only the team chat reads them', () {
      final runner = _src('lib/state/agent_runner.dart');
      expect(runner, contains('TeamStatus.I.begin(key)'));
      expect(runner, contains('TeamStatus.I.fail(key, e)'));
      expect(runner, contains('TeamStatus.I.end(key)'));
      expect(_src('lib/state/bots_controller.dart'), isNot(contains('hit a problem: \$e')));
      for (final f in Directory('lib/screens').listSync().whereType<File>()) {
        if (f.path.endsWith('offices_screen.dart')) continue;
        expect(f.readAsStringSync(), isNot(contains('TeamStatus')), reason: '${f.path}: team lines stay in the team chat');
      }
      for (final f in Directory('lib/widgets').listSync(recursive: true).whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains('TeamStatus')), reason: '${f.path}: team lines stay in the team chat');
      }
    });
  });
}
