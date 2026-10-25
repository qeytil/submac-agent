import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/services/ai_keys.dart';
import 'package:agent/services/ai_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(64, 7)]);
final mp4 = Uint8List.fromList([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, ...List.filled(64, 1)]);
final wav = Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45, ...List.filled(64, 0)]);

const key = 'sk-test1234567890abcdefGHIJKLmnop';

void main() {
  late Directory dir;
  late MemoryAiStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ai_models_test');
    store = MemoryAiStore();
    AiKeys.store = store;
    AiKeys.clearSessionForTests();
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AiModels make(Future<http.Response> Function(http.Request r) h, {List<String>? log}) => AiModels(
        store: store,
        client: () => MockClient((r) {
          log?.add('${r.method} ${r.url}');
          return h(r);
        }),
        sleep: (_) async {},
        mediaDir: () async => dir.path,
      );

  group('keys pasted in chat', () {
    test('a known key shape is hidden and can be looked up on the phone', () async {
      final r = AiKeys.redact('use base url https://api.openai.com/v1 key $key model gpt-image-1');
      expect(r.count, 1);
      expect(r.text, isNot(contains(key)));
      expect(r.text, contains('https://api.openai.com/v1'));
      final ref = AiKeys.refPattern.firstMatch(r.text)!.group(0)!;
      expect(await AiKeys.resolve(ref), key);
      expect(store.data.values, contains(key), reason: 'kept in encrypted storage, not only in memory');
    });

    test('a labelled unknown key is hidden; normal text is left alone', () {
      final r = AiKeys.redact('api key: Zx81kQp02LmN44trYb, then make a cat');
      expect(r.count, 1);
      expect(r.text, isNot(contains('Zx81kQp02LmN44trYb')));
      final plain = AiKeys.redact('The key point is to keep it simple, see https://example.com/a1b2c3d4e5f6g7h8');
      expect(plain.count, 0);
      expect(plain.text, 'The key point is to keep it simple, see https://example.com/a1b2c3d4e5f6g7h8');
    });

    test('hiding twice changes nothing more', () {
      final once = AiKeys.redact('key $key').text;
      expect(AiKeys.redact(once).text, once);
    });

    test('fal and Replicate keys', () {
      const fal = '0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b:00112233445566778899aabbccddeeff';
      const rep = 'r8_AbCdEfGhIjKlMnOpQrStUvWx1234';
      final r = AiKeys.redact('fal $fal and replicate $rep');
      expect(r.count, 2);
      expect(r.text, isNot(contains(fal)));
      expect(r.text, isNot(contains(rep)));
    });
  });

  group('request building', () {
    test('OpenAI-compatible image request', () {
      final r = AiModels.build(
          task: 'image', baseUrl: 'api.example.com/v1/', key: key, model: 'flux-pro', prompt: 'a red fox', size: '1024x1024', payload: {'quality': 'high'});
      expect(r.method, 'POST');
      expect(r.uri.toString(), 'https://api.example.com/v1/images/generations');
      expect(r.headers['Authorization'], 'Bearer $key');
      expect(r.json, {'model': 'flux-pro', 'prompt': 'a red fox', 'size': '1024x1024', 'quality': 'high'});
    });

    test('chat, speech and embeddings use the standard paths', () {
      expect(AiModels.build(task: 'text', baseUrl: 'https://x.ai/v1', key: key, model: 'm', prompt: 'hi').uri.path, '/v1/chat/completions');
      final s = AiModels.build(task: 'speech', baseUrl: 'https://x.ai/v1', key: key, model: 'tts-1', prompt: 'hello');
      expect(s.uri.path, '/v1/audio/speech');
      expect(s.json!['response_format'], 'wav');
      expect(s.json!['voice'], 'alloy');
      expect(AiModels.build(task: 'embed', baseUrl: 'https://x.ai/v1', key: key, model: 'e', prompt: 'x').uri.path, '/v1/embeddings');
    });

    test('custom endpoint with its own header and no scheme', () {
      final r = AiModels.build(
          task: 'custom',
          baseUrl: 'https://api.elevenlabs.io',
          key: 'abc',
          path: '/v1/text-to-speech/voice1',
          payload: {'text': 'hi'},
          authHeader: 'xi-api-key',
          authScheme: '');
      expect(r.uri.toString(), 'https://api.elevenlabs.io/v1/text-to-speech/voice1');
      expect(r.headers['xi-api-key'], 'abc');
      expect(r.headers.containsKey('Authorization'), isFalse);
      expect(r.json, {'text': 'hi'});
    });

    test('key as a URL parameter (Google style)', () {
      final r = AiModels.build(task: 'custom', baseUrl: 'https://g.example.com/v1beta', key: 'AIzaK', path: 'models/x:predict', authQuery: 'key');
      expect(r.uri.queryParameters['key'], 'AIzaK');
      expect(r.headers.containsKey('Authorization'), isFalse);
    });

    test('custom without a path is refused plainly', () {
      expect(() => AiModels.build(task: 'custom', baseUrl: 'https://a.b', key: ''), throwsA(isA<AiCallError>()));
    });

    test('a final reply is not a job', () {
      final req = AiModels.build(task: 'image', baseUrl: 'https://a.b/v1', key: '');
      expect(AiModels.jobOf({'data': [{'url': 'https://cdn/x.png'}]}, req), isNull);
      expect(AiModels.jobOf({'id': '1', 'status': 'succeeded', 'output': 'https://cdn/x.png'}, req), isNull);
    });
  });

  group('calls', () {
    test('image with base64 reply becomes an image card; the key never shows', () async {
      final ai = make((r) async {
        expect(r.headers['Authorization'], 'Bearer $key');
        return http.Response(jsonEncode({'data': [{'b64_json': base64Encode(png)}]}), 200, headers: {'content-type': 'application/json'});
      });
      final ref = AiKeys.refPattern.firstMatch(AiKeys.redact('key $key').text)!.group(0)!;
      final out = await ai.execute('ai_call', {'task': 'image', 'base_url': 'https://api.example.com/v1', 'api_key': ref, 'model': 'img-1', 'prompt': 'a fox'}, callId: 'c1');
      expect(out, startsWith('MEDIA_CARD '));
      expect(out, isNot(contains(key)));
      final card = AiModels.readCard(out)!;
      expect(card['kind'], 'image');
      expect(card['model'], 'img-1');
      expect(File((card['files'] as List).first as String).readAsBytesSync().sublist(0, 4), png.sublist(0, 4));
      expect(AiModels.progress.value.containsKey('c1'), isFalse);
    });

    test('Replicate-style async job is polled until done, then downloaded', () async {
      var polls = 0;
      final log = <String>[];
      final ai = make((r) async {
        if (r.method == 'POST') {
          return http.Response(jsonEncode({'id': 'p1', 'status': 'starting', 'urls': {'get': 'https://api.replicate.com/v1/predictions/p1'}}), 201);
        }
        if (r.url.path.endsWith('/p1')) {
          polls++;
          return http.Response(
              jsonEncode(polls < 3
                  ? {'id': 'p1', 'status': 'processing', 'input': {'image': 'https://cdn.example.com/input.png'}}
                  : {'id': 'p1', 'status': 'succeeded', 'output': ['https://replicate.delivery/out-0.webp', 'https://replicate.delivery/out-1.webp']}),
              200);
        }
        if (r.url.host == 'replicate.delivery') {
          expect(r.headers.containsKey('Authorization'), isFalse, reason: 'the key never goes to another host');
          return http.Response.bytes(png, 200, headers: {'content-type': 'image/webp'});
        }
        return http.Response('nope', 404);
      }, log: log);
      final out = await ai.execute('ai_call', {
        'task': 'custom',
        'base_url': 'https://api.replicate.com/v1',
        'api_key': key,
        'path': '/models/black-forest-labs/flux-schnell/predictions',
        'payload': {'input': {'prompt': 'a fox'}},
      });
      final card = AiModels.readCard(out)!;
      expect(card['kind'], 'images');
      expect((card['files'] as List).length, 2);
      expect(polls, 3);
      expect(log.where((l) => l.contains('input.png')), isEmpty, reason: 'an input picture is not an output');
    });

    test('fal queue: status_url, then response_url', () async {
      var n = 0;
      final ai = make((r) async {
        if (r.method == 'POST') {
          expect(r.headers['Authorization'], 'Key falkey');
          return http.Response(
              jsonEncode({
                'request_id': 'q1',
                'status': 'IN_QUEUE',
                'status_url': 'https://queue.fal.run/fal-ai/flux/requests/q1/status',
                'response_url': 'https://queue.fal.run/fal-ai/flux/requests/q1'
              }),
              200);
        }
        if (r.url.path.endsWith('/status')) {
          n++;
          return http.Response(jsonEncode({'status': n < 2 ? 'IN_PROGRESS' : 'COMPLETED'}), 200);
        }
        if (r.url.path.endsWith('/q1')) {
          return http.Response(jsonEncode({'images': [{'url': 'https://v3.fal.media/files/a.png', 'content_type': 'image/png'}]}), 200);
        }
        return http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
      });
      final out = await ai.execute('ai_call', {
        'task': 'custom',
        'base_url': 'https://queue.fal.run',
        'api_key': 'falkey',
        'auth_scheme': 'Key',
        'path': '/fal-ai/flux',
        'payload': {'prompt': 'a fox'},
      });
      expect(AiModels.readCard(out)!['kind'], 'image');
    });

    test('OpenAI-style video: create, poll, download content', () async {
      var n = 0;
      final ai = make((r) async {
        if (r.method == 'POST') return http.Response(jsonEncode({'id': 'video_1', 'object': 'video', 'status': 'queued'}), 200);
        if (r.url.path == '/v1/videos/video_1') {
          n++;
          return http.Response(jsonEncode({'id': 'video_1', 'object': 'video', 'status': n < 2 ? 'in_progress' : 'completed', 'progress': 50}), 200);
        }
        if (r.url.path == '/v1/videos/video_1/content') {
          expect(r.headers['Authorization'], 'Bearer $key');
          return http.Response.bytes(mp4, 200, headers: {'content-type': 'video/mp4'});
        }
        return http.Response('no', 404);
      });
      final out = await ai.execute('ai_call', {'task': 'video', 'base_url': 'https://api.openai.com/v1', 'api_key': key, 'model': 'sora-2', 'prompt': 'waves'});
      final card = AiModels.readCard(out)!;
      expect(card['kind'], 'video');
      expect((card['files'] as List).first as String, endsWith('.mp4'));
    });

    test('a video that comes with a still uses it as its poster', () async {
      final ai = make((r) async {
        if (r.method == 'POST') return http.Response(jsonEncode({'id': 'v2', 'object': 'video', 'status': 'queued'}), 200);
        if (r.url.path == '/v1/videos/v2') return http.Response(jsonEncode({'id': 'v2', 'object': 'video', 'status': 'completed'}), 200);
        if (r.url.queryParameters['variant'] == 'thumbnail') return http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
        return http.Response.bytes(mp4, 200, headers: {'content-type': 'video/mp4'});
      });
      final card = AiModels.readCard(await ai.execute('ai_call', {'task': 'video', 'base_url': 'https://api.openai.com/v1', 'api_key': key, 'prompt': 'waves'}))!;
      expect(card['kind'], 'video');
      expect((card['files'] as List).length, 1);
      expect(card['poster'] as String, endsWith('.png'));
    });

    test('speech returns sound bytes: an audio card', () async {
      final ai = make((r) async => http.Response.bytes(wav, 200, headers: {'content-type': 'audio/wav'}));
      final out = await ai.execute('ai_call', {'task': 'speech', 'base_url': 'https://api.openai.com/v1', 'api_key': key, 'model': 'tts-1', 'prompt': 'hello'});
      final card = AiModels.readCard(out)!;
      expect(card['kind'], 'audio');
      expect((card['files'] as List).first as String, endsWith('.wav'));
    });

    test('chat reply comes back as text', () async {
      final ai = make((r) async => http.Response(jsonEncode({'choices': [{'message': {'content': 'Hello there'}}]}), 200));
      final out = await ai.execute('ai_call', {'task': 'text', 'base_url': 'https://a.b/v1', 'api_key': key, 'model': 'm1', 'prompt': 'hi'});
      expect(out, contains('Hello there'));
      expect(out, isNot(startsWith('MEDIA_CARD')));
    });

    test('rate limit is waited out, then it works', () async {
      var n = 0;
      final waits = <Duration>[];
      final ai = AiModels(
        store: store,
        client: () => MockClient((r) async {
          n++;
          if (n == 1) return http.Response('{"error":{"message":"slow down"}}', 429, headers: {'retry-after': '3'});
          return http.Response(jsonEncode({'data': [{'b64_json': base64Encode(png)}]}), 200);
        }),
        sleep: (d) async => waits.add(d),
        mediaDir: () async => dir.path,
      );
      final out = await ai.execute('ai_call', {'task': 'image', 'base_url': 'https://a.b/v1', 'api_key': key, 'prompt': 'x'});
      expect(out, startsWith('MEDIA_CARD'));
      expect(waits, contains(const Duration(seconds: 3)));
    });

    test('a refused key is explained without showing it', () async {
      final ai = make((r) async => http.Response('{"error":{"message":"Incorrect API key provided: $key"}}', 401));
      final out = await ai.execute('ai_call', {'task': 'image', 'base_url': 'https://a.b/v1', 'api_key': key, 'prompt': 'x'});
      expect(out, startsWith('Error: The provider refused the key'));
      expect(out, isNot(contains(key)));
    });

    test('a failed job says so', () async {
      final ai = make((r) async => r.method == 'POST'
          ? http.Response(jsonEncode({'id': 'j', 'status': 'queued', 'urls': {'get': 'https://a.b/v1/j'}}), 200)
          : http.Response(jsonEncode({'id': 'j', 'status': 'failed', 'error': 'NSFW content'}), 200));
      final out = await ai.execute('ai_call', {'task': 'custom', 'base_url': 'https://a.b/v1', 'api_key': key, 'path': '/run', 'payload': {'p': 1}});
      expect(out, contains('failed'));
      expect(out, contains('NSFW'));
    });

    test('no provider: asks for one', () async {
      final out = await make((r) async => http.Response('', 200)).execute('ai_call', {'task': 'image', 'prompt': 'x'});
      expect(out, startsWith('Error: No provider given'));
    });
  });

  group('saved connections', () {
    test('save, list, use by name and forget; the key is never listed', () async {
      final ai = make((r) async {
        if (r.url.path.endsWith('/models')) return http.Response(jsonEncode({'data': [{'id': 'a-1'}, {'id': 'b-2'}]}), 200);
        expect(r.headers['Authorization'], 'Bearer $key');
        return http.Response(jsonEncode({'data': [{'b64_json': base64Encode(png)}]}), 200);
      });
      final ref = AiKeys.refPattern.firstMatch(AiKeys.redact('key $key').text)!.group(0)!;
      final saved = await ai.execute('ai_providers', {'action': 'save', 'name': 'Studio', 'base_url': 'https://api.studio.ai/v1/', 'api_key': ref});
      expect(saved, contains('Saved "Studio"'));
      final list = await ai.execute('ai_providers', {'action': 'list'});
      expect(list, contains('Studio: https://api.studio.ai/v1'));
      expect(list, isNot(contains(key)));
      expect(store.data['ai_providers_v1'], isNot(contains(key)), reason: 'the record holds only the reference');
      final models = await ai.execute('ai_providers', {'action': 'models', 'name': 'studio'});
      expect(models, contains('a-1'));
      AiKeys.clearSessionForTests(); // a later session: the key comes from storage
      final out = await ai.execute('ai_call', {'task': 'image', 'provider': 'Studio', 'model': 'a-1', 'prompt': 'x'});
      expect(out, startsWith('MEDIA_CARD'));
      final gone = await ai.execute('ai_providers', {'action': 'forget', 'name': 'Studio'});
      expect(gone, contains('Removed'));
      expect(store.data.values.where((v) => v == key), isEmpty);
    });

    test('model ids from different list shapes', () {
      expect(AiModels.modelIds({'data': [{'id': 'x'}]}), ['x']);
      expect(AiModels.modelIds({'models': [{'name': 'models/gemini'}]}), ['models/gemini']);
      expect(AiModels.modelIds(['a', 'b']), ['a', 'b']);
    });
  });
}
