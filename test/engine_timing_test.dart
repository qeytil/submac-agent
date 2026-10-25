// Dev 1 engine (PLAN 1.3 / 1.4 / 1.6): the app's time limits, Contract A error events and heartbeat, the one model,
// the context window from the server, one run per chat, photos sent once and shrunk to 2048 px.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:agent/models.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/context_window.dart';
import 'package:agent/services/image_once.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/photo_prep.dart';
import 'package:agent/services/quick_lane.dart';
import 'package:agent/services/send_gate.dart';
import 'package:agent/services/stream_policy.dart';

String chunk(String text) => 'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': {'content': text}}
      ]
    })}\n\n';
const done = 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}\n\ndata: [DONE]\n\n';

/// A fake SubMac server: each step is sent after its delay (an empty text sends nothing, just waits).
MockClient sse(List<(int, String)> steps, {int status = 200, void Function(http.BaseRequest r)? seen, Map<String, String> headers = const {}}) =>
    MockClient.streaming((req, body) async {
      seen?.call(req);
      final ctrl = StreamController<List<int>>();
      () async {
        for (final (ms, text) in steps) {
          await Future<void>.delayed(Duration(milliseconds: ms));
          if (ctrl.isClosed) return;
          if (text.isNotEmpty) ctrl.add(utf8.encode(text));
        }
        await ctrl.close();
      }();
      return http.StreamedResponse(ctrl.stream, status, headers: {'content-type': 'text/event-stream', ...headers});
    });

Future<LlmResult> call({void Function()? onPing, String? effort, List<String>? out}) => LlmClient().streamChat(
      provider: Cloud.provider,
      model: Cloud.submac,
      messages: const [
        {'role': 'user', 'content': 'hi'}
      ],
      onDelta: (d) => out?.add(d),
      onPing: onPing,
      effort: effort,
    );

