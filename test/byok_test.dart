import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/byok.dart';
import 'package:agent/services/byok_fetch.dart';
import 'package:agent/services/byok_opencode.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/oc_lanes.dart';

ByokProvider _prov({
  String id = 'byok-1a2b3c4d',
  String preset = 'tokenharbor',
  ByokKind kind = ByokKind.openaiCompatible,
  bool enabled = true,
  List<ByokModel>? models,
  List<ByokKey>? keys,
}) =>
    ByokProvider(
      id: id,
      kind: kind,
      preset: preset,
      baseUrl: ByokPresets.byId(preset)?.baseUrl ?? 'https://example.test/v1',
      enabled: enabled,
      keys: keys ?? [ByokKey(id: 'k1', name: 'main', hint: 'cdef')],
      activeKey: 'k1',
      models: models ?? [ByokModel(id: 'gpt-x'), ByokModel(id: 'off-model', enabled: false)],
    );

void main() {
  group('presets', () {
    test('base URLs', () {
      expect(ByokPresets.byId('tokenharbor')!.baseUrl, 'https://tokenharbor.ai/v1');
      expect(ByokPresets.byId('nvidia')!.baseUrl, 'https://integrate.api.nvidia.com/v1');
      expect(ByokPresets.byId('opencode')!.baseUrl, 'https://opencode.ai/inference/openai/v1');
      expect(ByokPresets.byId('nope'), isNull);
    });

    test('ids are unique', () {
      final ids = ByokPresets.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('model list parsing', () {
    test('OpenAI shape drops non-chat models', () {
      final json = jsonDecode(
          '{"object":"list","data":[{"id":"gpt-4o","object":"model"},{"id":"text-embedding-3-small"},{"id":"whisper-1"},{"id":"gpt-4o"}]}');
      final ms = ByokFetch.parse(ByokKind.openai, json);
      expect(ms.map((m) => m.id), ['gpt-4o']);
    });

    test('Anthropic shape', () {
      final json = {
        'data': [
          {
            'id': 'claude-sonnet-4-5',
            'display_name': 'Claude Sonnet 4.5',
            'type': 'model',
            'max_input_tokens': 200000,
            'max_tokens': 64000,
          }
        ],
        'has_more': false,
      };
      final ms = ByokFetch.parse(ByokKind.anthropic, json);
      expect(ms, hasLength(1));
      expect(ms.first.id, 'claude-sonnet-4-5');
      expect(ms.first.label, 'Claude Sonnet 4.5');
      expect(ms.first.context, 200000);
      expect(ms.first.output, 64000);
    });

    test('Gemini shape keeps generateContent models and strips models/', () {
      final json = {
        'models': [
          {
            'name': 'models/gemini-2.5-pro',
            'displayName': 'Gemini 2.5 Pro',
            'inputTokenLimit': 1048576,
            'outputTokenLimit': 65536,
            'supportedGenerationMethods': ['generateContent', 'countTokens'],
          },
          {
            'name': 'models/text-embedding-004',
            'supportedGenerationMethods': ['embedContent'],
          },
        ],
        'nextPageToken': 'abc',
      };
      final ms = ByokFetch.parse(ByokKind.gemini, json);
      expect(ms.map((m) => m.id), ['gemini-2.5-pro']);
      expect(ms.first.context, 1048576);
      expect(ms.first.output, 65536);
      expect(ByokFetch.nextPage(json), 'abc');
    });

    test('Together bare array', () {
      final json = [
        {'id': 'meta-llama/Llama-3.3-70B-Instruct-Turbo', 'type': 'chat', 'display_name': 'Llama 3.3 70B', 'context_length': 131072},
        {'id': 'BAAI/bge-large-en-v1.5', 'type': 'embedding'},
      ];
      final ms = ByokFetch.parse(ByokKind.openaiCompatible, json);
      expect(ms.map((m) => m.id), ['meta-llama/Llama-3.3-70B-Instruct-Turbo']);
      expect(ms.first.context, 131072);
    });

    test('garbage gives nothing', () {
      expect(ByokFetch.parse(ByokKind.openai, null), isEmpty);
      expect(ByokFetch.parse(ByokKind.gemini, 'x'), isEmpty);
    });
  });

  group('opencode config', () {
    const secret = 'thk_live_SUPERSECRET_abcdef';
    String? secretOf(ByokProvider p) => secret;

    test('uses {env:SUBMAC_BYOK_*} and never contains the key', () {
      final p = _prov();
      final cfg = ByokOpencode.providers([p], secretOf);
      final text = jsonEncode(cfg);
      expect(text.contains(secret), isFalse);
      final opts = (cfg[p.id] as Map)['options'] as Map;
      expect(opts['apiKey'], '{env:SUBMAC_BYOK_1A2B3C4D}');
      expect(opts['baseURL'], 'https://tokenharbor.ai/v1');
      expect(((cfg[p.id] as Map)['models'] as Map).keys, ['gpt-x']);
      expect(ByokOpencode.env([p], secretOf), {'SUBMAC_BYOK_1A2B3C4D': secret});
      expect(ByokOpencode.signature([p], secretOf).contains(secret), isFalse);
    });

    test('providers without key, models, or enabled are left out', () {
      expect(ByokOpencode.providers([_prov()], (_) => null), isEmpty);
      expect(ByokOpencode.providers([_prov(enabled: false)], secretOf), isEmpty);
      expect(ByokOpencode.providers([_prov(models: [ByokModel(id: 'a', enabled: false)])], secretOf), isEmpty);
    });

    test('local provider without a key has no apiKey', () {
      final p = _prov(preset: 'ollama', keys: []);
      final cfg = ByokOpencode.providers([p], (_) => null);
      expect(((cfg[p.id] as Map)['options'] as Map).containsKey('apiKey'), isFalse);
    });
  });

  group('OcLane.pick', () {
    tearDown(() => ByokStore.I.resetForTests());

    test('usable BYOK choice goes to the provider', () {
      ByokStore.I.resetForTests(ByokConfig(providers: [_prov()]), {'k1': 'secret'});
      final m = OcLane.pick(background: false, userModel: 'byok-1a2b3c4d|gpt-x');
      expect(m, {'providerID': 'byok-1a2b3c4d', 'modelID': 'gpt-x'});
      expect(OcLane.isByok(m), isTrue);
    });

    test('falls back to Telesia for unusable choices', () {
      ByokStore.I.resetForTests(ByokConfig(providers: [_prov()]), {'k1': 'secret'});
      for (final s in ['byok-1a2b3c4d|off-model', 'byok-1a2b3c4d|missing', 'byok-ffffffff|gpt-x', 'submac', 'garbage']) {
        final m = OcLane.pick(background: false, userModel: s);
        expect(OcLane.isByok(m), isFalse, reason: s);
        expect(m['modelID'], Cloud.submac, reason: s);
      }
      // No key stored.
      ByokStore.I.resetForTests(ByokConfig(providers: [_prov()]), {});
      expect(OcLane.isByok(OcLane.pick(background: false, userModel: 'byok-1a2b3c4d|gpt-x')), isFalse);
      // Provider disabled.
      ByokStore.I.resetForTests(ByokConfig(providers: [_prov(enabled: false)]), {'k1': 'secret'});
      expect(OcLane.isByok(OcLane.pick(background: true, botModel: 'byok-1a2b3c4d|gpt-x')), isFalse);
    });
  });

  group('keys', () {
    test('masking shows only the last four', () {
      expect(ByokKey.mask('cdef'), '••••cdef');
      expect(ByokKey.mask(''), '••••');
    });

    test('provider errors scrub the key', () {
      const key = 'sk-verysecretkey123';
      final line = ByokFetch.errorLine(401, '{"error":{"message":"Incorrect API key provided: $key"}}', key: key);
      expect(line.contains(key), isFalse);
      expect(ByokStore.isKeyError(line), isTrue);
    });

    test('saved config never holds the secret', () {
      final p = _prov();
      final json = jsonEncode(ByokConfig(providers: [p]).toJson());
      expect(json.contains('cdef'), isTrue);
      expect(json.contains('secret'), isFalse);
      final back = ByokConfig.fromJson(json);
      expect(back.providers.single.id, p.id);
    });
  });
}
