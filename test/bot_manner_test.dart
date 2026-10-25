// Every bot speaks like a calm, competent colleague and follows instructions faithfully (owner, 2026-10-24).
import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';

final _emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F000}-\u{1F2FF}]', unicode: true);
final _childish = RegExp(r"\b(yay|woo+hoo|awesome sauce|super ?duper|bestie|buddy|teehee|lol|omg|let's gooo*)\b", caseSensitive: false);

/// Problems with the tone of a fixed text the app writes or sends.
List<String> toneProblems(String t) => [
      if (_emoji.hasMatch(t)) 'emoji',
      if (t.contains('!!')) 'double exclamation',
      if (_childish.hasMatch(t)) 'childish word: ${_childish.firstMatch(t)!.group(0)}',
    ];

void main() {
  test('the checker itself catches bad tone', () {
    expect(toneProblems('Done!! 🎉'), isNotEmpty);
    expect(toneProblems('Yay, all set buddy'), isNotEmpty);
    expect(toneProblems('Done. The report is in the team folder.'), isEmpty);
  });

  test('the manner block says how to speak and how to follow instructions', () {
    const b = BotManner.block;
    for (final must in [
      'calm, competent colleague',
      'first person',
      'No hype, no emoji',
      'no childish',
      'no exclamation marks',
      'Address the owner respectfully',
      'name the teammate',
      'what was done, the result, and what comes next',
      'In Somali',
      'Do exactly what was asked: the scope, format, language, length',
      'Never ignore or override a direct instruction, and never argue',
      'ask one short, polite question instead of guessing',
      'say so kindly in one line and offer the closest thing you can do',
    ]) {
      expect(b, contains(must), reason: must);
    }
    expect(toneProblems(b), isEmpty);
  });

  test('every fixed team phrase (English and Somali) is plain and calm: no emoji, no exclamation marks', () {
    for (final p in BotManner.phrases) {
      expect(toneProblems(p), isEmpty, reason: p);
      expect(p.contains('!'), isFalse, reason: p);
    }
  });

  test('every bot prompt carries the manner; members follow the lead, the lead follows the owner', () {
    final lead = Bot(id: 'bml', name: 'Hodan', role: 'Manager', persona: 'Calm.');
    final mate = Bot(id: 'bmm', name: 'Nova', role: 'Researcher', persona: 'Curious.');
    Bots.I.bots.addAll([lead, mate]);
    addTearDown(() => Bots.I.bots.removeWhere((b) => b.id.startsWith('bm')));
    for (final b in [lead, mate, ...BotTemplates.all, BotTemplates.chief]) {
      expect(Bots.I.stablePromptOf(b), contains(BotManner.block), reason: b.name);
      expect(Bots.I.quickPromptOf(b), contains(BotManner.block), reason: b.name);
    }
    final o = Office(id: 'bmo', name: 'Coffee', members: ['bml', 'bmm'], chiefId: 'bml');
    expect(Offices.I.teamStablePromptOf(o, lead), contains(BotManner.leadLine));
    expect(Offices.I.teamStablePromptOf(o, mate), contains(BotManner.memberLine('Hodan')));
    expect(BotManner.member('Hodan'), contains('exactly as asked'));
    expect(BotManner.member('Hodan'), contains('owner\'s words above all'));
    expect(BotManner.lead, contains('get the team going'));
    expect(BotManner.lead, contains('only for a real judgment call'));
  });

  test('built-in bots: names, roles, personas and missions are adult and calm', () {
    for (final b in [...BotTemplates.all, BotTemplates.chief]) {
      for (final t in [b.name, b.role, b.persona, b.mission]) {
        expect(toneProblems(t), isEmpty, reason: '${b.name}: $t');
        expect(t.contains('!'), isFalse, reason: '${b.name}: $t');
      }
    }
  });

  test('the lead\'s plan message is calm in English and Somali', () {
    final nova = Bot(id: 'bmn', name: 'Nova', role: 'Researcher', persona: '');
    for (final so in [false, true]) {
      final t = TeamRun.planText(TeamPlan(job: 'x', parts: [(bot: nova, ask: 'Find prices')], somali: so), reply: 'You want prices.');
      expect(toneProblems(t), isEmpty);
      expect(t.contains('!'), isFalse);
      expect(t, contains('- Nova: Find prices'));
    }
  });

  test('bots work the Grok way: a task runs end to end; an opening or a greeting only suggests', () {
    const b = BotManner.block;
    expect(b, contains('carry it through end to end'));
    expect(b, contains('suggest one or two concrete first tasks'));
    expect(b, contains('```choices'));
    expect(toneProblems(b), isEmpty);
  });
}
