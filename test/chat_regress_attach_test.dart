// PR-8 fix/attachments-vision: CB-23 (a photo follow-up reaches a route that can see; a photo turn's 1M window header is
// not adopted), CB-26 (attachment size limits, photos shrunk to 2048 px) and CB-31 (photos not re-sent after a restart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agent/models.dart';
import 'package:agent/services/attach_limits.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/context_window.dart';
import 'package:agent/services/image_once.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/photo_prep.dart';
import 'package:agent/services/vision_follow_up.dart';

Uint8List photo({int w = 1600, int h = 1200}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(200, 40, 40));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

ChatMessage user(String id, String text, {Uint8List? image}) => ChatMessage(
      id: id,
      role: 'user',
      content: text,
      attachments: image == null ? null : [Attachment(name: 'IMG_1.jpg', mime: 'image/jpeg', bytes: image)],
    );

ChatMessage reply(String id, String text) => ChatMessage(id: id, role: 'assistant', content: text);

/// The image parts a built request carries.
List<String> imagesIn(List<Map<String, dynamic>> payload) => [
      for (final m in payload)
        if (m['content'] is List)
          for (final p in m['content'] as List)
            if (p is Map && p['type'] == 'image_url') (p['image_url'] as Map)['url'] as String,
    ];

class MemStore implements ImageOnceStore {
  Map<String, List<String>> data = {};
  int writes = 0;
  @override
  Future<Map<String, List<String>>> read() async => {for (final e in data.entries) e.key: List.of(e.value)};
  @override
  Future<void> write(Map<String, List<String>> sent) async {
    writes++;
    data = {for (final e in sent.entries) e.key: List.of(e.value)};
  }
}

