import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ai_keys.dart';
import 'ai_models.dart';
import 'media_providers.dart';
import 'media_store.dart';
import 'turn_visuals.dart';

/// Making pictures, video, speech and sound with the user's own media providers (owner 2026-11-04,
/// docs/media-providers.md). Runs on the phone, straight against the provider: nothing passes SubMac's servers.
///
/// Request building ([MediaGen.build]) and answer reading ([MediaGen.read]) are pure and tested per protocol with a mock
/// HTTP client; [MediaGen.run] sends, polls long jobs (with progress, cancellable) and downloads the result;
/// [MediaGen.generate] is the `media_generate` tool: it saves the result in the calling chat's folder and answers with a
/// MEDIA_CARD the chat draws as a card.

/// What to make.
class MediaAsk {
  const MediaAsk({
    required this.kind,
    required this.prompt,
    this.model = '',
    this.size = '',
    this.aspect = '',
    this.duration,
    this.voice = '',
    this.image,
    this.imageMime = 'image/png',
  });
  final MediaKind kind;
  final String prompt;

  /// Overrides the provider's model when set.
  final String model;

  /// WxH (pictures) when asked for.
  final String size;

  /// "16:9", "portrait"... when asked for.
  final String aspect;

  /// Seconds (video, sound, music).
  final int? duration;
  final String voice;

  /// A picture to edit or animate.
  final Uint8List? image;
  final String imageMime;

  String get dataUri => image == null ? '' : 'data:$imageMime;base64,${base64Encode(image!)}';
}

/// A file part of a multipart request.
class MediaFilePart {
  const MediaFilePart(this.field, this.bytes, this.filename, this.mime);
  final String field;
  final Uint8List bytes;
  final String filename;
  final String mime;
}

/// One HTTP request, ready to send. [tag] says which step of the protocol it is (start, poll, result, content,
/// cancel, download, test), so the answer is read the right way.
class MediaCall {
  MediaCall(this.method, this.uri, {Map<String, String>? headers, this.json, Map<String, String>? fields, List<MediaFilePart>? files, this.tag = 'start'})
      : headers = headers ?? {},
        fields = fields ?? {},
        files = files ?? [];
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? json;
  final Map<String, String> fields;
  final List<MediaFilePart> files;
  final String tag;

  bool get multipart => files.isNotEmpty || fields.isNotEmpty;

  Map<String, dynamic>? get body => json is Map ? Map<String, dynamic>.from(json as Map) : null;

  http.BaseRequest toRequest() {
    if (multipart) {
      final r = http.MultipartRequest(method, uri)..headers.addAll({...headers}..remove('content-type'));
      r.fields.addAll(fields);
      for (final f in files) {
        r.files.add(http.MultipartFile.fromBytes(f.field, f.bytes, filename: f.filename));
      }
      return r;
    }
    final r = http.Request(method, uri)..headers.addAll(headers);
    if (json != null) {
      r.headers['content-type'] = 'application/json';
      r.body = jsonEncode(json);
    }
    return r;
  }

  MediaCall again({String? tag}) => MediaCall(method, uri, headers: headers, json: json, fields: fields, files: files, tag: tag ?? this.tag);
}

/// A finished file the provider sent inline.
class MediaOut {
  MediaOut(this.bytes, this.mime, {this.url = ''});
  final Uint8List bytes;
  final String mime;
  final String url;
}

/// What one answer means: finished outputs, or a job still running (poll again), or a result to fetch next.
class MediaStep {
  MediaStep({List<MediaOut>? blobs, List<String>? urls, this.next, this.cancel, this.progress, this.text = ''})
      : blobs = blobs ?? [],
        urls = urls ?? [];
  final List<MediaOut> blobs;

  /// Files to download (https, or data: URIs).
  final List<String> urls;

  /// The request to send next (a poll while running, or the result/content once done).
  final MediaCall? next;

  /// How to stop the job at the provider.
  final MediaCall? cancel;

  /// A short progress line ("Queued, 2 ahead", "40%").
  final String? progress;

  /// Words the model sent with the result.
  final String text;

  bool get done => next == null;
  bool get empty => blobs.isEmpty && urls.isEmpty;
}

class MediaGenError implements Exception {
  MediaGenError(this.message, {this.status = 0});
  final String message;
  final int status;
  @override
  String toString() => message;
}

class MediaCancelled implements Exception {
  const MediaCancelled();
  @override
  String toString() => 'stopped';
}

class MediaGen {
  MediaGen({http.Client Function()? client, Future<void> Function(Duration)? sleep, MediaProviderStore? store})
      : _client = client ?? http.Client.new,
        _sleep = sleep ?? Future<void>.delayed,
        _store = store;

  static MediaGen I = MediaGen();

  final http.Client Function() _client;
  final Future<void> Function(Duration) _sleep;
  final MediaProviderStore? _store;
  MediaProviderStore get store => _store ?? MediaProviderStore.I;

  static const toolName = 'media_generate';
  static const names = {toolName};

  static const runwayVersion = '2024-11-06';

  // ================================================================== the tool

  /// The tool, offered (through find_tools, never in the per-message listing) only while at least one media provider
  /// is set up. Its description names the providers the user has, so the agent can pick one by name.
  static List<Map<String, dynamic>> definitions(MediaProviderStore s) {
    if (!s.hasAny) return const [];
    final lines = <String>[];
    for (final k in MediaKind.values) {
      final list = s.usableOf(k);
      if (list.isEmpty) continue;
      lines.add('${k.id}: ${[for (final p in list) '${p.label} (${p.model}${p.id == s.defaultId(k) ? ', default' : ''})'].join('; ')}');
    }
    final kinds = [for (final k in MediaKind.values) if (s.has(k)) k.id];
    return [
      {
        'type': 'function',
        'function': {
          'name': toolName,
          'description': 'Make a picture, video, spoken audio (text to speech) or music/sound effect with the USER\'s own media '
              'providers (their keys, called from this phone; it costs on their account). Use it only when the user asks for '
              'one ("make", "draw", "generate", "say this out loud", "use my <provider>"); never make media they did not ask '
              'for. The result is shown to them as a card in this chat and saved in their files; do not repeat its path. '
              'Video takes minutes: tell them it is on its way. To edit or animate a picture, pass it as input_image. '
              'Set up now: ${lines.join(' | ')}.',
          'parameters': {
            'type': 'object',
            'properties': {
              'kind': {'type': 'string', 'enum': kinds, 'description': 'image, video, speech (text to speech) or audio (music, sound effects).'},
              'prompt': {'type': 'string', 'description': 'What to make: a rich description (subject, style, light, camera, mood), or for speech the exact words to say.'},
              'provider': {'type': 'string', 'description': 'Which of the user\'s providers (name as listed). Empty = the default for this kind.'},
              'model': {'type': 'string', 'description': 'A model id, only when the user named one. Empty = the provider\'s model.'},
              'aspect': {'type': 'string', 'description': 'Shape: 1:1, 16:9, 9:16, 4:3, 3:4 (pictures and video).'},
              'size': {'type': 'string', 'description': 'Picture size WxH, e.g. 1024x1024, when the user asked for one.'},
              'duration': {'type': 'integer', 'description': 'Seconds, for video, music or a sound.'},
              'voice': {'type': 'string', 'description': 'Voice for speech (the provider\'s voice name or id). Empty = the saved voice.'},
              'input_image': {'type': 'string', 'description': 'Path of a picture in the workspace to edit (image) or animate (video).'},
            },
            'required': ['kind', 'prompt'],
          },
        },
      }
    ];
  }

