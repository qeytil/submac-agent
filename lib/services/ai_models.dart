import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_keys.dart';
import 'tools.dart';

/// An AI connection the user asked Telesia to remember (name, address, how the key is sent). The key itself sits in
/// encrypted storage under its `key_ref`; this record only names the reference.
class AiProvider {
  String name;
  String baseUrl;
  String keyRef;
  String authHeader;
  String authScheme;
  String authQuery;
  Map<String, String> headers;
  List<String> models;
  AiProvider({
    required this.name,
    required this.baseUrl,
    this.keyRef = '',
    this.authHeader = 'Authorization',
    this.authScheme = 'Bearer',
    this.authQuery = '',
    Map<String, String>? headers,
    List<String>? models,
  })  : headers = headers ?? {},
        models = models ?? [];

  Map<String, dynamic> toJson() => {
        'name': name,
        'base_url': baseUrl,
        'key_ref': keyRef,
        'auth_header': authHeader,
        'auth_scheme': authScheme,
        'auth_query': authQuery,
        'headers': headers,
        'models': models,
      };

  factory AiProvider.fromJson(Map<String, dynamic> j) => AiProvider(
        name: '${j['name'] ?? ''}',
        baseUrl: '${j['base_url'] ?? ''}',
        keyRef: '${j['key_ref'] ?? ''}',
        authHeader: '${j['auth_header'] ?? 'Authorization'}',
        authScheme: '${j['auth_scheme'] ?? 'Bearer'}',
        authQuery: '${j['auth_query'] ?? ''}',
        headers: (j['headers'] is Map) ? (j['headers'] as Map).map((k, v) => MapEntry('$k', '$v')) : {},
        models: (j['models'] is List) ? [for (final m in j['models'] as List) '$m'] : [],
      );
}

/// One HTTP request, ready to send. JSON body, raw bytes, or multipart fields + files.
class AiRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic>? json;
  final Map<String, String> fields;
  final Map<String, String> files; // form field -> local path
  const AiRequest({required this.method, required this.uri, required this.headers, this.json, this.fields = const {}, this.files = const {}});
  bool get multipart => files.isNotEmpty;
}

/// A long job the provider runs on its side (Replicate, fal, BFL, OpenAI videos, Google operations...).
class AiJob {
  final Uri pollUrl;
  /// Where the finished result is read when it is not in the status reply (fal's response_url).
  final Uri? resultUrl;
  /// OpenAI-style video: the file is downloaded from `<base>/videos/<id>/content` once completed.
  final Uri? contentUrl;
  const AiJob(this.pollUrl, {this.resultUrl, this.contentUrl});
}

/// Media and text found in a provider's reply.
class AiOutputs {
  final List<String> urls = [];
  final List<Uint8List> blobs = [];
  final List<String> blobMimes = [];
  final List<String> texts = [];
  int embeddings = 0;
  int dims = 0;
  bool get isEmpty => urls.isEmpty && blobs.isEmpty && texts.isEmpty && embeddings == 0;
}

class AiCallError implements Exception {
  final String message;
  AiCallError(this.message);
  @override
  String toString() => message;
}

/// Calls AI models the user brings: any OpenAI-compatible API (chat, images, image edits, speech, transcription,
/// embeddings, videos) and any other REST API (custom path, payload, headers), including async jobs that are polled
/// until done. Results are downloaded into the workspace and shown in chat as media cards (MEDIA_CARD results).
/// Calls go straight from the phone to the provider: nothing passes Telesia's servers and nothing is billed by Telesia.
class AiModels {
  AiModels({AiSecretStore? store, http.Client Function()? client, Future<void> Function(Duration)? sleep, Future<String> Function()? mediaDir})
      : _store = store,
        _client = client ?? http.Client.new,
        _sleep = sleep ?? Future<void>.delayed,
        _mediaDir = mediaDir;

  static AiModels I = AiModels();

  final AiSecretStore? _store;
  final http.Client Function() _client;
  final Future<void> Function(Duration) _sleep;
  Future<String> Function()? _mediaDir;
  AiSecretStore get store => _store ?? AiKeys.store;

  /// Set by the app to the workspace media folder.
  set mediaDir(Future<String> Function() f) => _mediaDir = f;

  /// Live progress of a running call, by tool call id ("Queued", "Generating 40%"), for the card's skeleton.
  static final ValueNotifier<Map<String, String>> progress = ValueNotifier(const {});

  static void _progress(String? id, String? label) {
    if (id == null) return;
    final m = Map<String, String>.from(progress.value);
    if (label == null) {
      m.remove(id);
    } else {
      m[id] = label;
    }
    progress.value = m;
  }

  static const call = 'ai_call';
  static const providers = 'ai_providers';
  static const names = {call, providers};

