// Launch scenario suite (feat/launch-hardening). Representative launch prompts and model behaviours (mocked model:
// a fake ai-chat through LlmClient.testClient) go through the REAL task loop: send -> _runAgent -> Genkit core ->
// LlmClient. Every scenario asserts the run ends on its own (no crash, no hang), the user sees a reply or a readable
// error card, no raw exception text reaches the screen, and the scenario's own point (language, honesty, tool routing,
// graceful limits). The prompt matrix these come from is docs/use-case-matrix.md.
//
// Run: flutter test test/launch_scenarios_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/agent/core.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/agent_craft.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/reply_lang.dart';
import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------------ fake ai-chat

class _Docs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Docs(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

String _chunk(Map<String, dynamic> delta, {String? finish}) =>
    'data: ${jsonEncode({'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]})}\n\n';

/// One answer of the fake ai-chat.
class _Say {
  _Say.text(this.text, {this.finish = 'stop'})
      : calls = const [],
        status = 200,
        error = null,
        offline = false;
  _Say.calls(this.calls)
      : text = '',
        finish = 'tool_calls',
        status = 200,
        error = null,
        offline = false;
  _Say.status(this.status, this.error)
      : text = '',
        calls = const [],
        finish = 'stop',
        offline = false;
  _Say.offline()
      : text = '',
        calls = const [],
        finish = 'stop',
        status = 0,
        error = null,
        offline = true;
  final String text;
  final List<(String, Map<String, dynamic>)> calls;
  final String finish;
  final int status;
  final Map<String, dynamic>? error;
  final bool offline;
}

/// Streamed agent calls take the scripted answers in order (the last one repeats); other calls (title, summaries) get
/// a short plain answer.
class _FakeCloud {
  _FakeCloud(this.script);
  final List<_Say> script;
  final agentRaw = <String>[];

  /// The text of every message of agent request [i] (system, history, tool results, tail note), joined.
  String request(int i) => agentRaw[i];

  /// Tool names offered in agent request [i].
  List<String> toolsOf(int i) {
    final b = jsonDecode(agentRaw[i]) as Map<String, dynamic>;
    final t = b['tools'];
    if (t is! List) return const [];
    return [for (final d in t) '${(d as Map)['function']?['name'] ?? ''}'];
  }

  http.Client client() => MockClient.streaming((req, bodyStream) async {
        final raw = await bodyStream.bytesToString();
        final body = jsonDecode(raw) as Map<String, dynamic>;
        if (body['stream'] != true) {
          final plain = jsonEncode({
            'choices': [
              {'index': 0, 'message': {'role': 'assistant', 'content': 'Chat'}, 'finish_reason': 'stop'}
            ]
          });
          return http.StreamedResponse(Stream.value(utf8.encode(plain)), 200, headers: {'content-type': 'application/json'});
        }
        agentRaw.add(raw);
        final a = script[(agentRaw.length - 1).clamp(0, script.length - 1)];
        final n = agentRaw.length;
        if (a.offline) throw const SocketException('Failed host lookup: ai-chat');
        if (a.status != 200) {
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(a.error ?? {}))), a.status,
              headers: {'content-type': 'application/json'});
        }
        final out = StringBuffer(': ping\n\n');
        if (a.calls.isEmpty) {
          // Long texts arrive in several chunks, like a real stream.
          for (var i = 0; i < a.text.length; i += 4000) {
            out.write(_chunk({'content': a.text.substring(i, i + 4000 > a.text.length ? a.text.length : i + 4000)}));
          }
          out.write(_chunk({}, finish: a.finish));
        } else {
          if (a.text.isNotEmpty) out.write(_chunk({'content': a.text}));
          for (var i = 0; i < a.calls.length; i++) {
            out.write(_chunk({
              'tool_calls': [
                {
                  'index': i,
                  'id': 'call_${n}_$i',
                  'type': 'function',
                  'function': {'name': a.calls[i].$1, 'arguments': jsonEncode(a.calls[i].$2)}
                }
              ]
            }));
          }
          out.write(_chunk({}, finish: 'tool_calls'));
        }
        out.write('data: [DONE]\n\n');
        return http.StreamedResponse(Stream.value(utf8.encode(out.toString())), 200, headers: {'content-type': 'text/event-stream'});
      });
}