  /// Where a chat's media goes: the owner's chats in `media/`, a bot's private chat in its own folder, team work in
  /// its team's folder (a team's results never land in a bot's or the owner's folder).
  static String folderFor(String workspace, {String botFolder = '', String teamFolder = ''}) {
    final ws = workspace.endsWith('/') ? workspace.substring(0, workspace.length - 1) : workspace;
    if (teamFolder.isNotEmpty) return '$ws/$teamFolder/media';
    if (botFolder.isNotEmpty) return '$ws/$botFolder/media';
    return '$ws/media';
  }

  /// File cards for the media a team member's turn made (its tool outputs), added under its reply in the team chat,
  /// where tool steps are not shown.
  static String cardsFromOutputs(Iterable<String> outputs) {
    final files = <String>[];
    for (final o in outputs) {
      final card = AiModels.readCard(o);
      if (card != null && card['files'] is List) {
        for (final f in card['files'] as List) {
          if (!files.contains('$f')) files.add('$f');
        }
      }
      final m = RegExp(r'^(?:IMAGE|AUDIO|VIDEO)_SAVED (\S+)').firstMatch(o);
      if (m != null && !files.contains(m.group(1)!)) files.add(m.group(1)!);
    }
    return files.map((f) => '```file\n$f\n```').join('\n\n');
  }

  /// The `media_generate` tool. [folder] is the calling chat's media folder ([folderFor]); [cancelled] says the chat's
  /// turn was stopped; [progress] gets short lines while a long job runs.
  Future<String> generate(Map<String, dynamic> args,
      {required String folder, String workspace = '', bool Function()? cancelled, void Function(String line)? progress}) async {
    final kind = MediaKindX.parse('${args['kind'] ?? ''}');
    if (kind == null) return 'Error: kind must be image, video, speech or audio.';
    final prompt = '${args['prompt'] ?? args['text'] ?? ''}'.trim();
    if (prompt.isEmpty) return 'Error: give a prompt (for speech: the words to say).';
    final named = '${args['provider'] ?? ''}'.trim();
    final p = store.pick(kind, named: named);
    if (p == null) {
      final have = store.usableOf(kind).map((x) => x.label).join(', ');
      if (named.isNotEmpty && have.isNotEmpty) return 'Error: no ${kind.id} provider called "$named". Set up for ${kind.id}: $have.';
      return 'Error: no ${kind.label.toLowerCase()} provider is set up. The user can add one in Settings > Media models '
          '(their own key, e.g. OpenAI, Google, fal, Replicate, ElevenLabs). Tell them that in one line.';
    }
    final key = store.secretFor(p) ?? '';
    Uint8List? image;
    var imageMime = 'image/png';
    final input = '${args['input_image'] ?? args['image'] ?? ''}'.trim();
    if (input.isNotEmpty) {
      final f = File(workspace.isEmpty ? input : TurnVisuals.resolve(input, workspace));
      if (!await f.exists()) return 'Error: input_image not found: $input';
      image = await f.readAsBytes();
      imageMime = MediaStore.mimeOf(f.path);
      if (!imageMime.startsWith('image/')) imageMime = 'image/png';
    }
    final ask = MediaAsk(
      kind: kind,
      prompt: prompt,
      model: '${args['model'] ?? ''}'.trim(),
      size: '${args['size'] ?? ''}'.trim(),
      aspect: '${args['aspect'] ?? args['aspect_ratio'] ?? ''}'.trim(),
      duration: (args['duration'] as num?)?.toInt() ?? int.tryParse('${args['duration'] ?? ''}'),
      voice: '${args['voice'] ?? ''}'.trim(),
      image: image,
      imageMime: imageMime,
    );
    final model = ask.model.isEmpty ? p.model : ask.model;
    try {
      final outs = await run(p, key, ask, cancelled: cancelled, progress: progress);
      final saved = await save(outs, folder, kind);
      for (final s in saved) {
        unawaited(MediaStore.I.keep(s).then((_) {}, onError: (_) {}));
      }
      final cardKind = switch (kind) {
        MediaKind.image => saved.length > 1 ? 'images' : 'image',
        MediaKind.video => 'video',
        MediaKind.speech || MediaKind.audio => 'audio',
      };
      final card = {
        'v': 1,
        'kind': cardKind,
        'files': saved,
        'task': switch (kind) { MediaKind.image => 'image', MediaKind.video => 'video', MediaKind.speech => 'speech', MediaKind.audio => 'music' },
        'model': model,
        'provider': p.label,
        'prompt': prompt.length > 400 ? '${prompt.substring(0, 400)}…' : prompt,
      };
      return '${AiModels.cardLine(card)}\nThe ${kind.noun} (${p.label}, $model) is shown to the user as a card and saved '
          '(${saved.join(', ')}). Do not repeat the path; say in one line what you made and offer one tweak.';
    } on MediaCancelled {
      return 'Stopped: the ${kind.noun} was cancelled before it finished.';
    } on MediaGenError catch (e) {
      return 'Error from ${p.label}: ${AiKeys.scrub(e.message, key)}';
    } on TimeoutException {
      return 'Error: ${p.label} took too long to answer. Try once more, or a shorter request.';
    } on SocketException catch (e) {
      return 'Error: could not reach ${p.label} (${e.message}). Check the base URL and the connection.';
    } catch (e) {
      return 'Error from ${p.label}: ${AiKeys.scrub('$e', key)}';
    }
  }

  /// generate_image with the user's image provider (the server has no picture model, owner 2026-11-04): the result in
  /// the IMAGE_SAVED shape generate_image always answered with.
  Future<String> generateImageCompat(Map<String, dynamic> args, {required String folder, bool Function()? cancelled, void Function(String)? progress}) async {
    final out = await generate({...args, 'kind': 'image'}, folder: folder, cancelled: cancelled, progress: progress);
    final card = AiModels.readCard(out);
    final files = card?['files'];
    if (files is List && files.isNotEmpty) {
      return 'IMAGE_SAVED ${files.first}\nThe image (${card!['provider']}, ${card['model']}) is shown to the user and saved in their Library.';
    }
    return out;
  }

  // ================================================================== running