  static const tasks = ['text', 'image', 'image_edit', 'speech', 'transcribe', 'embed', 'video', 'music', 'custom'];

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> req) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static final List<Map<String, dynamic>> definitions = [
    _fn(
        call,
        'Call an AI model the USER brings (their own base URL + API key, or a connection they saved). Use it when the user '
            'gives a provider in chat ("use this: base URL …, key …, model …, make a picture of …") or names a saved one. '
            'Works with any OpenAI-compatible API (task text/image/image_edit/speech/transcribe/embed/video) and any other REST '
            'API (task custom with path + payload, e.g. Replicate, fal, ElevenLabs, BFL). Long jobs are polled until done. '
            'Pictures, sound, video and files come back as cards the user sees by themselves: do not repeat paths or links; '
            'say in one line what you made and offer one tweak. Use exactly the model the user named; if they named none and '
            'the provider has several, ask (ai_providers models lists them). Never use a provider the user did not give. '
            'A key the user pasted shows in chat as key_ref:xxxxxxxxxx: pass that as api_key. Never write a key in your reply. '
            'The first time a key was hidden, tell the user kindly in one line that you hid it from the chat and keep it only '
            'on this phone, and ask once whether to save the provider for next time (ai_providers save).',
        {
          'task': {'type': 'string', 'enum': tasks, 'description': 'What to do. custom = any endpoint (give path and payload).'},
          'provider': {'type': 'string', 'description': 'Name of a saved connection (instead of base_url + api_key).'},
          'base_url': {'type': 'string', 'description': 'API base, e.g. https://api.openai.com/v1 or https://api.replicate.com/v1.'},
          'api_key': {'type': 'string', 'description': 'The key_ref:… the chat shows, or empty for a saved provider.'},
          'model': {'type': 'string', 'description': 'Model id exactly as the user named it.'},
          'prompt': {'type': 'string', 'description': 'The prompt, the text to speak, or the message.'},
          'path': {'type': 'string', 'description': 'Endpoint path (or full URL) when it is not the OpenAI default, e.g. /predictions.'},
          'method': {'type': 'string', 'description': 'HTTP method for custom (default POST).'},
          'payload': {'type': 'object', 'description': 'JSON body (custom) or extra fields merged into the default body.'},
          'headers': {'type': 'object', 'description': 'Extra headers, e.g. {"Prefer":"wait"}.'},
          'auth_header': {'type': 'string', 'description': 'Header that carries the key (default Authorization; e.g. x-api-key, xi-api-key, x-key).'},
          'auth_scheme': {'type': 'string', 'description': 'Word before the key (default Bearer; "Key" for fal, "" for none).'},
          'auth_query': {'type': 'string', 'description': 'Send the key as this URL parameter instead (e.g. key for Google).'},
          'input_files': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Workspace files to send (image to edit, audio to transcribe).'},
          'size': {'type': 'string', 'description': 'Image/video size, e.g. 1024x1024.'},
          'n': {'type': 'integer', 'description': 'How many images (default 1, max 4).'},
          'voice': {'type': 'string', 'description': 'Voice for speech (default alloy).'},
          'seconds': {'type': 'integer', 'description': 'Video length when the API takes one.'},
          'poll_path': {'type': 'string', 'description': 'Status URL template for an async API when it is not detected, e.g. /jobs/{id}.'},
          'timeout_seconds': {'type': 'integer', 'description': 'How long to wait for a long job (default 600, max 1800).'},
        },
        ['task']),
    _fn(
        providers,
        'The AI connections the user saved (keys stay on this phone and are never shown). '
            'list: names, addresses and models. save: only after the user said yes to saving it (name, base_url, api_key = the '
            'key_ref, optional auth_header/auth_scheme/headers/models). forget: remove one. models: ask a provider which models '
            'it has (GET /models). test: check that the address and key work.',
        {
          'action': {'type': 'string', 'enum': ['list', 'save', 'forget', 'models', 'test']},
          'name': {'type': 'string'},
          'base_url': {'type': 'string'},
          'api_key': {'type': 'string', 'description': 'The key_ref:… from the chat.'},
          'auth_header': {'type': 'string'},
          'auth_scheme': {'type': 'string'},
          'auth_query': {'type': 'string'},
          'headers': {'type': 'object'},
          'models': {'type': 'array', 'items': {'type': 'string'}},
        },
        ['action']),
  ];

  // ---------------------------------------------------------------- saved connections

  static const _listKey = 'ai_providers_v1';

  Future<List<AiProvider>> saved() async {
    final raw = await store.read(_listKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return [for (final j in jsonDecode(raw) as List) AiProvider.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAll(List<AiProvider> list) => store.write(_listKey, jsonEncode([for (final p in list) p.toJson()]));

  Future<AiProvider?> byName(String name) async {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    final all = await saved();
    return all.where((p) => p.name.toLowerCase() == n).firstOrNull ?? all.where((p) => p.name.toLowerCase().contains(n)).firstOrNull;
  }

  // ---------------------------------------------------------------- request building (pure)

  static String normBase(String base) {
    var b = base.trim();
    if (b.isEmpty) return b;
    if (!b.startsWith('http')) b = 'https://$b';
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  static Uri join(String base, String path) {
    final p = path.trim();
    if (p.startsWith('http://') || p.startsWith('https://')) return Uri.parse(p);
    final b = normBase(base);
    return Uri.parse(p.isEmpty ? b : '$b${p.startsWith('/') ? '' : '/'}$p');
  }

  static const _defaultPaths = {
    'text': '/chat/completions',
    'image': '/images/generations',
    'image_edit': '/images/edits',
    'speech': '/audio/speech',
    'transcribe': '/audio/transcriptions',
    'embed': '/embeddings',
    'video': '/videos',
  };

  static Map<String, String> authHeaders(String key, {String header = 'Authorization', String scheme = 'Bearer', String query = ''}) {
    if (key.isEmpty || query.isNotEmpty) return {};
    final h = header.trim().isEmpty ? 'Authorization' : header.trim();
    final s = scheme.trim();
    return {h: s.isEmpty ? key : '$s $key'};
  }

  /// Builds the request for [task]. [key] is the real key (already looked up).
  static AiRequest build({
    required String task,
    required String baseUrl,
    required String key,
    String model = '',
    String prompt = '',
    String path = '',
    String method = '',
    Map<String, dynamic>? payload,
    Map<String, String> headers = const {},
    String authHeader = 'Authorization',
    String authScheme = 'Bearer',
    String authQuery = '',
    List<String> inputFiles = const [],
    String size = '',
    int n = 1,
    String voice = '',
    int seconds = 0,
  }) {
    final t = tasks.contains(task) ? task : 'custom';
    final p = path.trim().isNotEmpty ? path.trim() : (_defaultPaths[t] ?? '');
    if (t == 'custom' && p.isEmpty) throw AiCallError('A custom call needs a path (or a full URL).');
    if (t == 'music' && p.isEmpty) throw AiCallError('Music has no standard endpoint: give the path and payload this provider uses.');
    var uri = join(baseUrl, p);
    if (authQuery.trim().isNotEmpty && key.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, authQuery.trim(): key});
    }
    final h = <String, String>{
      ...authHeaders(key, header: authHeader, scheme: authScheme, query: authQuery),
      ...headers,
    };
    final extra = payload ?? const <String, dynamic>{};
    final count = n.clamp(1, 4);
    Map<String, dynamic>? body;
    var fields = <String, String>{};
    var files = <String, String>{};
    switch (t) {
      case 'text':
        body = {
          if (model.isNotEmpty) 'model': model,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
        };
        break;
      case 'image':
        body = {
          if (model.isNotEmpty) 'model': model,
          'prompt': prompt,
          if (count > 1) 'n': count,
          if (size.isNotEmpty) 'size': size,
        };
        break;
      case 'image_edit':
        if (inputFiles.isEmpty) throw AiCallError('Give the picture to change in input_files.');
        fields = {
          if (model.isNotEmpty) 'model': model,
          'prompt': prompt,
          if (count > 1) 'n': '$count',
          if (size.isNotEmpty) 'size': size,
          for (final e in extra.entries) e.key: '${e.value}',
        };
        files = {for (var i = 0; i < inputFiles.length; i++) (inputFiles.length == 1 ? 'image' : 'image[]#$i'): inputFiles[i]};
        break;
      case 'speech':
        body = {
          if (model.isNotEmpty) 'model': model,
          'input': prompt,
          'voice': voice.isEmpty ? 'alloy' : voice,
          // WAV plays in the chat's own waveform player.
          'response_format': 'wav',
        };
        break;
      case 'transcribe':
        if (inputFiles.isEmpty) throw AiCallError('Give the recording in input_files.');
        fields = {if (model.isNotEmpty) 'model': model, if (prompt.isNotEmpty) 'prompt': prompt, for (final e in extra.entries) e.key: '${e.value}'};
        files = {'file': inputFiles.first};
        break;
      case 'embed':
        body = {if (model.isNotEmpty) 'model': model, 'input': prompt};
        break;
      case 'video':
        body = {
          if (model.isNotEmpty) 'model': model,
          'prompt': prompt,
          if (seconds > 0) 'seconds': '$seconds',
          if (size.isNotEmpty) 'size': size,
        };
        break;
      default: // custom, music with a path
        if (inputFiles.isNotEmpty) {
          fields = {for (final e in extra.entries) e.key: (e.value is String ? e.value as String : jsonEncode(e.value))};
          files = {'file': inputFiles.first};
        } else {
          body = {...extra};
          if (body.isEmpty) {
            if (model.isNotEmpty) body['model'] = model;
            if (prompt.isNotEmpty) body['prompt'] = prompt;
          }
        }
    }
    if (body != null && t != 'custom' && t != 'music') body = {...body, ...extra};
    final m = method.trim().isEmpty ? 'POST' : method.trim().toUpperCase();
    if (body != null && m != 'GET') h.putIfAbsent('Content-Type', () => 'application/json');
    return AiRequest(method: m, uri: uri, headers: h, json: m == 'GET' ? null : body, fields: fields, files: files);
  }

  // ---------------------------------------------------------------- reply parsing (pure)

  static const _b64Keys = {'b64_json', 'b64', 'base64', 'bytesBase64Encoded', 'image_base64', 'audio_base64', 'video_base64', 'audio_content', 'audioContent'};
  static const _skipUrlKeys = {'get', 'cancel', 'stream', 'status_url', 'response_url', 'polling_url', 'webhook', 'logs', 'web', 'self', 'next', 'prev'};
  static final _mediaExt = RegExp(r'\.(png|jpe?g|webp|gif|mp4|webm|mov|mp3|wav|m4a|ogg|flac|aac|pdf|zip)(\?|$)', caseSensitive: false);
  static const _mediaKeys = {
    'url', 'image', 'images', 'video', 'videos', 'audio', 'output', 'outputs', 'file', 'files', 'uri', 'href', 'sample', 'result',
    'download_url', 'video_url', 'audio_url', 'image_url', 'thumbnail', 'poster', 'media', 'artifacts', 'generated', 'data'
  };

  /// Parts of a reply that echo the request (an input picture is not an output).
  static const _skipMapKeys = {'input', 'inputs', 'request', 'params', 'parameters', 'metadata', 'logs', 'urls', 'usage', 'error'};

  static AiOutputs parse(dynamic json) {
    final out = AiOutputs();
    final seen = <String>{};
    void walk(dynamic v, String key, bool mediaCtx) {
      if (v is Map) {
        for (final e in v.entries) {
          final k = '${e.key}';
          if (_skipMapKeys.contains(k)) continue;
          if (k == 'embedding' && e.value is List) {
            out.embeddings++;
            out.dims = (e.value as List).length;
            continue;
          }
          walk(e.value, k, mediaCtx || _mediaKeys.contains(k));
        }
      } else if (v is List) {
        for (final x in v) {
          walk(x, key, mediaCtx);
        }
      } else if (v is String) {
        final s = v.trim();
        if (s.startsWith('data:') && s.contains(';base64,')) {
          final mime = s.substring(5, s.indexOf(';'));
          try {
            out.blobs.add(base64Decode(s.substring(s.indexOf(',') + 1)));
            out.blobMimes.add(mime);
          } catch (_) {}
        } else if (_b64Keys.contains(key) && s.length > 64) {
          try {
            out.blobs.add(base64Decode(s));
            out.blobMimes.add(key.contains('audio') ? 'audio/wav' : (key.contains('video') ? 'video/mp4' : ''));
          } catch (_) {}
        } else if ((s.startsWith('https://') || s.startsWith('http://')) && !_skipUrlKeys.contains(key)) {
          if ((mediaCtx || _mediaExt.hasMatch(s)) && seen.add(s)) out.urls.add(s);
        }
      }
    }

    walk(json, '', false);
    if (json is Map) {
      final choices = json['choices'];
      if (choices is List && choices.isNotEmpty) {
        final c = choices.first;
        final msg = c is Map ? c['message'] : null;
        final content = msg is Map ? msg['content'] : (c is Map ? c['text'] : null);
        if (content is String && content.trim().isNotEmpty) out.texts.add(content.trim());
      }
      for (final k in const ['output_text', 'text', 'transcript']) {
        final t = json[k];
        if (t is String && t.trim().isNotEmpty) out.texts.add(t.trim());
      }
    }
    return out;
  }

  static const pendingStates = {
    'starting', 'queued', 'pending', 'processing', 'in_progress', 'running', 'in_queue', 'submitted', 'created', 'waiting', 'generating', 'scheduled', 'started'
  };
  static const failedStates = {'failed', 'error', 'canceled', 'cancelled', 'rejected', 'expired', 'content moderated', 'request moderated'};

  static String stateOf(dynamic json) {
    if (json is! Map) return '';
    final s = json['status'] ?? json['state'];
    return s is String ? s.toLowerCase().trim() : '';
  }

  /// A long job, when the reply says the work is still going (or is the start of one); null when the reply is final.
  static AiJob? jobOf(dynamic json, AiRequest req, {String task = '', String pollPath = '', String baseUrl = '', Map<String, String> respHeaders = const {}}) {
    if (json is! Map) return null;
    final state = stateOf(json);
    final id = '${json['id'] ?? json['request_id'] ?? json['task_id'] ?? json['job_id'] ?? json['generation_id'] ?? ''}';
    final base = '${req.uri.scheme}://${req.uri.authority}';
    // Google long-running operation.
    if (json['done'] == false && json['name'] is String) {
      final b = req.uri.path.contains('/v1beta') ? '$base/v1beta' : (req.uri.path.contains('/v1') ? '$base/v1' : base);
      return AiJob(Uri.parse('$b/${json['name']}'));
    }
    final pending = pendingStates.contains(state);
    if (!pending) return null;
    Uri? poll;
    Uri? result;
    Uri? content;
    final urls = json['urls'];
    if (urls is Map && urls['get'] is String) poll = Uri.parse(urls['get'] as String); // Replicate
    if (json['status_url'] is String) poll = Uri.parse(json['status_url'] as String); // fal queue
    if (json['response_url'] is String) result = Uri.parse(json['response_url'] as String);
    if (json['polling_url'] is String) poll = Uri.parse(json['polling_url'] as String); // BFL
    final loc = respHeaders['location'] ?? respHeaders['operation-location'];
    if (poll == null && loc != null && loc.isNotEmpty) poll = req.uri.resolve(loc);
    if (pollPath.isNotEmpty && id.isNotEmpty) {
      final pp = pollPath.replaceAll('{id}', id);
      poll = pp.startsWith('http') ? Uri.parse(pp) : (baseUrl.isNotEmpty ? join(baseUrl, pp) : req.uri.resolve(pp));
    }
    // OpenAI-compatible videos: GET /videos/{id}, then /videos/{id}/content.
    if (poll == null && id.isNotEmpty && (task == 'video' || json['object'] == 'video')) {
      final root = req.uri.toString().split('?').first.replaceFirst(RegExp(r'/+$'), '');
      poll = Uri.parse('$root/$id');
      content = Uri.parse('$root/$id/content');
    }
    // Last guess: the same address plus the id.
    if (poll == null && id.isNotEmpty) {
      poll = Uri.parse('${req.uri.toString().split('?').first.replaceFirst(RegExp(r'/+$'), '')}/$id');
    }
    if (poll == null) return null;
    if (req.uri.queryParameters.isNotEmpty && poll.host == req.uri.host && poll.queryParameters.isEmpty) {
      poll = poll.replace(queryParameters: req.uri.queryParameters);
    }
    return AiJob(poll, resultUrl: result, contentUrl: content);
  }

  /// What the work is called while it runs, as a short phrase (Hark's status pill: no percentages, no timers).
  static String workingLine(String task) => switch (task) {
        'image' || 'image_edit' => 'Creating an image',
        'video' => 'Creating your video',
        'speech' => 'Generating audio file',
        'music' => 'Creating your music',
        'transcribe' => 'Writing out the recording',
        'embed' => 'Reading it closely',
        _ => 'Working with your model',
      };

  /// A short progress line for a status reply ("Waiting in line", "Creating your video").
  static String progressLine(dynamic json, Duration elapsed, {String task = ''}) {
    final st = stateOf(json);
    if (const {'queued', 'in_queue', 'pending', 'submitted', 'waiting', 'scheduled'}.contains(st)) return 'Waiting in line';
    // A long job gets a calm reassurance after two minutes instead of a ticking clock.
    if (elapsed.inMinutes >= 2) return '${workingLine(task)}, nearly there';
    return workingLine(task);
  }

  /// Plain words for an HTTP failure. The key is scrubbed by the caller.
  static String errorLine(int code, String body, String path) {
    var detail = '';
    try {
      final j = jsonDecode(body);
      final e = j is Map ? (j['error'] ?? j['detail'] ?? j['message'] ?? j['title']) : null;
      detail = e is Map ? '${e['message'] ?? e['detail'] ?? e}' : (e == null ? '' : '$e');
    } catch (_) {
      detail = body.trim();
    }
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    final said = detail.isEmpty ? '' : ' The provider said: "$detail"';
    if (code == 401 || code == 403) return 'The provider refused the key (HTTP $code).$said Ask the user to check the key or its access.';
    if (code == 404) return 'Nothing at $path (HTTP 404): the path or model name may be different for this provider.$said';
    if (code == 402) return 'The provider says the account has no credit (HTTP 402).$said';
    if (code == 429) return 'The provider is rate-limiting (HTTP 429) and did not free up after waiting.$said Try again in a minute.';
    if (code >= 500) return 'The provider had a problem on its side (HTTP $code).$said';
    return 'The provider did not accept the request (HTTP $code).$said';
  }

  // ---------------------------------------------------------------- running

  Future<http.Response> _send(http.Client c, AiRequest r) async {
    if (r.multipart) {
      final mr = http.MultipartRequest(r.method, r.uri)..headers.addAll({...r.headers}..remove('Content-Type'));
      mr.fields.addAll(r.fields);
      for (final e in r.files.entries) {
        final field = e.key.contains('#') ? e.key.split('#').first : e.key;
        mr.files.add(await http.MultipartFile.fromPath(field, e.value));
      }
      return http.Response.fromStream(await c.send(mr).timeout(const Duration(seconds: 180)));
    }
    final rq = http.Request(r.method, r.uri)..headers.addAll(r.headers);
    if (r.json != null) rq.body = jsonEncode(r.json);
    return http.Response.fromStream(await c.send(rq).timeout(const Duration(seconds: 180)));
  }

  /// Sends with patience: waits out a 429 (Retry-After up to 30 s, twice) and retries one 5xx.
  Future<http.Response> _sendPatient(http.Client c, AiRequest r, String? callId) async {
    var tries429 = 0;
    var tries5xx = 0;
    while (true) {
      final resp = await _send(c, r);
      if (resp.statusCode == 429 && tries429 < 2) {
        tries429++;
        final ra = int.tryParse(resp.headers['retry-after'] ?? '') ?? (5 * tries429);
        _progress(callId, 'The provider is busy, waiting a moment');
        await _sleep(Duration(seconds: ra.clamp(1, 30)));
        continue;
      }
      if (resp.statusCode >= 500 && tries5xx < 1) {
        tries5xx++;
        await _sleep(const Duration(seconds: 2));
        continue;
      }
      return resp;
    }
  }

  static dynamic _json(http.Response r) {
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  static bool _isBinary(http.Response r) {
    final ct = (r.headers['content-type'] ?? '').toLowerCase();
    return ct.startsWith('image/') || ct.startsWith('audio/') || ct.startsWith('video/') || ct.contains('octet-stream') || ct.contains('application/pdf');
  }

  /// Polls [job] until it finishes; returns the final JSON (or the downloaded bytes' response for OpenAI videos).
  Future<(dynamic, http.Response?)> _poll(http.Client c, AiJob job, Map<String, String> auth, {required int timeoutSec, String? callId, String task = ''}) async {
    final start = DateTime.now();
    var wait = 2;
    while (true) {
      final elapsed = DateTime.now().difference(start);
      if (elapsed.inSeconds > timeoutSec) {
        throw AiCallError('The job is still running after ${timeoutSec ~/ 60} min. It may finish later at the provider; '
            'offer to check again (status address: ${job.pollUrl.replace(queryParameters: const {})}).');
      }
      await _sleep(Duration(seconds: wait));
      wait = (wait * 1.5).ceil().clamp(2, 10);
      final r = await _sendPatient(c, AiRequest(method: 'GET', uri: job.pollUrl, headers: auth), callId);
      if (r.statusCode >= 400) throw AiCallError(errorLine(r.statusCode, utf8.decode(r.bodyBytes, allowMalformed: true), job.pollUrl.path));
      final j = _json(r);
      final st = stateOf(j);
      if (failedStates.contains(st)) {
        final e = j is Map ? (j['error'] ?? j['detail'] ?? j['failure_reason'] ?? j['message'] ?? '') : '';
        throw AiCallError('The provider says the job $st${'$e'.isEmpty ? '' : ': ${e is Map ? (e['message'] ?? e) : e}'}.');
      }
      if (j is Map && j['done'] == true) {
        if (j['error'] != null) throw AiCallError('The provider says the job failed: ${(j['error'] is Map) ? (j['error'] as Map)['message'] : j['error']}');
        return (j['response'] ?? j, null);
      }
      if (pendingStates.contains(st) || (j is Map && j['done'] == false)) {
        _progress(callId, progressLine(j, DateTime.now().difference(start), task: task));
        continue;
      }
      // Finished.
      if (job.resultUrl != null) {
        final rr = await _sendPatient(c, AiRequest(method: 'GET', uri: job.resultUrl!, headers: auth), callId);
        if (rr.statusCode >= 400) throw AiCallError(errorLine(rr.statusCode, rr.body, job.resultUrl!.path));
        return (_json(rr), null);
      }
      if (job.contentUrl != null) {
        final rr = await _sendPatient(c, AiRequest(method: 'GET', uri: job.contentUrl!, headers: auth), callId);
        if (rr.statusCode >= 400) throw AiCallError(errorLine(rr.statusCode, rr.body, job.contentUrl!.path));
        return (j, rr);
      }
      return (j, null);
    }
  }

  static String extFor(String mime, String url) {
    final m = RegExp(r'\.([a-z0-9]{2,4})(\?|$)', caseSensitive: false).firstMatch(Uri.tryParse(url)?.path ?? '');
    final fromUrl = m?.group(1)?.toLowerCase();
    const known = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'mp4', 'webm', 'mov', 'mp3', 'wav', 'm4a', 'ogg', 'flac', 'aac', 'pdf', 'zip', 'json', 'txt'};
    if (fromUrl != null && known.contains(fromUrl)) return fromUrl == 'jpeg' ? 'jpg' : fromUrl;
    final t = mime.split(';').first.trim().toLowerCase();
    const map = {
      'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif', 'video/mp4': 'mp4', 'video/webm': 'webm',
      'video/quicktime': 'mov', 'audio/mpeg': 'mp3', 'audio/mp3': 'mp3', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/wave': 'wav',
      'audio/ogg': 'ogg', 'audio/flac': 'flac', 'audio/aac': 'aac', 'audio/mp4': 'm4a', 'application/pdf': 'pdf', 'application/zip': 'zip',
    };
    return map[t] ?? '';
  }

  /// Guesses a file type from its first bytes when the provider gives none.
  static String sniff(Uint8List b) {
    bool at(List<int> sig, [int off = 0]) => b.length > off + sig.length && List.generate(sig.length, (i) => b[off + i]).join(',') == sig.join(',');
    if (at([0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (at([0xFF, 0xD8, 0xFF])) return 'jpg';
    if (at([0x52, 0x49, 0x46, 0x46]) && at([0x57, 0x45, 0x42, 0x50], 8)) return 'webp';
    if (at([0x52, 0x49, 0x46, 0x46]) && at([0x57, 0x41, 0x56, 0x45], 8)) return 'wav';
    if (at([0x47, 0x49, 0x46])) return 'gif';
    if (at([0x66, 0x74, 0x79, 0x70], 4)) return 'mp4';
    if (at([0x49, 0x44, 0x33]) || at([0xFF, 0xFB])) return 'mp3';
    if (at([0x4F, 0x67, 0x67, 0x53])) return 'ogg';
    if (at([0x25, 0x50, 0x44, 0x46])) return 'pdf';
    return 'bin';
  }

  static String kindOfExt(String ext) {
    if (const {'png', 'jpg', 'webp', 'gif'}.contains(ext)) return 'image';
    if (const {'mp3', 'wav', 'm4a', 'ogg', 'flac', 'aac'}.contains(ext)) return 'audio';
    if (const {'mp4', 'webm', 'mov'}.contains(ext)) return 'video';
    return 'file';
  }

  Future<String> _dir() async {
    final f = _mediaDir;
    final base = f == null ? '${await AgentTools.workspaceDir()}/media' : await f();
    final d = Directory(base);
    await d.create(recursive: true);
    return d.path;
  }

  Future<String> _saveBytes(Uint8List b, String ext, int i) async {
    final e = ext.isEmpty || ext == 'bin' ? sniff(b) : ext;
    final f = File('${await _dir()}/ai_${DateTime.now().millisecondsSinceEpoch}_$i.$e');
    await f.writeAsBytes(b);
    return f.path;
  }

  /// MEDIA_CARD line: the chat draws it as a card (see widgets/media_cards.dart).
  static String cardLine(Map<String, dynamic> card) => 'MEDIA_CARD ${jsonEncode(card)}';

  /// Reads a MEDIA_CARD tool result back (null when it is not one).
  static Map<String, dynamic>? readCard(String result) {
    if (!result.startsWith('MEDIA_CARD ')) return null;
    try {
      final j = jsonDecode(result.substring(11).split('\n').first);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> execute(String name, Map<String, dynamic> args, {String? callId}) async {
    try {
      if (name == providers) return await _providers(args);
      return await _call(args, callId);
    } on AiCallError catch (e) {
      return 'Error: ${e.message}';
    } on TimeoutException {
      return 'Error: the provider took too long to answer. Try once more, or a smaller request.';
    } on SocketException catch (e) {
      return 'Error: could not reach the provider (${e.message}). Check the base URL and the connection.';
    } catch (e) {
      return 'Error: $e';
    } finally {
      _progress(callId, null);
    }
  }

  static Map<String, String> _strMap(dynamic v) => v is Map ? v.map((k, x) => MapEntry('$k', '$x')) : <String, String>{};

  Future<String> _call(Map<String, dynamic> a, String? callId) async {
    final task = '${a['task'] ?? 'custom'}'.trim();
    AiProvider? prov;
    final pName = '${a['provider'] ?? ''}'.trim();
    if (pName.isNotEmpty) {
      prov = await byName(pName);
      if (prov == null && '${a['base_url'] ?? ''}'.trim().isEmpty) {
        final names = (await saved()).map((p) => p.name).join(', ');
        throw AiCallError('No saved connection called "$pName"${names.isEmpty ? ' (none saved yet)' : ' (saved: $names)'}. Ask the user for the base URL and key.');
      }
    }
    final base = '${a['base_url'] ?? ''}'.trim().isNotEmpty ? '${a['base_url']}'.trim() : (prov?.baseUrl ?? '');
    final path = '${a['path'] ?? ''}'.trim();
    if (base.isEmpty && !path.startsWith('http')) throw AiCallError('No provider given. Ask the user for the base URL and API key (or a saved connection name).');
    final keyArg = '${a['api_key'] ?? ''}'.trim().isNotEmpty ? '${a['api_key']}'.trim() : (prov?.keyRef ?? '');
    final key = await AiKeys.resolve(keyArg) ?? '';
    if (keyArg.startsWith(AiKeys.refPrefix) && key.isEmpty) {
      throw AiCallError('That key is not on this phone any more (it was hidden on another phone). Ask the user to paste it again.');
    }
    final model = '${a['model'] ?? ''}'.trim().isNotEmpty ? '${a['model']}'.trim() : (prov?.models.length == 1 ? prov!.models.first : '');
    final prompt = '${a['prompt'] ?? ''}';
    final payload = a['payload'] is Map ? Map<String, dynamic>.from(a['payload'] as Map) : (a['payload'] is String ? _tryMap('${a['payload']}') : null);
    final authHeader = '${a['auth_header'] ?? prov?.authHeader ?? 'Authorization'}';
    final authScheme = a.containsKey('auth_scheme') ? '${a['auth_scheme'] ?? ''}' : (prov?.authScheme ?? 'Bearer');
    final authQuery = '${a['auth_query'] ?? prov?.authQuery ?? ''}';
    final files = <String>[for (final f in (a['input_files'] is List ? a['input_files'] as List : const [])) await _resolveFile('$f')];
    for (final f in files) {
      if (!File(f).existsSync()) throw AiCallError('File not found: $f');
    }
    final req = build(
      task: task,
      baseUrl: base,
      key: key,
      model: model,
      prompt: prompt,
      path: path,
      method: '${a['method'] ?? ''}',
      payload: payload,
      headers: {...?prov?.headers, ..._strMap(a['headers'])},
      authHeader: authHeader,
      authScheme: authScheme,
      authQuery: authQuery,
      inputFiles: files,
      size: '${a['size'] ?? ''}',
      n: (a['n'] as num?)?.toInt() ?? 1,
      voice: '${a['voice'] ?? ''}',
      seconds: (a['seconds'] as num?)?.toInt() ?? 0,
    );
    final auth = {...authHeaders(key, header: authHeader, scheme: authScheme, query: authQuery), ...?prov?.headers, ..._strMap(a['headers'])}
      ..remove('Content-Type');
    final timeout = ((a['timeout_seconds'] as num?)?.toInt() ?? 600).clamp(30, 1800);
    _progress(callId, workingLine(task));
    final c = _client();
    try {
      var resp = await _sendPatient(c, req, callId);
      if (resp.statusCode >= 400) {
        throw AiCallError(AiKeys.scrub(errorLine(resp.statusCode, utf8.decode(resp.bodyBytes, allowMalformed: true), req.uri.path), key));
      }
      dynamic json;
      AiJob? usedJob;
      http.Response? binary = _isBinary(resp) ? resp : null;
      if (binary == null) {
        json = _json(resp);
        final job = jobOf(json, req, task: task, pollPath: '${a['poll_path'] ?? ''}', baseUrl: base, respHeaders: resp.headers);
        if (job != null) {
          usedJob = job;
          _progress(callId, progressLine(json, Duration.zero, task: task));
          final (j, bin) = await _poll(c, job, auth, timeoutSec: timeout, callId: callId, task: task);
          json = j;
          binary = bin;
        }
      }
      _progress(callId, 'Getting a file ready');
      final saved = <String>[];
      if (binary != null) {
        saved.add(await _saveBytes(binary.bodyBytes, extFor(binary.headers['content-type'] ?? '', binary.request?.url.toString() ?? ''), 0));
      }
      final outs = json == null ? AiOutputs() : parse(json);
      for (var i = 0; i < outs.blobs.length && saved.length < 8; i++) {
        saved.add(await _saveBytes(outs.blobs[i], extFor(outs.blobMimes[i], ''), saved.length));
      }
      for (final u in outs.urls) {
        if (saved.length >= 8) break;
        final uri = Uri.parse(u);
        // The provider's own file links need the key; other hosts (CDNs, signed links) must not get it.
        final sameHost = uri.host == req.uri.host;
        final dl = sameHost && authQuery.isNotEmpty && key.isNotEmpty && !uri.queryParameters.containsKey(authQuery)
            ? uri.replace(queryParameters: {...uri.queryParameters, authQuery: key})
            : uri;
        final r = await _sendPatient(c, AiRequest(method: 'GET', uri: dl, headers: sameHost ? auth : const {}), callId);
        if (r.statusCode >= 400) continue;
        if (!_isBinary(r) && (r.headers['content-type'] ?? '').contains('json')) continue;
        saved.add(await _saveBytes(r.bodyBytes, extFor(r.headers['content-type'] ?? '', u), saved.length));
      }
      // OpenAI-style videos also offer a still for the card's poster.
      final cu = usedJob?.contentUrl;
      if (cu != null && saved.isNotEmpty && kindOfExt(saved.first.split('.').last) == 'video') {
        try {
          final r = await _send(c, AiRequest(method: 'GET', uri: cu.replace(queryParameters: {...cu.queryParameters, 'variant': 'thumbnail'}), headers: auth));
          if (r.statusCode < 400 && (r.headers['content-type'] ?? '').startsWith('image/')) {
            saved.add(await _saveBytes(r.bodyBytes, extFor(r.headers['content-type'] ?? '', ''), saved.length));
          }
        } catch (_) {}
      }
      final text = outs.texts.isEmpty ? '' : outs.texts.first;
      if (saved.isEmpty) {
        if (outs.embeddings > 0) return 'Got ${outs.embeddings} embedding${outs.embeddings == 1 ? '' : 's'} of ${outs.dims} numbers each from ${model.isEmpty ? 'the model' : model}.';
        if (text.isNotEmpty) return AiKeys.scrub('Reply from ${model.isEmpty ? 'the model' : model}:\n$text', key);
        final raw = json == null ? resp.body : jsonEncode(json);
        return AiKeys.scrub('The provider answered but sent no picture, sound, video or text I could find. Its reply:\n'
            '${raw.length > 1500 ? '${raw.substring(0, 1500)}…' : raw}', key);
      }
      // A video that came with a still: the still is its poster, not a second result.
      String? poster;
      final videos = saved.where((p) => kindOfExt(p.split('.').last) == 'video').toList();
      final stills = saved.where((p) => kindOfExt(p.split('.').last) == 'image').toList();
      if (videos.length == 1 && stills.isNotEmpty && videos.length + stills.length == saved.length) {
        poster = stills.first;
        saved
          ..clear()
          ..add(videos.first);
      }
      final kinds = saved.map((p) => kindOfExt(p.split('.').last)).toSet();
      final kind = kinds.length == 1 ? (kinds.first == 'image' && saved.length > 1 ? 'images' : kinds.first) : 'files';
      final card = {
        'v': 1,
        'kind': kind,
        'files': saved,
        if (poster != null) 'poster': poster,
        'task': task,
        if (model.isNotEmpty) 'model': model,
        'provider': prov?.name ?? (Uri.tryParse(normBase(base))?.host ?? ''),
        if (prompt.isNotEmpty) 'prompt': prompt.length > 400 ? '${prompt.substring(0, 400)}…' : prompt,
        if (text.isNotEmpty) 'text': AiKeys.scrub(text.length > 600 ? '${text.substring(0, 600)}…' : text, key),
      };
      final what = switch (kind) {
        'image' => 'The picture',
        'images' => 'The ${saved.length} pictures',
        'audio' => 'The sound',
        'video' => 'The video',
        _ => 'The file${saved.length == 1 ? '' : 's'}',
      };
      return '${cardLine(card)}\n$what ${saved.length == 1 && kind != 'images' ? 'is' : 'are'} shown to the user as a card and saved in their Library '
          '(${saved.join(', ')}). Do not repeat the path; say in one line what you made and offer one tweak.';
    } finally {
      c.close();
    }
  }

  static Map<String, dynamic>? _tryMap(String s) {
    try {
      final j = jsonDecode(s);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveFile(String p) async {
    final t = p.trim().replaceFirst('file://', '');
    if (t.startsWith('/')) return t;
    final f = _mediaDir;
    final media = f == null ? '${await AgentTools.workspaceDir()}/media' : await f();
    final ws = media.endsWith('/media') ? media.substring(0, media.length - 6) : media;
    return '$ws/$t';
  }

  Future<String> _providers(Map<String, dynamic> a) async {
    final action = '${a['action'] ?? 'list'}';
    final all = await saved();
    switch (action) {
      case 'list':
        if (all.isEmpty) return 'No AI connections saved yet. The user can give one in chat: base URL, API key and model.';
        return [
          for (final p in all)
            '${p.name}: ${p.baseUrl}${p.models.isEmpty ? '' : ' · models: ${p.models.join(', ')}'} · key ${p.keyRef.isEmpty ? 'none' : 'saved on this phone'}'
        ].join('\n');
      case 'save':
        final name = '${a['name'] ?? ''}'.trim();
        final base = normBase('${a['base_url'] ?? ''}');
        if (name.isEmpty || base.isEmpty) throw AiCallError('Saving needs a name and a base_url.');
        var keyRef = '${a['api_key'] ?? ''}'.trim();
        if (keyRef.isNotEmpty && !keyRef.startsWith(AiKeys.refPrefix)) keyRef = await AiKeys.keep(keyRef);
        if (keyRef.isNotEmpty) {
          // Make sure the key itself is in encrypted storage (it may only be in this session's memory).
          final k = await AiKeys.resolve(keyRef);
          if (k == null || k.isEmpty) throw AiCallError('That key is not on this phone. Ask the user to paste it again.');
          await AiKeys.keep(k);
        }
        final p = AiProvider(
          name: name,
          baseUrl: base,
          keyRef: keyRef,
          authHeader: '${a['auth_header'] ?? 'Authorization'}',
          authScheme: a.containsKey('auth_scheme') ? '${a['auth_scheme'] ?? ''}' : 'Bearer',
          authQuery: '${a['auth_query'] ?? ''}',
          headers: _strMap(a['headers']),
          models: [for (final m in (a['models'] is List ? a['models'] as List : const [])) '$m'],
        );
        all.removeWhere((x) => x.name.toLowerCase() == name.toLowerCase());
        all.add(p);
        await _saveAll(all);
        return 'Saved "$name" (${p.baseUrl}). The key stays only on this phone, encrypted. Next time the user can just say "use $name".';
      case 'forget':
        final name = '${a['name'] ?? ''}'.trim().toLowerCase();
        final before = all.length;
        final gone = all.where((x) => x.name.toLowerCase() == name).toList();
        all.removeWhere((x) => x.name.toLowerCase() == name);
        if (all.length == before) return 'No saved connection called "${a['name']}".';
        await _saveAll(all);
        for (final g in gone) {
          final r = AiKeys.refPattern.firstMatch(g.keyRef)?.group(1);
          if (r != null && !all.any((x) => x.keyRef == g.keyRef)) await store.delete('ai_key_$r');
        }
        return 'Removed "${a['name']}" and its key from this phone.';
      case 'models':
      case 'test':
        final p = '${a['name'] ?? ''}'.trim().isEmpty ? null : await byName('${a['name']}');
        final base = '${a['base_url'] ?? ''}'.trim().isNotEmpty ? '${a['base_url']}' : (p?.baseUrl ?? '');
        if (base.isEmpty) throw AiCallError('Give a saved name or a base_url.');
        final keyArg = '${a['api_key'] ?? ''}'.trim().isNotEmpty ? '${a['api_key']}' : (p?.keyRef ?? '');
        final key = await AiKeys.resolve(keyArg) ?? '';
        final authHeader = '${a['auth_header'] ?? p?.authHeader ?? 'Authorization'}';
        final authScheme = a.containsKey('auth_scheme') ? '${a['auth_scheme'] ?? ''}' : (p?.authScheme ?? 'Bearer');
        final authQuery = '${a['auth_query'] ?? p?.authQuery ?? ''}';
        var uri = join(base, '/models');
        if (authQuery.isNotEmpty && key.isNotEmpty) uri = uri.replace(queryParameters: {authQuery: key});
        final c = _client();
        try {
          final r = await _sendPatient(
              c,
              AiRequest(method: 'GET', uri: uri, headers: {
                ...authHeaders(key, header: authHeader, scheme: authScheme, query: authQuery),
                ...?p?.headers,
                ..._strMap(a['headers']),
              }),
              null);
          if (r.statusCode >= 400) {
            return AiKeys.scrub('Error: ${errorLine(r.statusCode, r.body, uri.path)}${r.statusCode == 404 ? ' This provider may not list models; the user can name the model.' : ''}', key);
          }
          final ids = modelIds(_json(r));
          if (action == 'test') return 'Connection works (${normBase(base)}): ${ids.length} model${ids.length == 1 ? '' : 's'} listed.';
          if (ids.isEmpty) return 'The provider answered but listed no models. Ask the user which model to use.';
          if (p != null) {
            p.models = ids.take(40).toList();
            await _saveAll(all.map((x) => x.name == p.name ? p : x).toList());
          }
          return 'Models (${ids.length}): ${ids.take(80).join(', ')}${ids.length > 80 ? ', …' : ''}';
        } finally {
          c.close();
        }
    }
    throw AiCallError('Unknown action "$action".');
  }

  /// Model ids from a /models reply (OpenAI `data[].id`, Google `models[].name`, or a plain list).
  static List<String> modelIds(dynamic j) {
    final list = j is Map ? (j['data'] ?? j['models'] ?? j['results']) : j;
    if (list is! List) return [];
    return [
      for (final m in list)
        if (m is String) m else if (m is Map && (m['id'] ?? m['name'] ?? m['model']) != null) '${m['id'] ?? m['name'] ?? m['model']}'
    ];
  }
}