void main() {
  setUp(() {
    LlmClient.testHeaders = (source) async => {'Content-Type': 'application/json', 'x-submac-source': source};
    StreamPolicy.headers = const Duration(seconds: 10);
    StreamPolicy.silence = const Duration(seconds: 30);
    StreamPolicy.firstWord = const Duration(seconds: 45);
    ContextWindow.reset();
  });

  group('one model', () {
    test('the app only knows the name submac', () {
      expect(Cloud.submac, 'submac');
      expect(Cloud.provider.defaultModel, 'submac');
    });

    test('lanes stay (laneFor), the dead reply cap is gone', () {
      expect(QuickLane.laneFor('hi'), QuickLane.quick);
      expect(QuickLane.laneFor('search hotels in Mogadishu'), QuickLane.full);
    });
  });

  group('time limits (PLAN 1.3, app row)', () {
    test('the numbers are the plan\'s', () {
      expect(StreamPolicy.headers, const Duration(seconds: 10));
      expect(StreamPolicy.silence, const Duration(seconds: 30));
      expect(StreamPolicy.firstWord, const Duration(seconds: 45));
      expect(StreamPolicy.autoRetries, 1);
      expect(StreamPolicy.dropContinues, 2);
      expect(StreamPolicy.busyText, 'SubMac is busy. Tap to try again.');
      expect(LlmClient.idleTimeout, const Duration(seconds: 30));
    });

    test('one quiet retry, only before any output, only for something that may pass', () {
      expect(StreamPolicy.retryBeforeOutput(retriesDone: 0, gotOutput: false, retryable: true), isTrue);
      expect(StreamPolicy.retryBeforeOutput(retriesDone: 1, gotOutput: false, retryable: true), isFalse);
      expect(StreamPolicy.retryBeforeOutput(retriesDone: 0, gotOutput: true, retryable: true), isFalse);
      expect(StreamPolicy.retryBeforeOutput(retriesDone: 0, gotOutput: false, retryable: false), isFalse);
    });

    test('the retry waits for Retry-After only while it still fits in the 45 s', () {
      expect(StreamPolicy.retryWait(elapsed: Duration.zero), const Duration(seconds: 2));
      expect(StreamPolicy.retryWait(retryAfter: const Duration(seconds: 15), elapsed: const Duration(seconds: 5)), const Duration(seconds: 15));
      expect(StreamPolicy.retryWait(retryAfter: const Duration(seconds: 30), elapsed: Duration.zero), StreamPolicy.maxRetryWait);
      expect(StreamPolicy.retryWait(retryAfter: const Duration(seconds: 20), elapsed: const Duration(seconds: 30)), isNull);
      expect(StreamPolicy.retryWait(elapsed: const Duration(seconds: 44)), isNull);
    });

    test('"continue" after a drop: at most twice per step', () {
      expect(StreamPolicy.canReissueAfterDrop(0), isTrue);
      expect(StreamPolicy.canReissueAfterDrop(1), isTrue);
      expect(StreamPolicy.canReissueAfterDrop(2), isFalse);
    });

    test('first word watch: fires when nothing came, never after a word', () async {
      var late = 0;
      final w = FirstWordWatch(() => late++, limit: const Duration(milliseconds: 60))..start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(late, 1);
      expect(w.fired, isTrue);
      expect(w.gotWord, isFalse);

      var late2 = 0;
      final w2 = FirstWordWatch(() => late2++, limit: const Duration(milliseconds: 60))..start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      w2.heard();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(late2, 0);
      expect(w2.fired, isFalse);
      expect(w2.gotWord, isTrue);
      w2.stop();
    });

    test('no response headers within the limit -> busy (retryable), not a hang', () async {
      StreamPolicy.headers = const Duration(milliseconds: 100);
      LlmClient.testClient = MockClient.streaming((req, body) => Completer<http.StreamedResponse>().future);
      final sw = Stopwatch()..start();
      try {
        await call();
        fail('should time out');
      } on LlmException catch (e) {
        expect(e.code, 'busy');
        expect(e.isRetryable, isTrue);
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('30 s of silence (scaled) -> the line counts as dropped', () async {
      StreamPolicy.silence = const Duration(milliseconds: 120);
      LlmClient.testClient = sse([(0, ': ping\n\n'), (0, chunk('Hel')), (400, chunk('lo'))]);
      final out = <String>[];
      try {
        await call(out: out);
        fail('should drop');
      } on LlmException catch (e) {
        expect(e.message, contains('connection dropped'));
        expect(e.isRetryable, isTrue);
      }
      expect(out, ['Hel']);
    });

    test('the server\'s : ping keeps a slow first word alive and is not shown', () async {
      StreamPolicy.silence = const Duration(milliseconds: 150);
      var pings = 0;
      LlmClient.testClient = sse([
        (0, ': ping\n\n'),
        for (var i = 0; i < 5; i++) (80, ': ping\n\n'),
        (50, chunk('Salaam')),
        (0, done),
      ]);
      final out = <String>[];
      final r = await call(onPing: () => pings++, out: out);
      expect(r.content, 'Salaam');
      expect(out, ['Salaam']);
      expect(pings, 6);
    });
  });

  group('Contract A error events', () {
    Future<LlmException> errorFor(String body) async {
      LlmClient.testClient = sse([(0, ': ping\n\n'), (0, body)]);
      try {
        await call();
      } on LlmException catch (e) {
        return e;
      }
      fail('no error');
    }

    test('busy with Retry-After -> retryable, waits the server\'s time', () async {
      final e = await errorFor('event: error\ndata: {"error":{"code":"busy","message":"SubMac is busy right now. Please try again in a moment.","retry_after":21}}\n\n');
      expect(e.code, 'busy');
      expect(e.status, 503);
      expect(e.isRetryable, isTrue);
      expect(e.retryAfter, const Duration(seconds: 21));
      expect(e.message, 'SubMac is busy right now. Please try again in a moment.');
    });

    test('limits, no plan and blocked are final (no retry)', () async {
      for (final code in ['limit_daily', 'limit_total', 'no_plan', 'blocked']) {
        final e = await errorFor('event: error\ndata: {"error":{"code":"$code","message":"x"}}\n\n');
        expect(e.code, code);
        expect(e.isFinal, isTrue, reason: code);
        expect(e.isRetryable, isFalse, reason: code);
      }
    });

    test('too_long -> compact, never retried as is', () async {
      final e = await errorFor('event: error\ndata: {"error":{"code":"too_long","message":"This is too long to send in one go. Start a new chat or send less at once."}}\n\n');
      expect(e.isTooLong, isTrue);
      expect(e.isRetryable, isFalse);
    });

    test('server -> retryable; unknown codes and missing text get fixed friendly words', () async {
      final e = await errorFor('event: error\ndata: {"error":{"code":"server"}}\n\n');
      expect(e.isRetryable, isTrue);
      expect(e.message, StreamPolicy.textFor('server'));
      final odd = await errorFor('event: error\ndata: {"error":{"code":"weird_thing","message":""}}\n\n');
      expect(odd.code, 'server');
      expect(odd.message, isNot(contains('weird')));
    });

    test('an old-style error chunk (numeric code) is a dropped model', () async {
      final e = await errorFor('data: {"error":{"code":502,"message":"upstream said no"}}\n\n');
      expect(e.status, 502);
      expect(e.isRetryable, isTrue);
      expect(e.message, isNot(contains('upstream')));
    });
  });

  group('requests', () {
    test('always model submac; effort hint only when asked', () async {
      http.BaseRequest? got;
      LlmClient.testClient = sse([(0, chunk('ok')), (0, done)], seen: (r) => got = r);
      await call(effort: 'low');
      expect(got!.headers['x-submac-effort'], 'low');
      expect(jsonDecode((got as http.Request).body)['model'], 'submac');
      LlmClient.testClient = sse([(0, chunk('ok')), (0, done)], seen: (r) => got = r);
      await call();
      expect(got!.headers.containsKey('x-submac-effort'), isFalse);
    });

    test('x-submac-window from the server sets the compaction window', () async {
      expect(ContextWindow.tokens, 128000, reason: 'every route has at least 128k (PLAN 1.1)');
      LlmClient.testClient = sse([(0, chunk('ok')), (0, done)], headers: {'x-submac-window': '200000'});
      await call();
      expect(ContextWindow.tokens, 200000);
      expect(ContextWindow.compactAt(), 150000);
    });

    test('window readings are sanity-checked', () {
      expect(ContextWindow.note('abc'), isFalse);
      expect(ContextWindow.note('0'), isFalse);
      ContextWindow.note('1000');
      expect(ContextWindow.tokens, ContextWindow.min);
      ContextWindow.note('99999999');
      expect(ContextWindow.tokens, ContextWindow.max);
      ContextWindow.reset();
      expect(ContextWindow.compactAt(), 96000);
    });
  });

  group('one run per chat (PLAN 1.4)', () {
    // The same steps send() takes, with the slow part (saving, uploading a photo) in the middle.
    Future<void> send(SendGate gate, String? conv, List<String> started, String text, Duration upload) async {
      final open = gate.openOn(conv);
      final claim = open == null ? gate.claim(conv) : null; // before any await
      if (open != null) {
        await open.ready;
        return; // joins the task the first message starts
      }
      await Future<void>.delayed(upload);
      claim!.open(conv ?? 'c1');
      started.add(text);
    }

    test('a message sent during a photo upload joins the same task (one answer)', () async {
      final gate = SendGate();
      final started = <String>[];
      final a = send(gate, 'c1', started, 'photo', const Duration(milliseconds: 80));
      final b = send(gate, 'c1', started, 'and this?', Duration.zero);
      await Future.wait([a, b]);
      expect(started, ['photo']);
      expect(gate.openOn('c1'), isNull, reason: 'released once the first message is saved');
    });

    test('a new chat: the claim also covers the id it gets', () async {
      final gate = SendGate();
      final c = gate.claim(null);
      expect(gate.openOn(null), same(c));
      c.alias('c9');
      expect(gate.openOn('c9'), same(c));
      c.open('c9');
      expect(await c.ready, 'c9');
      expect(gate.openOn(null), isNull);
      expect(gate.openOn('c9'), isNull);
    });

    test('a failed save releases the chat (null), so the next message can try again', () async {
      final gate = SendGate();
      final c = gate.claim('c2');
      c.open(null);
      expect(await c.ready, isNull);
      expect(gate.openOn('c2'), isNull);
    });

    test('other chats are not blocked', () {
      final gate = SendGate();
      gate.claim('a');
      expect(gate.openOn('b'), isNull);
    });
  });

  group('photos (PLAN 1.4)', () {
    test('each picture goes once; later steps get a one-line note', () {
      final once = ImageOnce();
      final k = ImageOnce.keyOf('m1', 0);
      once.begin('c');
      expect(once.take('c', k), isTrue); // step 1 carries it
      once.commit('c');
      once.begin('c');
      expect(once.take('c', k), isFalse); // step 2: note
      expect(ImageOnce.note('IMG_1.jpg', '/ws/uploads/IMG_1.jpg'), contains('IMG_1.jpg'));
      expect(ImageOnce.note('a.png', null).split('\n').length, 1);
    });

    test('a step that failed sends the picture again; regenerate does too', () {
      final once = ImageOnce();
      final k = ImageOnce.keyOf('m1', 0);
      once.begin('c');
      expect(once.take('c', k), isTrue);
      once.begin('c'); // the step failed and was built again: nothing committed
      expect(once.take('c', k), isTrue);
      once.commit('c');
      expect(once.wasSent('c', k), isTrue);
      once.unsend('c', 'm1');
      expect(once.take('c', k), isTrue);
      expect(once.wasSent('other', k), isFalse);
    });

    test('a big gallery photo is shrunk to 2048 px JPEG', () {
      final big = img.Image(width: 3000, height: 2000);
      img.fill(big, color: img.ColorRgb8(30, 120, 200));
      final png = Uint8List.fromList(img.encodePng(big));
      final out = PhotoPrep.shrink(png)!;
      final back = img.decodeJpg(out)!;
      expect(back.width, 2048);
      expect(back.height, 1365);
      expect(PhotoPrep.jpgName('IMG_1.png'), 'IMG_1.jpg');
    });

    test('tall photos keep their shape; small ones are left alone', () {
      final tall = img.Image(width: 1000, height: 4096);
      final out = PhotoPrep.shrink(Uint8List.fromList(img.encodeJpg(tall)))!;
      final back = img.decodeJpg(out)!;
      expect(back.height, 2048);
      expect(back.width, 500);
      final small = img.Image(width: 800, height: 600);
      expect(PhotoPrep.shrink(Uint8List.fromList(img.encodeJpg(small))), isNull);
      expect(PhotoPrep.shrink(Uint8List.fromList([1, 2, 3])), isNull);
      expect(PhotoPrep.canShrink('image/heic'), isFalse);
      expect(PhotoPrep.canShrink('image/png'), isTrue);
    });
  });

  test('send() claims the chat before its first await (no second agent during an upload)', () {
    final src = File('lib/state/chat_controller.dart').readAsStringSync();
    final body = src.substring(src.indexOf('Future<void> send('));
    expect(body.indexOf('_sendGate.claim('), greaterThan(0));
    expect(body.indexOf('_sendGate.claim('), lessThan(body.indexOf('await ')));
  });

  test('no model aliases or per-model routing left in the app', () {
    final bad = RegExp(r"submac-(smart|fast|think|vision|lite|somali)|roleRef\(|_withThinking|_quickRoute|_seeRef|liftIf|_backupFor|_noToolModels|_liteModels|AutoRouter");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(bad.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    expect(File('lib/services/auto_router.dart').existsSync(), isFalse);
  });

  test('the attachment model keeps what send() swaps in', () {
    final a = Attachment(name: 'x.png', mime: 'image/png', bytes: Uint8List(4));
    expect(a.isImage, isTrue);
  });
}
