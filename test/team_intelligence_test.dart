// Team intelligence (owner, 2026-10-24): routing like a real group chat (Grok Bot: whoever is addressed answers; the
// team decides otherwise; the lead stays quiet unless addressed or running a job the owner gave the team), silence as
// the natural default (no @silent hack), no automation on a timer, replies, the expandable long-text container, the
// composite team head and tiny status rings. docs/team-intelligence.md.
import 'dart:convert';

import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/bot_status.dart' show RingState;
import 'package:agent/services/bots.dart';
import 'package:agent/services/no_reply.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/chat/long_text.dart';
import 'package:agent/widgets/chat/reply_quote.dart';
import 'package:agent/widgets/status_ring.dart';
import 'package:agent/widgets/team_face.dart';
import 'package:agent/screens/bots_screen.dart' show BotAvatar;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, {TextDirection dir = TextDirection.ltr, bool still = false, Size size = const Size(400, 800)}) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: still),
        child: Directionality(textDirection: dir, child: Scaffold(body: child)),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lead = Bot(id: 'til', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final nova = Bot(id: 'tin', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  final amal = Bot(id: 'tia', name: 'Amal', role: 'Analyst', persona: 'Careful.');
  final calls = <String>[];
  var floor = '{"speaker":"none","team_task":false}';

  Future<String> fakeAsk(Bot b, String system, String user, {int maxTokens = 0}) async {
    if (system.contains('# Who speaks')) {
      calls.add(system.contains('just wrote to') ? 'floor:lead' : 'floor');
      return floor;
    }
    if (system.contains('# Plan for the owner')) {
      calls.add('plan');
      return '{"reply":"Plan.","questions":[],"parts":[{"bot":"Nova","ask":"Research"},{"bot":"Amal","ask":"Analyse"}]}';
    }
    if (system.contains('# Your part')) {
      calls.add('part:${b.name}');
      return 'Done.\n---\nResult from ${b.name}.';
    }
    if (system.contains('# Combine')) {
      calls.add('combine');
      return 'Combined.';
    }
    calls.add('other');
    return '';
  }

  Office team() => Office(id: 'oti${DateTime.now().microsecondsSinceEpoch}', name: 'Coffee', members: ['til', 'tin', 'tia'], chiefId: 'til');
  List<String> asked(Office o) => [for (final j in Offices.I.queue.where((j) => j.officeId == o.id && j.kind == 'reply')) j.botId];

  setUp(() {
    Bots.I.bots.addAll([lead, nova, amal]);
    TeamRun.I
      ..reset()
      ..ask = fakeAsk
      ..promptOf = (b) => 'You are ${b.name}.';
    calls.clear();
    floor = '{"speaker":"none","team_task":false}';
    Offices.I.queue.clear();
  });
  tearDown(() {
    Bots.I.bots.removeWhere((b) => b.id.startsWith('ti'));
    Offices.I.queue.clear();
    TeamRun.I.reset();
  });

  group('routing: whoever is addressed answers, and only they', () {
    test('@mention of one bot goes only to that bot; the lead stays silent and no decision is needed', () async {
      final o = team();
      TeamRun.I.send(o, '@Nova what did you find on prices?');
      await TeamRun.I.work;
      expect(asked(o), ['tin']);
      expect(calls, isEmpty, reason: 'no floor call, no plan');
      expect(o.posts.where((p) => p.from == 'til'), isEmpty, reason: 'the lead says nothing');
    });

    test('several mentions: each of them, nobody else', () {
      final o = team();
      TeamRun.I.send(o, '@Nova and @Amal please compare notes');
      expect(asked(o), ['tin', 'tia']);
      expect(asked(o), isNot(contains('til')));
    });

    test('a reply to a bot\'s message goes to that bot', () {
      final o = team();
      final post = Offices.I.post(o, 'tia', 'Which market should I check?');
      TeamRun.I.send(o, 'Hargeisa first', replyTo: post.id);
      expect(asked(o), ['tia']);
      expect(o.posts.last.replyTo, post.id, reason: 'the owner\'s post keeps the link');
      final job = Offices.I.queue.firstWhere((j) => j.botId == 'tia');
      expect(job.instruction, contains('Which market should I check?'), reason: 'the bot sees what is being replied to');
      expect(calls, isEmpty);
    });

    test('a message that starts with a member\'s name addresses them', () {
      final o = team();
      TeamRun.I.send(o, 'Amal, can you check the totals?');
      expect(asked(o), ['tia']);
    });

    test('@team asks every member', () async {
      final o = team();
      TeamRun.I.send(o, '@team quick update please');
      await TeamRun.I.work;
      expect(asked(o)..sort(), ['tia', 'til', 'tin']..sort());
    });

    test('the lead, when addressed, answers itself unless the owner gives the team a job', () async {
      final o = team();
      floor = '{"speaker":"Hodan","team_task":false}';
      TeamRun.I.send(o, '@Hodan how are you planning the week?');
      await TeamRun.I.work;
      expect(calls, ['floor:lead']);
      expect(asked(o), ['til']);
      floor = '{"speaker":"Hodan","team_task":true}';
      Offices.I.queue.clear();
      calls.clear();
      TeamRun.I.send(o, '@Hodan get the team to research suppliers and compare prices');
      await TeamRun.I.work;
      expect(calls.first, 'floor:lead');
      expect(calls, containsAll(['plan', 'part:Nova', 'part:Amal', 'combine']));
      expect(asked(o), isEmpty, reason: 'the job runs as a team, not as a lone reply');
    });

    test('nobody addressed: the team decides; a member whose role fits answers, the lead stays quiet', () async {
      final o = team();
      floor = '{"speaker":"Nova","team_task":false}';
      TeamRun.I.send(o, 'Any news on coffee prices this week?');
      await TeamRun.I.work;
      expect(calls, ['floor']);
      expect(asked(o), ['tin']);
      expect(o.posts.where((p) => p.from == 'til'), isEmpty);
    });

    test('nobody addressed and nothing to answer: silence is a normal outcome', () async {
      final o = team();
      TeamRun.I.send(o, 'FYI I will be offline tomorrow');
      await TeamRun.I.work;
      expect(calls, ['floor']);
      expect(asked(o), isEmpty);
      expect(o.posts.where((p) => p.from != 'you'), isEmpty, reason: 'no bot and no system line');
    });

    test('a job for the whole team while the lead leads (the owner handed over): the lead coordinates it', () async {
      // Team awareness (owner 2026-11-05): the lead plans a team job only when the owner handed over or gives it the
      // job by name; while the owner leads, the members the job needs answer (team_awareness_test.dart).
      final o = team()..delegated = true;
      floor = '{"speaker":"Hodan","team_task":true}';
      TeamRun.I.send(o, 'Team, find the three cheapest suppliers and compare them');
      await TeamRun.I.work;
      // CB-36: two listed deliverables make it a team job without the "who speaks" call.
      expect(calls, ['plan', 'part:Nova', 'part:Amal', 'combine']);
      expect(o.posts.last.kind, 'answer');
    });

    test('the floor prompt is instructions with the roster and the recent chat, not a rule table', () {
      final o = team();
      Offices.I.post(o, 'tin', 'I found three suppliers.');
      final sys = TeamRun.floorSystem(o, lead, [nova, amal]);
      expect(sys, contains('- Hodan: team lead, Manager'));
      expect(sys, contains('Nova (member, Researcher): I found three suppliers.'));
      expect(sys, contains('Silence is normal'));
      expect(sys, contains('the lead is a member like the others'));
    });
  });

  group('@silent and silence', () {
    test('the owner\'s "@silent" is posted and nobody answers (it is no longer mistaken for a mention)', () async {
      final o = team();
      TeamRun.I.send(o, 'Note for later: budget is 500 @silent');
      await TeamRun.I.work;
      expect(asked(o), isEmpty);
      expect(calls, isEmpty);
      expect(o.posts.single.from, 'you');
    });

    test('an @word that is no member is not a mention', () {
      final o = team();
      expect(Offices.I.mentioned(o, 'email me at a@b.com or @someone'), isEmpty);
      expect(Offices.I.mentioned(o, '@nova hi').single.id, 'tin');
    });

    test('silence markers read as silence; real words next to a stray tag are kept', () {
      for (final t in ['', '[no reply]', '[No Reply]', '@silent', 'NO_REPLY', '  [no reply]. ']) {
        expect(NoReply.isSilent(t), isTrue, reason: t);
      }
      expect(NoReply.clean('Prices are up 4%. @silent'), 'Prices are up 4%.');
      expect(NoReply.clean('Done, the file is in the folder.\n[no reply]'), 'Done, the file is in the folder.');
      expect(NoReply.isSilent('مرحبا silent'), isFalse, reason: 'Arabic text is never swallowed');
      expect(NoReply.isSilent('The test was silent on errors'), isFalse);
    });

    test('a wake outcome keeps the words that came with a silence tag', () {
      final out = BotOutcome.parse('I answered the owner.\n@silent');
      expect(out.kind, 'silent');
      expect(out.text, 'I answered the owner.');
      expect(BotOutcome.parse('[no reply]').text, '');
      expect(BotOutcome.visible('Here it is. [no reply]'), 'Here it is.');
    });
  });

  group('no automation, no chatter', () {
    test('while the team works, the owner\'s words reach the work with one system line, never a bot\'s canned reply', () async {
      // CB-37 (fix plan 2026-10-25): the message used to vanish without a word; now one system line says it reached the work.
      final o = team();
      TeamRun.I.running.add(o.id);
      TeamRun.I.send(o, 'also check Berbera');
      expect(o.posts.first.from, 'you');
      expect(o.posts.where((p) => p.from != 'you').map((p) => '${p.from}|${p.kind}'), ['system|system']);
      expect(o.posts.last.text, BotManner.noted());
      TeamRun.I.running.clear();
    });

    test('timed rounds are gone: an old tick or report alarm queues nothing; supervise never posts', () async {
      SharedPreferences.setMockInitialValues({});
      final o = team()..mode = 'supervised';
      Offices.I.offices.add(o);
      o.tasks.add(OfficeTask(id: 't1', title: 'Old task', owner: 'tin', status: 'doing'));
      expect(await Offices.I.fire('office|${o.id}|tick'), isFalse);
      expect(await Offices.I.fire('office|${o.id}|digest'), isFalse);
      Offices.I.supervise(o);
      expect(Offices.I.queue, isEmpty);
      expect(o.posts, isEmpty);
      Offices.I.offices.remove(o);
    });

    test('"Works on its own" is gone: an old team reads as "Only when I ask"', () {
      final j = jsonDecode(jsonEncode(team().toJson())) as Map<String, dynamic>;
      j['mode'] = 'away';
      expect(Office.fromJson(j).mode, 'manual');
    });

    test('a bot is never told to open its own chat with a greeting', () {
      expect(BotManner.block, isNot(contains('open your chat')));
    });
  });

  group('replies', () {
    test('a reply rides at the top of the message and comes back out', () {
      const r = ReplyRef(id: 'm-42', author: 'SubMac', quote: 'The meeting is at **3 pm** on Friday.\nBring the slides.');
      final enc = ReplyCodec.encode(r, 'Can we move it to 4?');
      expect(enc, startsWith('[Reply to SubMac · #m-42]\n> The meeting is at 3 pm on Friday. Bring the slides.'));
      final dec = ReplyCodec.decode(enc);
      expect(dec.ref!.id, 'm-42');
      expect(dec.ref!.author, 'SubMac');
      expect(dec.body, 'Can we move it to 4?');
      expect(ReplyCodec.decode('Just a message').ref, isNull);
      expect(ReplyCodec.quoteOf('x' * 900).length, lessThanOrEqualTo(ReplyCodec.quoteMax + 1));
    });

    testWidgets('swipe a message to reply (and the other way in RTL)', (t) async {
      for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
        var replied = 0;
        await t.pumpWidget(_host(
          SwipeToReply(onReply: () => replied++, child: const SizedBox(width: 300, height: 60, child: Text('hello'))),
          dir: dir,
        ));
        final dx = dir == TextDirection.ltr ? 90.0 : -90.0;
        await t.drag(find.text('hello'), Offset(dx, 0));
        await t.pumpAndSettle();
        expect(replied, 1, reason: '$dir');
        await t.drag(find.text('hello'), Offset(-dx, 0));
        await t.pumpAndSettle();
        expect(replied, 1, reason: 'the wrong way does nothing ($dir)');
      }
    });

    testWidgets('the quote in a bubble jumps to the original', (t) async {
      final scroll = ScrollController();
      await t.pumpWidget(_host(ListView.builder(
        controller: scroll,
        reverse: true,
        itemCount: 80,
        itemBuilder: (_, i) => MessageAnchor(
          id: 'm$i',
          child: SizedBox(height: 90, child: i == 0 ? ReplyQuote(author: 'Nova', quote: 'old words', onTap: () => jumpToMessage(scroll, 'm60')) : Text('message $i')),
        ),
      )));
      expect(find.text('message 60'), findsNothing);
      await t.tap(find.byKey(const ValueKey('reply-quote')));
      await t.pumpAndSettle();
      expect(find.text('message 60'), findsOneWidget);
      expect(MessageAnchors.flash.value, 'm60');
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('long texts fold into an expandable container', () {
    final long = List.generate(40, (i) => 'Line $i of a long result with plenty of words in it.').join('\n');

    testWidgets('a long text shows a preview with Show more and Open; it opens in place and folds again', (t) async {
      await t.pumpWidget(_host(SingleChildScrollView(child: ExpandableText(text: long, child: Text(long)))));
      expect(find.byKey(const ValueKey('long-text-folded')), findsOneWidget);
      expect(find.text('Show more'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      final folded = t.getSize(find.byType(ExpandableText)).height;
      await t.tap(find.text('Show more'));
      await t.pumpAndSettle();
      expect(find.text('Show less'), findsOneWidget);
      expect(t.getSize(find.byType(ExpandableText)).height, greaterThan(folded));
      // Open, the text runs past the bottom of the test screen: scroll to the control first.
      await t.ensureVisible(find.text('Show less'));
      await t.pumpAndSettle();
      await t.tap(find.text('Show less'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-text-folded')), findsOneWidget);
      expect(t.getSize(find.byType(ExpandableText)).height, folded);
    });

    testWidgets('short text is left alone; a reply that streamed in stays open', (t) async {
      await t.pumpWidget(_host(const ExpandableText(text: 'Short answer.', child: Text('Short answer.'))));
      expect(find.text('Show more'), findsNothing);
      await t.pumpWidget(_host(SingleChildScrollView(child: ExpandableText(text: long, startOpen: true, child: Text(long)))));
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('reduced motion: it opens at once', (t) async {
      await t.pumpWidget(_host(SingleChildScrollView(child: ExpandableText(text: long, child: Text(long))), still: true));
      await t.tap(find.text('Show more'));
      await t.pump();
      expect(find.text('Show less'), findsOneWidget);
      expect(find.byKey(const ValueKey('long-text-open')), findsOneWidget);
      expect(find.byType(AnimatedSize), findsNothing);
    });
  });

  group('team head and tiny rings', () {
    Office withMembers(int n) {
      final ids = ['til', 'tin', 'tia', 'tix', 'tiy'].take(n).toList();
      return Office(id: 'face$n', name: 'Team $n', members: ids, chiefId: ids.first);
    }

    setUp(() {
      Bots.I.bots.addAll([Bot(id: 'tix', name: 'Xa', role: 'Writer', persona: ''), Bot(id: 'tiy', name: 'Ya', role: 'Coder', persona: '')]);
    });

    for (final n in [1, 2, 3, 4, 5]) {
      testWidgets('$n member(s): one circle, exactly a bot head\'s size, with ${n.clamp(1, 4)} tiny face(s)', (t) async {
        await t.pumpWidget(_host(Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            TeamFace(office: withMembers(n), size: 40),
            BotAvatar(key: const ValueKey('single'), bot: lead, size: 40),
          ]),
        )));
        final team = t.getSize(find.byKey(ValueKey('team-face-face$n')));
        expect(team, const Size(40, 40));
        expect(team, t.getSize(find.byKey(const ValueKey('single'))), reason: 'a team head is never bigger than a bot head');
        final minis = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('team-face-mini-'));
        expect(minis, n == 1 ? findsNothing : findsNWidgets(n.clamp(2, 4)));
        expect(find.byType(BotAvatar), findsNWidgets(n.clamp(1, 4) + 1));
      });
    }

    testWidgets('the team head sits in the same status ring as a bot head (same outer size)', (t) async {
      await t.pumpWidget(_host(Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          StatusRing(key: const ValueKey('r-team'), state: RingState.working, size: 40, child: TeamFace(office: withMembers(3), size: 40)),
          StatusRing(key: const ValueKey('r-bot'), state: RingState.idle, size: 40, child: BotAvatar(bot: lead, size: 40)),
        ]),
      ), still: true));
      expect(t.getSize(find.byKey(const ValueKey('r-team'))), t.getSize(find.byKey(const ValueKey('r-bot'))));
    });

    testWidgets('RTL: the first face sits on the right', (t) async {
      Future<double> firstX(TextDirection dir) async {
        await t.pumpWidget(_host(Center(child: TeamFace(office: withMembers(2), size: 60)), dir: dir));
        return t.getCenter(find.byKey(const ValueKey('team-face-mini-0'))).dx - t.getCenter(find.byKey(const ValueKey('team-face-face2'))).dx;
      }

      expect(await firstX(TextDirection.ltr), lessThan(0));
      expect(await firstX(TextDirection.rtl), greaterThan(0));
    });

    test('status rings are tiny: a hairline close to the face', () {
      expect(StatusRing.stroke, lessThanOrEqualTo(1.5));
      expect(StatusRing.outer(40) - 40, lessThanOrEqualTo(5.0));
    });
  });
}
