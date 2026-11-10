import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:agent/services/ai_keys.dart';
import 'package:agent/services/ai_models.dart';
import 'package:agent/services/byok.dart';
import 'package:agent/services/media_gen.dart';
import 'package:agent/services/media_providers.dart';
import 'package:agent/services/telesia_gateway.dart';

const _key = 'sk-test-SECRET-1234567890';

/// A tiny PNG's first bytes (enough for type sniffing).
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]);

MediaProvider _p(String preset, {String id = 'media-aaaa1111', String keyId = 'k1'}) {
  final pr = MediaProvider.fromPreset(MediaPresets.byId(preset)!, id: id);
  pr.keyId = keyId;
  pr.keyHint = '7890';
  return pr;
}

MediaAsk _ask(MediaKind k, {String prompt = 'a red fox', String aspect = '', int? duration, Uint8List? image, String voice = ''}) =>
    MediaAsk(kind: k, prompt: prompt, aspect: aspect, duration: duration, image: image, voice: voice);

http.Response _json(Object j, [int code = 200]) => http.Response(jsonEncode(j), code, headers: {'content-type': 'application/json'});

MediaStep _read(MediaProvider p, MediaCall sent, Object body, {int code = 200}) =>
    MediaGen.read(p, _key, sent, code, {'content-type': 'application/json'}, Uint8List.fromList(utf8.encode(jsonEncode(body))));

