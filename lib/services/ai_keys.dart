import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where API keys and saved AI connections live: the phone's encrypted storage only. Tests swap in [MemoryAiStore].
abstract class AiSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureAiStore implements AiSecretStore {
  const SecureAiStore();
  // Kept on purpose: flutter_secure_storage 10 reads this to migrate data saved by 9.x. Drop it only after every phone ran a v10 build.
  // ignore: deprecated_member_use
  static const _s = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } catch (_) {}
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _s.delete(key: key);
    } catch (_) {}
  }
}

class MemoryAiStore implements AiSecretStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// The result of hiding keys in a message.
class Redacted {
  final String text;
  final int count;
  const Redacted(this.text, this.count);
}

/// API keys the user pastes in chat never stay in the chat: before a message is saved or synced, each key is moved
/// to the phone's encrypted storage and replaced with a short reference (`key_ref:1a2b3c4d5e`). The agent passes that
/// reference to `ai_call`, which looks the key up on the phone. The key is never written back into chat or tool output.
class AiKeys {
  AiKeys._();

  static AiSecretStore store = const SecureAiStore();

  /// Keys hidden this session (so a call right after the message never waits on storage).
  static final Map<String, String> _mem = {};

  static const refPrefix = 'key_ref:';
  static final refPattern = RegExp(r'key_ref:([0-9a-f]{10})');

  // Well-known key shapes (OpenAI, Anthropic, Replicate, Hugging Face, Groq, xAI, Google, Perplexity, Fireworks,
  // NVIDIA, ElevenLabs, fal). A generic "api key: xxxxx" line is caught by [_labelled].
  static final _known = RegExp(
      r'(?<![A-Za-z0-9_\-])('
      r'sk-(?:proj-|ant-|or-v1-)?[A-Za-z0-9_\-]{20,}'
      r'|sk_[A-Za-z0-9]{20,}'
      r'|r8_[A-Za-z0-9]{20,}'
      r'|hf_[A-Za-z0-9]{20,}'
      r'|gsk_[A-Za-z0-9]{20,}'
      r'|xai-[A-Za-z0-9]{20,}'
      r'|pplx-[A-Za-z0-9]{20,}'
      r'|fw_[A-Za-z0-9]{16,}'
      r'|nvapi-[A-Za-z0-9_\-]{20,}'
      r'|AIza[0-9A-Za-z_\-]{30,}'
      r'|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{32}'
      r')(?![A-Za-z0-9_\-])');

  static final _labelled = RegExp(
      r'''(api[\s_\-]?key|apikey|access[\s_\-]?token|secret(?:[\s_\-]?key)?|auth(?:orization)?|bearer|token|key|furaha)(\s*(?:is|=|:)?\s*["'`]?)(?:bearer\s+)?([A-Za-z0-9_\-\.:]{16,})''',
      caseSensitive: false);

  static String refFor(String key) => sha256.convert(utf8.encode(key)).toString().substring(0, 10);

  static String _hide(String key) {
    final r = refFor(key);
    _mem[r] = key;
    unawaited(store.write('ai_key_$r', key));
    return '[API key hidden $refPrefix$r]';
  }

  static bool _looksLikeKey(String s) =>
      !s.startsWith(refPrefix) &&
      !s.startsWith('http') &&
      !s.contains('://') &&
      RegExp(r'[0-9]').hasMatch(s) &&
      RegExp(r'[A-Za-z]').hasMatch(s) &&
      !RegExp(r'^[0-9a-f]{10}$').hasMatch(s);

  /// Hides every key in [text]. Text without keys comes back unchanged.
  static Redacted redact(String text) {
    if (text.isEmpty) return Redacted(text, 0);
    var n = 0;
    var out = text.replaceAllMapped(_known, (m) {
      n++;
      return _hide(m.group(1)!);
    });
    out = out.replaceAllMapped(_labelled, (m) {
      final v = m.group(3)!;
      if (!_looksLikeKey(v)) return m.group(0)!;
      n++;
      return '${m.group(1)}${m.group(2)}${_hide(v)}';
    });
    return Redacted(out, n);
  }

  /// The real key for a `key_ref:` reference; any other text is taken as the key itself.
  static Future<String?> resolve(String value) async {
    final v = value.trim();
    if (v.isEmpty) return null;
    final m = refPattern.firstMatch(v);
    if (m == null) return v;
    final r = m.group(1)!;
    return _mem[r] ?? await store.read('ai_key_$r');
  }

  /// Keeps a key (typed into a tool call) and returns its reference.
  static Future<String> keep(String key) async {
    final r = refFor(key);
    _mem[r] = key;
    await store.write('ai_key_$r', key);
    return '$refPrefix$r';
  }

  /// Replaces [key] (and its usual "Bearer" form) in any text that leaves the tool.
  static String scrub(String text, String? key) {
    if (key == null || key.length < 6) return text;
    return text.replaceAll(key, '••••');
  }

  /// A key shown safely: "sk-…9f2a".
  static String mask(String key) {
    if (key.length <= 8) return '••••';
    return '${key.substring(0, 3)}…${key.substring(key.length - 4)}';
  }

  static void clearSessionForTests() => _mem.clear();
}
