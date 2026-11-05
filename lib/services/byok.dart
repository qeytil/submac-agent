import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai_keys.dart';

/// Bring your own key (owner 2026-11-03, docs/byok.md): the user's own AI providers, next to SubMac's model.
///
/// What lives here: the provider presets, the saved config (providers, keys, models, the chat choice) and the store
/// that keeps it in the phone's encrypted storage. Keys are kept apart from the config (one secure entry per key), so
/// the config can be read, compared and passed around without ever carrying a secret. Nothing here talks to SubMac's
/// servers; calls to a provider go straight from the phone (byok_fetch.dart, and opencode through byok_opencode.dart).

/// The wire protocol a provider speaks (decides the opencode SDK package, the model list call and the auth header).
enum ByokKind { openai, openaiCompatible, anthropic, anthropicCompatible, gemini, openrouter }

extension ByokKindX on ByokKind {
  String get id => switch (this) {
        ByokKind.openai => 'openai',
        ByokKind.openaiCompatible => 'openai-compatible',
        ByokKind.anthropic => 'anthropic',
        ByokKind.anthropicCompatible => 'anthropic-compatible',
        ByokKind.gemini => 'gemini',
        ByokKind.openrouter => 'openrouter',
      };

  /// Anthropic's Messages API (x-api-key + anthropic-version).
  bool get isAnthropic => this == ByokKind.anthropic || this == ByokKind.anthropicCompatible;

  /// Plain-language name of the protocol, for the edit screen.
  String get label => switch (this) {
        ByokKind.openai => 'OpenAI',
        ByokKind.openaiCompatible => 'OpenAI-compatible',
        ByokKind.anthropic => 'Anthropic',
        ByokKind.anthropicCompatible => 'Anthropic-compatible',
        ByokKind.gemini => 'Google Gemini',
        ByokKind.openrouter => 'OpenRouter',
      };

  static ByokKind parse(String? s) {
    for (final k in ByokKind.values) {
      if (k.id == s || k.name == s) return k;
    }
    // An unknown kind (a newer app wrote it) is read as the most common protocol rather than dropped.
    return ByokKind.openaiCompatible;
  }
}

/// A ready-made provider: the right base URL, protocol and model list address, verified against each provider's own
/// docs on 2026-11-03 (sources in docs/byok.md).
class ByokPreset {
  const ByokPreset({
    required this.id,
    required this.name,
    required this.kind,
    this.baseUrl = '',
    this.modelsUrl = '',
    this.needsKey = true,
    this.keyHint = '',
    this.keyUrl = '',
    this.note = '',
    this.logo = '',
    this.custom = false,
  });

  final String id;
  final String name;
  final ByokKind kind;

  /// Empty for the custom presets (the user types it).
  final String baseUrl;

  /// Where the model list is when it is not `<base>/models` (OpenCode lists on another path).
  final String modelsUrl;

  /// Local servers (Ollama, LM Studio) take no key.
  final bool needsKey;
  final String keyHint;
  final String keyUrl;

  /// One short line shown under the key field when the provider has a catch.
  final String note;

  /// BrandLogo id (assets/logos/<logo>.svg); empty = initials.
  final String logo;

  /// The user types the base URL (custom OpenAI- or Anthropic-compatible).
  final bool custom;
}

class ByokPresets {
  ByokPresets._();