Future<void> _until(bool Function() ok, {int ms = 4000}) async {
  for (var i = 0; i < ms ~/ 10 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<AppState> _app(_FakeCloud cloud, Directory tmp) async {
  SharedPreferences.setMockInitialValues({});
  PathProviderPlatform.instance = _Docs(tmp.path);
  LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
  LlmClient.testClient = cloud.client();
  final s = AppState();
  s.repo.testUserId = 'u-launch-${tmp.path.hashCode}';
  await s.local.init();
  return s;
}

/// What the user can read in the chat: replies with words, and error cards.
List<String> _visible(AppState s) =>
    [for (final m in s.messages) if (m.role == 'assistant' && m.error == null && m.content.trim().isNotEmpty) m.content];
List<String> _errors(AppState s) => [for (final m in s.messages) if (m.role == 'assistant' && m.error != null) m.error!];

/// Raw internals that must never reach the screen.
final _raw = RegExp(r'GenkitException|NOT_FOUND|StateError|Null check|_TypeError|SocketException|Instance of|Stack trace|#0 ');

/// Sends [text] and waits until the task ends; fails if it never ends on its own.
Future<void> _run(AppState s, String text, {List<Attachment> files = const [], int ms = 15000}) async {
  unawaited(s.send(text, files));
  await _until(() => s.runs.isNotEmpty, ms: 3000);
  await _until(() => s.runs.isEmpty, ms: ms);
  final stuck = s.runs.isNotEmpty;
  for (final r in [...s.runs]) {
    s.stopRun(r);
  }
  expect(stuck, isFalse, reason: 'the task never ended on its own');
}

/// The common contract of every scenario: something readable, nothing raw.
void _contract(AppState s) {
  final seen = [..._visible(s), ..._errors(s)];
  expect(seen, isNotEmpty, reason: 'the user saw nothing');
  for (final t in seen) {
    expect(_raw.hasMatch(t), isFalse, reason: 'raw internals on screen: $t');
  }
}

const _soAsk = 'Fadlan ii sheeg sida loo sameeyo shaah fiican oo carruurta ay jeclaan karaan, waan ku mahadsanahay walaal.';
const _arAsk = 'من فضلك اشرح لي كيف أعد كوبًا جيدًا من الشاي بالحليب في البيت.';
const _enReply = 'To make a good cup of tea, boil fresh water, warm the pot, add one spoon of tea for each cup and let it '
    'steep for three to five minutes. Then pour it through a strainer and add milk or sugar if you like. It is simple and '
    'it tastes much better than a tea bag.';
const _soReply = 'Si aad u samayso shaah fiican, biyo cusub karkari, ku dar caleen shaah iyo xoogaa sonkor ah, kadibna u daa '
    'shan daqiiqo. Ka dib caano ku dar haddii aad rabto. Waa fudud yahay, carruurtuna way jeclaan doonaan, walaal.';
const _arReply = 'لتحضير كوب جيد من الشاي، اغلِ ماءً عذبًا، ثم أضف ملعقة شاي لكل كوب واتركه ينقع من ثلاث إلى خمس دقائق، '
    'ثم صبّه وأضف الحليب أو السكر حسب رغبتك. الطريقة سهلة وطعمها أفضل بكثير من أكياس الشاي الجاهزة.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('launch'));
  tearDown(() async {
    LlmClient.testClient = http.Client();
    LlmClient.testHeaders = null;
    AppLang.I.choice = 'phone';
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ================================================================== knowledge, writing, language
  group('Q&A, writing and language', () {
    test('S01 English question: one call, a plain answer, the English anchor at the end of the request', () async {
      final cloud = _FakeCloud([_Say.text(_enReply)]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Please explain how to make a good cup of tea at home for my family.');
      _contract(s);
      expect(cloud.agentRaw.length, 1);
      expect(_visible(s).last, _enReply);
      expect(cloud.request(0), contains('is in English. Write your reply to them in English'));
    });

    test('S02 Somali question answered in Somali: anchor says Somali, nothing is sent back', () async {
      final cloud = _FakeCloud([_Say.text(_soReply)]);
      final s = await _app(cloud, tmp);
      await _run(s, _soAsk);
      _contract(s);
      expect(cloud.agentRaw.length, 1);
      expect(cloud.request(0), contains('is in Somali. Write your reply to them in Somali'));
      expect(_visible(s).last, _soReply);
    });

    test('S03 Arabic question answered in English: sent back once, the Arabic rewrite is what the user sees', () async {
      final cloud = _FakeCloud([_Say.text(_enReply), _Say.text(_arReply)]);
      final s = await _app(cloud, tmp);
      await _run(s, _arAsk);
      _contract(s);
      expect(cloud.agentRaw.length, 2);
      expect(cloud.request(1), contains('# Reply in Arabic'));
      expect(_visible(s), [_arReply], reason: 'the English draft leaves the chat');
    });

    test('S04 Somali question, a model that keeps answering in English: one round only, then the reply stands', () async {
      final cloud = _FakeCloud([_Say.text(_enReply)]);
      final s = await _app(cloud, tmp);
      await _run(s, _soAsk);
      _contract(s);
      expect(cloud.agentRaw.length, 2, reason: 'never a loop of send-backs');
      expect(_visible(s).last, _enReply);
    });

    test('S05 "translate to English": an English answer to a Somali message is right, not sent back', () async {
      final cloud = _FakeCloud([_Say.text(_enReply)]);
      final s = await _app(cloud, tmp);
      await _run(s, 'U turjun af Ingiriisi qoraalkan: $_soAsk');
      _contract(s);
      expect(cloud.agentRaw.length, 1);
    });

    test('S06 mixed Somali + English message: Somali is detected (the user\'s own language)', () async {
      final cloud = _FakeCloud([_Say.text(_soReply)]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Walaal fadlan ii qor email gaaban oo aan u dirayo manager-ka, waxaan rabaa inaan fasax qaato berri.');
      _contract(s);
      expect(cloud.request(0), contains('in Somali'));
    });

    test('S07 a short follow-up ("haa") keeps the language of the message before it', () async {
      final cloud = _FakeCloud([_Say.text(_soReply), _Say.text(_soReply)]);
      final s = await _app(cloud, tmp);
      await _run(s, _soAsk);
      await _run(s, 'haa');
      _contract(s);
      expect(cloud.request(cloud.agentRaw.length - 1), contains('in Somali'));
    });

    test('S08 the main prompt carries the craft block (every kind of ask, and the cannot-do playbook)', () async {
      final cloud = _FakeCloud([_Say.text('Sure.')]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Write a short poem about the sea at night, four lines, calm mood, in simple words please.');
      _contract(s);
      expect(cloud.request(0), contains(AgentCraft.heading));
      expect(cloud.request(0), contains('When you cannot'));
    });
  });

  // ================================================================== honesty
  group('No fake claims', () {
    test('S09 English "I have sent it" with no tool: the truth gate sends it back once', () async {
      final cloud = _FakeCloud([
        _Say.text('I\'ve sent the message to Ali on WhatsApp.'),
        _Say.text('I could not send it from here. Here is the text to send: "I will be 10 minutes late."'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Tell Ali on WhatsApp that I will be 10 minutes late, he is waiting at the office.');
      _contract(s);
      expect(cloud.agentRaw.length, 2);
      expect(cloud.request(1), contains('That is not proven yet'));
      expect(_visible(s).join(' '), isNot(contains('I\'ve sent the message')));
    });

    test('S10 Somali "Fariinta waa la diray" with no tool: sent back', () async {
      final cloud = _FakeCloud([
        _Say.text('Fariinta waa la diray, walaal.'),
        _Say.text('Fariinta weli lama dirin. Waa kan qoraalka aad diri karto: "Waan soo daahayaa toban daqiiqo."'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Fadlan u dir Cali fariin WhatsApp ah oo dheh waan soo daahayaa toban daqiiqo walaal.');
      _contract(s);
      expect(cloud.request(1), contains('That is not proven yet'));
    });

    test('S11 Arabic "تم إرسال الرسالة" with no tool: sent back', () async {
      final cloud = _FakeCloud([
        _Say.text('تم إرسال الرسالة إلى علي.'),
        _Say.text('لم أرسل الرسالة بعد. هذا هو النص الذي يمكنك إرساله: "سأتأخر عشر دقائق."'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'أرسل رسالة إلى علي على واتساب وقل له إنني سأتأخر عشر دقائق من فضلك.');
      _contract(s);
      expect(cloud.request(1), contains('That is not proven yet'));
    });
  });

  // ================================================================== tools and limits
  group('Tool routing and missing capabilities', () {
    test('S12 maths: the model calls calculate, its real result is in the next request, then a plain answer', () async {
      final cloud = _FakeCloud([
        _Say.calls([('calculate', {'expression': '15% of 2340'})]),
        _Say.text('15% of 2,340 is 351.'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'What is 15% of 2340? I need the exact number for an invoice.');
      _contract(s);
      expect(cloud.agentRaw.length, 2);
      expect(cloud.request(1), contains('351'), reason: 'the tool really ran and its result reached the model');
      expect(_visible(s).last, contains('351'));
    });

    test('S13 a tool SubMac does not have: the model is pointed at the closest real one and recovers', () async {
      final cloud = _FakeCloud([
        _Say.calls([('math.calculator', {'expression': '2+2'})]),
        _Say.calls([('calculate', {'expression': '2+2'})]),
        _Say.text('2 + 2 = 4.'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Add 2 and 2 for me using the calculator please, I want to be sure.');
      _contract(s);
      expect(cloud.request(1), contains('Closest real tools'));
      expect(cloud.request(1), contains('calculate'));
      expect(_visible(s).last, '2 + 2 = 4.');
    });

    test('S14 unknown tools every time in a Somali chat: the stop reply is in Somali', () async {
      final cloud = _FakeCloud([
        _Say.calls([('zz_fly_drone', {'to': 'x'})]),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Fadlan diyaaradda yar ee drone-ka ah u dir suuqa oo ii keen khudaarta, waan ku mahadsanahay walaal.');
      _contract(s);
      expect(cloud.agentRaw.length, ToolNames.maxUnknownTurns);
      expect(_visible(s), [ToolNames.stopReplyFor('so')]);
    });

    test('S15 unknown tools every time in an Arabic chat: the stop reply is in Arabic', () async {
      final cloud = _FakeCloud([
        _Say.calls([('zz_fly_drone', {'to': 'x'})]),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'من فضلك أرسل الطائرة المسيرة إلى السوق واجلب لي الخضار اليوم.');
      _contract(s);
      expect(_visible(s), [ToolNames.stopReplyFor('ar')]);
    });

    test('S16 a planned multi-step task: todo then work then one final answer', () async {
      final cloud = _FakeCloud([
        _Say.calls([('todo', {'steps': ['Work out the total', 'Write the answer']})]),
        _Say.calls([('calculate', {'expression': '120*3 + 45'}), ('todo', {'done': [1]})]),
        _Say.calls([('todo', {'done': [2]})]),
        _Say.text('The total is 405.'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, '1. Work out 120*3 + 45\n2. Tell me the total\n3. Keep it short');
      _contract(s);
      expect(_visible(s).last, contains('405'));
    });

    test('S17 Somali announcement with nothing done is sent back to actually do it', () async {
      final cloud = _FakeCloud([
        _Say.text('Hadda waxaan xisaabinayaa wadarta.'),
        _Say.calls([('calculate', {'expression': '250*4'})]),
        _Say.text('Wadartu waa 1000.'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Fadlan ii xisaabi 250 jeer 4, waxaan u baahanahay wadarta saxda ah walaal.');
      _contract(s);
      // The first reply is a promise only; the loop asks for the work and the real answer follows.
      expect(cloud.agentRaw.length, greaterThanOrEqualTo(2));
      expect(_visible(s).last, contains('1000'));
    });
  });

  // ================================================================== outputs
  group('Long and rich outputs', () {
    test('S18 a very long code answer streams in many chunks and is kept whole', () async {
      final code = '```python\n${List.generate(1500, (i) => 'def f$i(x):\n    return x + $i\n').join()}```';
      final cloud = _FakeCloud([_Say.text('Here is the module:\n\n$code')]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Write a python module with 1500 small functions, each adding its own number.');
      _contract(s);
      expect(_visible(s).last.length, greaterThan(40000));
      expect(_visible(s).last, contains('def f1499'));
    });

    test('S19 a reply cut off by the length limit is continued into the same message', () async {
      final cloud = _FakeCloud([
        _Say.text('Part one of the story. The sea was calm and', finish: 'length'),
        _Say.text(' the night was quiet. The end.'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Write me a very short story about the sea at night.');
      _contract(s);
      expect(cloud.request(1), contains('cut off by the length limit'));
      expect(_visible(s).length, 1, reason: 'one bubble');
      expect(_visible(s).single, contains('The sea was calm and the night was quiet'));
    });

    test('S20 a markdown table is turned into a table card by the app (no model call)', () async {
      final cloud = _FakeCloud([_Say.text('| Fruit | Price |\n|---|---|\n| Apple | 1 |\n| Mango | 2 |')]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Compare the price of apples and mangoes in a small table.');
      _contract(s);
      expect(cloud.agentRaw.length, 1);
      expect(_visible(s).last, contains('```table'));
    });

    test('S21 maths in LaTeX and an Arabic reply with code come through untouched', () async {
      const reply = 'مساحة الدائرة:\n\n\$\$\nA = \\pi r^2\n\$\$\n\n```python\nimport math\nprint(math.pi * 2 ** 2)\n```';
      final cloud = _FakeCloud([_Say.text(reply)]);
      final s = await _app(cloud, tmp);
      await _run(s, 'ما هي مساحة دائرة نصف قطرها ٢ سم؟ اكتب الكود أيضًا من فضلك.');
      _contract(s);
      expect(cloud.agentRaw.length, 1, reason: 'Arabic prose + code is not a language mismatch');
      expect(_visible(s).last, contains('\\pi r^2'));
    });
  });

  // ================================================================== failures
  group('Errors, limits and network', () {
    test('S22 a blank model reply is nudged, then the real answer shows', () async {
      final cloud = _FakeCloud([_Say.text(''), _Say.text('Here you go: the capital of Somalia is Mogadishu.')]);
      final s = await _app(cloud, tmp);
      await _run(s, 'What is the capital of Somalia and roughly how many people live there?');
      _contract(s);
      expect(_visible(s).last, contains('Mogadishu'));
    });

    test('S23 a model that only ever answers blank ends with a readable card, never a hang', () async {
      final cloud = _FakeCloud([_Say.text('')]);
      final s = await _app(cloud, tmp);
      await _run(s, 'What is the capital of Somalia and roughly how many people live there?');
      _contract(s);
      expect(cloud.agentRaw.length, lessThanOrEqualTo(4));
    });

    test('S24 daily allowance used up (429 limit_daily): an error card, no retry storm', () async {
      final cloud = _FakeCloud([
        _Say.status(429, {
          'error': {'code': 'limit_daily', 'message': 'You have used today\'s replies.'},
        }),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Plan a three day trip to Hargeisa for me with a daily budget please.');
      _contract(s);
      expect(_errors(s), isNotEmpty);
      expect(cloud.agentRaw.length, lessThanOrEqualTo(2));
    });

    test('S25 signed out on the server (401): an error card, the task ends', () async {
      final cloud = _FakeCloud([
        _Say.status(401, {
          'error': {'code': 'auth', 'message': 'Not signed in'},
        }),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Summarise the main causes of inflation in two short paragraphs please.');
      _contract(s);
      expect(_errors(s), isNotEmpty);
    });

    test('S26 the phone is offline: the task ends with a readable card (no raw SocketException)', () async {
      final cloud = _FakeCloud([_Say.offline()]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Summarise the main causes of inflation in two short paragraphs please.', ms: 60000);
      _contract(s);
      expect(_errors(s), isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('S27 a too-long request (413 too_long) is folded or answered plainly, never re-sent forever', () async {
      final cloud = _FakeCloud([
        _Say.status(413, {
          'error': {'code': 'too_long', 'message': 'The request is too long for the model.'},
        }),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'Explain this: ${'word ' * 3000}');
      _contract(s);
      expect(cloud.agentRaw.length, lessThanOrEqualTo(4));
    });
  });

  // ================================================================== user behaviour
  group('Stop, repeat, attach', () {
    test('S28 Stop in the middle of a task: the run ends, no error card', () async {
      final gate = Completer<void>();
      final script = [
        _Say.calls([('calculate', {'expression': '1+1'})]),
        _Say.text('Never reached.'),
      ];
      final cloud = _FakeCloud(script);
      final base = cloud.client();
      LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
      final s = await _app(cloud, tmp);
      // The second model call waits until the test lets it go (after Stop).
      LlmClient.testClient = MockClient.streaming((req, body) async {
        if (cloud.agentRaw.isNotEmpty) await gate.future;
        final r = http.Request(req.method, req.url)..headers.addAll(req.headers);
        r.bodyBytes = await body.toBytes();
        return base.send(r);
      });
      unawaited(s.send('Work out 1+1 and then tell me a long story about it.', const []));
      await _until(() => cloud.agentRaw.isNotEmpty && s.runs.isNotEmpty, ms: 4000);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      for (final r in [...s.runs]) {
        s.stopRun(r);
      }
      gate.complete();
      await _until(() => s.runs.isEmpty, ms: 4000);
      expect(s.runs, isEmpty);
      final errs = _errors(s).where((e) => _raw.hasMatch(e));
      expect(errs, isEmpty);
      expect(_visible(s).join(' '), isNot(contains('Never reached.')));
    });

    test('S29 two messages sent at once: both are answered, one task at a time, no crash', () async {
      final cloud = _FakeCloud([_Say.text('First answer.'), _Say.text('Second answer.'), _Say.text('Third answer.')]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('What is the tallest mountain in Africa, and how tall is it?', const []));
      unawaited(s.send('And the longest river in Africa, how long is it?', const []));
      await _until(() => s.runs.isNotEmpty, ms: 3000);
      await _until(() => s.runs.isEmpty && cloud.agentRaw.length >= 2, ms: 15000);
      await _until(() => s.runs.isEmpty, ms: 15000);
      expect(s.runs, isEmpty);
      _contract(s);
      final users = s.messages.where((m) => m.role == 'user').length;
      expect(users, 2);
      expect(_visible(s), isNotEmpty);
    });

    test('S30 an attached Word file: the request says to read it with read_document', () async {
      final cloud = _FakeCloud([_Say.text('I will read it first.'), _Say.text('Summary: it is a short report.')]);
      final s = await _app(cloud, tmp);
      final doc = Attachment(
          name: 'report.docx',
          mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          bytes: Uint8List.fromList(utf8.encode('PK fake docx')));
      await _run(s, 'Summarise this report in three bullet points please.', files: [doc]);
      _contract(s);
      expect(cloud.request(0), contains('read_document'));
    });

    test('S31 an attached voice note: the request says it cannot be heard, so nothing is made up', () async {
      final cloud = _FakeCloud([_Say.text('I can\'t listen to recordings here. Could you type the main points?')]);
      final s = await _app(cloud, tmp);
      final note = Attachment(name: 'note.m4a', mime: 'audio/mp4', bytes: Uint8List.fromList(List.filled(64, 1)));
      await _run(s, 'What does this voice note say? Write it out for me please.', files: [note]);
      _contract(s);
      expect(cloud.request(0), contains('cannot hear or watch'));
    });

    test('S32 a greeting takes the quick lane: no tools, an instant reply', () async {
      final cloud = _FakeCloud([_Say.text('Hi! What can I do for you today?')]);
      final s = await _app(cloud, tmp);
      await _run(s, 'hi');
      _contract(s);
      expect(cloud.agentRaw.length, 1);
      expect(cloud.toolsOf(0), isEmpty);
    });

    test('S33 an ambiguous ask gets an answer or one question with choices, and the language anchor', () async {
      final cloud = _FakeCloud([
        _Say.text('Happy to help with your business. What do you want to start with?\n\n```choices\n["A business plan","More customers","Bookkeeping"]\n```'),
      ]);
      final s = await _app(cloud, tmp);
      await _run(s, 'help me with my business');
      _contract(s);
      expect(cloud.agentRaw.length, 1);
      expect(_visible(s).last, contains('```choices'));
    });
  });

  // ================================================================== sanity of the anchor helper itself
  test('S34 the anchor never appears for app-made wakes (no user language to follow)', () {
    expect(ReplyLang.ofChat(const []), isNull);
  });
}
