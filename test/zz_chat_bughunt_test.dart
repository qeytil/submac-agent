// Chat + output bug hunt (2026-10-25, main a891a83 / v1.13.102+172). PROBE TESTS: each test asserts the CORRECT
// behaviour, so it is RED on main and turns green once its bug is fixed. Report: docs in the PR / work/chatbugs/report.md.
//
// Run: flutter test test/zz_chat_bughunt_test.dart
import 'dart:async';
import 'dart:convert';

import 'package:agent/agent/core.dart';
import 'package:agent/agent/reply_schema.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/choices.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/chat/message_actions.dart';
import 'package:agent/widgets/message_view.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:agent/widgets/reply_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

// ------------------------------------------------------------------ helpers

class _Hooks extends CoreHooks {
  final committed = <Reply>[];
  bool stop = false;
  @override
  bool get cancelled => stop;
  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: const [
        {'role': 'user', 'content': 'hi'}
      ]);
  @override
  Future<void> commit(Reply r) async => committed.add(r);
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async => 'ok';
}

Widget _host(Widget child, {TextDirection dir = TextDirection.ltr, bool still = true}) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: const Size(400, 860), disableAnimations: still),
          child: Directionality(textDirection: dir, child: Scaffold(body: SingleChildScrollView(child: child))),
        ),
      ),
    );

String _chunk(Map<String, dynamic> delta, {String? finish}) =>
    'data: ${jsonEncode({'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]})}\n\n';

MockClient _sse(List<List<int>> parts) => MockClient.streaming((req, body) async {
      final ctrl = StreamController<List<int>>();
      () async {
        for (final p in parts) {
          await Future<void>.delayed(Duration.zero);
          ctrl.add(p);
        }
        await ctrl.close();
      }();
      return http.StreamedResponse(ctrl.stream, 200, headers: {'content-type': 'text/event-stream'});
    });

