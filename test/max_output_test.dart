import 'dart:io';

import 'package:agent/services/byok.dart';
import 'package:agent/services/byok_opencode.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/opencode.dart';
import 'package:agent/services/output_limits.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> ev(String type, Map<String, dynamic> props) => {'type': type, 'properties': props};

Map<String, dynamic> asst(String id, {String? finish, int created = 0}) => ev('message.updated', {
      'info': {
        'id': id,
        'sessionID': 's1',
        'role': 'assistant',
        'time': {'created': created},
        if (finish != null) 'finish': finish,
      }
    });

Map<String, dynamic> text(String id, String msg, String t) =>
    ev('message.part.updated', {'part': {'id': id, 'sessionID': 's1', 'messageID': msg, 'type': 'text', 'text': t}});

Map<String, dynamic> idle() => ev('session.status', {'sessionID': 's1', 'status': {'type': 'idle'}});
Map<String, dynamic> busy() => ev('session.status', {'sessionID': 's1', 'status': {'type': 'busy'}});

ByokProvider prov(List<ByokModel> models, {ByokKind kind = ByokKind.openai}) =>
    ByokProvider(id: 'byok-abcd1234', kind: kind, name: 'Mine', baseUrl: 'https://api.example.com/v1', models: models);

void main() {
  group('output limits per model', () {
    test('the provider\'s own figure wins, capped at the ceiling', () {
      expect(OutputLimits.forModel('anything', known: 50000), 50000);
      expect(OutputLimits.forModel('anything', known: 999999), OutputLimits.ceiling);
      expect(OutputLimits.forModel('gpt-5', known: 0), 128000, reason: '0 is no figure');
    });

    test('known families get their published maximum', () {
      expect(OutputLimits.forModel('gpt-5'), 128000);
      expect(OutputLimits.forModel('gpt-5-mini-2025-08-07'), 128000);
      expect(OutputLimits.forModel('gpt-5-chat-latest'), 16384);
      expect(OutputLimits.forModel('gpt-4.1-mini'), 32768);
      expect(OutputLimits.forModel('gpt-4o-2024-08-06'), 16384);
      expect(OutputLimits.forModel('o3'), 100000);
      expect(OutputLimits.forModel('o4-mini'), 100000);
      expect(OutputLimits.forModel('o1-mini'), 65536);
      expect(OutputLimits.forModel('claude-opus-4-20250514'), 32000);
      expect(OutputLimits.forModel('claude-opus-4-1'), 32000);
      expect(OutputLimits.forModel('claude-opus-4-5-20251101'), 64000);
      expect(OutputLimits.forModel('claude-sonnet-4-5'), 64000);
      expect(OutputLimits.forModel('anthropic/claude-3.7-sonnet'), 64000);
      expect(OutputLimits.forModel('claude-3-5-sonnet-latest'), 8192);
      expect(OutputLimits.forModel('claude-3-haiku-20240307'), 4096);
      expect(OutputLimits.forModel('gemini-2.5-pro'), 65536);
      expect(OutputLimits.forModel('models/gemini-2.0-flash'), 8192);
      expect(OutputLimits.forModel('deepseek-chat'), 8192);
      expect(OutputLimits.forModel('deepseek-reasoner'), 64000);
      expect(OutputLimits.forModel('openai/gpt-oss-120b'), 32768);
    });

    test('an unknown model gets the fallback, never the old flat 8,192', () {
      expect(OutputLimits.forModel('my-local-llama'), OutputLimits.fallback);
      expect(OutputLimits.fallback, greaterThan(8192));
      expect(ByokOpencode.defaultOutput, OutputLimits.fallback);
    });

    test('opencode\'s ceiling covers every configured model and Telesia\'s own', () {
      expect(OutputLimits.engineMax([]), OutputLimits.telesia);
      expect(OutputLimits.engineMax([8192]), OutputLimits.telesia);
      expect(OutputLimits.engineMax([128000]), 128000);
      expect(OutputLimits.engineMax([999999]), OutputLimits.ceiling);
      expect(OutputLimits.telesia, greaterThan(32000), reason: 'opencode\'s default ceiling was the cap');
    });

    test('ocStart carries Telesia\'s model limit and opencode\'s ceiling', () {
      final a = OpenCodeEngine.startLimits(0);
      expect(a['modelOutput'], OutputLimits.telesia);
      expect(a['outputTokenMax'], OutputLimits.telesia);
      expect(OpenCodeEngine.startLimits(128000)['outputTokenMax'], 128000);
    });
  });

  group('the user\'s own providers in opencode\'s config', () {
    String? key(ByokProvider _) => 'sk-test';

    test('a model with no listed limit gets its family maximum, not 8,192', () {
      final p = prov([ByokModel(id: 'gpt-4.1', context: 1047576)]);
      final cfg = ByokOpencode.providers([p], key);
      expect(cfg['byok-abcd1234']['models']['gpt-4.1']['limit']['output'], 32768);
    });

    test('the provider\'s listed output limit is kept', () {
      final p = prov([ByokModel(id: 'x-model', context: 200000, output: 64000)]);
      final cfg = ByokOpencode.providers([p], key);
      expect(cfg['byok-abcd1234']['models']['x-model']['limit'], {'context': 200000, 'output': 64000});
    });

    test('the output limit is never more than half the window (opencode would compact on every step)', () {
      final p = prov([ByokModel(id: 'gpt-5')]); // OpenAI lists no window: the 128,000 default applies
      final cfg = ByokOpencode.providers([p], key);
      expect(cfg['byok-abcd1234']['models']['gpt-5']['limit'], {'context': 128000, 'output': 64000});
      final small = prov([ByokModel(id: 'tiny', context: 8192, output: 8192)]);
      expect(ByokOpencode.providers([small], key)['byok-abcd1234']['models']['tiny']['limit']['output'], 4096);
    });

    test('the largest limit of the usable models raises opencode\'s ceiling', () {
      final p = prov([ByokModel(id: 'gpt-5', context: 400000), ByokModel(id: 'gpt-4o', context: 128000)]);
      expect(ByokOpencode.maxOutput([p], key), 128000);
      expect(ByokOpencode.maxOutput([p], (_) => null), 0, reason: 'no key: not usable');
    });
  });

  group('a reply cut for length is continued (opencode turns)', () {
    test('finish "length" on the newest assistant message marks the turn cut', () {
      final t = OpenCodeTurn('s1');
      t.apply(asst('a1', created: 1));
      t.apply(text('p1', 'a1', 'Part one of a long'));
      expect(t.cutOff, isFalse);
      t.apply(asst('a1', created: 1, finish: 'length'));
      t.apply(idle());
      expect(t.lastFinish, 'length');
      expect(t.cutOff, isTrue);
      expect(t.shouldContinue, isTrue);
      expect(t.leftCut, isFalse);
    });

    test('a normal end is not cut', () {
      final t = OpenCodeTurn('s1');
      t.apply(asst('a1', created: 1));
      t.apply(text('p1', 'a1', 'Done.'));
      t.apply(asst('a1', created: 1, finish: 'stop'));
      t.apply(idle());
      expect(t.cutOff, isFalse);
      expect(t.shouldContinue, isFalse);
    });

    test('the continuation is glued onto the cut text, as one answer', () {
      final t = OpenCodeTurn('s1');
      t.apply(asst('a1', created: 1));
      t.apply(text('p1', 'a1', 'The quick brown fox jum'));
      t.apply(asst('a1', created: 1, finish: 'length'));
      t.apply(idle());
      expect(t.shouldContinue, isTrue);
      t.beginContinue();
      expect(t.done, isFalse);
      expect(t.cutOff, isFalse, reason: 'the cut message stops counting once continue is sent');
      expect(t.shouldContinue, isFalse);
      // The continue prompt is the user's message: skipped.
      t.apply(ev('message.updated', {'info': {'id': 'u2', 'sessionID': 's1', 'role': 'user'}}));
      t.apply(text('pu', 'u2', ReplyContinuation.prompt));
      expect(t.parts.containsKey('pu'), isFalse);
      t.apply(busy());
      t.apply(asst('a2', created: 2));
      t.apply(ev('message.part.delta', {'sessionID': 's1', 'messageID': 'a2', 'partID': 'p2', 'field': 'text', 'delta': 'ps over the lazy dog.'}));
      expect(t.parts['p2']!.continues, 'p1');
      expect(t.rootOf(t.parts['p2']!).id, 'p1');
      expect(t.chainText(t.parts['p1']!), 'The quick brown fox jumps over the lazy dog.');
      t.apply(asst('a2', created: 2, finish: 'stop'));
      t.apply(idle());
      expect(t.answer, 'The quick brown fox jumps over the lazy dog.');
      expect(t.cutOff, isFalse);
      expect(t.continues, 1);
    });

    test('a step after the continue starts a new paragraph (no glue)', () {
      final t = OpenCodeTurn('s1');
      t.apply(asst('a1', created: 1));
      t.apply(text('p1', 'a1', 'Writing the file'));
      t.apply(asst('a1', created: 1, finish: 'length'));
      t.apply(idle());
      t.beginContinue();
      t.apply(asst('a2', created: 2));
      t.apply(ev('message.part.updated', {
        'part': {'id': 't1', 'sessionID': 's1', 'messageID': 'a2', 'type': 'tool', 'tool': 'write', 'callID': 'c1',
          'state': {'status': 'completed', 'input': {}, 'output': 'ok'}},
      }));
      t.apply(text('p2', 'a2', 'Saved it.'));
      expect(t.parts['p2']!.continues, isNull);
      expect(t.answer, 'Saved it.');
    });

    test('a cut reply after a tool step keeps the tool step and joins only its own text', () {
      final t = OpenCodeTurn('s1');
      t.apply(asst('a1', created: 1));
      t.apply(ev('message.part.updated', {
        'part': {'id': 't1', 'sessionID': 's1', 'messageID': 'a1', 'type': 'tool', 'tool': 'bash', 'callID': 'c1',
          'state': {'status': 'completed', 'input': {}, 'output': 'x'}},
      }));
      t.apply(asst('a2', created: 2));
      t.apply(text('p1', 'a2', 'Here is the report: part A'));
      t.apply(asst('a2', created: 2, finish: 'length'));
      t.apply(idle());
      t.beginContinue();
      t.apply(asst('a3', created: 3));
      t.apply(text('p2', 'a3', ', part B.'));
      t.apply(asst('a3', created: 3, finish: 'stop'));
      t.apply(idle());
      expect(t.answer, 'Here is the report: part A, part B.');
    });

    test('after the last continuation a still-cut reply is left cut and says so', () {
      final t = OpenCodeTurn('s1');
      var created = 1;
      t.apply(asst('a$created', created: created));
      t.apply(text('p$created', 'a$created', 'x'));
      t.apply(asst('a$created', created: created, finish: 'length'));
      t.apply(idle());
      for (var i = 0; i < ReplyContinuation.maxContinues; i++) {
        expect(t.shouldContinue, isTrue);
        t.beginContinue();
        created++;
        t.apply(asst('a$created', created: created));
        t.apply(text('p$created', 'a$created', 'y'));
        t.apply(asst('a$created', created: created, finish: 'length'));
        t.apply(idle());
      }
      expect(t.shouldContinue, isFalse);
      expect(t.leftCut, isTrue);
      expect(t.answer, 'x${'y' * ReplyContinuation.maxContinues}');
    });

    test('an error is never continued', () {
      final t = OpenCodeTurn('s1');
      t.apply(asst('a1', created: 1, finish: 'length'));
      t.error = 'boom';
      t.done = true;
      expect(t.shouldContinue, isFalse);
      expect(t.leftCut, isFalse);
    });

    test('a snapshot read after a lost stream carries the finish too', () {
      final t = OpenCodeTurn('s1');
      final since = DateTime.fromMillisecondsSinceEpoch(1000);
      t.applySnapshot([
        {
          'info': {'id': 'a1', 'sessionID': 's1', 'role': 'assistant', 'time': {'created': 2000}, 'finish': 'length'},
          'parts': [
            {'id': 'p1', 'sessionID': 's1', 'messageID': 'a1', 'type': 'text', 'text': 'cut here'}
          ],
        }
      ], since: since);
      t.done = true;
      expect(t.shouldContinue, isTrue);
    });
  });

  group('plain calls', () {
    test('finish reasons that mean "out of room"', () {
      expect(ReplyContinuation.isCut('length'), isTrue);
      expect(ReplyContinuation.isCut('max_tokens'), isTrue);
      expect(ReplyContinuation.isCut('stop'), isFalse);
      expect(ReplyContinuation.isCut(null), isFalse);
    });

    test('the next piece is asked for with the words so far as the model\'s own turn', () {
      final base = [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'write a lot'},
      ];
      final m = ReplyContinuation.messages(base, 'so far');
      expect(m.length, 4);
      expect(m[2], {'role': 'assistant', 'content': 'so far'});
      expect(m[3]['role'], 'user');
      expect(m[3]['content'], ReplyContinuation.prompt);
      expect(base.length, 2, reason: 'the original list is untouched');
    });

    test('pieces join as written; a repeated tail is dropped once', () {
      expect(ReplyContinuation.join('Hello wor', 'ld'), 'Hello world');
      expect(ReplyContinuation.join('', 'abc'), 'abc');
      expect(ReplyContinuation.join('abc', ''), 'abc');
      const tail = 'the last sentence that was written before the cut';
      expect(ReplyContinuation.join('Intro. $tail', '$tail and more.'), 'Intro. $tail and more.');
    });

    test('a non-streamed answer gives its text and finish reason', () {
      final r = LlmClient.answerOf({
        'choices': [
          {'message': {'content': 'partial'}, 'finish_reason': 'length'}
        ]
      });
      expect(r.text, 'partial');
      expect(r.finish, 'length');
      expect(LlmClient.answerOf({'choices': []}).text, '');
      expect(LlmClient.answerOf(null).finish, isNull);
    });
  });

  group('wiring', () {
    test('the engine config gives Telesia\'s models a limit and raises opencode\'s ceiling', () {
      final kt = File('android_native/OpenCode.kt').readAsStringSync();
      expect(kt, contains('env["OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX"] = "\$outputTokenMax"'));
      expect(kt, contains('model.put("limit", org.json.JSONObject().put("context", 0).put("output", modelOutput))'));
      final ch = File('android_native/OcChannel.kt').readAsStringSync();
      expect(ch, contains('call.argument<Any>("modelOutput")'));
      expect(ch, contains('call.argument<Any>("outputTokenMax")'));
      expect(File('lib/services/opencode.dart').readAsStringSync(), contains('...startLimits(ByokOpencode.maxOutputOf(ByokStore.I)),'));
    });

    test('chat and team turns continue a cut reply; a team continues in the bot engine now', () {
      final r = File('lib/state/agent_runner.dart').readAsStringSync();
      // The owner's chat: its opencode session is continued.
      expect(RegExp(r'turn\.beginContinue\(\);').allMatches(r).length, 1);
      expect(RegExp(r"oc\.prompt\((session|s), \[\{'type': 'text', 'text': ReplyContinuation\.prompt\}\]").allMatches(r).length, 1);
      expect(r, contains('turn.leftCut'));
      // A bot's and a team's turn (owner 2026-11-07): the bot engine continues a cut reply itself (maxContinues).
      expect(r, contains('BotAgentEngine('));
    });

    test('team answers and bot consults are no longer capped at 1,200-2,000 tokens, and continue', () {
      final b = File('lib/state/bots_controller.dart').readAsStringSync();
      expect(b, contains('{int maxTokens = OutputLimits.answer}'));
      expect(RegExp(r'continues: ReplyContinuation\.maxContinues').allMatches(b).length, 2);
      final t = File('lib/services/team_run.dart').readAsStringSync();
      expect(t, isNot(contains('maxTokens: 2000')));
      expect(t, isNot(contains('maxTokens: 1500')));
    });
  });
}