void main() {
  group('presets', () {
    test('ids are unique and every kind has providers', () {
      final ids = MediaPresets.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final k in MediaKind.values) {
        expect(MediaPresets.of(k), isNotEmpty, reason: k.id);
      }
    });

    test('ready-made presets carry a base URL, a model and a protocol', () {
      for (final p in MediaPresets.all.where((p) => !p.custom)) {
        expect(p.baseUrl, startsWith('https://'), reason: p.id);
        expect(p.model, isNotEmpty, reason: p.id);
      }
      expect(MediaPresets.byId('openai-image')!.wire, MediaWire.openaiImages);
      expect(MediaPresets.byId('gemini-image')!.wire, MediaWire.geminiInteractions);
      expect(MediaPresets.byId('gemini-image-legacy')!.model, 'gemini-2.5-flash-image');
      expect(MediaPresets.byId('gemini-speech-legacy')!.model, 'gemini-2.5-flash-preview-tts');
      expect(MediaPresets.byId('fal-image')!.baseUrl, 'https://queue.fal.run');
      expect(MediaPresets.byId('runway-video')!.baseUrl, 'https://api.dev.runwayml.com/v1');
      expect(MediaPresets.byokPresetsFor('google'), {'gemini'});
    });
  });

  group('config', () {
    test('round trip keeps providers and defaults, never a key', () {
      final pr = _p('openai-image');
      final cfg = MediaConfig(providers: [pr], defaults: {MediaKind.image: pr.id});
      final text = jsonEncode(cfg.toJson());
      expect(text, isNot(contains(_key)));
      final back = MediaConfig.fromJson(text);
      expect(back.providers.single.model, 'gpt-image-1');
      expect(back.providers.single.wire, MediaWire.openaiImages);
      expect(back.defaults[MediaKind.image], pr.id);
    });

    test('broken entries, duplicates and stray defaults are dropped', () {
      final back = MediaConfig.fromJson({
        'providers': [
          {'id': 'media-aaaa1111', 'kind': 'image', 'preset': 'openai-image', 'model': 'm'},
          {'id': 'media-aaaa1111', 'kind': 'video'},
          {'id': 'nope', 'kind': 'image'},
          'junk',
        ],
        'defaults': {'image': 'media-aaaa1111', 'video': 'media-aaaa1111', 'speech': 'media-zzzz9999'},
      });
      expect(back.providers, hasLength(1));
      expect(back.defaults, {MediaKind.image: 'media-aaaa1111'});
      expect(MediaConfig.fromJson('not json').providers, isEmpty);
      expect(MediaConfig.fromJson(null).providers, isEmpty);
    });
  });

  group('store', () {
    late MemoryAiStore mem;
    late ByokStore byok;
    late MediaProviderStore s;
    setUp(() {
      mem = MemoryAiStore();
      byok = ByokStore(store: mem)..resetForTests();
      s = MediaProviderStore(store: mem, byok: byok)..resetForTests();
    });

    test('keys go to encrypted storage, apart from the config; the first provider is the default', () async {
      final pr = MediaProvider.fromPreset(MediaPresets.byId('openai-image')!, id: 'media-aaaa1111');
      await s.setKey(pr, _key);
      await s.upsert(pr);
      expect(s.defaultId(MediaKind.image), pr.id);
      expect(mem.data[MediaProviderStore.configEntry], isNot(contains(_key)));
      expect(mem.data[MediaProviderStore.keyEntry(pr.keyId)], _key);
      expect(s.secretFor(pr), _key);
      expect(s.keyLabel(pr), '••••7890');
      // Loaded again from storage.
      final s2 = MediaProviderStore(store: mem, byok: byok);
      await s2.load();
      expect(s2.secretFor(s2.provider(pr.id)!), _key);
      expect(s2.hasAny, isTrue);
    });

    test('a key can be borrowed from a chat provider or another media provider of the same vendor', () async {
      final b = ByokProvider(id: 'byok-1a2b3c4d', kind: ByokKind.openai, preset: 'openai', keys: [ByokKey(id: 'bk', hint: 'aaaa')], activeKey: 'bk');
      byok.resetForTests(ByokConfig(providers: [b]), {'bk': 'sk-from-chat'});
      final img = MediaProvider.fromPreset(MediaPresets.byId('openai-image')!, id: 'media-aaaa1111');
      expect(s.keySources(img).map((e) => e.$1), ['byok-1a2b3c4d']);
      img.keyFrom = b.id;
      await s.upsert(img);
      expect(s.secretFor(img), 'sk-from-chat');

      final tts = MediaProvider.fromPreset(MediaPresets.byId('openai-speech')!, id: 'media-bbbb2222');
      await s.setKey(tts, _key);
      await s.upsert(tts);
      final video = MediaProvider.fromPreset(MediaPresets.byId('openai-video')!, id: 'media-cccc3333')..keyFrom = tts.id;
      await s.upsert(video);
      expect(s.secretFor(video), _key);
      // A different vendor's key is never offered.
      final fal = MediaProvider.fromPreset(MediaPresets.byId('fal-image')!, id: 'media-dddd4444');
      expect(s.keySources(fal), isEmpty);

      // Removing the lender hands its key to the borrower instead of breaking it.
      await s.remove(tts.id);
      expect(s.secretFor(s.provider(video.id)!), _key);
      expect(mem.data.values, contains(_key));
    });

    test('pick: named provider, else the default, else none', () async {
      final a = _p('openai-image', id: 'media-aaaa1111', keyId: 'ka');
      final b = _p('fal-image', id: 'media-bbbb2222', keyId: 'kb');
      s.resetForTests(MediaConfig(providers: [a, b], defaults: {MediaKind.image: b.id}), {'ka': 'x', 'kb': 'y'});
      expect(s.pick(MediaKind.image)!.id, b.id);
      expect(s.pick(MediaKind.image, named: 'openai')!.id, a.id);
      expect(s.pick(MediaKind.image, named: 'OpenAI')!.id, a.id);
      expect(s.pick(MediaKind.image, named: 'midjourney'), isNull);
      expect(s.pick(MediaKind.video), isNull);
      // Off, or no key: not usable.
      a.enabled = false;
      expect(s.usableOf(MediaKind.image).map((p) => p.id), [b.id]);
      s.resetForTests(MediaConfig(providers: [b]), {});
      expect(s.hasAny, isFalse);
    });

    test('removing the default promotes another provider of that kind', () async {
      final a = _p('openai-image', id: 'media-aaaa1111', keyId: 'ka');
      final b = _p('fal-image', id: 'media-bbbb2222', keyId: 'kb');
      s.resetForTests(MediaConfig(providers: [a, b], defaults: {MediaKind.image: a.id}), {'ka': 'x', 'kb': 'y'});
      await s.remove(a.id);
      expect(s.defaultId(MediaKind.image), b.id);
    });
  });

  group('tool gating', () {
    test('media_generate is offered only while a provider is set up, never in the per-message listing', () {
      final s = MediaProviderStore(store: MemoryAiStore())..resetForTests();
      expect(MediaGen.definitions(s), isEmpty);
      final pr = _p('openai-speech');
      s.resetForTests(MediaConfig(providers: [pr], defaults: {MediaKind.speech: pr.id}), {'k1': _key});
      final defs = MediaGen.definitions(s);
      expect(defs, hasLength(1));
      final fn = defs.first['function'] as Map;
      expect(fn['name'], 'media_generate');
      final kinds = ((fn['parameters'] as Map)['properties'] as Map)['kind']['enum'];
      expect(kinds, ['speech']);
      expect('${fn['description']}', contains('OpenAI TTS'));
      expect('${fn['description']}', contains('never make media they did not ask'));
      expect('${fn['description']}', isNot(contains(_key)));
      // opencode's per-message tools stay find_tools + run_tool.
      final listing = TelesiaGateway.listing(defs);
      expect(listing.map((t) => (t['function'] as Map)['name']), ['find_tools', 'run_tool']);
      // ...and find_tools finds it.
      final gw = TelesiaGateway(tools: () => defs, run: (n, a) async => '');
      expect(gw.find('make a video or picture media'), contains('media_generate'));
    });

    test('the telesia skill says when to use it', () {
      expect(TelesiaGateway.skill, contains('media_generate'));
      expect(TelesiaGateway.skill, contains('never make media they did not ask for'));
    });
  });

  group('routing', () {
    test('owner, bot and team media land in their own folders', () {
      expect(MediaGen.folderFor('/ws'), '/ws/media');
      expect(MediaGen.folderFor('/ws/', botFolder: 'bots/b1'), '/ws/bots/b1/media');
      expect(MediaGen.folderFor('/ws', botFolder: 'bots/b1', teamFolder: 'teams/t1'), '/ws/teams/t1/media');
    });

    test('a team member\'s media becomes file cards under its team reply', () {
      final card = AiModels.cardLine({'v': 1, 'kind': 'image', 'files': ['/ws/teams/t1/media/a.png']});
      final out = MediaGen.cardsFromOutputs(['$card\nThe picture...', 'IMAGE_SAVED /ws/teams/t1/media/b.png\nok', 'plain text']);
      expect(out, '```file\n/ws/teams/t1/media/a.png\n```\n\n```file\n/ws/teams/t1/media/b.png\n```');
      expect(MediaGen.cardsFromOutputs(['nothing']), isEmpty);
    });
  });

  group('request building', () {
    test('keys go in headers, never in the URL, per protocol', () {
      for (final preset in MediaPresets.all.where((p) => !p.custom)) {
        final p = MediaProvider.fromPreset(preset, id: 'media-aaaa1111');
        final c = MediaGen.build(p, _key, _ask(preset.kind));
        expect(c.uri.toString(), isNot(contains(_key)), reason: preset.id);
        expect(c.headers.values.any((v) => v.contains(_key)), isTrue, reason: preset.id);
      }
      expect(MediaGen.authHeaders(_p('gemini-image'), _key)['x-goog-api-key'], _key);
      expect(MediaGen.authHeaders(_p('fal-image'), _key)['Authorization'], 'Key $_key');
      expect(MediaGen.authHeaders(_p('elevenlabs-speech'), _key)['xi-api-key'], _key);
      expect(MediaGen.authHeaders(_p('runway-video'), _key)['X-Runway-Version'], MediaGen.runwayVersion);
      expect(MediaGen.authHeaders(_p('openai-image'), _key)['Authorization'], 'Bearer $_key');
    });

    test('OpenAI images: size from the shape; bytes asked for dall-e only', () {
      final c = MediaGen.build(_p('openai-image'), _key, _ask(MediaKind.image, aspect: '16:9'));
      expect(c.uri.toString(), 'https://api.openai.com/v1/images/generations');
      expect(c.body!['size'], '1536x1024');
      expect(c.body!.containsKey('response_format'), isFalse);
      final p = _p('openai-image')..model = 'dall-e-3';
      final d = MediaGen.build(p, _key, _ask(MediaKind.image, aspect: 'portrait'));
      expect(d.body!['size'], '1024x1792');
      expect(d.body!['response_format'], 'b64_json');
    });

    test('OpenAI image edit is multipart with the picture', () {
      final c = MediaGen.build(_p('openai-image'), _key, _ask(MediaKind.image, image: _png));
      expect(c.uri.path, '/v1/images/edits');
      expect(c.multipart, isTrue);
      expect(c.files.single.field, 'image');
      expect(c.fields['prompt'], 'a red fox');
    });

    test('xAI and Together speak the images API with their own fields', () {
      final x = MediaGen.build(_p('xai-image'), _key, _ask(MediaKind.image, aspect: '9:16'));
      expect(x.uri.toString(), 'https://api.x.ai/v1/images/generations');
      expect(x.body!['aspect_ratio'], '9:16');
      expect(x.body!.containsKey('size'), isFalse);
      final xe = MediaGen.build(_p('xai-image'), _key, _ask(MediaKind.image, image: _png));
      expect((xe.body!['image'] as Map)['url'], startsWith('data:image/png;base64,'));
      final t = MediaGen.build(_p('together-image'), _key, _ask(MediaKind.image));
      expect(t.body!['width'], 1024);
      expect(t.body!['response_format'], 'b64_json');
    });

    test('OpenRouter asks for image output', () {
      final c = MediaGen.build(_p('openrouter-image'), _key, _ask(MediaKind.image, aspect: '1:1'));
      expect(c.uri.toString(), 'https://openrouter.ai/api/v1/chat/completions');
      expect(c.body!['modalities'], ['image', 'text']);
      expect(c.body!['image_config'], {'aspect_ratio': '1:1'});
    });

    test('Gemini Interactions: image, background video, speech with a voice', () {
      final img = MediaGen.build(_p('gemini-image'), _key, _ask(MediaKind.image, aspect: '16:9'));
      expect(img.uri.toString(), 'https://generativelanguage.googleapis.com/v1beta/interactions');
      expect(img.body!['model'], 'gemini-nano-banana-2.1');
      expect(img.body!['response_format'], {'type': 'image', 'aspect_ratio': '16:9'});
      final vid = MediaGen.build(_p('gemini-video'), _key, _ask(MediaKind.video, aspect: 'portrait', image: _png));
      expect(vid.body!['background'], isTrue);
      expect((vid.body!['response_format'] as Map)['aspect_ratio'], '9:16');
      expect(((vid.body!['input'] as List).first as Map)['type'], 'image');
      final sp = MediaGen.build(_p('gemini-speech'), _key, _ask(MediaKind.speech, prompt: 'hello'));
      expect(sp.body!['response_format'], {'type': 'audio'});
      expect(jsonEncode(sp.body!['generation_config']), contains('"voice":"Kore"'));
    });

    test('Gemini generateContent: picture modalities and TTS voice', () {
      final img = MediaGen.build(_p('gemini-image-legacy'), _key, _ask(MediaKind.image));
      expect(img.uri.toString(), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent');
      expect((img.body!['generationConfig'] as Map)['responseModalities'], ['TEXT', 'IMAGE']);
      final tts = MediaGen.build(_p('gemini-speech-legacy'), _key, _ask(MediaKind.speech, voice: 'Puck'));
      expect(jsonEncode(tts.body), contains('"voiceName":"Puck"'));
      expect((tts.body!['generationConfig'] as Map)['responseModalities'], ['AUDIO']);
    });

    test('Veo long-running predict', () {
      final c = MediaGen.build(_p('veo-video'), _key, _ask(MediaKind.video, duration: 12));
      expect(c.uri.path, endsWith('/models/veo-3.1-generate-001:predictLongRunning'));
      expect((c.body!['parameters'] as Map)['durationSeconds'], 8);
    });

    test('fal queue: endpoint id in the path, shape per kind', () {
      final c = MediaGen.build(_p('fal-image'), _key, _ask(MediaKind.image, aspect: '16:9'));
      expect(c.uri.toString(), 'https://queue.fal.run/fal-ai/flux/schnell');
      expect(c.body!['image_size'], 'landscape_16_9');
      final v = MediaGen.build(_p('fal-video'), _key, _ask(MediaKind.video, duration: 5, image: _png));
      expect(v.body!['duration'], '5');
      expect(v.body!['image_url'], startsWith('data:image/png;base64,'));
    });

    test('Replicate: official model path, or a version; waits for short jobs only', () {
      final c = MediaGen.build(_p('replicate-image'), _key, _ask(MediaKind.image));
      expect(c.uri.toString(), 'https://api.replicate.com/v1/models/black-forest-labs/flux-schnell/predictions');
      expect(c.headers['Prefer'], 'wait=60');
      expect((c.body!['input'] as Map)['prompt'], 'a red fox');
      final p = _p('replicate-video')..model = 'someone/model:abc123';
      final v = MediaGen.build(p, _key, _ask(MediaKind.video));
      expect(v.uri.path, '/v1/predictions');
      expect(v.body!['version'], 'abc123');
      expect(v.headers.containsKey('Prefer'), isFalse);
    });

    test('Stability: multipart, answers with the picture', () {
      final c = MediaGen.build(_p('stability-image'), _key, _ask(MediaKind.image, aspect: '16:9'));
      expect(c.uri.toString(), 'https://api.stability.ai/v2beta/stable-image/generate/core');
      expect(c.multipart, isTrue);
      expect(c.fields['aspect_ratio'], '16:9');
      expect(c.headers['accept'], 'image/*');
    });

    test('Runway: text or image to video, ratio and duration', () {
      final t = MediaGen.build(_p('runway-video'), _key, _ask(MediaKind.video, aspect: 'portrait', duration: 30));
      expect(t.uri.path, '/v1/text_to_video');
      expect(t.body!['ratio'], '720:1280');
      expect(t.body!['duration'], 10);
      final i = MediaGen.build(_p('runway-video'), _key, _ask(MediaKind.video, image: _png));
      expect(i.uri.path, '/v1/image_to_video');
      expect(i.body!['promptImage'], startsWith('data:'));
    });

    test('OpenAI videos, xAI videos, OpenAI speech, ElevenLabs', () {
      final o = MediaGen.build(_p('openai-video'), _key, _ask(MediaKind.video, duration: 7));
      expect(o.uri.toString(), 'https://api.openai.com/v1/videos');
      expect(o.body!['seconds'], '8');
      final x = MediaGen.build(_p('xai-video'), _key, _ask(MediaKind.video, duration: 6));
      expect(x.uri.toString(), 'https://api.x.ai/v1/videos/generations');
      expect(x.body!['duration'], 6);
      final s = MediaGen.build(_p('openai-speech'), _key, _ask(MediaKind.speech, prompt: 'hi'));
      expect(s.body, {'model': 'gpt-4o-mini-tts', 'input': 'hi', 'voice': 'alloy', 'response_format': 'mp3'});
      final e = MediaGen.build(_p('elevenlabs-speech'), _key, _ask(MediaKind.speech, prompt: 'hi'));
      expect(e.uri.path, '/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb');
      expect(e.uri.queryParameters['output_format'], 'mp3_44100_128');
      final snd = MediaGen.build(_p('elevenlabs-sound'), _key, _ask(MediaKind.audio, duration: 50));
      expect(snd.body!['duration_seconds'], 30);
      final mus = MediaGen.build(_p('elevenlabs-music'), _key, _ask(MediaKind.audio, duration: 20));
      expect(mus.body!['music_length_ms'], 20000);
    });
  });

  group('reading answers', () {
    test('OpenAI images: b64 or url', () {
      final p = _p('openai-image');
      final sent = MediaGen.build(p, _key, _ask(MediaKind.image));
      final s = _read(p, sent, {
        'data': [
          {'b64_json': base64Encode(_png)},
          {'url': 'https://cdn.example/x.png'}
        ]
      });
      expect(s.done, isTrue);
      expect(s.blobs.single.bytes, _png);
      expect(s.urls, ['https://cdn.example/x.png']);
    });

    test('OpenRouter images in the message', () {
      final p = _p('openrouter-image');
      final s = _read(p, MediaGen.build(p, _key, _ask(MediaKind.image)), {
        'choices': [
          {
            'message': {
              'content': 'Here you go',
              'images': [
                {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,${base64Encode(_png)}'}}
              ]
            }
          }
        ]
      });
      expect(s.urls.single, startsWith('data:image/png;base64,'));
      expect(s.text, 'Here you go');
    });

    test('Gemini Interactions: finished steps, or a job to poll', () {
      final p = _p('gemini-video');
      final sent = MediaGen.build(p, _key, _ask(MediaKind.video));
      final pending = _read(p, sent, {'id': 'v1_abc', 'status': 'in_progress'});
      expect(pending.done, isFalse);
      expect(pending.next!.uri.toString(), 'https://generativelanguage.googleapis.com/v1beta/interactions/v1_abc');
      expect(pending.next!.headers['x-goog-api-key'], _key);
      final done = _read(p, pending.next!, {
        'id': 'v1_abc',
        'status': 'completed',
        'steps': [
          {'type': 'user_input', 'content': []},
          {
            'type': 'model_output',
            'content': [
              {'type': 'video', 'mime_type': 'video/mp4', 'data': base64Encode([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 1, 2])}
            ]
          }
        ]
      });
      expect(done.done, isTrue);
      expect(done.blobs.single.mime, 'video/mp4');
      expect(() => _read(p, sent, {'id': 'x', 'status': 'failed', 'error': {'message': 'blocked'}}), throwsA(isA<MediaGenError>()));
    });

    test('Gemini TTS raw PCM becomes a playable WAV', () {
      final p = _p('gemini-speech-legacy');
      final pcm = Uint8List.fromList(List.filled(48, 1));
      final s = _read(p, MediaGen.build(p, _key, _ask(MediaKind.speech)), {
        'candidates': [
          {
            'content': {
              'parts': [
                {'inlineData': {'mimeType': 'audio/L16;codec=pcm;rate=24000', 'data': base64Encode(pcm)}}
              ]
            }
          }
        ]
      });
      final b = s.blobs.single;
      expect(b.mime, 'audio/wav');
      expect(String.fromCharCodes(b.bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(b.bytes.sublist(8, 12)), 'WAVE');
      expect(b.bytes.length, 44 + 48);
      expect(ByteData.sublistView(b.bytes).getUint32(24, Endian.little), 24000);
    });

    test('Veo: operation, then the video link', () {
      final p = _p('veo-video');
      final sent = MediaGen.build(p, _key, _ask(MediaKind.video));
      final op = _read(p, sent, {'name': 'models/veo-3.1-generate-001/operations/op1'});
      expect(op.next!.uri.toString(), 'https://generativelanguage.googleapis.com/v1beta/models/veo-3.1-generate-001/operations/op1');
      final done = _read(p, op.next!, {
        'name': 'x',
        'done': true,
        'response': {
          'generateVideoResponse': {
            'generatedSamples': [
              {'video': {'uri': 'https://generativelanguage.googleapis.com/v1beta/files/f1:download?alt=media'}}
            ]
          }
        }
      });
      expect(done.urls.single, contains('files/f1:download'));
    });

    test('fal: queued, then completed, then the result', () {
      final p = _p('fal-image');
      final sent = MediaGen.build(p, _key, _ask(MediaKind.image));
      final q = _read(p, sent, {
        'request_id': 'r1',
        'status_url': 'https://queue.fal.run/fal-ai/flux/requests/r1/status',
        'response_url': 'https://queue.fal.run/fal-ai/flux/requests/r1',
        'cancel_url': 'https://queue.fal.run/fal-ai/flux/requests/r1/cancel',
        'queue_position': 2,
      });
      expect(q.next!.tag, 'poll');
      expect(q.progress, 'Queued, 2 ahead');
      expect(q.cancel!.method, 'PUT');
      final c = _read(p, q.next!, {'status': 'COMPLETED', 'response_url': 'https://queue.fal.run/fal-ai/flux/requests/r1'});
      expect(c.next!.tag, 'result');
      final r = _read(p, c.next!, {
        'images': [
          {'url': 'https://v3.fal.media/files/a.png', 'width': 1024}
        ],
        'prompt': 'https://not-a-file'
      });
      expect(r.urls, ['https://v3.fal.media/files/a.png']);
    });

    test('Replicate: running, then the output', () {
      final p = _p('replicate-video');
      final sent = MediaGen.build(p, _key, _ask(MediaKind.video));
      final run = _read(p, sent, {
        'id': 'p1',
        'status': 'processing',
        'urls': {'get': 'https://api.replicate.com/v1/predictions/p1', 'cancel': 'https://api.replicate.com/v1/predictions/p1/cancel'}
      });
      expect(run.next!.uri.toString(), 'https://api.replicate.com/v1/predictions/p1');
      expect(run.cancel!.method, 'POST');
      final done = _read(p, run.next!, {'status': 'succeeded', 'output': 'https://replicate.delivery/x/out.mp4'});
      expect(done.urls, ['https://replicate.delivery/x/out.mp4']);
      expect(() => _read(p, run.next!, {'status': 'failed', 'error': 'NSFW'}), throwsA(isA<MediaGenError>()));
    });

    test('Runway, OpenAI videos and xAI videos poll to a file', () {
      final rw = _p('runway-video');
      final r1 = _read(rw, MediaGen.build(rw, _key, _ask(MediaKind.video)), {'id': 't1'});
      expect(r1.next!.uri.path, '/v1/tasks/t1');
      expect(r1.cancel!.method, 'DELETE');
      final r2 = _read(rw, r1.next!, {'id': 't1', 'status': 'RUNNING', 'progress': 0.4});
      expect(r2.progress, '40%');
      final r3 = _read(rw, r1.next!, {'id': 't1', 'status': 'SUCCEEDED', 'output': ['https://dnznrvs05pmza.cloudfront.net/v.mp4']});
      expect(r3.urls.single, endsWith('v.mp4'));

      final ov = _p('openai-video');
      final o1 = _read(ov, MediaGen.build(ov, _key, _ask(MediaKind.video)), {'id': 'video_1', 'status': 'queued'});
      expect(o1.next!.uri.path, '/v1/videos/video_1');
      final o2 = _read(ov, o1.next!, {'id': 'video_1', 'status': 'completed'});
      expect(o2.next!.uri.path, '/v1/videos/video_1/content');
      expect(o2.next!.tag, 'content');

      final xv = _p('xai-video');
      final x1 = _read(xv, MediaGen.build(xv, _key, _ask(MediaKind.video)), {'request_id': 'q1'});
      expect(x1.next!.uri.path, '/v1/videos/q1');
      final x2 = _read(xv, x1.next!, {'status': 'done', 'video': {'url': 'https://vidgen.x.ai/v.mp4'}});
      expect(x2.urls, ['https://vidgen.x.ai/v.mp4']);
    });

    test('a binary answer is the file itself', () {
      final p = _p('openai-speech');
      final s = MediaGen.read(p, _key, MediaGen.build(p, _key, _ask(MediaKind.speech)), 200, {'content-type': 'audio/mpeg'}, Uint8List.fromList([0x49, 0x44, 0x33, 1]));
      expect(s.blobs.single.mime, 'audio/mpeg');
    });

    test('errors are plain and never carry the key', () {
      final p = _p('openai-image');
      try {
        _read(p, MediaGen.build(p, _key, _ask(MediaKind.image)), {'error': {'message': 'Incorrect API key provided: $_key'}}, code: 401);
        fail('should throw');
      } on MediaGenError catch (e) {
        expect(e.status, 401);
        expect(e.message, contains('refused'));
        expect(e.message, isNot(contains(_key)));
      }
    });

    test('connection test: a refused key, fal\'s 404 for a good key', () {
      expect(MediaGen.testCall(_p('fal-image'), _key).uri.toString(),
          'https://queue.fal.run/fal-ai/flux/requests/00000000-0000-0000-0000-000000000000/status');
      expect(MediaGen.testCall(_p('stability-image'), _key).uri.toString(), 'https://api.stability.ai/v1/user/account');
      expect(MediaGen.testCall(_p('gemini-image'), _key).uri.path, '/v1beta/models');
      expect(MediaGen.readTest(_p('fal-image'), 404, ''), startsWith('Connected'));
      expect(MediaGen.readTest(_p('openai-image'), 200, '{}'), startsWith('Connected'));
      expect(() => MediaGen.readTest(_p('openai-image'), 401, '{}'), throwsA(isA<MediaGenError>()));
    });
  });

  group('running a job', () {
    test('fal job: polls with progress, downloads the result without the key on the CDN', () async {
      final seen = <http.Request>[];
      var polls = 0;
      final client = MockClient((req) async {
        seen.add(req);
        final u = req.url.toString();
        if (req.method == 'POST') {
          return _json({
            'request_id': 'r1',
            'status_url': 'https://queue.fal.run/fal-ai/flux/requests/r1/status',
            'response_url': 'https://queue.fal.run/fal-ai/flux/requests/r1',
            'cancel_url': 'https://queue.fal.run/fal-ai/flux/requests/r1/cancel',
          });
        }
        if (u.endsWith('/status')) return _json({'status': ++polls < 2 ? 'IN_PROGRESS' : 'COMPLETED'});
        if (u.endsWith('/r1')) return _json({'images': [{'url': 'https://v3.fal.media/files/a.png'}]});
        if (u.startsWith('https://v3.fal.media/')) return http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});
        return http.Response('?', 404);
      });
      final gen = MediaGen(client: () => client, sleep: (_) async {});
      final lines = <String>[];
      final outs = await gen.run(_p('fal-image'), _key, _ask(MediaKind.image), progress: lines.add);
      expect(outs.single.bytes, _png);
      expect(lines.any((l) => l.contains('Generating')), isTrue);
      final cdn = seen.firstWhere((r) => r.url.host == 'v3.fal.media');
      expect(cdn.headers.containsKey('Authorization'), isFalse);
      expect(seen.first.headers['Authorization'], 'Key $_key');
    });

    test('a stopped chat cancels the job at the provider', () async {
      final seen = <http.Request>[];
      var stop = false;
      final client = MockClient((req) async {
        seen.add(req);
        if (req.method == 'POST') {
          return _json({
            'id': 'p1',
            'status': 'starting',
            'urls': {'get': 'https://api.replicate.com/v1/predictions/p1', 'cancel': 'https://api.replicate.com/v1/predictions/p1/cancel'}
          });
        }
        stop = true;
        return _json({'id': 'p1', 'status': 'processing', 'urls': {'get': 'https://api.replicate.com/v1/predictions/p1'}});
      });
      final gen = MediaGen(client: () => client, sleep: (_) async {});
      await expectLater(gen.run(_p('replicate-video'), _key, _ask(MediaKind.video), cancelled: () => stop), throwsA(isA<MediaCancelled>()));
      expect(seen.last.method, 'POST');
      expect(seen.last.url.path, '/v1/predictions/p1/cancel');
    });

    test('media_generate saves into the caller\'s folder and answers with a card', () async {
      final dir = await Directory.systemTemp.createTemp('media_gen_test');
      addTearDown(() => dir.delete(recursive: true));
      final pr = _p('openai-image');
      final store = MediaProviderStore(store: MemoryAiStore())..resetForTests(MediaConfig(providers: [pr], defaults: {MediaKind.image: pr.id}), {'k1': _key});
      final client = MockClient((req) async => _json({
            'data': [
              {'b64_json': base64Encode(_png)}
            ]
          }));
      final gen = MediaGen(client: () => client, sleep: (_) async {}, store: store);
      final folder = MediaGen.folderFor(dir.path, botFolder: 'bots/b1');
      final out = await gen.generate({'kind': 'image', 'prompt': 'a fox'}, folder: folder);
      final card = AiModels.readCard(out)!;
      expect(card['kind'], 'image');
      expect(card['provider'], 'OpenAI');
      final f = File((card['files'] as List).single as String);
      expect(f.path, startsWith('${dir.path}/bots/b1/media/'));
      expect(f.path, endsWith('.png'));
      expect(await f.readAsBytes(), _png);
      expect(out, isNot(contains(_key)));

      // generate_image's IMAGE_SAVED shape.
      final compat = await gen.generateImageCompat({'prompt': 'a fox'}, folder: folder);
      expect(compat, startsWith('IMAGE_SAVED ${dir.path}/bots/b1/media/'));

      // Nothing set up for video: a plain line for the user.
      final none = await gen.generate({'kind': 'video', 'prompt': 'x'}, folder: folder);
      expect(none, contains('Settings > Media models'));
      final bad = await gen.generate({'kind': 'hologram', 'prompt': 'x'}, folder: folder);
      expect(bad, startsWith('Error'));
    });

    test('a provider error comes back as a plain line without the key', () async {
      final dir = await Directory.systemTemp.createTemp('media_gen_err');
      addTearDown(() => dir.delete(recursive: true));
      final pr = _p('openai-speech');
      final store = MediaProviderStore(store: MemoryAiStore())..resetForTests(MediaConfig(providers: [pr]), {'k1': _key});
      final client = MockClient((req) async => _json({'error': {'message': 'bad key $_key'}}, 401));
      final gen = MediaGen(client: () => client, sleep: (_) async {}, store: store);
      final out = await gen.generate({'kind': 'speech', 'prompt': 'hi'}, folder: dir.path);
      expect(out, startsWith('Error from OpenAI TTS'));
      expect(out, isNot(contains(_key)));
    });
  });

  test('shape and ratio helpers', () {
    expect(MediaGen.ratioOf(_ask(MediaKind.image, aspect: 'portrait')), '9:16');
    expect(MediaGen.ratioOf(_ask(MediaKind.image, aspect: '4:3')), '4:3');
    expect(MediaGen.shapeOf(const MediaAsk(kind: MediaKind.image, prompt: 'x', size: '1024x1536')), 'portrait');
    expect(MediaGen.ratioOf(_ask(MediaKind.image)), '');
    expect(MediaKindX.parse('music'), MediaKind.audio);
    expect(MediaKindX.parse('tts'), MediaKind.speech);
  });
}
