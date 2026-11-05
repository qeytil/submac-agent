import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'byok.dart';

/// Talking to a BYOK provider directly from the phone (owner 2026-11-03): listing its models and testing the
/// connection. Request building and answer parsing are pure (tested per provider type); [ByokFetch.models] and
/// [ByokFetch.test] do the HTTP. Keys go only into the request headers, never into a URL, a log or an error text.
class ByokFetch {
  ByokFetch({http.Client Function()? client}) : _client = client ?? http.Client.new;
  final http.Client Function() _client;

  static ByokFetch I = ByokFetch();

  static const anthropicVersion = '2023-06-01';

  /// The headers that carry the key, per protocol.
  static Map<String, String> authHeaders(ByokKind kind, String? key) {
    final k = (key ?? '').trim();
    if (kind.isAnthropic) return {if (k.isNotEmpty) 'x-api-key': k, 'anthropic-version': anthropicVersion};
    if (kind == ByokKind.gemini) return {if (k.isNotEmpty) 'x-goog-api-key': k};
    return {if (k.isNotEmpty) 'Authorization': 'Bearer $k'};
  }

  /// The model-list request of [p] (page [pageToken] for Gemini).
  static http.Request listRequest(ByokProvider p, String? key, {String? pageToken}) {
    final base = p.apiBase;
    Uri u;
    if (p.modelsUrl.trim().isNotEmpty) {
      u = Uri.parse(p.modelsUrl.trim());
    } else {
      u = Uri.parse('$base/models');
    }
    if (p.kind == ByokKind.gemini) {
      u = u.replace(queryParameters: {...u.queryParameters, 'pageSize': '1000', if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken});
    } else if (p.kind.isAnthropic) {
      u = u.replace(queryParameters: {...u.queryParameters, 'limit': '1000'});
    }
    final r = http.Request('GET', u);
    r.headers.addAll({'accept': 'application/json', ...p.headers, ...authHeaders(p.kind, key)});
    return r;
  }

  /// A one-token chat request, for providers with no model list (the test falls back to it).
  static http.Request pingRequest(ByokProvider p, String? key, String model) {
    final base = p.apiBase;
    final http.Request r;
    if (p.kind.isAnthropic) {
      r = http.Request('POST', Uri.parse('$base/messages'));
      r.body = jsonEncode({'model': model, 'max_tokens': 1, 'messages': [{'role': 'user', 'content': 'hi'}]});
    } else if (p.kind == ByokKind.gemini) {
      r = http.Request('POST', Uri.parse('$base/models/$model:generateContent'));
      r.body = jsonEncode({
        'contents': [{'role': 'user', 'parts': [{'text': 'hi'}]}],
        'generationConfig': {'maxOutputTokens': 1},
      });
    } else {
      r = http.Request('POST', Uri.parse('$base/chat/completions'));
      r.body = jsonEncode({'model': model, 'max_tokens': 1, 'messages': [{'role': 'user', 'content': 'hi'}]});
    }
    r.headers.addAll({'content-type': 'application/json', 'accept': 'application/json', ...p.headers, ...authHeaders(p.kind, key)});
    return r;
  }

  // ------------------------------------------------------------------ parsing

  static int? _int(Object? v) {
    if (v is num) return v > 0 ? v.toInt() : null;
    final n = int.tryParse('${v ?? ''}');
    return n != null && n > 0 ? n : null;
  }

  static bool? _supported(Object? v) {
    if (v is bool) return v;
    if (v is Map && v['supported'] is bool) return v['supported'] as bool;
    return null;
  }

  /// Ids that are clearly not chat models (embeddings, speech, images, moderation...).
  static final _nonChat = RegExp(
      r'(embed|whisper|tts|dall-?e|moderation|transcri|text-to-speech|speech|rerank|image-gen|imagen|veo-|sora|stable-diffusion|flux|clip|-audio|audio-|realtime|davinci-002|babbage)',
      caseSensitive: false);

  static bool chatLike(String id, {String? type}) {
    if (type != null && type.isNotEmpty && !const {'chat', 'language', 'code', 'model', 'llm', 'text'}.contains(type.toLowerCase())) return false;
    return !_nonChat.hasMatch(id);
  }