MockClient sse({Map<String, String> headers = const {}}) => MockClient.streaming((req, body) async {
      final ctrl = StreamController<List<int>>();
      () async {
        ctrl.add(utf8.encode('data: ${jsonEncode({
              'choices': [
                {'index': 0, 'delta': {'content': 'red'}}
              ]
            })}\n\n'
            'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'));
        await ctrl.close();
      }();
      return http.StreamedResponse(ctrl.stream, 200, headers: {'content-type': 'text/event-stream', ...headers});
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
  });
  setUp(ContextWindow.reset);

  group('CB-23 a follow-up about a photo still carries it', () {


    test('words that refer to a picture, in English, Somali and Arabic', () {
      expect(VisionFollowUp.refersToImage('what is in the picture?'), isTrue);
      expect(VisionFollowUp.refersToImage('Sawirka maxaa ku jira?'), isTrue);
      expect(VisionFollowUp.refersToImage('ماذا في الصورة؟'), isTrue);
      expect(VisionFollowUp.refersToImage('what is the weather in Mogadishu?'), isFalse);
    });

    test('only the latest photo goes again, and bot wakes do not count as turns', () {
      final a = user('x1', 'one', image: photo());
      final b = user('x2', 'two', image: photo());
      final wake = user('w', '\u2063wake\u2063 routine');
      expect(VisionFollowUp.again([a, b, user('x3', 'hm')]), {ImageOnce.keyOf('x2', 0)});
      expect(VisionFollowUp.again([b]), isEmpty, reason: 'its own turn');
      final many = [b, user('1', 'a'), user('2', 'b'), user('3', 'c'), wake];
      expect(VisionFollowUp.again(many, countsAsTurn: (m) => !m.content.startsWith('\u2063wake\u2063')), {ImageOnce.keyOf('x2', 0)});
      expect(VisionFollowUp.again(many), isEmpty);
    });

    test('a 1M window header after a photo turn does not raise the window', () {
      expect(ContextWindow.note('128000'), isFalse);
      expect(ContextWindow.note('1000000', filtered: true), isFalse);
      expect(ContextWindow.tokens, 128000);
      // A smaller reading from such a request still counts.
      ContextWindow.note('100000', filtered: true);
      expect(ContextWindow.tokens, 100000);
    });

    test('through the client: a photo request\'s 1M header is ignored, a plain one is taken', () async {
      LlmClient.testHeaders = (source) async => {'Content-Type': 'application/json'};
      LlmClient.testClient = sse(headers: {'x-telesia-window': '1000000'});
      await LlmClient().streamChat(
        provider: Cloud.provider,
        model: Cloud.telesia,
        messages: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'colour?'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,AAAA'}
              },
            ]
          }
        ],
        onDelta: (_) {},
      );
      expect(ContextWindow.tokens, 128000, reason: 'a vision turn reported 1M (CB-23)');
      LlmClient.testClient = sse(headers: {'x-telesia-window': '200000'});
      await LlmClient().streamChat(
        provider: Cloud.provider,
        model: Cloud.telesia,
        messages: const [
          {'role': 'user', 'content': 'hi'}
        ],
        onDelta: (_) {},
      );
      expect(ContextWindow.tokens, 200000);
    });

    test('the window is the smallest reading of the last 10 minutes', () {
      final t0 = DateTime(2026, 10, 25, 12);
      ContextWindow.note('128000', now: t0);
      ContextWindow.note('400000', now: t0.add(const Duration(minutes: 3)));
      expect(ContextWindow.tokens, 128000);
      ContextWindow.note('400000', now: t0.add(const Duration(minutes: 11)));
      expect(ContextWindow.tokens, 400000);
    });
  });

  group('CB-26 attachment size limits', () {
    test('a 30 MB file is refused with a notice', () {
      final c = AttachLimits.check([30 * AttachLimits.mb]);
      expect(c.ok, isEmpty);
      expect(c.tooBig, [0]);
      expect(AttachLimits.notice(c, lang: 'en'), contains('20 MB'));
      expect(AttachLimits.notice(c, lang: 'so'), contains('20 MB'));
      expect(AttachLimits.notice(c, lang: 'ar'), contains('20'));
      expect(AttachLimits.notice(c, lang: 'xx'), AttachLimits.notice(c, lang: 'en'));
    });

    test('25 MB per message: what does not fit is left out, the rest stays', () {
      final c = AttachLimits.check([15 * AttachLimits.mb, 15 * AttachLimits.mb, 5 * AttachLimits.mb]);
      expect(c.ok, [0, 2]);
      expect(c.overTotal, [1]);
      expect(AttachLimits.notice(c, lang: 'en'), contains('25 MB'));
      expect(AttachLimits.check([6 * AttachLimits.mb], already: 20 * AttachLimits.mb).overTotal, [0]);
      expect(AttachLimits.notice(AttachLimits.check([1, 2, 3])), isNull);
    });

    test('a 6000 px photo is shrunk to a 2048 px long edge, JPEG 80', () {
      final out = PhotoPrep.shrink(photo(w: 6000, h: 4000))!;
      final back = img.decodeJpg(out)!;
      expect(back.width, 2048);
      expect(back.height, 1365);
      expect(PhotoPrep.quality, 80);
    });

    test('the composer checks sizes before reading files whole', () {
      final src = File('lib/widgets/composer.dart').readAsStringSync();
      final pick = src.substring(src.indexOf('Future<void> _pick('), src.indexOf('int get _attachedBytes'));
      expect(pick, contains('withReadStream: true'));
      expect(pick, contains('withData: false'));
      expect(pick.indexOf('AttachLimits.check('), lessThan(pick.indexOf('_readPicked(')));
      final share = src.substring(src.indexOf('Future<void> _takeShare('), src.indexOf('Future<XFile?> _shoot('));
      expect(share.indexOf('AttachLimits.check('), lessThan(share.indexOf('readAsBytes()')));
      final cam = src.substring(src.indexOf('Future<void> _camera('), src.indexOf('Future<void> _scanText('));
      expect(cam.indexOf('AttachLimits.check('), lessThan(cam.indexOf('readAsBytes()')));
    });
  });

  group('CB-31 photos are not re-sent after a restart', () {
    test('a reloaded ImageOnce does not re-take sent keys', () async {
      final store = MemStore();
      final k = ImageOnce.keyOf('m1', 0);
      final before = ImageOnce(store: store);
      await before.ready;
      before.begin('c');
      expect(before.take('c', k), isTrue);
      before.commit('c');
      await Future<void>.delayed(Duration.zero);
      final after = ImageOnce(store: store); // the app restarted
      await after.ready;
      after.begin('c');
      expect(after.take('c', k), isFalse, reason: 'every photo in the history went out again after a restart (CB-31)');
      expect(after.wasSent('c', k), isTrue);
    });

    test('an unanswered step is not kept; regenerate and forget are', () async {
      final store = MemStore();
      final k = ImageOnce.keyOf('m1', 0);
      final a = ImageOnce(store: store);
      await a.ready;
      a.begin('c');
      a.take('c', k); // never answered
      await Future<void>.delayed(Duration.zero);
      expect(store.data, isEmpty);
      a.commit('c');
      a.unsend('c', 'm1');
      await Future<void>.delayed(Duration.zero);
      final b = ImageOnce(store: store);
      await b.ready;
      expect(b.take('c', k), isTrue, reason: 'regenerate lets it go once more, after a restart too');
      b.commit('c');
      b.forget('c');
      await Future<void>.delayed(Duration.zero);
      expect(store.data.containsKey('c'), isFalse);
    });

    test('kept in the phone\'s preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final k = ImageOnce.keyOf('m9', 1);
      final a = ImageOnce();
      await a.ready;
      a.begin('c9');
      a.take('c9', k);
      a.commit('c9');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final p = await SharedPreferences.getInstance();
      expect(p.getString(PrefsImageOnceStore.key), contains(k));
      final b = ImageOnce();
      await b.ready;
      expect(b.wasSent('c9', k), isTrue);
    });

    test('a commit before the kept keys finished loading is not lost', () async {
      final store = MemStore()..data = {'old': ['o#0']};
      final a = ImageOnce(store: store);
      a.begin('c');
      a.take('c', 'n#0');
      a.commit('c');
      await a.ready;
      expect(a.wasSent('c', 'n#0'), isTrue);
      expect(a.wasSent('old', 'o#0'), isTrue);
    });
  });
}
