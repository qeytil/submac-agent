import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai_keys.dart';
import 'byok.dart';

/// Media generation providers (owner 2026-11-04, docs/media-providers.md): "add media generation provider
/// configuration, so a bot or the agent can use that if I say use, because now the provider configuration is only for
/// chat completion".
///
/// Next to the chat providers (byok.dart), the user adds providers per capability (pictures, video, speech, music and
/// sound), each with its own base URL, key, model and a default per capability. Keys live in the phone's encrypted
/// storage, one entry per key, apart from the config, or are borrowed from a chat provider (BYOK) or another media
/// provider of the same vendor. Calls go straight from the phone to the provider (media_gen.dart); nothing passes
/// Telesia's servers and nothing is billed by Telesia.

/// What a provider makes.
enum MediaKind { image, video, speech, audio }

extension MediaKindX on MediaKind {
  String get id => name;

  /// Plain-language name, for the settings screen.
  String get label => switch (this) {
        MediaKind.image => 'Images',
        MediaKind.video => 'Video',
        MediaKind.speech => 'Speech',
        MediaKind.audio => 'Music & sound',
      };

  /// One thing of this kind, in a sentence ("the picture").
  String get noun => switch (this) {
        MediaKind.image => 'picture',
        MediaKind.video => 'video',
        MediaKind.speech => 'voice recording',
        MediaKind.audio => 'sound',
      };

  static MediaKind? parse(String? s) {
    final v = (s ?? '').trim().toLowerCase();
    for (final k in MediaKind.values) {
      if (k.name == v) return k;
    }
    return switch (v) {
      'picture' || 'photo' || 'images' || 'img' => MediaKind.image,
      'tts' || 'voice' => MediaKind.speech,
      'music' || 'sound' || 'sfx' => MediaKind.audio,
      'movie' || 'clip' => MediaKind.video,
      _ => null,
    };
  }
}

/// The wire protocol a media provider speaks: decides how the request is built, how the answer is read, and whether the
/// job is polled. Each one is tested with a mock HTTP client (test/media_providers_test.dart).
enum MediaWire {
  /// POST {base}/images/generations (+ /images/edits): OpenAI gpt-image / dall-e, xAI, Together, any compatible server.
  openaiImages,

  /// POST {base}/chat/completions with modalities [image, text]: OpenRouter image-output models.
  openrouterImage,

  /// POST {base}/interactions (Gemini Interactions API): Nano Banana pictures, Gemini Omni video, Gemini TTS.
  geminiInteractions,

  /// POST {base}/models/{model}:generateContent: older Gemini image models and the preview TTS models.
  geminiGenerate,

  /// POST {base}/models/{model}:predictLongRunning, then GET {base}/{operation}: Veo where it is still served.
  veo,

  /// POST https://queue.fal.run/{model}, poll status_url, read response_url.
  fal,

  /// POST {base}/models/{owner}/{name}/predictions (or /predictions with a version), poll urls.get.
  replicate,

  /// POST {base}/stable-image/generate/{model} (multipart, answers with the picture itself).
  stability,

  /// POST {base}/text_to_video or /image_to_video, poll GET {base}/tasks/{id}.
  runway,

  /// POST {base}/videos, poll GET {base}/videos/{id}, download {base}/videos/{id}/content (OpenAI Sora, compatible).
  openaiVideos,

  /// POST {base}/videos/generations, poll GET {base}/videos/{request_id} (xAI Grok Imagine video).
  xaiVideos,

  /// POST {base}/audio/speech (OpenAI TTS and compatible).
  openaiSpeech,

  /// POST {base}/text-to-speech/{voice} (ElevenLabs).
  elevenTts,

  /// POST {base}/sound-generation (ElevenLabs sound effects).
  elevenSound,

  /// POST {base}/music (ElevenLabs music).
  elevenMusic,
}

extension MediaWireX on MediaWire {
  String get id => name;