void main() {
  // ================================================================== chat flow

  group('CB-2 Stop mid-answer erases the words already shown', () {
    test('the turn committed after Stop keeps the text that had streamed', () async {
      final shown = StringBuffer(); // what the chat bubble showed (asst.content += delta in agent_stream.dart)
      final never = Completer<LlmResult>();
      final hooks = _Hooks();
      late AgentCore core;
      core = AgentCore(
        hooks: hooks,
        tools: const [],
        transport: (t) {
          shown.write('Here are the three cheapest flights to Nairobi: 1) ');
          return never.future; // still streaming
        },
      );
      final run = core.run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      hooks.stop = true; // AgentRun.stop(): cancelled = true, then core.stop()
      core.stop();
      final res = await run;
      expect(res.end, RunEnd.cancelled);
      // _MainHooks.commit sets asst.content = r.text and removes the message when it is empty and the run is
      // cancelled (agent_runner.dart commit()). So whatever reaches commit is what the user keeps.
      final kept = hooks.committed.isEmpty ? shown.toString() : hooks.committed.last.text;
      expect(kept, isNotEmpty, reason: 'Stop replaced the streamed words with an empty reply, so the bubble is deleted');
    });
  });

  group('CB-3 a tool name the app does not have kills the whole task', () {
    test('an unknown or namespaced tool name comes back to the model as an error result; the task goes on', () async {
      var calls = 0;
      final hooks = _Hooks();
      final core = AgentCore(hooks: hooks, tools: [
        {
          'type': 'function',
          'function': {'name': 'web_search', 'description': 'search', 'parameters': {'type': 'object', 'properties': {}}},
        }
      ], transport: (t) async {
        calls++;
        // gpt-oss (the current live route) is trained with built-in tools and is known to emit names like these.
        if (calls == 1) return LlmResult('', [ToolCall(id: 'c1', name: 'web_search<|channel|>commentary', arguments: jsonEncode({'q': 'x'}))], 'tool_calls');
        return LlmResult('Here is what I found.', [], 'stop');
      });
      final r = await core.run();
      // On main: RunEnd.failed with "GenkitException: Tool web_search<|channel|>commentary not found (Status: NOT_FOUND)".
      expect(r.end, RunEnd.done, reason: '${r.error}');
      expect(calls, 2);
    });
  });

  // ================================================================== provider responses

  group('LlmClient stream parsing (confirmed OK)', () {
    setUp(() => LlmClient.testHeaders = (source) async => {'Content-Type': 'application/json'});
    tearDown(() {
      LlmClient.testClient = http.Client();
      LlmClient.testHeaders = null;
    });
    test('a UTF-8 character and a JSON line split across chunks arrive whole', () async {
      final line = utf8.encode(_chunk({'content': 'Badda waa qurux — البحر جميل'}));
      final cut1 = 20, cut2 = line.length - 25; // inside the JSON, and inside an Arabic letter's bytes
      LlmClient.testClient = _sse([line.sublist(0, cut1), line.sublist(cut1, cut2), line.sublist(cut2), utf8.encode(_chunk({}, finish: 'stop'))]);
      final out = <String>[];
      final r = await LlmClient().streamChat(provider: Cloud.provider, model: Cloud.submac, messages: const [
        {'role': 'user', 'content': 'hi'}
      ], onDelta: out.add);
      expect(r.content, 'Badda waa qurux — البحر جميل');
      expect(r.finishReason, 'stop');
    });
  });

  // ================================================================== outputs

  group('CB-5 a newer identical choices card revives an answered one', () {
    test('the first card stays answered after the same options are offered again', () {
      const card = '```choices\n["Yes, book it", "Not now"]\n```';
      final msgs = [
        ChatMessage(id: 'a1', role: 'assistant', content: 'Book the 9 am flight?\n$card'),
        ChatMessage(id: 'u1', role: 'user', content: 'Yes, book it'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'Booked. Also book the hotel?\n$card'),
      ];
      // statusIn cannot tell which card it is drawing: both get the newest card's status.
      final (live, picked) = ChoicesCard.statusIn(msgs, const ['Yes, book it', 'Not now'], busy: false);
      // The first card must stay answered ("Yes, book it" ticked, not tappable). It comes back live and unticked,
      // and a tap on it sends "Yes, book it" again to the new question.
      expect((live, picked), (false, 'Yes, book it'), reason: 'old card is live again and lost its tick');
    }, skip: false);
  });

  group('CB-6 a code fence with an unusual language word swallows the rest of the reply', () {
    test('```c# … ``` followed by a table card still gives the table card', () {
      const reply = 'Here is the code:\n```c#\nConsole.WriteLine("hi");\n```\n\nPrices:\n```table\n{"columns":["Item","Price"],"rows":[["Tea","\$1"]]}\n```';
      final blocks = parseReply(reply);
      expect(blocks.where((b) => b.lang == 'table'), isNotEmpty,
          reason: 'the closing ``` of the c# block is read as an OPENING fence, so the table card becomes code text');
    });
  });

  group('CB-7 a card whose JSON is broken disappears without a trace', () {
    testWidgets('a finished reply with a malformed table still shows its content', (t) async {
      final m = ChatMessage(id: 'x', role: 'assistant', content: 'Your budget:\n```table\n{"columns":["Item","Cost"],"rows":[["Rent","\$300"],["Food","\$120"]\n```');
      await t.pumpWidget(_host(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Rent'), findsWidgets, reason: 'reply_blocks.dart draws SizedBox.shrink for a broken card');
    });
  });

  group('CB-8 Copy drops whole cards', () {
    testWidgets('Copy keeps the items of a ```list / ```links card', (t) async {
      String? copied;
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') {
          copied = (c.arguments as Map)['text'] as String?;
        }
        return null;
      });
      final m = ChatMessage(
          id: 'c1',
          role: 'assistant',
          content: 'Your packing list:\n```list\n{"title":"Packing","items":["Passport","Charger","Sunscreen"]}\n```\n'
              'Useful links:\n```links\n[{"title":"Visa portal","url":"https://evisa.go.ke"}]\n```');
      await t.pumpWidget(_host(AssistantMessageView(message: m, toolResults: const {}, showActions: true, isLast: true), still: false));
      await t.pump(const Duration(milliseconds: 600));
      await t.tap(find.textContaining('Your packing list'));
      await t.pump(const Duration(milliseconds: 600));
      await t.ensureVisible(find.descendant(of: find.byType(MessageActionRow), matching: find.byTooltip('Copy')).first);
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.descendant(of: find.byType(MessageActionRow), matching: find.byTooltip('Copy')).first);
      await t.pump(const Duration(milliseconds: 600));
      expect(copied, isNotNull);
      expect(copied, contains('Passport'), reason: 'message_view.dart _plain() replaces list/links/plan/sections/math… cards with ""');
      expect(copied, contains('evisa.go.ke'));
    });
  });

  group('CB-12 reduced motion: a reply that changes size throws in layout', () {
    testWidgets('a streaming reply growing under "Remove animations" lays out without errors', (t) async {
      final m = ChatMessage(id: 's', role: 'assistant', content: 'Short', streaming: true);
      await t.pumpWidget(_host(ReplyView(key: const ValueKey('r'), message: m)));
      await t.pump(const Duration(milliseconds: 200));
      m.content = 'Short answer, now much longer.\n\n${'More words arrive here. ' * 40}';
      m.streaming = false;
      await t.pumpWidget(_host(ReplyView(key: const ValueKey('r'), message: m)));
      await t.pump(const Duration(milliseconds: 200));
      // reply_blocks.dart wraps each block in AnimatedSize(duration: SubMotion.of(...)) = Duration.zero when animations
      // are off; a zero-length AnimatedSize re-dirties itself during layout (the repo's own rule: use SubSize).
      expect(t.takeException(), isNull);
    });
  });

  group('CB-9 one text direction for a whole reply', () {
    test('a Somali reply that opens with an Arabic greeting is still left-to-right', () {
      expect(textDirOf('السلام عليكم! Waan ku faraxsanahay inaan ku caawiyo. Maxaan kuu qabtaa maanta?'), TextDirection.ltr);
    });
    test('an Arabic reply that opens with a brand name is still right-to-left', () {
      expect(textDirOf('iPhone 16 هو أحدث هاتف من شركة آبل، ويأتي بكاميرا محسنة وبطارية أطول.'), TextDirection.rtl);
    });
  });

  group('CB-10 a reply cut by the length limit continues in a second bubble with a broken table', () {
    test('the continuation of a cut markdown table is neither repaired nor flagged', () {
      // First bubble (kept, cut off): "| Day | Plan |\n|---|---|\n| Mon | Beach |"; the continuation reply:
      const cont = '| Tue | Old town |\n| Wed | Museum |\n\nEnjoy the trip!';
      final fixed = ReplySchema.repair(cont);
      expect(fixed.contains('```table') || ReplySchema.problems(cont).isNotEmpty, isTrue,
          reason: 'rows without a header render as raw "| Tue | Old town |" text in a separate bubble');
    });
  });

  group('CB-11 small parsing slips', () {
    test('an answer with a thousands comma stays one answer', () {
      expect(Choices.parse('Under \$1,000'), ['Under \$1,000']);
    });
    test('a pipe inside inline code does not cut the table row (no cell is lost)', () {
      const md = '| Command | Meaning |\n|---|---|\n| `a \\| b` | pipe |';
      final out = ReplySchema.repair(md);
      final j = jsonDecode(RegExp(r'```table\n(.*)\n```').firstMatch(out)!.group(1)!) as Map;
      expect((j['rows'] as List).first, contains('pipe'), reason: 'the row is split on every | and the last cell is dropped');
    });
  });
}