  /// Turns a provider's model list into models (the shapes of OpenAI, Anthropic, Gemini, OpenRouter, Together,
  /// Mistral, Groq, Fireworks, vLLM and similar). Unknown fields are ignored; non-chat models are left out.
  static List<ByokModel> parse(ByokKind kind, Object? json) {
    final out = <ByokModel>[];
    final seen = <String>{};
    void add(ByokModel m) {
      if (m.id.trim().isEmpty || !seen.add(m.id)) return;
      out.add(m);
    }

    if (kind == ByokKind.gemini) {
      final list = json is Map && json['models'] is List ? json['models'] as List : const [];
      for (final e in list) {
        if (e is! Map) continue;
        final methods = [for (final x in (e['supportedGenerationMethods'] is List ? e['supportedGenerationMethods'] as List : const [])) '$x'];
        if (!methods.contains('generateContent')) continue;
        final name = '${e['name'] ?? ''}';
        final id = name.startsWith('models/') ? name.substring(7) : (e['baseModelId'] is String ? e['baseModelId'] as String : name);
        if (!chatLike(id)) continue;
        add(ByokModel(
          id: id,
          name: '${e['displayName'] ?? ''}',
          context: _int(e['inputTokenLimit']),
          output: _int(e['outputTokenLimit']),
          reasoning: e['thinking'] is bool ? e['thinking'] as bool : null,
          vision: true,
          tools: true,
        ));
      }
      return out;
    }

    final list = json is List ? json : (json is Map && json['data'] is List ? json['data'] as List : (json is Map && json['models'] is List ? json['models'] as List : const []));
    for (final e in list) {
      if (e is String) {
        if (chatLike(e)) add(ByokModel(id: e));
        continue;
      }
      if (e is! Map) continue;
      final id = '${e['id'] ?? e['name'] ?? ''}'.trim();
      final type = e['type'] is String ? e['type'] as String : null;
      if (kind.isAnthropic) {
        final caps = e['capabilities'] is Map ? e['capabilities'] as Map : const {};
        add(ByokModel(
          id: id,
          name: '${e['display_name'] ?? ''}',
          context: _int(e['max_input_tokens']),
          output: _int(e['max_tokens']),
          vision: _supported(caps['image_input']),
          reasoning: _supported(caps['thinking']),
          tools: true,
        ));
        continue;
      }
      if (!chatLike(id, type: type == 'model' ? null : type)) continue;
      final arch = e['architecture'] is Map ? e['architecture'] as Map : const {};
      final inputs = [for (final x in (arch['input_modalities'] is List ? arch['input_modalities'] as List : const [])) '$x'];
      final params = [for (final x in (e['supported_parameters'] is List ? e['supported_parameters'] as List : const [])) '$x'];
      final caps = e['capabilities'] is Map ? e['capabilities'] as Map : const {};
      final top = e['top_provider'] is Map ? e['top_provider'] as Map : const {};
      final m = ByokModel(
        id: id,
        name: '${e['name'] is String && e['name'] != id ? e['name'] : (e['display_name'] ?? '')}',
        context: _int(e['context_length']) ??
            _int(e['context_window']) ??
            _int(e['max_context_length']) ??
            _int(e['max_model_len']) ??
            _int(e['context']) ??
            _int(top['context_length']),
        output: _int(top['max_completion_tokens']) ?? _int(e['max_completion_tokens']) ?? _int(e['max_output_tokens']),
        vision: inputs.isNotEmpty ? inputs.contains('image') : (caps['vision'] is bool ? caps['vision'] as bool : null),
        tools: params.isNotEmpty ? params.contains('tools') : (caps['function_calling'] is bool ? caps['function_calling'] as bool : null),
        reasoning: params.isNotEmpty ? (params.contains('reasoning') || params.contains('include_reasoning')) : null,
      );
      add(m);
    }
    return out;
  }

  /// The next Gemini page token, if any.
  static String? nextPage(Object? json) => json is Map && json['nextPageToken'] is String && (json['nextPageToken'] as String).isNotEmpty ? json['nextPageToken'] as String : null;

  // ------------------------------------------------------------------ errors

  /// A provider's failure in plain words. The key never appears (it is scrubbed from the body first).
  static String errorLine(int status, String body, {String? key}) {
    var detail = _detail(body);
    if (key != null && key.length >= 6) detail = detail.replaceAll(key, '••••');
    final tail = detail.isEmpty ? '' : ' ($detail)';
    if (status == 401 || status == 403) return 'The provider refused this key$tail. Check the key, or that it may use this API.';
    if (status == 404) return 'Nothing at this address$tail. Check the base URL.';
    if (status == 402) return 'The account is out of credit$tail.';
    if (status == 429) return 'Rate limited or out of quota$tail. Wait a moment, or use another key.';
    if (status == 400) return 'The provider did not accept the request$tail.';
    if (status >= 500) return 'The provider had a problem (HTTP $status)$tail. Try again later.';
    return 'HTTP $status$tail.';
  }