  static MediaWire parse(String? s, {MediaWire fallback = MediaWire.openaiImages}) {
    for (final w in MediaWire.values) {
      if (w.name == s) return w;
    }
    return fallback;
  }

  /// Plain-language name of the protocol, for the edit screen.
  String get label => switch (this) {
        MediaWire.openaiImages => 'OpenAI Images API',
        MediaWire.openrouterImage => 'OpenRouter (chat with image output)',
        MediaWire.geminiInteractions => 'Gemini Interactions API',
        MediaWire.geminiGenerate => 'Gemini generateContent',
        MediaWire.veo => 'Veo (long-running predict)',
        MediaWire.fal => 'fal queue',
        MediaWire.replicate => 'Replicate predictions',
        MediaWire.stability => 'Stability Stable Image',
        MediaWire.runway => 'Runway tasks',
        MediaWire.openaiVideos => 'OpenAI Videos API',
        MediaWire.xaiVideos => 'xAI video generations',
        MediaWire.openaiSpeech => 'OpenAI speech API',
        MediaWire.elevenTts => 'ElevenLabs text to speech',
        MediaWire.elevenSound => 'ElevenLabs sound effects',
        MediaWire.elevenMusic => 'ElevenLabs music',
      };

  /// Jobs that run on the provider's side and are polled until done.
  bool get polls => const {MediaWire.veo, MediaWire.fal, MediaWire.replicate, MediaWire.runway, MediaWire.openaiVideos, MediaWire.xaiVideos}
      .contains(this);
}

/// A ready-made media provider: the right base URL, protocol and default model, checked against each provider's own
/// docs on 2026-11-04 (sources in docs/media-providers.md). The model is always editable.
class MediaPreset {
  const MediaPreset({
    required this.id,
    required this.name,
    required this.kind,
    required this.wire,
    this.baseUrl = '',
    this.model = '',
    this.models = const [],
    this.vendor = '',
    this.keyHint = '',
    this.keyUrl = '',
    this.note = '',
    this.logo = '',
    this.voice = '',
    this.custom = false,
  });

  final String id;
  final String name;
  final MediaKind kind;
  final MediaWire wire;
  final String baseUrl;

  /// The default model id.
  final String model;

  /// Other model ids offered as one-tap choices.
  final List<String> models;

  /// Who sells the key: presets of the same vendor (and chat providers of it) can share one key.
  final String vendor;
  final String keyHint;
  final String keyUrl;
  final String note;
  final String logo;

  /// Default voice (speech).
  final String voice;

  /// The user types the base URL.
  final bool custom;
}

class MediaPresets {
  MediaPresets._();

  static const _openai = 'https://api.openai.com/v1';
  static const _gemini = 'https://generativelanguage.googleapis.com/v1beta';
  static const _fal = 'https://queue.fal.run';
  static const _replicate = 'https://api.replicate.com/v1';
  static const _eleven = 'https://api.elevenlabs.io/v1';

