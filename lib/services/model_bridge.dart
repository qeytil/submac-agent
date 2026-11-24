import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'byok.dart';
import 'tools.dart' show AgentTools;

/// Hand a task to another of the owner's configured models and carry on with its answer (owner 2026-11).
///
/// The model answering the owner works on the model chosen in Settings. When it cannot do something itself — it cannot
/// see pictures, or a different model is stronger or cheaper for a subtask — it lists the configured models and passes
/// the work (text, or an image to a model that can see) to one of them, then continues. Keys never leave the phone;
/// every call uses the owner's own provider and key.
class ModelBridge {
  ModelBridge._();

  static const names = {'ask_model', 'list_models'};

  static final List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'list_models',
        'description': 'The models the owner configured (Settings > Models): their label, provider and id, and whether each '
            'can see images. Use it to choose a model to hand a task to with ask_model.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'ask_model',
        'description': 'Hand a task to ANOTHER of the owner\'s configured models and get its answer back, then carry on '
            'with the owner\'s task yourself. Use it when the current model cannot do something (e.g. it cannot see images: '
            'pass the picture(s) to a model that can see, and use its description), or when another model is stronger or '
            'cheaper for a subtask. This does not switch the chat: it is one side request. model = a label/id from '
            'list_models, or "vision"/"auto" to pick a model that can see images.',
        'parameters': {
          'type': 'object',
          'properties': {
            'model': {'type': 'string', 'description': 'A label or id from list_models, or "vision"/"auto".'},
            'prompt': {'type': 'string', 'description': 'Exactly what to ask that model, with the detail it needs.'},
            'images': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Image file paths (e.g. an upload) to send, if the model can see.'},
          },
          'required': ['prompt'],
        },
      },
    },
  ];

  static List<BridgeModel> models() => [
        for (final pick in ByokStore.I.choices)
          BridgeModel(
            pick.provider.id,
            pick.provider.name.trim().isEmpty ? pick.provider.kind.id : pick.provider.name.trim(),
            pick.model.id,
            pick.model.label,
            pick.model.vision,
            pick.provider.kind,
          ),
      ];

  static String describe() {
    final ms = models();
    if (ms.isEmpty) return 'No model is configured on this phone yet (Settings > Models).';
    final sb = StringBuffer('Your configured models (pass a label or id to ask_model, or "vision"/"auto"):');
    for (final m in ms) {
      final sees = m.vision == true ? ' · can see images' : (m.vision == false ? ' · text only' : '');
      sb.write('\n- ${m.label} (${m.providerName}) id=${m.modelId}$sees');
    }
    return sb.toString();
  }

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    if (name == 'list_models') return describe();
    return ask(
      model: '${a['model'] ?? ''}',
      prompt: '${a['prompt'] ?? ''}',
      images: [for (final p in (a['images'] as List? ?? const [])) '$p'],
    );
  }

  static Future<String> ask({required String model, required String prompt, List<String> images = const []}) async {
    final list = models();
    if (list.isEmpty) return 'No model of the owner is configured (Settings > Models). Do the task yourself and say so.';
    if (prompt.trim().isEmpty) return 'Error: give the prompt.';
    final m = _pick(list, model, wantsVision: images.isNotEmpty);
    final p = ByokStore.I.provider(m.providerId);
    if (p == null) return '${m.label} is no longer configured. Run list_models and try another.';
    final key = ByokStore.I.activeSecret(p);
    if (p.needsKey && (key == null || key.isEmpty)) return '${m.label} has no key on this phone.';
    final textOnly = images.isNotEmpty && m.vision == false;
    final tail = textOnly ? '\n\n(This model cannot take images, so they were not sent.)' : '';
    final c = http.Client();
    try {
      final (status, body) = await _call(c, p, key, m, prompt.trim() + tail, images, textOnly);
      if (status >= 300) return '${m.label} said: HTTP $status ${_clip(body, 400)}';
      final out = _textFrom(body);
      return out.isEmpty ? '${m.label} returned nothing.' : _clip(out, 6000);
    } catch (e) {
      return 'Could not reach ${m.label}: $e';
    } finally {
      c.close();
    }
  }

  static BridgeModel _pick(List<BridgeModel> list, String want, {required bool wantsVision}) {
    final w = want.trim().toLowerCase();
    final vision = list.where((x) => x.vision == true).toList();
    if (w.isEmpty || w == 'auto' || w == 'vision') {
      return wantsVision && vision.isNotEmpty ? vision.first : list.first;
    }
    for (final m in list) {
      if (m.modelId.toLowerCase() == w || m.label.toLowerCase() == w || '${m.providerName}/${m.modelId}'.toLowerCase() == w) return m;
    }
    for (final m in list) {
      if (m.modelId.toLowerCase().contains(w) || m.label.toLowerCase().contains(w)) return m;
    }
    return wantsVision && vision.isNotEmpty ? vision.first : list.first;
  }

  static Future<(int, String)> _call(http.Client c, ByokProvider p, String? key, BridgeModel m, String prompt, List<String> images, bool textOnly) async {
    final base = p.baseUrl.endsWith('/') ? p.baseUrl.substring(0, p.baseUrl.length - 1) : p.baseUrl;
    final anth = p.kind == ByokKind.anthropic || p.kind == ByokKind.anthropicCompatible;
    final headers = <String, String>{'content-type': 'application/json', ...p.headers};
    if (key != null && key.isNotEmpty) {
      headers[anth ? 'x-api-key' : 'authorization'] = anth ? key : 'Bearer $key';
    }
    if (anth) headers['anthropic-version'] = '2023-06-01';
    final loaded = await _images(images, take: !textOnly);
    final rich = loaded.isNotEmpty;
    final content = anth
        ? <dynamic>[
            {'type': 'text', 'text': prompt},
            for (final img in loaded) {'type': 'image', 'source': {'type': 'base64', 'media_type': img.$1, 'data': img.$2}},
          ]
        : <dynamic>[
            {'type': 'text', 'text': prompt},
            for (final img in loaded) {'type': 'image_url', 'image_url': {'url': 'data:${img.$1};base64,${img.$2}'}},
          ];
    final body = anth
        ? {'model': m.modelId, 'max_tokens': 2048, 'messages': [{'role': 'user', 'content': rich ? content : prompt}]}
        : {'model': m.modelId, 'messages': [{'role': 'user', 'content': rich ? content : prompt}]};
    final res = await c
        .post(Uri.parse('$base${anth ? '/messages' : '/chat/completions'}'), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 90));
    return (res.statusCode, res.body);
  }

  static Future<List<(String, String)>> _images(List<String> paths, {required bool take}) async {
    if (!take) return const [];
    final out = <(String, String)>[];
    final ws = await AgentTools.workspaceDir();
    for (var raw in paths) {
      var path = raw.trim();
      if (path.isEmpty) continue;
      if (!path.startsWith('/')) path = '$ws/$path';
      final f = File(path);
      if (!await f.exists()) continue;
      final ext = path.split('.').last.toLowerCase();
      final mime = const {
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'webp': 'image/webp',
        'gif': 'image/gif',
        'bmp': 'image/bmp',
        'heic': 'image/heic',
      }[ext] ?? 'image/jpeg';
      try {
        out.add((mime, base64Encode(await f.readAsBytes())));
      } catch (_) {}
    }
    return out;
  }

  static String _textFrom(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final ch = j['choices'];
        if (ch is List && ch.isNotEmpty && ch.first is Map) {
          final msg = (ch.first as Map)['message'];
          final ct = msg is Map ? msg['content'] : null;
          if (ct is String) return ct.trim();
          if (ct is List) return [for (final p in ct) if (p is Map && p['text'] is String) '${p['text']}'].join('\n').trim();
        }
        final content = j['content'];
        if (content is List) return [for (final p in content) if (p is Map && p['text'] is String) '${p['text']}'].join('\n').trim();
        if (j['output_text'] is String) return '${j['output_text']}'.trim();
        if (j['response'] is String) return '${j['response']}'.trim();
      }
    } catch (_) {}
    return '';
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
}

class BridgeModel {
  const BridgeModel(this.providerId, this.providerName, this.modelId, this.label, this.vision, this.kind);
  final String providerId;
  final String providerName;
  final String modelId;
  final String label;
  final bool? vision;
  final ByokKind kind;
}