  static String _detail(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        if (e is Map && e['message'] != null) return _clip('${e['message']}');
        if (e is String) return _clip(e);
        if (j['message'] != null) return _clip('${j['message']}');
        if (j['detail'] != null) return _clip('${j['detail']}');
      }
      if (j is List && j.isNotEmpty && j.first is Map && (j.first as Map)['error'] is Map) {
        return _clip('${((j.first as Map)['error'] as Map)['message'] ?? ''}');
      }
    } catch (_) {}
    final t = body.trim();
    return t.startsWith('<') ? '' : _clip(t);
  }

  static String _clip(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 160 ? '${t.substring(0, 157)}…' : t;
  }

  /// A network failure in plain words.
  static String networkLine(Object e, String url) {
    final host = Uri.tryParse(url)?.host ?? url;
    if (e is TimeoutException) return 'No answer from $host in time. Check the address and your connection.';
    if (e is SocketException) {
      final local = host == 'localhost' || host == '127.0.0.1' || host.startsWith('192.168.') || host.startsWith('10.');
      return local ? 'Cannot reach $host. Is the server running and reachable from this phone?' : 'Cannot reach $host. Check the address and your connection.';
    }
    if (e is HandshakeException || e is TlsException) return 'A secure connection to $host failed.';
    if (e is FormatException) return 'That base URL is not a valid address.';
    return 'Could not reach $host.';
  }

  // ------------------------------------------------------------------ HTTP

  Future<(int, String)> _send(http.Request r, {Duration timeout = const Duration(seconds: 25)}) async {
    final c = _client();
    try {
      final s = await c.send(r).timeout(timeout);
      final body = await s.stream.bytesToString().timeout(timeout);
      return (s.statusCode, body);
    } finally {
      c.close();
    }
  }

  /// Lists [p]'s models with [key]. Throws [ByokError] with a plain message.
  Future<List<ByokModel>> models(ByokProvider p, String? key) async {
    if (p.apiBase.isEmpty && p.modelsUrl.isEmpty) throw ByokError('Add the base URL first.');
    final out = <ByokModel>[];
    String? page;
    for (var i = 0; i < 5; i++) {
      final r = listRequest(p, key, pageToken: page);
      final (code, body) = await _guard(r, key);
      if (code < 200 || code >= 300) throw ByokError(errorLine(code, body, key: key), status: code);
      Object? j;
      try {
        j = jsonDecode(body);
      } catch (_) {
        throw ByokError('The provider answered, but not with a model list. Check the base URL.');
      }
      out.addAll(parse(p.kind, j));
      page = p.kind == ByokKind.gemini ? nextPage(j) : null;
      if (page == null) break;
    }
    return out;
  }

  Future<(int, String)> _guard(http.Request r, String? key) async {
    try {
      return await _send(r);
    } on ByokError {
      rethrow;
    } catch (e) {
      throw ByokError(networkLine(e, r.url.toString()));
    }
  }

  /// Tests [p] with [key]: lists models; when the provider has no list (404/405) and [model] is given, sends one tiny
  /// chat request instead. Returns a short success line; throws [ByokError] with a plain message.
  Future<String> test(ByokProvider p, String? key, {String? model}) async {
    if (p.needsKey && (key == null || key.trim().isEmpty)) throw ByokError('Add a key first.');
    try {
      final list = await models(p, key);
      return list.isEmpty ? 'Connected. The provider lists no chat models; add one by its id.' : 'Connected. ${list.length} models available.';
    } on ByokError catch (e) {
      final m = model ?? (p.enabledModels.isEmpty ? null : p.enabledModels.first.id);
      if ((e.status == 404 || e.status == 405) && m != null) {
        final (code, body) = await _guard(pingRequest(p, key, m), key);
        if (code >= 200 && code < 300) return 'Connected. $m answered.';
        throw ByokError(errorLine(code, body, key: key), status: code);
      }
      rethrow;
    }
  }
}

class ByokError implements Exception {
  ByokError(this.message, {this.status = 0});
  final String message;
  final int status;
  @override
  String toString() => message;
}