  static const all = <MediaPreset>[
    // ---- pictures
    MediaPreset(
        id: 'openai-image', name: 'OpenAI', kind: MediaKind.image, wire: MediaWire.openaiImages, baseUrl: _openai, model: 'gpt-image-1',
        models: ['gpt-image-1', 'gpt-image-1-mini', 'dall-e-3', 'dall-e-2'], vendor: 'openai', keyHint: 'sk-…', keyUrl: 'https://platform.openai.com/api-keys', logo: 'openai'),
    MediaPreset(
        id: 'gemini-image', name: 'Google Gemini (Nano Banana)', kind: MediaKind.image, wire: MediaWire.geminiInteractions, baseUrl: _gemini,
        model: 'gemini-nano-banana-2.1', models: ['gemini-nano-banana-2.1', 'gemini-3.1-flash-image', 'gemini-3-pro-image'], vendor: 'google',
        keyHint: 'AIza…', keyUrl: 'https://aistudio.google.com/apikey', logo: 'googlegemini'),
    MediaPreset(
        id: 'gemini-image-legacy', name: 'Google Gemini (generateContent)', kind: MediaKind.image, wire: MediaWire.geminiGenerate, baseUrl: _gemini,
        model: 'gemini-2.5-flash-image', models: ['gemini-2.5-flash-image', 'gemini-3.1-flash-image'], vendor: 'google', keyHint: 'AIza…',
        keyUrl: 'https://aistudio.google.com/apikey', logo: 'googlegemini',
        note: 'The older generateContent call, for Gemini image models that still answer on it. Imagen was shut down on the Gemini API.'),
    MediaPreset(
        id: 'openrouter-image', name: 'OpenRouter', kind: MediaKind.image, wire: MediaWire.openrouterImage, baseUrl: 'https://openrouter.ai/api/v1',
        model: 'google/gemini-2.5-flash-image', models: ['google/gemini-2.5-flash-image', 'openai/gpt-5-image-mini'], vendor: 'openrouter',
        keyHint: 'sk-or-v1-…', keyUrl: 'https://openrouter.ai/keys', logo: 'openrouter', note: 'Pick a model whose output includes images.'),
    MediaPreset(
        id: 'fal-image', name: 'fal.ai', kind: MediaKind.image, wire: MediaWire.fal, baseUrl: _fal, model: 'fal-ai/flux/schnell',
        models: ['fal-ai/flux/schnell', 'fal-ai/flux/dev', 'fal-ai/nano-banana-2'], vendor: 'fal', keyUrl: 'https://fal.ai/dashboard/keys',
        note: 'The model is the fal endpoint id, e.g. fal-ai/flux/schnell.'),
    MediaPreset(
        id: 'replicate-image', name: 'Replicate', kind: MediaKind.image, wire: MediaWire.replicate, baseUrl: _replicate,
        model: 'black-forest-labs/flux-schnell', models: ['black-forest-labs/flux-schnell', 'black-forest-labs/flux-1.1-pro'], vendor: 'replicate',
        keyHint: 'r8_…', keyUrl: 'https://replicate.com/account/api-tokens', logo: 'replicate',
        note: 'owner/model for official models, or owner/model:version.'),
    MediaPreset(
        id: 'stability-image', name: 'Stability AI', kind: MediaKind.image, wire: MediaWire.stability, baseUrl: 'https://api.stability.ai/v2beta',
        model: 'core', models: ['core', 'ultra', 'sd3'], vendor: 'stability', keyHint: 'sk-…', keyUrl: 'https://platform.stability.ai/account/keys'),
    MediaPreset(
        id: 'xai-image', name: 'xAI Grok Imagine', kind: MediaKind.image, wire: MediaWire.openaiImages, baseUrl: 'https://api.x.ai/v1',
        model: 'grok-imagine-image-2.0', models: ['grok-imagine-image-2.0'], vendor: 'xai', keyHint: 'xai-…', keyUrl: 'https://console.x.ai', logo: 'xai'),
    MediaPreset(
        id: 'together-image', name: 'Together AI (FLUX)', kind: MediaKind.image, wire: MediaWire.openaiImages, baseUrl: 'https://api.together.xyz/v1',
        model: 'black-forest-labs/FLUX.1-schnell', models: ['black-forest-labs/FLUX.1-schnell', 'black-forest-labs/FLUX.1.1-pro'], vendor: 'together',
        keyUrl: 'https://api.together.ai/settings/api-keys'),
    MediaPreset(
        id: 'custom-image', name: 'OpenAI-compatible images', kind: MediaKind.image, wire: MediaWire.openaiImages, custom: true,
        note: 'Any server with POST /images/generations. Paste its base URL, usually ending in /v1.'),

    // ---- video
    MediaPreset(
        id: 'gemini-video', name: 'Google Gemini Omni Flash', kind: MediaKind.video, wire: MediaWire.geminiInteractions, baseUrl: _gemini,
        model: 'gemini-omni-1.1-flash', models: ['gemini-omni-1.1-flash'], vendor: 'google', keyHint: 'AIza…', keyUrl: 'https://aistudio.google.com/apikey',
        logo: 'googlegemini', note: 'Google’s video model on the Gemini API (Veo preview there was shut down on 2026-10-22).'),
    MediaPreset(
        id: 'veo-video', name: 'Google Veo (long-running)', kind: MediaKind.video, wire: MediaWire.veo, baseUrl: _gemini, model: 'veo-3.1-generate-001',
        models: ['veo-3.1-generate-001', 'veo-3.1-fast-generate-001'], vendor: 'google', keyHint: 'AIza…', logo: 'googlegemini',
        note: 'predictLongRunning, for an endpoint that still serves Veo (change the base URL if yours differs).'),
    MediaPreset(
        id: 'openai-video', name: 'OpenAI Sora', kind: MediaKind.video, wire: MediaWire.openaiVideos, baseUrl: _openai, model: 'sora-2',
        models: ['sora-2', 'sora-2-pro'], vendor: 'openai', keyHint: 'sk-…', keyUrl: 'https://platform.openai.com/api-keys', logo: 'openai'),
    MediaPreset(
        id: 'xai-video', name: 'xAI Grok Imagine video', kind: MediaKind.video, wire: MediaWire.xaiVideos, baseUrl: 'https://api.x.ai/v1',
        model: 'grok-imagine-video-1.5', models: ['grok-imagine-video-1.5', 'grok-imagine-video-1.5-lite'], vendor: 'xai', keyHint: 'xai-…', logo: 'xai'),
    MediaPreset(
        id: 'fal-video', name: 'fal.ai video', kind: MediaKind.video, wire: MediaWire.fal, baseUrl: _fal, model: 'fal-ai/kling-video/v2.1/standard/text-to-video',
        vendor: 'fal', keyUrl: 'https://fal.ai/dashboard/keys', note: 'The model is the fal endpoint id of a text-to-video or image-to-video model.'),
    MediaPreset(
        id: 'replicate-video', name: 'Replicate video', kind: MediaKind.video, wire: MediaWire.replicate, baseUrl: _replicate, model: 'minimax/video-01',
        vendor: 'replicate', keyHint: 'r8_…', logo: 'replicate'),
    MediaPreset(
        id: 'runway-video', name: 'Runway', kind: MediaKind.video, wire: MediaWire.runway, baseUrl: 'https://api.dev.runwayml.com/v1', model: 'gen4.5',
        models: ['gen4.5', 'veo3.1_fast', 'veo3.1'], vendor: 'runway', keyUrl: 'https://dev.runwayml.com'),
    MediaPreset(
        id: 'custom-video', name: 'OpenAI-compatible video', kind: MediaKind.video, wire: MediaWire.openaiVideos, custom: true,
        note: 'Any server with POST /videos, GET /videos/{id} and /videos/{id}/content.'),

    // ---- speech
    MediaPreset(
        id: 'openai-speech', name: 'OpenAI TTS', kind: MediaKind.speech, wire: MediaWire.openaiSpeech, baseUrl: _openai, model: 'gpt-4o-mini-tts',
        models: ['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'], vendor: 'openai', keyHint: 'sk-…', logo: 'openai', voice: 'alloy'),
    MediaPreset(
        id: 'elevenlabs-speech', name: 'ElevenLabs', kind: MediaKind.speech, wire: MediaWire.elevenTts, baseUrl: _eleven, model: 'eleven_multilingual_v2',
        models: ['eleven_multilingual_v2', 'eleven_flash_v2_5', 'eleven_v3'], vendor: 'elevenlabs', keyUrl: 'https://elevenlabs.io/app/settings/api-keys',
        logo: 'elevenlabs', voice: 'JBFqnCBsd6RMkjVDRZzb', note: 'The voice is an ElevenLabs voice id.'),
    MediaPreset(
        id: 'gemini-speech', name: 'Google Gemini TTS', kind: MediaKind.speech, wire: MediaWire.geminiInteractions, baseUrl: _gemini,
        model: 'gemini-3.8-flash-tts', models: ['gemini-3.8-flash-tts', 'gemini-3.8-flash-lite-tts'], vendor: 'google', keyHint: 'AIza…', logo: 'googlegemini',
        voice: 'Kore'),
    MediaPreset(
        id: 'gemini-speech-legacy', name: 'Google Gemini TTS (generateContent)', kind: MediaKind.speech, wire: MediaWire.geminiGenerate, baseUrl: _gemini,
        model: 'gemini-2.5-flash-preview-tts', models: ['gemini-2.5-flash-preview-tts', 'gemini-2.5-pro-preview-tts'], vendor: 'google', keyHint: 'AIza…',
        logo: 'googlegemini', voice: 'Kore'),
    MediaPreset(
        id: 'custom-speech', name: 'OpenAI-compatible speech', kind: MediaKind.speech, wire: MediaWire.openaiSpeech, custom: true, voice: 'alloy',
        note: 'Any server with POST /audio/speech.'),

    // ---- music and sound
    MediaPreset(
        id: 'elevenlabs-sound', name: 'ElevenLabs sound effects', kind: MediaKind.audio, wire: MediaWire.elevenSound, baseUrl: _eleven,
        model: 'eleven_text_to_sound_v2', vendor: 'elevenlabs', logo: 'elevenlabs'),
    MediaPreset(
        id: 'elevenlabs-music', name: 'ElevenLabs music', kind: MediaKind.audio, wire: MediaWire.elevenMusic, baseUrl: _eleven, model: 'music_v1',
        vendor: 'elevenlabs', logo: 'elevenlabs'),
    MediaPreset(
        id: 'fal-audio', name: 'fal.ai audio', kind: MediaKind.audio, wire: MediaWire.fal, baseUrl: _fal, model: 'fal-ai/stable-audio', vendor: 'fal'),
    MediaPreset(
        id: 'replicate-audio', name: 'Replicate audio', kind: MediaKind.audio, wire: MediaWire.replicate, baseUrl: _replicate, model: 'minimax/music-01',
        vendor: 'replicate', keyHint: 'r8_…', logo: 'replicate'),
  ];