  /// Sends the job, polls it while it runs and downloads what it made. Throws [MediaGenError], [MediaCancelled].
  Future<List<MediaOut>> run(MediaProvider p, String key, MediaAsk ask,
      {bool Function()? cancelled, void Function(String line)? progress, Duration? timeout}) async {
    final limit = timeout ?? (ask.kind == MediaKind.video ? const Duration(minutes: 20) : const Duration(minutes: 6));
    final start = DateTime.now();
    final c = _client();
    bool stop() => cancelled?.call() ?? false;
    MediaCall? cancelCall;
    try {
      var call = build(p, key, ask);
      progress?.call('Starting the ${ask.kind.noun} with ${p.label}');
      var wait = 2;
      while (true) {
        if (stop()) throw const MediaCancelled();
        final resp = await _send(c, call, ask.kind == MediaKind.video && call.tag == 'start' ? 300 : 180);
        final step = read(p, key, call, resp.statusCode, resp.headers, resp.bodyBytes);
        cancelCall = step.cancel ?? cancelCall;
        if (step.done) {
          if (step.empty) {
            throw MediaGenError(step.text.isNotEmpty
                ? 'The provider answered with text only: ${step.text.length > 300 ? '${step.text.substring(0, 300)}…' : step.text}'
                : 'The provider answered but sent no ${ask.kind.noun}.');
          }
          progress?.call('Getting the file ready');
          final outs = [...step.blobs];
          for (final u in step.urls) {
            if (stop()) throw const MediaCancelled();
            final o = await _download(c, p, key, u);
            if (o != null) outs.add(o);
          }
          if (outs.isEmpty) throw MediaGenError('The ${ask.kind.noun} was made but could not be downloaded.');
          return outs;
        }
        final next = step.next!;
        if (next.tag == 'poll') {
          final elapsed = DateTime.now().difference(start);
          if (elapsed > limit) {
            throw MediaGenError('The job is still running after ${limit.inMinutes} min; it may still finish at ${p.label}.');
          }
          final line = step.progress == null ? 'Working' : step.progress!;
          progress?.call('${_cap(ask.kind.noun)} with ${p.label}: $line · ${_clock(elapsed)}');
          // Waits in 1 s slices so a stop is noticed at once.
          for (var i = 0; i < wait; i++) {
            if (stop()) throw const MediaCancelled();
            await _sleep(const Duration(seconds: 1));
          }
          wait = (wait * 1.5).ceil().clamp(2, 10);
        }
        call = next;
      }
    } on MediaCancelled {
      final cc = cancelCall;
      if (cc != null) {
        try {
          await _send(c, cc, 20);
        } catch (_) {}
      }
      rethrow;
    } finally {
      c.close();
    }
  }

  static String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
  static String _clock(Duration d) => d.inMinutes > 0 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';

  Future<http.Response> _send(http.Client c, MediaCall call, int seconds) async {
    var tries = 0;
    while (true) {
      final resp = await http.Response.fromStream(await c.send(call.toRequest()).timeout(Duration(seconds: seconds)));
      // A busy provider: wait it out twice (Retry-After up to 30 s).
      if (resp.statusCode == 429 && tries < 2 && call.tag != 'cancel') {
        tries++;
        final ra = int.tryParse(resp.headers['retry-after'] ?? '') ?? 5 * tries;
        await _sleep(Duration(seconds: ra.clamp(1, 30)));
        continue;
      }
      return resp;
    }
  }

  Future<MediaOut?> _download(http.Client c, MediaProvider p, String key, String url) async {
    if (url.startsWith('data:')) {
      final comma = url.indexOf(',');
      if (comma < 0) return null;
      final head = url.substring(5, comma);
      final mime = head.split(';').first;
      try {
        return MediaOut(base64Decode(url.substring(comma + 1)), mime.isEmpty ? 'application/octet-stream' : mime);
      } catch (_) {
        return null;
      }
    }
    final u = Uri.tryParse(url);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http')) return null;
    // The provider's own file links need the key; other hosts (CDNs, signed links) never get it.
    final base = Uri.tryParse(p.apiBase);
    final same = base != null && base.host == u.host;
    final resp = await _send(c, MediaCall('GET', u, headers: same ? authHeaders(p, key) : {}, tag: 'download'), 300);
    if (resp.statusCode >= 400) return null;
    return MediaOut(resp.bodyBytes, (resp.headers['content-type'] ?? '').split(';').first.trim(), url: url);
  }

  /// Saves [outs] in [dir]; returns the paths.
  static Future<List<String>> save(List<MediaOut> outs, String dir, MediaKind kind) async {
    final d = Directory(dir);
    await d.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final paths = <String>[];
    for (var i = 0; i < outs.length && i < 8; i++) {
      final o = outs[i];
      var ext = AiModels.extFor(o.mime, o.url);
      if (ext.isEmpty || ext == 'json' || ext == 'txt') ext = AiModels.sniff(o.bytes);
      if (ext == 'bin') {
        ext = switch (kind) { MediaKind.image => 'png', MediaKind.video => 'mp4', _ => 'mp3' };
      }
      final f = File('${d.path}/${kind.id}_${stamp}_$i.$ext');
      await f.writeAsBytes(o.bytes, flush: true);
      paths.add(f.path);
    }
    return paths;
  }

  // ================================================================== building requests

  /// The headers that carry the key, per protocol (never the URL).
  static Map<String, String> authHeaders(MediaProvider p, String? key) {
    final k = (key ?? '').trim();
    final h = <String, String>{...p.headers};
    if (k.isNotEmpty) {
      switch (p.wire) {
        case MediaWire.geminiInteractions:
        case MediaWire.geminiGenerate:
        case MediaWire.veo:
          h['x-goog-api-key'] = k;
        case MediaWire.fal:
          h['Authorization'] = 'Key $k';
        case MediaWire.elevenTts:
        case MediaWire.elevenSound:
        case MediaWire.elevenMusic:
          h['xi-api-key'] = k;
        default:
          h['Authorization'] = 'Bearer $k';
      }
    }
    if (p.wire == MediaWire.runway) h['X-Runway-Version'] = runwayVersion;
    return h;
  }

  /// Portrait, landscape or square from the ask ("9:16", "portrait", a WxH size).
  static String shapeOf(MediaAsk a) {
    final s = a.aspect.toLowerCase().trim();
    final m = RegExp(r'^(\d{1,5})\s*[x:]\s*(\d{1,5})$').firstMatch(s.isNotEmpty ? s : a.size.toLowerCase().trim());
    if (m != null) {
      final w = int.parse(m.group(1)!), h = int.parse(m.group(2)!);
      if (w == h) return 'square';
      return w > h ? 'landscape' : 'portrait';
    }
    if (const {'portrait', 'tall', 'vertical'}.contains(s)) return 'portrait';
    if (const {'landscape', 'wide', 'horizontal'}.contains(s)) return 'landscape';
    if (s == 'square') return 'square';
    return '';
  }

  /// An aspect ratio string ("16:9") for APIs that take one; empty when nothing was asked for.
  static String ratioOf(MediaAsk a) {
    final s = a.aspect.trim();
    if (RegExp(r'^\d{1,2}:\d{1,2}$').hasMatch(s)) return s;
    return switch (shapeOf(a)) { 'landscape' => '16:9', 'portrait' => '9:16', 'square' => '1:1', _ => '' };
  }