  static const all = <ByokPreset>[
    ByokPreset(id: 'openai', name: 'OpenAI', kind: ByokKind.openai, baseUrl: 'https://api.openai.com/v1', keyHint: 'sk-…', keyUrl: 'https://platform.openai.com/api-keys', logo: 'openai'),
    ByokPreset(id: 'anthropic', name: 'Anthropic', kind: ByokKind.anthropic, baseUrl: 'https://api.anthropic.com/v1', keyHint: 'sk-ant-…', keyUrl: 'https://console.anthropic.com/settings/keys', logo: 'anthropic'),
    ByokPreset(id: 'gemini', name: 'Google Gemini', kind: ByokKind.gemini, baseUrl: 'https://generativelanguage.googleapis.com/v1beta', keyHint: 'AIza…', keyUrl: 'https://aistudio.google.com/apikey', logo: 'googlegemini'),
    ByokPreset(id: 'openrouter', name: 'OpenRouter', kind: ByokKind.openrouter, baseUrl: 'https://openrouter.ai/api/v1', keyHint: 'sk-or-v1-…', keyUrl: 'https://openrouter.ai/keys', logo: 'openrouter'),
    ByokPreset(id: 'deepseek', name: 'DeepSeek', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.deepseek.com', keyHint: 'sk-…', keyUrl: 'https://platform.deepseek.com/api_keys', logo: 'deepseek'),
    ByokPreset(id: 'nvidia', name: 'NVIDIA NIM', kind: ByokKind.openaiCompatible, baseUrl: 'https://integrate.api.nvidia.com/v1', keyHint: 'nvapi-…', keyUrl: 'https://build.nvidia.com', logo: 'nvidia'),
    ByokPreset(id: 'tokenharbor', name: 'TokenHarbor', kind: ByokKind.openaiCompatible, baseUrl: 'https://tokenharbor.ai/v1', keyHint: 'thk_live_…', keyUrl: 'https://tokenharbor.ai/dashboard/api-keys'),
    ByokPreset(
        id: 'opencode',
        name: 'OpenCode',
        kind: ByokKind.openaiCompatible,
        baseUrl: 'https://opencode.ai/inference/openai/v1',
        modelsUrl: 'https://opencode.ai/inference/v1/models',
        keyHint: 'oc_sk_…',
        keyUrl: 'https://opencode.ai/console',
        note: 'Paid and Go models work with your Console key. Free models only answer inside OpenCode’s own app.',
        logo: 'opencode'),
    ByokPreset(id: 'groq', name: 'Groq', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.groq.com/openai/v1', keyHint: 'gsk_…', keyUrl: 'https://console.groq.com/keys'),
    ByokPreset(id: 'mistral', name: 'Mistral', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.mistral.ai/v1', keyUrl: 'https://console.mistral.ai/api-keys', logo: 'mistralai'),
    ByokPreset(id: 'xai', name: 'xAI', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.x.ai/v1', keyHint: 'xai-…', keyUrl: 'https://console.x.ai', logo: 'xai'),
    ByokPreset(id: 'together', name: 'Together AI', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.together.xyz/v1', keyUrl: 'https://api.together.ai/settings/api-keys'),
    ByokPreset(id: 'fireworks', name: 'Fireworks', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.fireworks.ai/inference/v1', keyHint: 'fw_…', keyUrl: 'https://fireworks.ai/account/api-keys'),
    ByokPreset(id: 'cerebras', name: 'Cerebras', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.cerebras.ai/v1', keyHint: 'csk-…', keyUrl: 'https://cloud.cerebras.ai'),
    ByokPreset(id: 'moonshot', name: 'Moonshot (Kimi)', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.moonshot.ai/v1', keyHint: 'sk-…', keyUrl: 'https://platform.kimi.ai', logo: 'moonshotai'),
    ByokPreset(id: 'zai', name: 'Z.ai (GLM)', kind: ByokKind.openaiCompatible, baseUrl: 'https://api.z.ai/api/paas/v4', keyUrl: 'https://z.ai/manage-apikey/apikey-list'),
    ByokPreset(
        id: 'ollama',
        name: 'Ollama',
        kind: ByokKind.openaiCompatible,
        baseUrl: 'http://localhost:11434/v1',
        needsKey: false,
        note: 'Runs on this phone or your network. Use the computer’s address (http://192.168.x.x:11434/v1) for one on your Wi-Fi.',
        logo: 'ollama'),
    ByokPreset(
        id: 'lmstudio',
        name: 'LM Studio',
        kind: ByokKind.openaiCompatible,
        baseUrl: 'http://localhost:1234/v1',
        needsKey: false,
        note: 'Turn on “Serve on local network” in LM Studio and use the computer’s address.',
        logo: 'lmstudio'),
    ByokPreset(id: 'custom-openai', name: 'OpenAI-compatible', kind: ByokKind.openaiCompatible, custom: true, note: 'Any server that speaks the OpenAI chat API. Paste its base URL, usually ending in /v1.'),
    ByokPreset(id: 'custom-anthropic', name: 'Anthropic-compatible', kind: ByokKind.anthropicCompatible, custom: true, note: 'Any server that speaks Anthropic’s Messages API, e.g. https://tokenharbor.ai or https://api.deepseek.com/anthropic.'),
  ];

  static ByokPreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// One API key of a provider. The secret itself is in encrypted storage under [ByokStore.keyEntry]; [hint] is its
/// last four characters, enough to tell keys apart on screen.
class ByokKey {
  ByokKey({required this.id, this.name = '', this.hint = '', this.failedAt});
  final String id;
  String name;
  String hint;

  /// When the provider last refused this key (rotation skips it for a while). Not shown as an error by itself.
  DateTime? failedAt;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'hint': hint, if (failedAt != null) 'failed_at': failedAt!.toIso8601String()};

  factory ByokKey.fromJson(Map j) => ByokKey(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        hint: '${j['hint'] ?? ''}',
        failedAt: DateTime.tryParse('${j['failed_at'] ?? ''}'),
      );

  /// What the UI shows for a key: never the key, only its last four.
  static String mask(String hint) => hint.isEmpty ? '••••' : '••••$hint';
}

/// One model of a provider, with what is known about it (from the provider's list, or typed by the user).
class ByokModel {
  ByokModel({
    required this.id,
    this.name = '',
    this.context,
    this.output,
    this.reasoning,
    this.vision,
    this.tools,
    this.enabled = true,
    this.custom = false,
  });

  final String id;
  String name;
  int? context;
  int? output;
  bool? reasoning;
  bool? vision;
  bool? tools;
  bool enabled;

  /// Added by hand (not from the provider's list).
  bool custom;

  String get label => name.trim().isEmpty ? id : name.trim();

  static final _small = RegExp(r'(\b(mini|nano|lite|haiku|tiny|small|micro|instant)\b|\b1?\d(\.\d)?b\b)', caseSensitive: false);
  static final _strong = RegExp(
      r'(opus|sonnet|gpt-?5|\bo[134]\b|\bo[134]-(pro|high)|gemini-[\d.]+-pro|gemini-pro|grok-[34]|deepseek-(r1|v3|reasoner)|qwen3?-max|qwen3-coder|kimi-k2|glm-4\.[5-9]|glm-[5-9]|mistral-large|llama-?[34](\.\d)?-405b|\bpro\b|-pro\b|thinking|reasoner)',
      caseSensitive: false);

  /// How strong a model looks from its name and what the provider said about it: 2 strong, 1 normal, 0 small/fast.
  /// Only orders pickers (strong models pinned first); it never decides which model a turn runs on.
  int get strength {
    final n = '$id $name';
    if (_small.hasMatch(n)) return 0;
    if (_strong.hasMatch(n) || reasoning == true) return 2;
    return 1;
  }

  /// [models] with the strong ones first; equal strength keeps the given order.
  static List<ByokModel> strongFirst(List<ByokModel> models) {
    final idx = {for (var i = 0; i < models.length; i++) models[i]: i};
    return [...models]..sort((a, b) {
        final d = b.strength - a.strength;
        return d != 0 ? d : idx[a]!.compareTo(idx[b]!);
      });
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (name.isNotEmpty) 'name': name,
        if (context != null) 'context': context,
        if (output != null) 'output': output,
        if (reasoning != null) 'reasoning': reasoning,
        if (vision != null) 'vision': vision,
        if (tools != null) 'tools': tools,
        'enabled': enabled,
        if (custom) 'custom': true,
      };

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static bool? _bool(Object? v) => v is bool ? v : null;

  factory ByokModel.fromJson(Map j) => ByokModel(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        context: _int(j['context']),
        output: _int(j['output']),
        reasoning: _bool(j['reasoning']),
        vision: _bool(j['vision']),
        tools: _bool(j['tools']),
        enabled: j['enabled'] != false,
        custom: j['custom'] == true,
      );

  ByokModel copy() => ByokModel.fromJson(toJson());
}

/// One of the user's providers.
class ByokProvider {
  ByokProvider({
    required this.id,
    required this.kind,
    this.preset = '',
    this.name = '',
    this.baseUrl = '',
    this.modelsUrl = '',
    Map<String, String>? headers,
    this.enabled = true,
    List<ByokKey>? keys,
    this.activeKey = '',
    this.rotate = false,
    List<ByokModel>? models,
  })  : headers = headers ?? {},
        keys = keys ?? [],
        models = models ?? [];

  /// `byok-` + 8 hex: also the opencode provider id (never a built-in id, so opencode's catalogue is never needed).
  final String id;
  ByokKind kind;
  String preset;
  String name;
  String baseUrl;
  String modelsUrl;
  Map<String, String> headers;
  bool enabled;
  List<ByokKey> keys;
  String activeKey;

  /// When a key is refused or out of quota, move to the next key on its own.
  bool rotate;
  List<ByokModel> models;

  static const prefix = 'byok-';
  static final idPattern = RegExp(r'^byok-[a-z0-9]{4,24}$');

  static String newId([Random? r]) {
    final rnd = r ?? Random.secure();
    return '$prefix${List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join()}';
  }

  ByokPreset? get presetDef => ByokPresets.byId(preset);

  /// Whether this provider needs a key at all (local servers do not).
  bool get needsKey => presetDef?.needsKey ?? true;

  String get logo => presetDef?.logo ?? '';

  String get label => name.trim().isNotEmpty ? name.trim() : (presetDef?.name ?? 'Provider');

  ByokKey? get active {
    for (final k in keys) {
      if (k.id == activeKey) return k;
    }
    return keys.isEmpty ? null : keys.first;
  }

  List<ByokModel> get enabledModels => [for (final m in models) if (m.enabled) m];

  ByokModel? model(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The base URL the API is called on. Anthropic SDKs take a base without the version and add `/v1`; the AI SDK
  /// (and our list call) want it with `/v1`. So an Anthropic-style base with no version segment gets `/v1`.
  String get apiBase => apiBaseOf(kind, baseUrl);

  static String apiBaseOf(ByokKind kind, String base) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (kind.isAnthropic && b.isNotEmpty && !RegExp(r'/v\d+[a-z0-9]*$').hasMatch(b)) b = '$b/v1';
    return b;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.id,
        if (preset.isNotEmpty) 'preset': preset,
        'name': name,
        'base_url': baseUrl,
        if (modelsUrl.isNotEmpty) 'models_url': modelsUrl,
        if (headers.isNotEmpty) 'headers': headers,
        'enabled': enabled,
        'keys': [for (final k in keys) k.toJson()],
        if (activeKey.isNotEmpty) 'active_key': activeKey,
        if (rotate) 'rotate': true,
        'models': [for (final m in models) m.toJson()],
      };

  factory ByokProvider.fromJson(Map j) {
    final keys = [
      for (final k in (j['keys'] is List ? j['keys'] as List : const []))
        if (k is Map && '${k['id'] ?? ''}'.isNotEmpty) ByokKey.fromJson(k),
    ];
    final models = <ByokModel>[];
    final seen = <String>{};
    for (final m in (j['models'] is List ? j['models'] as List : const [])) {
      // Early drafts kept models as plain ids.
      final mm = m is Map ? ByokModel.fromJson(m) : (m is String ? ByokModel(id: m) : null);
      if (mm == null || mm.id.trim().isEmpty || !seen.add(mm.id)) continue;
      models.add(mm);
    }
    return ByokProvider(
      id: '${j['id'] ?? ''}',
      kind: ByokKindX.parse('${j['kind'] ?? ''}'),
      preset: '${j['preset'] ?? ''}',
      name: '${j['name'] ?? ''}',
      baseUrl: '${j['base_url'] ?? j['baseUrl'] ?? ''}',
      modelsUrl: '${j['models_url'] ?? ''}',
      headers: j['headers'] is Map ? (j['headers'] as Map).map((k, v) => MapEntry('$k', '$v')) : {},
      enabled: j['enabled'] != false,
      keys: keys,
      activeKey: '${j['active_key'] ?? ''}',
      rotate: j['rotate'] == true,
      models: models,
    );
  }

  ByokProvider copy() => ByokProvider.fromJson(jsonDecode(jsonEncode(toJson())) as Map);

  /// A fresh provider from a preset.
  factory ByokProvider.fromPreset(ByokPreset p, {String? id}) => ByokProvider(
        id: id ?? newId(),
        kind: p.kind,
        preset: p.id,
        name: p.name,
        baseUrl: p.baseUrl,
        modelsUrl: p.modelsUrl,
      );
}

/// A model choice: SubMac's own model, or one model of one of the user's providers.
///
/// Written like a bot's model setting (`providerId|modelId`), so bots and the chat share one format:
/// `auto` / empty / `submac` / `submac|<alias>` = SubMac; `byok-1a2b3c4d|claude-sonnet-4-5` = BYOK.
class ByokRef {
  const ByokRef(this.provider, this.model);
  final String provider;
  final String model;

  static const submac = 'submac';

  /// The ref of a BYOK model, or null when [setting] names SubMac (or nothing usable).
  static ByokRef? parse(String? setting) {
    final s = (setting ?? '').trim();
    final i = s.indexOf('|');
    if (i <= 0) return null;
    final p = s.substring(0, i).trim();
    final m = s.substring(i + 1).trim();
    if (!p.startsWith(ByokProvider.prefix) || m.isEmpty) return null;
    return ByokRef(p, m);
  }

  @override
  String toString() => '$provider|$model';

  @override
  bool operator ==(Object other) => other is ByokRef && other.provider == provider && other.model == model;
  @override
  int get hashCode => Object.hash(provider, model);
}

/// Everything saved: the providers (no secrets) and the chat's model choice.
class ByokConfig {
  ByokConfig({List<ByokProvider>? providers, this.chat = ByokRef.submac}) : providers = providers ?? [];
  static const version = 1;

  final List<ByokProvider> providers;

  /// The owner's chats: `submac` or `byok-…|model`.
  String chat;

  Map<String, dynamic> toJson() => {'v': version, 'chat': chat, 'providers': [for (final p in providers) p.toJson()]};

  /// Reads any saved shape: a bare list of providers, a missing chat, unknown kinds, duplicate or broken entries.
  factory ByokConfig.fromJson(Object? raw) {
    Object? j = raw;
    if (j is String) {
      try {
        j = jsonDecode(j);
      } catch (_) {
        j = null;
      }
    }
    if (j is List) j = <String, Object?>{'providers': j};
    if (j is! Map) return ByokConfig();
    final list = <ByokProvider>[];
    final seen = <String>{};
    for (final p in (j['providers'] is List ? j['providers'] as List : const [])) {
      if (p is! Map) continue;
      final pr = ByokProvider.fromJson(p);
      if (!ByokProvider.idPattern.hasMatch(pr.id) || !seen.add(pr.id)) continue;
      list.add(pr);
    }
    final chat = '${j['chat'] ?? ''}'.trim();
    return ByokConfig(providers: list, chat: chat.isEmpty ? ByokRef.submac : chat);
  }
}

/// One BYOK model ready to use: its provider and model.
class ByokPick {
  const ByokPick(this.provider, this.model);
  final ByokProvider provider;
  final ByokModel model;
  ByokRef get ref => ByokRef(provider.id, model.id);
}

/// The saved BYOK setup, loaded once at start and kept in memory (OcLane reads it synchronously per turn).
class ByokStore extends ChangeNotifier {
  ByokStore({AiSecretStore? store}) : _store = store;
  static ByokStore I = ByokStore();

  final AiSecretStore? _store;
  AiSecretStore get store => _store ?? AiKeys.store;

  static const configEntry = 'byok_config_v1';
  static String keyEntry(String keyId) => 'byok_key_$keyId';

  ByokConfig _cfg = ByokConfig();
  ByokConfig get config => _cfg;
  List<ByokProvider> get providers => List.unmodifiable(_cfg.providers);

  /// Keys read from storage this session (provider key id -> secret). Never logged or printed.
  final Map<String, String> _keys = {};
  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      _cfg = ByokConfig.fromJson(await store.read(configEntry));
      _keys.clear();
      for (final p in _cfg.providers) {
        for (final k in p.keys) {
          final v = await store.read(keyEntry(k.id));
          if (v != null && v.isNotEmpty) _keys[k.id] = v;
        }
      }
    } catch (_) {
      _cfg = ByokConfig();
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    await store.write(configEntry, jsonEncode(_cfg.toJson()));
    notifyListeners();
  }

  ByokProvider? provider(String id) {
    for (final p in _cfg.providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The secret of [keyId], from memory (loaded at start). Only the opencode env and direct provider calls read it.
  String? secret(String keyId) => _keys[keyId];

  /// The key a provider calls with now (its active key), or null.
  String? activeSecret(ByokProvider p) {
    final k = p.active;
    return k == null ? null : _keys[k.id];
  }

  /// Saves a provider (new or edited). Keys are saved with [addKey]; this keeps the provider's list as given.
  Future<void> upsert(ByokProvider p) async {
    final i = _cfg.providers.indexWhere((x) => x.id == p.id);
    if (i >= 0) {
      _cfg.providers[i] = p;
    } else {
      _cfg.providers.add(p);
    }
    if (p.activeKey.isEmpty && p.keys.isNotEmpty) p.activeKey = p.keys.first.id;
    await _save();
  }

  Future<void> remove(String providerId) async {
    final p = provider(providerId);
    if (p == null) return;
    for (final k in p.keys) {
      _keys.remove(k.id);
      await store.delete(keyEntry(k.id));
    }
    _cfg.providers.removeWhere((x) => x.id == providerId);
    if (ByokRef.parse(_cfg.chat)?.provider == providerId) _cfg.chat = ByokRef.submac;
    await _save();
  }

  /// Adds a key to [p] (stored encrypted, apart from the config) and returns its record. The first key becomes active.
  Future<ByokKey> addKey(ByokProvider p, String secret, {String name = ''}) async {
    final s = secret.trim();
    final r = Random.secure();
    final k = ByokKey(
      id: List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join(),
      name: name.trim().isEmpty ? 'Key ${p.keys.length + 1}' : name.trim(),
      hint: s.length >= 4 ? s.substring(s.length - 4) : '',
    );
    await store.write(keyEntry(k.id), s);
    _keys[k.id] = s;
    p.keys.add(k);
    if (p.activeKey.isEmpty || p.keys.length == 1) p.activeKey = k.id;
    // The key's record is saved with its provider (upsert); until then only the encrypted secret exists.
    if (identical(provider(p.id), p)) await _save();
    return k;
  }

  /// Removes a key at once: its secret is deleted, from [p] (an edit copy) and from the saved provider alike.
  Future<void> removeKey(ByokProvider p, String keyId) async {
    _keys.remove(keyId);
    await store.delete(keyEntry(keyId));
    final saved = provider(p.id);
    for (final x in {p, if (saved != null) saved}) {
      x.keys.removeWhere((k) => k.id == keyId);
      if (x.activeKey == keyId) x.activeKey = x.keys.isEmpty ? '' : x.keys.first.id;
    }
    if (saved != null) await _save();
  }

  /// Drops keys that were stored for a provider that was never saved (the add flow was left half way).
  Future<void> discardKeys(Iterable<ByokKey> keys) async {
    for (final k in keys) {
      _keys.remove(k.id);
      await store.delete(keyEntry(k.id));
    }
  }

  // ------------------------------------------------------------------ choosing a model

  /// The owner's chat model setting (`submac` or `byok-…|model`).
  String get chatModel => _cfg.chat;

  Future<void> setChatModel(String setting) async {
    _cfg.chat = setting.trim().isEmpty ? ByokRef.submac : setting.trim();
    await _save();
  }

  /// A usable BYOK model for [setting]: the provider exists and is on, the model is on, and there is a key when the
  /// provider needs one. Null means "use SubMac".
  ByokPick? resolve(String? setting) {
    final ref = ByokRef.parse(setting);
    if (ref == null) return null;
    final p = provider(ref.provider);
    if (p == null || !p.enabled) return null;
    final m = p.model(ref.model);
    if (m == null || !m.enabled) return null;
    if (p.needsKey && activeSecret(p) == null) return null;
    return ByokPick(p, m);
  }

  /// Every model the user can pick, grouped by provider (enabled providers and models only). Within a provider the
  /// strong models come first ([ByokModel.strength]), the rest keep the provider's order.
  List<ByokPick> get choices => [
        for (final p in _cfg.providers)
          if (p.enabled && (!p.needsKey || activeSecret(p) != null))
            for (final m in ByokModel.strongFirst(p.enabledModels)) ByokPick(p, m),
      ];

  bool get hasChoices => choices.isNotEmpty;

  /// The name of a model setting as shown in pickers ("SubMac", or "Claude Sonnet 4.5 · Anthropic").
  String labelOf(String? setting, {bool withProvider = false}) {
    final pick = resolve(setting);
    if (pick == null) return 'SubMac';
    return withProvider ? '${pick.model.label} · ${pick.provider.label}' : pick.model.label;
  }

  // ------------------------------------------------------------------ key rotation

  /// Words in a failed turn's error that mean the key itself is the problem (refused, out of quota or credit).
  static final _keyError = RegExp(
      r'\b(401|402|403|429)\b|unauthori[sz]ed|invalid[ _-]?(api[ _-]?)?key|incorrect api key|authentication|permission denied|quota|insufficient|credit|billing|rate[ _-]?limit|too many requests',
      caseSensitive: false);

  static bool isKeyError(String? text) => text != null && _keyError.hasMatch(text);

  /// After a BYOK turn failed with [error]: when the provider rotates and has another key, that key becomes active
  /// (the engine picks it up before the next turn). Returns the new key's name, or null when nothing changed.
  Future<String?> rotateAfter(String providerId, String? error) async {
    if (!isKeyError(error)) return null;
    final p = provider(providerId);
    if (p == null || !p.rotate || p.keys.length < 2) return null;
    final now = DateTime.now();
    final cur = p.active;
    cur?.failedAt = now;
    final i = cur == null ? -1 : p.keys.indexOf(cur);
    for (var n = 1; n <= p.keys.length; n++) {
      final k = p.keys[(i + n) % p.keys.length];
      if (k == cur || _keys[k.id] == null) continue;
      // A key refused in the last 10 minutes is skipped while another is still untried.
      final recent = k.failedAt != null && now.difference(k.failedAt!) < const Duration(minutes: 10);
      if (recent && n < p.keys.length - 1) continue;
      p.activeKey = k.id;
      await _save();
      return k.name;
    }
    return null;
  }

  // ------------------------------------------------------------------ tests

  @visibleForTesting
  void resetForTests([ByokConfig? cfg, Map<String, String>? keys]) {
    _cfg = cfg ?? ByokConfig();
    _keys
      ..clear()
      ..addAll(keys ?? const {});
    _loaded = true;
  }
}