  static MediaPreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  static List<MediaPreset> of(MediaKind k) => [for (final p in all) if (p.kind == k) p];

  /// The BYOK chat presets whose keys work for [vendor] (their preset ids).
  static Set<String> byokPresetsFor(String vendor) => switch (vendor) {
        '' => const {},
        'google' => const {'gemini'},
        _ => {vendor},
      };
}

/// One of the user's media providers. The key is never in here: [keyId] names its entry in encrypted storage, or
/// [keyFrom] borrows the key of a chat provider (`byok-…`) or another media provider (`media-…`).
class MediaProvider {
  MediaProvider({
    required this.id,
    required this.kind,
    required this.wire,
    this.preset = '',
    this.name = '',
    this.baseUrl = '',
    this.model = '',
    this.voice = '',
    this.keyId = '',
    this.keyHint = '',
    this.keyFrom = '',
    Map<String, String>? headers,
    this.enabled = true,
  }) : headers = headers ?? {};

  /// `media-` + 8 hex.
  final String id;
  MediaKind kind;
  MediaWire wire;
  String preset;
  String name;
  String baseUrl;
  String model;
  String voice;
  String keyId;
  String keyHint;
  String keyFrom;
  Map<String, String> headers;
  bool enabled;

  static const prefix = 'media-';
  static final idPattern = RegExp(r'^media-[a-z0-9]{4,24}$');