  static String _openaiSize(MediaAsk a, String model) {
    if (RegExp(r'^\d{3,4}x\d{3,4}$').hasMatch(a.size)) return a.size;
    final shape = shapeOf(a);
    if (model.startsWith('dall-e-3')) return switch (shape) { 'landscape' => '1792x1024', 'portrait' => '1024x1792', _ => '1024x1024' };
    if (model.startsWith('dall-e-2')) return '1024x1024';
    return switch (shape) { 'landscape' => '1536x1024', 'portrait' => '1024x1536', _ => '1024x1024' };
  }

  static (int, int) _wh(MediaAsk a) {
    final m = RegExp(r'^(\d{3,4})x(\d{3,4})$').firstMatch(a.size);
    if (m != null) return (int.parse(m.group(1)!), int.parse(m.group(2)!));
    return switch (shapeOf(a)) { 'landscape' => (1344, 768), 'portrait' => (768, 1344), _ => (1024, 1024) };
  }

  static String _ext(String mime) => switch (mime) { 'image/jpeg' => 'jpg', 'image/webp' => 'webp', 'image/gif' => 'gif', _ => 'png' };

  static Uri _u(String base, String path, [Map<String, String>? q]) {
    final u = Uri.parse('$base$path');
    return q == null ? u : u.replace(queryParameters: {...u.queryParameters, ...q});
  }