  static String newId([Random? r]) {
    final rnd = r ?? Random.secure();
    return '$prefix${List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join()}';
  }

  MediaPreset? get presetDef => MediaPresets.byId(preset);
  String get vendor => presetDef?.vendor ?? '';
  String get logo => presetDef?.logo ?? '';
  String get label => name.trim().isNotEmpty ? name.trim() : (presetDef?.name ?? 'Provider');

  /// The base URL without a trailing slash.
  String get apiBase {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.id,
        'wire': wire.id,
        if (preset.isNotEmpty) 'preset': preset,
        'name': name,
        'base_url': baseUrl,
        'model': model,
        if (voice.isNotEmpty) 'voice': voice,
        if (keyId.isNotEmpty) 'key_id': keyId,
        if (keyHint.isNotEmpty) 'key_hint': keyHint,
        if (keyFrom.isNotEmpty) 'key_from': keyFrom,
        if (headers.isNotEmpty) 'headers': headers,
        'enabled': enabled,
      };

  factory MediaProvider.fromJson(Map j) {
    final preset = MediaPresets.byId('${j['preset'] ?? ''}');
    return MediaProvider(
      id: '${j['id'] ?? ''}',
      kind: MediaKindX.parse('${j['kind'] ?? ''}') ?? preset?.kind ?? MediaKind.image,
      wire: MediaWireX.parse('${j['wire'] ?? ''}', fallback: preset?.wire ?? MediaWire.openaiImages),
      preset: '${j['preset'] ?? ''}',
      name: '${j['name'] ?? ''}',
      baseUrl: '${j['base_url'] ?? ''}',
      model: '${j['model'] ?? ''}',
      voice: '${j['voice'] ?? ''}',
      keyId: '${j['key_id'] ?? ''}',
      keyHint: '${j['key_hint'] ?? ''}',
      keyFrom: '${j['key_from'] ?? ''}',
      headers: j['headers'] is Map ? (j['headers'] as Map).map((k, v) => MapEntry('$k', '$v')) : {},
      enabled: j['enabled'] != false,
    );
  }

  MediaProvider copy() => MediaProvider.fromJson(jsonDecode(jsonEncode(toJson())) as Map);

  factory MediaProvider.fromPreset(MediaPreset p, {String? id}) => MediaProvider(
        id: id ?? newId(),
        kind: p.kind,
        wire: p.wire,
        preset: p.id,
        name: p.name,
        baseUrl: p.baseUrl,
        model: p.model,
        voice: p.voice,
      );
}

/// Everything saved: the providers (no secrets) and the default provider per kind.
class MediaConfig {
  MediaConfig({List<MediaProvider>? providers, Map<MediaKind, String>? defaults})
      : providers = providers ?? [],
        defaults = defaults ?? {};
  static const version = 1;

  final List<MediaProvider> providers;
  final Map<MediaKind, String> defaults;

  Map<String, dynamic> toJson() => {
        'v': version,
        'providers': [for (final p in providers) p.toJson()],
        'defaults': {for (final e in defaults.entries) e.key.id: e.value},
      };

  /// Reads any saved shape (a bare list, broken or duplicate entries, defaults that point nowhere).
  factory MediaConfig.fromJson(Object? raw) {
    Object? j = raw;
    if (j is String) {
      try {
        j = jsonDecode(j);
      } catch (_) {
        j = null;
      }
    }
    if (j is List) j = <String, Object?>{'providers': j};
    if (j is! Map) return MediaConfig();
    final list = <MediaProvider>[];
    final seen = <String>{};
    for (final p in (j['providers'] is List ? j['providers'] as List : const [])) {
      if (p is! Map) continue;
      final pr = MediaProvider.fromJson(p);
      if (!MediaProvider.idPattern.hasMatch(pr.id) || !seen.add(pr.id)) continue;
      list.add(pr);
    }
    final defaults = <MediaKind, String>{};
    if (j['defaults'] is Map) {
      (j['defaults'] as Map).forEach((k, v) {
        final kind = MediaKindX.parse('$k');
        final id = '$v';
        if (kind != null && list.any((p) => p.id == id && p.kind == kind)) defaults[kind] = id;
      });
    }
    return MediaConfig(providers: list, defaults: defaults);
  }
}