  /// The first request of a job.
  static MediaCall build(MediaProvider p, String key, MediaAsk a) {
    final base = p.apiBase;
    final model = a.model.isNotEmpty ? a.model : p.model;
    final auth = authHeaders(p, key);
    final h = {'accept': 'application/json', ...auth};
    final ratio = ratioOf(a);
    final landscape = shapeOf(a) != 'portrait';
    switch (p.wire) {
      case MediaWire.openaiImages:
        final vendor = p.vendor;
        if (a.image != null) {
          if (vendor == 'xai') {
            return MediaCall('POST', _u(base, '/images/edits'), headers: h, json: {
              'model': model,
              'prompt': a.prompt,
              'image': {'url': a.dataUri, 'type': 'image_url'},
            });
          }
          return MediaCall('POST', _u(base, '/images/edits'),
              headers: h,
              fields: {'model': model, 'prompt': a.prompt, if (vendor != 'together') 'size': _openaiSize(a, model)},
              files: [MediaFilePart('image', a.image!, 'input.${_ext(a.imageMime)}', a.imageMime)]);
        }
        final body = <String, dynamic>{'model': model, 'prompt': a.prompt, 'n': 1};
        if (vendor == 'together') {
          final (w, hh) = _wh(a);
          body
            ..['width'] = w
            ..['height'] = hh
            ..['response_format'] = 'b64_json';
        } else if (vendor == 'xai') {
          if (ratio.isNotEmpty) body['aspect_ratio'] = ratio;
          body['response_format'] = 'b64_json';
        } else {
          body['size'] = _openaiSize(a, model);
          // dall-e answers with a link that expires unless asked for the bytes; gpt-image always sends bytes.
          if (model.startsWith('dall-e')) body['response_format'] = 'b64_json';
        }
        return MediaCall('POST', _u(base, '/images/generations'), headers: h, json: body);

      case MediaWire.openrouterImage:
        final content = a.image == null
            ? a.prompt
            : [
                {'type': 'text', 'text': a.prompt},
                {'type': 'image_url', 'image_url': {'url': a.dataUri}},
              ];
        return MediaCall('POST', _u(base, '/chat/completions'), headers: h, json: {
          'model': model,
          'messages': [
            {'role': 'user', 'content': content}
          ],
          'modalities': ['image', 'text'],
          if (ratio.isNotEmpty) 'image_config': {'aspect_ratio': ratio},
        });

      case MediaWire.geminiInteractions:
        final parts = <Map<String, dynamic>>[
          if (a.image != null) {'type': 'image', 'data': base64Encode(a.image!), 'mime_type': a.imageMime},
          {'type': 'text', 'text': a.prompt},
        ];
        final Map<String, dynamic> body;
        switch (a.kind) {
          case MediaKind.speech:
          case MediaKind.audio:
            body = {
              'model': model,
              'input': [
                {'type': 'user_input', 'content': parts}
              ],
              'response_format': {'type': 'audio'},
              'generation_config': {
                'speech_config': [
                  {'voice': a.voice.isNotEmpty ? a.voice : (p.voice.isNotEmpty ? p.voice : 'Kore')}
                ]
              },
            };
          case MediaKind.video:
            body = {
              'model': model,
              'input': parts,
              'response_format': {'type': 'video', 'aspect_ratio': landscape ? '16:9' : '9:16'},
              // Minutes of work: the job runs on Google's side and is polled, not held open on one request.
              'background': true,
            };
          case MediaKind.image:
            body = {
              'model': model,
              'input': parts,
              'response_format': {'type': 'image', if (ratio.isNotEmpty) 'aspect_ratio': ratio},
            };
        }
        return MediaCall('POST', _u(base, '/interactions'), headers: h, json: body);

      case MediaWire.geminiGenerate:
        final speech = a.kind == MediaKind.speech || a.kind == MediaKind.audio;
        return MediaCall('POST', _u(base, '/models/$model:generateContent'), headers: h, json: {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': a.prompt},
                if (a.image != null) {'inline_data': {'mime_type': a.imageMime, 'data': base64Encode(a.image!)}},
              ],
            }
          ],
          'generationConfig': speech
              ? {
                  'responseModalities': ['AUDIO'],
                  'speechConfig': {
                    'voiceConfig': {
                      'prebuiltVoiceConfig': {'voiceName': a.voice.isNotEmpty ? a.voice : (p.voice.isNotEmpty ? p.voice : 'Kore')}
                    }
                  },
                }
              : {
                  'responseModalities': ['TEXT', 'IMAGE'],
                  if (ratio.isNotEmpty) 'imageConfig': {'aspectRatio': ratio},
                },
        });

      case MediaWire.veo:
        return MediaCall('POST', _u(base, '/models/$model:predictLongRunning'), headers: h, json: {
          'instances': [
            {
              'prompt': a.prompt,
              if (a.image != null) 'image': {'bytesBase64Encoded': base64Encode(a.image!), 'mimeType': a.imageMime},
            }
          ],
          'parameters': {
            'aspectRatio': landscape ? '16:9' : '9:16',
            if (a.duration != null) 'durationSeconds': a.duration!.clamp(4, 8),
          },
        });

      case MediaWire.fal:
        final input = <String, dynamic>{'prompt': a.prompt};
        if (a.image != null) input['image_url'] = a.dataUri;
        switch (a.kind) {
          case MediaKind.image:
            final shape = shapeOf(a);
            if (shape.isNotEmpty) input['image_size'] = switch (shape) { 'landscape' => 'landscape_16_9', 'portrait' => 'portrait_16_9', _ => 'square_hd' };
          case MediaKind.video:
            if (ratio.isNotEmpty) input['aspect_ratio'] = ratio;
            if (a.duration != null) input['duration'] = '${a.duration}';
          case MediaKind.audio:
            if (a.duration != null) input['seconds_total'] = a.duration;
          case MediaKind.speech:
            input['text'] = a.prompt;
            if (a.voice.isNotEmpty || p.voice.isNotEmpty) input['voice'] = a.voice.isNotEmpty ? a.voice : p.voice;
        }
        final path = model.startsWith('/') ? model : '/$model';
        return MediaCall('POST', _u(base, path), headers: h, json: input);

      case MediaWire.replicate:
        final input = <String, dynamic>{'prompt': a.prompt};
        if (a.image != null) input['image'] = a.dataUri;
        if (ratio.isNotEmpty && (a.kind == MediaKind.image || a.kind == MediaKind.video)) input['aspect_ratio'] = ratio;
        if (a.duration != null && a.kind != MediaKind.image) input['duration'] = a.duration;
        if (a.kind == MediaKind.speech) {
          input['text'] = a.prompt;
          if (a.voice.isNotEmpty || p.voice.isNotEmpty) input['voice'] = a.voice.isNotEmpty ? a.voice : p.voice;
        }
        // Short jobs answer on the same request (up to 60 s); video is polled.
        final hh = {...h, if (a.kind != MediaKind.video) 'Prefer': 'wait=60'};
        final colon = model.indexOf(':');
        if (colon > 0) {
          return MediaCall('POST', _u(base, '/predictions'), headers: hh, json: {'version': model.substring(colon + 1), 'input': input});
        }
        return MediaCall('POST', _u(base, '/models/$model/predictions'), headers: hh, json: {'input': input});

      case MediaWire.stability:
        final fields = <String, String>{'prompt': a.prompt, 'output_format': 'png'};
        if (a.image != null) {
          fields['mode'] = 'image-to-image';
          fields['strength'] = '0.65';
        } else if (ratio.isNotEmpty) {
          fields['aspect_ratio'] = ratio;
        }
        return MediaCall('POST', _u(base, '/stable-image/generate/$model'),
            headers: {...auth, 'accept': 'image/*'},
            fields: fields,
            files: a.image == null ? [] : [MediaFilePart('image', a.image!, 'input.${_ext(a.imageMime)}', a.imageMime)]);

      case MediaWire.runway:
        final veoLike = model.startsWith('veo');
        final dur = veoLike ? _nearest(a.duration ?? 8, const [4, 6, 8]) : (a.duration ?? 5).clamp(2, 10);
        final body = <String, dynamic>{
          'model': model,
          'promptText': a.prompt.length > 1000 ? a.prompt.substring(0, 1000) : a.prompt,
          'ratio': landscape ? '1280:720' : '720:1280',
          'duration': dur,
        };
        if (a.image != null) {
          body['promptImage'] = a.dataUri;
          return MediaCall('POST', _u(base, '/image_to_video'), headers: h, json: body);
        }
        return MediaCall('POST', _u(base, '/text_to_video'), headers: h, json: body);

      case MediaWire.openaiVideos:
        final secs = '${_nearest(a.duration ?? 4, const [4, 8, 12])}';
        final size = landscape ? '1280x720' : '720x1280';
        if (a.image != null) {
          return MediaCall('POST', _u(base, '/videos'),
              headers: h,
              fields: {'model': model, 'prompt': a.prompt, 'seconds': secs, 'size': size},
              files: [MediaFilePart('input_reference', a.image!, 'input.${_ext(a.imageMime)}', a.imageMime)]);
        }
        return MediaCall('POST', _u(base, '/videos'), headers: h, json: {'model': model, 'prompt': a.prompt, 'seconds': secs, 'size': size});

      case MediaWire.xaiVideos:
        return MediaCall('POST', _u(base, '/videos/generations'), headers: h, json: {
          'model': model,
          'prompt': a.prompt,
          if (a.duration != null) 'duration': a.duration!.clamp(1, 15),
          if (ratio.isNotEmpty) 'aspect_ratio': ratio,
          if (a.image != null) 'image': {'url': a.dataUri},
        });

      case MediaWire.openaiSpeech:
        return MediaCall('POST', _u(base, '/audio/speech'), headers: {...auth, 'accept': 'audio/*'}, json: {
          'model': model,
          'input': a.prompt,
          'voice': a.voice.isNotEmpty ? a.voice : (p.voice.isNotEmpty ? p.voice : 'alloy'),
          'response_format': 'mp3',
        });

      case MediaWire.elevenTts:
        final voice = a.voice.isNotEmpty ? a.voice : (p.voice.isNotEmpty ? p.voice : 'JBFqnCBsd6RMkjVDRZzb');
        return MediaCall('POST', _u(base, '/text-to-speech/${Uri.encodeComponent(voice)}', {'output_format': 'mp3_44100_128'}),
            headers: {...auth, 'accept': 'audio/mpeg'}, json: {'text': a.prompt, 'model_id': model});

      case MediaWire.elevenSound:
        return MediaCall('POST', _u(base, '/sound-generation'), headers: {...auth, 'accept': 'audio/mpeg'}, json: {
          'text': a.prompt,
          if (model.isNotEmpty) 'model_id': model,
          if (a.duration != null) 'duration_seconds': a.duration!.clamp(1, 30),
        });

      case MediaWire.elevenMusic:
        return MediaCall('POST', _u(base, '/music'), headers: {...auth, 'accept': 'audio/mpeg'}, json: {
          'prompt': a.prompt,
          if (model.isNotEmpty) 'model_id': model,
          if (a.duration != null) 'music_length_ms': a.duration!.clamp(10, 300) * 1000,
        });
    }
  }

  static int _nearest(int v, List<int> allowed) {
    var best = allowed.first;
    for (final x in allowed) {
      if ((x - v).abs() < (best - v).abs()) best = x;
    }
    return best;
  }

  // ================================================================== reading answers

  static Object? _json(Uint8List body) {
    try {
      return jsonDecode(utf8.decode(body));
    } catch (_) {
      return null;
    }
  }

  static bool _binary(Map<String, String> headers) {
    final ct = (headers['content-type'] ?? '').toLowerCase();
    return ct.startsWith('image/') || ct.startsWith('audio/') || ct.startsWith('video/') || ct.contains('octet-stream');
  }

  /// The provider's own words for an error, from the usual shapes.
  static String errorText(Object? j, String raw) {
    if (j is Map) {
      final e = j['error'] ?? j['detail'] ?? j['message'] ?? j['errors'] ?? j['failure'] ?? j['title'];
      if (e is Map) return '${e['message'] ?? e['detail'] ?? e['status'] ?? jsonEncode(e)}';
      if (e is List && e.isNotEmpty) return e.map((x) => x is Map ? (x['message'] ?? x['msg'] ?? jsonEncode(x)) : '$x').join('; ');
      if (e != null) return '$e';
    }
    final t = raw.trim();
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }

  static MediaGenError httpError(int code, Object? j, String raw, String key) {
    final said = AiKeys.scrub(errorText(j, raw), key);
    final tail = said.isEmpty ? '' : ' It said: $said';
    if (code == 401 || code == 403) return MediaGenError('The key was refused (HTTP $code). Check the key in Settings > Media models.$tail', status: code);
    if (code == 402) return MediaGenError('The account has no credit left for this (HTTP 402).$tail', status: code);
    if (code == 404) return MediaGenError('Not found (HTTP 404): check the base URL and the model id.$tail', status: code);
    if (code == 429) return MediaGenError('The provider is busy or the quota is used up (HTTP 429).$tail', status: code);
    if (code >= 500) return MediaGenError('The provider had a problem on its side (HTTP $code).$tail', status: code);
    return MediaGenError('The provider did not accept the request (HTTP $code).$tail', status: code);
  }

  static Uint8List? _b64(Object? v) {
    if (v is! String || v.isEmpty) return null;
    try {
      return base64Decode(v.contains(',') && v.startsWith('data:') ? v.substring(v.indexOf(',') + 1) : v);
    } catch (_) {
      return null;
    }
  }

  /// Raw 16-bit PCM wrapped in a WAV header (Gemini TTS answers with audio/L16).
  static Uint8List wav(Uint8List pcm, {int rate = 24000, int channels = 1, int bits = 16}) {
    final b = BytesBuilder();
    final hdr = ByteData(44);
    void str(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        hdr.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    hdr.setUint32(4, 36 + pcm.length, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    hdr.setUint32(16, 16, Endian.little);
    hdr.setUint16(20, 1, Endian.little);
    hdr.setUint16(22, channels, Endian.little);
    hdr.setUint32(24, rate, Endian.little);
    hdr.setUint32(28, rate * channels * bits ~/ 8, Endian.little);
    hdr.setUint16(32, channels * bits ~/ 8, Endian.little);
    hdr.setUint16(34, bits, Endian.little);
    str(36, 'data');
    hdr.setUint32(40, pcm.length, Endian.little);
    b.add(hdr.buffer.asUint8List());
    b.add(pcm);
    return b.toBytes();
  }

  /// Inline audio as a playable file: raw PCM (audio/L16, audio/pcm) becomes WAV.
  static MediaOut _audioOut(Uint8List bytes, String mime) {
    final m = mime.toLowerCase();
    if (m.contains('l16') || m.contains('pcm')) {
      final rate = int.tryParse(RegExp(r'rate=(\d+)').firstMatch(m)?.group(1) ?? '') ?? 24000;
      return MediaOut(wav(bytes, rate: rate), 'audio/wav');
    }
    return MediaOut(bytes, mime.isEmpty ? 'audio/wav' : mime);
  }

  static const _pendingStates = {
    'starting', 'processing', 'queued', 'in_queue', 'in_progress', 'pending', 'running', 'throttled', 'created', 'submitted', 'waiting', 'generating',
  };
  static const _failedStates = {'failed', 'error', 'canceled', 'cancelled', 'expired', 'rejected'};

  static const _skipUrlKeys = {'status_url', 'response_url', 'cancel_url', 'get', 'cancel', 'stream', 'web', 'logs', 'self', 'webhook', 'urls'};
  static final _mediaExt = RegExp(r'\.(png|jpe?g|webp|gif|mp4|webm|mov|mp3|wav|m4a|ogg|flac|aac)(\?|$)', caseSensitive: false);

  /// Media links in a JSON answer (fal and Replicate shapes: images[].url, video.url, audio_file.url, output...).
  static List<String> urlsIn(Object? j, {String key = ''}) {
    final out = <String>[];
    void walk(Object? v, String k) {
      if (_skipUrlKeys.contains(k)) return;
      if (v is String) {
        final isLink = v.startsWith('https://') || v.startsWith('http://') || v.startsWith('data:');
        if (!isLink) return;
        if (k == 'url' || k.endsWith('_url') || k == 'output' || k == 'uri' || _mediaExt.hasMatch(v) || v.startsWith('data:')) {
          if (!out.contains(v)) out.add(v);
        }
      } else if (v is List) {
        for (final x in v) {
          walk(x, k);
        }
      } else if (v is Map) {
        for (final e in v.entries) {
          final kk = '${e.key}';
          if (const {'input', 'request', 'metadata', 'prompt', 'error'}.contains(kk)) continue;
          walk(e.value, kk);
        }
      }
    }

    walk(j, key);
    return out;
  }

  /// Reads one answer of [p]'s protocol to [sent].
  static MediaStep read(MediaProvider p, String key, MediaCall sent, int status, Map<String, String> headers, Uint8List body) {
    final raw = _binary(headers) ? '' : utf8.decode(body, allowMalformed: true);
    final j = _binary(headers) ? null : _json(body);
    if (status >= 400) throw httpError(status, j, raw, key);
    final ct = (headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
    // Any step that answers with the file itself is done (Stability, speech, OpenAI video content, downloads).
    if (_binary(headers)) return MediaStep(blobs: [MediaOut(body, ct)]);
    final base = p.apiBase;
    final auth = authHeaders(p, key);
    switch (p.wire) {
      case MediaWire.openaiImages:
        final data = j is Map && j['data'] is List ? j['data'] as List : const [];
        final blobs = <MediaOut>[];
        final urls = <String>[];
        final fmt = j is Map ? '${j['output_format'] ?? 'png'}' : 'png';
        for (final d in data) {
          if (d is! Map) continue;
          final b = _b64(d['b64_json'] ?? d['b64']);
          if (b != null) {
            blobs.add(MediaOut(b, 'image/${fmt == 'jpg' ? 'jpeg' : fmt}'));
          } else if (d['url'] is String) {
            urls.add(d['url'] as String);
          }
        }
        return MediaStep(blobs: blobs, urls: urls, text: j is Map ? '${data.isEmpty ? (j['message'] ?? '') : ''}' : '');

      case MediaWire.openrouterImage:
        final choice = j is Map && j['choices'] is List && (j['choices'] as List).isNotEmpty ? (j['choices'] as List).first : null;
        final msg = choice is Map && choice['message'] is Map ? choice['message'] as Map : const {};
        final urls = <String>[];
        for (final im in (msg['images'] is List ? msg['images'] as List : const [])) {
          if (im is! Map) continue;
          final iu = im['image_url'];
          final u = iu is Map ? iu['url'] : (iu is String ? iu : im['url']);
          if (u is String && u.isNotEmpty) urls.add(u);
        }
        final content = msg['content'];
        return MediaStep(urls: urls, text: content is String ? content : '');

      case MediaWire.geminiInteractions:
        if (j is! Map) throw MediaGenError('The provider sent an answer that could not be read.');
        final st = '${j['status'] ?? ''}'.toLowerCase();
        if (_failedStates.contains(st)) throw MediaGenError('The job $st: ${errorText(j, raw)}');
        final blobs = <MediaOut>[];
        final urls = <String>[];
        final texts = <String>[];
        void take(Object? c) {
          if (c is! Map) return;
          final type = '${c['type'] ?? ''}';
          final mime = '${c['mime_type'] ?? c['mimeType'] ?? ''}';
          if (type == 'text' && c['text'] is String) texts.add(c['text'] as String);
          if (type == 'image' || type == 'video' || type == 'audio') {
            final b = _b64(c['data']);
            if (b != null) {
              final m = mime.isNotEmpty ? mime : (type == 'image' ? 'image/png' : type == 'video' ? 'video/mp4' : 'audio/wav');
              blobs.add(type == 'audio' ? _audioOut(b, m) : MediaOut(b, m));
            } else if (c['uri'] is String) {
              urls.add(c['uri'] as String);
            }
          }
        }

        for (final s in (j['steps'] is List ? j['steps'] as List : const [])) {
          if (s is! Map || s['type'] != 'model_output') continue;
          for (final c in (s['content'] is List ? s['content'] as List : const [])) {
            take(c);
          }
        }
        // The SDK-style convenience fields, in case the REST answer carries them.
        for (final f in const ['output_image', 'output_video', 'output_audio']) {
          if (blobs.isEmpty && urls.isEmpty && j[f] is Map) take({'type': f.substring(7), ...(j[f] as Map)});
        }
        if (blobs.isNotEmpty || urls.isNotEmpty) return MediaStep(blobs: blobs, urls: urls, text: texts.join('\n'));
        final id = '${j['id'] ?? ''}';
        if (id.isNotEmpty && (st.isEmpty || _pendingStates.contains(st))) {
          return MediaStep(
            next: MediaCall('GET', _u(base, '/interactions/$id'), headers: auth, tag: 'poll'),
            progress: st.isEmpty ? 'Working' : (st == 'in_progress' ? 'Generating' : 'Queued'),
          );
        }
        return MediaStep(text: texts.join('\n'));

      case MediaWire.geminiGenerate:
        final blobs = <MediaOut>[];
        final texts = <String>[];
        for (final cand in (j is Map && j['candidates'] is List ? j['candidates'] as List : const [])) {
          final parts = cand is Map && cand['content'] is Map && (cand['content'] as Map)['parts'] is List ? (cand['content'] as Map)['parts'] as List : const [];
          for (final part in parts) {
            if (part is! Map) continue;
            final inl = part['inlineData'] ?? part['inline_data'];
            if (inl is Map) {
              final b = _b64(inl['data']);
              final mime = '${inl['mimeType'] ?? inl['mime_type'] ?? ''}';
              if (b != null) blobs.add(mime.startsWith('audio/') ? _audioOut(b, mime) : MediaOut(b, mime.isEmpty ? 'image/png' : mime));
            } else if (part['text'] is String) {
              texts.add(part['text'] as String);
            }
          }
        }
        if (blobs.isEmpty && j is Map && j['promptFeedback'] is Map) {
          throw MediaGenError('The request was blocked: ${(j['promptFeedback'] as Map)['blockReason'] ?? 'safety'}.');
        }
        return MediaStep(blobs: blobs, text: texts.join('\n'));

      case MediaWire.veo:
        if (j is! Map) throw MediaGenError('The provider sent an answer that could not be read.');
        final name = '${j['name'] ?? ''}';
        if (j['done'] == true) {
          if (j['error'] != null) throw MediaGenError('The job failed: ${errorText({'error': j['error']}, raw)}');
          final r = j['response'];
          final urls = <String>[];
          final blobs = <MediaOut>[];
          final samples = r is Map && r['generateVideoResponse'] is Map ? (r['generateVideoResponse'] as Map)['generatedSamples'] : (r is Map ? r['videos'] : null);
          for (final s in (samples is List ? samples : const [])) {
            final v = s is Map ? (s['video'] ?? s) : null;
            if (v is! Map) continue;
            if (v['uri'] is String) {
              urls.add(v['uri'] as String);
            } else {
              final b = _b64(v['bytesBase64Encoded'] ?? v['encodedVideo']);
              if (b != null) blobs.add(MediaOut(b, '${v['mimeType'] ?? 'video/mp4'}'));
            }
          }
          if (urls.isEmpty && blobs.isEmpty) {
            final filtered = r is Map && r['generateVideoResponse'] is Map ? (r['generateVideoResponse'] as Map)['raiMediaFilteredReasons'] : null;
            if (filtered != null) throw MediaGenError('The video was filtered: $filtered');
          }
          return MediaStep(blobs: blobs, urls: urls);
        }
        if (name.isEmpty) throw MediaGenError('The provider did not start a job: ${errorText(j, raw)}');
        return MediaStep(next: MediaCall('GET', _u(base, '/$name'), headers: auth, tag: 'poll'), progress: 'Generating');

      case MediaWire.fal:
        if (j is! Map) throw MediaGenError('The provider sent an answer that could not be read.');
        if (sent.tag == 'result') return MediaStep(urls: urlsIn(j));
        final st = '${j['status'] ?? ''}'.toUpperCase();
        final statusUrl = '${j['status_url'] ?? ''}';
        final responseUrl = '${j['response_url'] ?? ''}';
        final cancelUrl = '${j['cancel_url'] ?? ''}';
        final cancel = cancelUrl.isEmpty ? null : MediaCall('PUT', Uri.parse(cancelUrl), headers: auth, tag: 'cancel');
        if (st == 'COMPLETED') {
          if (j['error'] != null) throw MediaGenError('The job failed: ${j['error']}');
          final r = responseUrl.isNotEmpty ? responseUrl : sent.uri.toString().replaceFirst(RegExp(r'/status$'), '');
          return MediaStep(next: MediaCall('GET', Uri.parse(r), headers: auth, tag: 'result'), cancel: cancel);
        }
        if (st == 'IN_QUEUE' || st == 'IN_PROGRESS' || (sent.tag == 'start' && statusUrl.isNotEmpty)) {
          final poll = statusUrl.isNotEmpty ? MediaCall('GET', Uri.parse(statusUrl), headers: auth, tag: 'poll') : sent.again(tag: 'poll');
          final pos = j['queue_position'];
          return MediaStep(
            next: poll,
            cancel: cancel,
            progress: st == 'IN_PROGRESS' ? 'Generating' : (pos is num && pos > 0 ? 'Queued, $pos ahead' : 'Queued'),
          );
        }
        // fal.run (synchronous) answers with the result itself.
        return MediaStep(urls: urlsIn(j));

      case MediaWire.replicate:
        if (j is! Map) throw MediaGenError('The provider sent an answer that could not be read.');
        final st = '${j['status'] ?? ''}'.toLowerCase();
        final urlsMap = j['urls'] is Map ? j['urls'] as Map : const {};
        final cancel = urlsMap['cancel'] is String ? MediaCall('POST', Uri.parse(urlsMap['cancel'] as String), headers: auth, tag: 'cancel') : null;
        if (_failedStates.contains(st)) throw MediaGenError('The job $st${j['error'] == null ? '' : ': ${j['error']}'}.');
        if (st == 'succeeded') return MediaStep(urls: urlsIn(j['output'], key: 'output'));
        final get = urlsMap['get'] is String ? Uri.parse(urlsMap['get'] as String) : (j['id'] != null ? _u(base, '/predictions/${j['id']}') : null);
        if (get == null) throw MediaGenError('The provider did not start a job: ${errorText(j, raw)}');
        return MediaStep(next: MediaCall('GET', get, headers: auth, tag: 'poll'), cancel: cancel, progress: st == 'starting' ? 'Starting' : 'Generating');

      case MediaWire.stability:
        // A JSON answer to the picture request is an error or a filtered result.
        if (j is Map && (j['image'] is String)) {
          final b = _b64(j['image']);
          if (b != null) return MediaStep(blobs: [MediaOut(b, 'image/png')]);
        }
        throw MediaGenError('No picture came back: ${errorText(j, raw)}');

      case MediaWire.runway:
        if (j is! Map) throw MediaGenError('The provider sent an answer that could not be read.');
        final id = '${j['id'] ?? ''}';
        final st = '${j['status'] ?? ''}'.toUpperCase();
        final cancel = id.isEmpty ? null : MediaCall('DELETE', _u(base, '/tasks/$id'), headers: auth, tag: 'cancel');
        if (st == 'SUCCEEDED') return MediaStep(urls: [for (final o in (j['output'] is List ? j['output'] as List : const [])) if (o is String) o]);
        if (st == 'FAILED' || st == 'CANCELLED') throw MediaGenError('The job ${st.toLowerCase()}: ${j['failure'] ?? j['failureCode'] ?? ''}');
        if (id.isEmpty) throw MediaGenError('The provider did not start a job: ${errorText(j, raw)}');
        final pr = j['progress'];
        return MediaStep(
          next: MediaCall('GET', _u(base, '/tasks/$id'), headers: auth, tag: 'poll'),
          cancel: cancel,
          progress: pr is num && pr > 0 ? '${(pr * 100).round()}%' : (st == 'RUNNING' ? 'Generating' : 'Queued'),
        );

      case MediaWire.openaiVideos:
        if (j is! Map) throw MediaGenError('The provider sent an answer that could not be read.');
        final id = '${j['id'] ?? ''}';
        final st = '${j['status'] ?? ''}'.toLowerCase();
        if (_failedStates.contains(st)) throw MediaGenError('The job $st: ${errorText(j, raw)}');
        if (id.isEmpty) throw MediaGenError('The provider did not start a job: ${errorText(j, raw)}');
        if (st == 'completed' || st == 'succeeded') {
          return MediaStep(next: MediaCall('GET', _u(base, '/videos/$id/content'), headers: {...auth, 'accept': 'video/*'}, tag: 'content'));
        }
        final pr = j['progress'];
        return MediaStep(
          next: MediaCall('GET', _u(base, '/videos/$id'), headers: auth, tag: 'poll'),
          progress: pr is num && pr > 0 ? '${pr.round()}%' : (st == 'in_progress' ? 'Generating' : 'Queued'),
        );

      case MediaWire.xaiVideos:
        if (j is! Map) throw MediaGenError('The provider sent an answer that could not be read.');
        final st = '${j['status'] ?? ''}'.toLowerCase();
        if (_failedStates.contains(st)) throw MediaGenError('The job $st: ${errorText(j, raw)}');
        if (st == 'done' || st == 'completed') {
          final v = j['video'];
          final url = v is Map ? v['url'] : j['url'];
          return MediaStep(urls: [if (url is String) url]);
        }
        final id = '${j['request_id'] ?? j['id'] ?? ''}';
        if (id.isEmpty && sent.tag == 'start') throw MediaGenError('The provider did not start a job: ${errorText(j, raw)}');
        final poll = sent.tag == 'poll' ? sent : MediaCall('GET', _u(base, '/videos/$id'), headers: auth, tag: 'poll');
        return MediaStep(next: poll, progress: st == 'pending' || st.isEmpty ? 'Generating' : st);

      case MediaWire.openaiSpeech:
      case MediaWire.elevenTts:
      case MediaWire.elevenSound:
      case MediaWire.elevenMusic:
        // These answer with the audio itself (handled above); JSON here is an error without an error status.
        throw MediaGenError('No audio came back: ${errorText(j, raw)}');
    }
  }

  // ================================================================== testing the connection

  /// A cheap request that shows whether the address and key work, without making anything.
  static MediaCall testCall(MediaProvider p, String? key) {
    final base = p.apiBase;
    final auth = {'accept': 'application/json', ...authHeaders(p, key)};
    switch (p.wire) {
      case MediaWire.geminiInteractions:
      case MediaWire.geminiGenerate:
      case MediaWire.veo:
        return MediaCall('GET', _u(base, '/models', {'pageSize': '1'}), headers: auth, tag: 'test');
      case MediaWire.fal:
        // No list call on the queue host: a status lookup of a request that does not exist says 404 with a good key and
        // 401/403 with a bad one.
        final segs = p.model.split('/').where((s) => s.isNotEmpty).toList();
        final app = segs.length >= 2 ? '${segs[0]}/${segs[1]}' : (segs.isEmpty ? 'fal-ai/flux' : segs.first);
        return MediaCall('GET', _u(base, '/$app/requests/00000000-0000-0000-0000-000000000000/status'), headers: auth, tag: 'test');
      case MediaWire.replicate:
        return MediaCall('GET', _u(base, '/account'), headers: auth, tag: 'test');
      case MediaWire.stability:
        final u = Uri.parse(base);
        return MediaCall('GET', u.replace(path: '/v1/user/account', query: null), headers: auth, tag: 'test');
      case MediaWire.runway:
        return MediaCall('GET', _u(base, '/organization'), headers: auth, tag: 'test');
      default:
        return MediaCall('GET', _u(base, '/models'), headers: auth, tag: 'test');
    }
  }

  /// What a test answer means: a line to show, or a [MediaGenError].
  static String readTest(MediaProvider p, int status, String body) {
    if (status >= 200 && status < 300) return 'Connected. ${p.label} accepted the key.';
    if (p.wire == MediaWire.fal && status == 404) return 'Connected. fal accepted the key.';
    if (status == 401 || status == 403) throw MediaGenError('The key was refused (HTTP $status).', status: status);
    if (status == 404) throw MediaGenError('Reached the server, but nothing answers at this address (HTTP 404). Check the base URL.', status: status);
    throw httpError(status, _json(Uint8List.fromList(utf8.encode(body))), body, '');
  }

  /// Tests [p] with [key] (the one typed on the screen, or the saved one).
  Future<String> test(MediaProvider p, String? key) async {
    if (p.apiBase.isEmpty) throw MediaGenError('Add the base URL.');
    final u = Uri.tryParse(p.apiBase);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) throw MediaGenError('The base URL should start with https://');
    if ((key ?? '').trim().isEmpty) throw MediaGenError('Add a key first.');
    final c = _client();
    try {
      final resp = await http.Response.fromStream(await c.send(testCall(p, key).toRequest()).timeout(const Duration(seconds: 20)));
      return readTest(p, resp.statusCode, AiKeys.scrub(utf8.decode(resp.bodyBytes, allowMalformed: true), key));
    } on TimeoutException {
      throw MediaGenError('No answer in 20 seconds. Check the base URL and the connection.');
    } on SocketException catch (e) {
      throw MediaGenError('Could not reach the server (${e.message}).');
    } finally {
      c.close();
    }
  }
}