/// The saved media setup, loaded once at start and kept in memory.
class MediaProviderStore extends ChangeNotifier {
  MediaProviderStore({AiSecretStore? store, ByokStore? byok})
      : _store = store,
        _byok = byok;
  static MediaProviderStore I = MediaProviderStore();

  final AiSecretStore? _store;
  final ByokStore? _byok;
  AiSecretStore get store => _store ?? AiKeys.store;
  ByokStore get byok => _byok ?? ByokStore.I;

  static const configEntry = 'media_providers_v1';
  static String keyEntry(String keyId) => 'media_key_$keyId';

  MediaConfig _cfg = MediaConfig();
  MediaConfig get config => _cfg;
  List<MediaProvider> get providers => List.unmodifiable(_cfg.providers);

  final Map<String, String> _keys = {};
  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      _cfg = MediaConfig.fromJson(await store.read(configEntry));
      _keys.clear();
      for (final p in _cfg.providers) {
        if (p.keyId.isEmpty) continue;
        final v = await store.read(keyEntry(p.keyId));
        if (v != null && v.isNotEmpty) _keys[p.keyId] = v;
      }
    } catch (_) {
      _cfg = MediaConfig();
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    await store.write(configEntry, jsonEncode(_cfg.toJson()));
    notifyListeners();
  }

  MediaProvider? provider(String id) {
    for (final p in _cfg.providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<MediaProvider> of(MediaKind k) => [for (final p in _cfg.providers) if (p.kind == k) p];

  /// Saves a provider (new or edited). The first provider of a kind becomes its default.
  Future<void> upsert(MediaProvider p) async {
    final i = _cfg.providers.indexWhere((x) => x.id == p.id);
    if (i >= 0) {
      final old = _cfg.providers[i];
      _cfg.providers[i] = p;
      // A provider moved to another kind is no longer the old kind's default.
      if (old.kind != p.kind && _cfg.defaults[old.kind] == p.id) _cfg.defaults.remove(old.kind);
    } else {
      _cfg.providers.add(p);
    }
    if (!_cfg.defaults.containsKey(p.kind)) _cfg.defaults[p.kind] = p.id;
    await _save();
  }

  Future<void> remove(String id) async {
    final p = provider(id);
    if (p == null) return;
    _cfg.providers.removeWhere((x) => x.id == id);
    // Providers that borrowed this one's key take the key over, so removing one never breaks the other.
    for (final x in _cfg.providers) {
      if (x.keyFrom != id) continue;
      x
        ..keyFrom = ''
        ..keyId = p.keyId
        ..keyHint = p.keyHint;
    }
    if (p.keyId.isNotEmpty && !_cfg.providers.any((x) => x.keyId == p.keyId)) {
      _keys.remove(p.keyId);
      await store.delete(keyEntry(p.keyId));
    }
    if (_cfg.defaults[p.kind] == id) {
      _cfg.defaults.remove(p.kind);
      final next = of(p.kind).where((x) => x.enabled).firstOrNull;
      if (next != null) _cfg.defaults[p.kind] = next.id;
    }
    await _save();
  }

  /// Stores [secret] as [p]'s own key (encrypted, apart from the config). Replaces an earlier own key.
  Future<void> setKey(MediaProvider p, String secret) async {
    final s = secret.trim();
    if (s.isEmpty) return;
    final old = p.keyId;
    final r = Random.secure();
    final id = List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
    await store.write(keyEntry(id), s);
    _keys[id] = s;
    p
      ..keyId = id
      ..keyHint = s.length >= 4 ? s.substring(s.length - 4) : ''
      ..keyFrom = '';
    if (old.isNotEmpty && !_cfg.providers.any((x) => x.id != p.id && x.keyId == old)) {
      _keys.remove(old);
      await store.delete(keyEntry(old));
    }
    if (identical(provider(p.id), p)) await _save();
  }

  /// Drops a key stored for a provider that was never saved (the add flow was left half way).
  Future<void> discardKey(String keyId) async {
    if (keyId.isEmpty || _cfg.providers.any((x) => x.keyId == keyId)) return;
    _keys.remove(keyId);
    await store.delete(keyEntry(keyId));
  }

  /// The key [p] calls with: its own, or the borrowed one (a chat provider's active key, or another media provider's
  /// own key). Never logged or printed.
  String? secretFor(MediaProvider p) {
    if (p.keyFrom.isNotEmpty) {
      if (p.keyFrom.startsWith(ByokProvider.prefix)) {
        final b = byok.provider(p.keyFrom);
        return b == null ? null : byok.activeSecret(b);
      }
      final other = provider(p.keyFrom);
      if (other != null && other.id != p.id && other.keyId.isNotEmpty) return _keys[other.keyId];
      return null;
    }
    return p.keyId.isEmpty ? null : _keys[p.keyId];
  }

  /// Where [p] could borrow a key from: chat providers and media providers of the same vendor that have one.
  List<(String, String)> keySources(MediaProvider p) {
    final v = p.vendor;
    if (v.isEmpty) return const [];
    final byokPresets = MediaPresets.byokPresetsFor(v);
    return [
      for (final b in byok.providers)
        if (byokPresets.contains(b.preset) && byok.activeSecret(b) != null) (b.id, '${b.label} (chat)'),
      for (final m in _cfg.providers)
        if (m.id != p.id && m.vendor == v && m.keyId.isNotEmpty && _keys[m.keyId] != null) (m.id, '${m.label} (${m.kind.label.toLowerCase()})'),
    ];
  }

  /// The masked key line for the screen ("••••abcd", "from OpenAI (chat)", "no key").
  String keyLabel(MediaProvider p) {
    if (p.keyFrom.isNotEmpty) {
      final src = keySources(p).where((s) => s.$1 == p.keyFrom).firstOrNull;
      return src == null ? 'key missing' : 'key from ${src.$2}';
    }
    if (p.keyId.isEmpty || _keys[p.keyId] == null) return 'no key';
    return ByokKey.mask(p.keyHint);
  }

  // ------------------------------------------------------------------ choosing

  String? defaultId(MediaKind k) => _cfg.defaults[k];

  Future<void> setDefault(MediaKind k, String id) async {
    final p = provider(id);
    if (p == null || p.kind != k) return;
    _cfg.defaults[k] = id;
    await _save();
  }

  /// Ready to call: on, with a model and a key.
  bool usable(MediaProvider p) => p.enabled && p.model.trim().isNotEmpty && p.apiBase.isNotEmpty && secretFor(p) != null;

  /// Every usable provider of [k], the default first.
  List<MediaProvider> usableOf(MediaKind k) {
    final list = [for (final p in of(k)) if (usable(p)) p];
    final d = defaultId(k);
    list.sort((a, b) => (a.id == d ? 0 : 1).compareTo(b.id == d ? 0 : 1));
    return list;
  }

  bool has(MediaKind k) => usableOf(k).isNotEmpty;

  /// At least one provider can make something (the media tool is offered only then).
  bool get hasAny => MediaKind.values.any(has);

  /// The provider for a call: the one named (by id, name or preset, case-insensitive), else the kind's default, else
  /// the first usable one. Null when there is none.
  MediaProvider? pick(MediaKind k, {String? named}) {
    final list = usableOf(k);
    if (list.isEmpty) return null;
    final n = (named ?? '').trim().toLowerCase();
    if (n.isEmpty) return list.first;
    for (final p in list) {
      if (p.id == n || p.label.toLowerCase() == n || p.preset == n) return p;
    }
    for (final p in list) {
      if (p.label.toLowerCase().contains(n) || p.vendor == n || p.preset.startsWith(n)) return p;
    }
    return null;
  }

  // ------------------------------------------------------------------ tests

  @visibleForTesting
  void resetForTests([MediaConfig? cfg, Map<String, String>? keys]) {
    _cfg = cfg ?? MediaConfig();
    _keys
      ..clear()
      ..addAll(keys ?? const {});
    _loaded = true;
  }
}
