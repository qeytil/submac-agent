import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'byok.dart';

/// The user's own providers written into opencode's config (owner 2026-11-03, docs/byok.md).
///
/// opencode 1.19.5 bundles its provider SDKs inside the binary (checked on the arm64 build: lazy `/$bunfs` imports for
/// `@ai-sdk/openai-compatible`, `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/openai`, `@openrouter/ai-sdk-provider`
/// and more), so nothing is installed from npm on the phone. Each enabled provider becomes one custom opencode provider
/// whose id is the BYOK id (`byok-…`), with its models listed explicitly, so opencode's models.dev catalogue is never
/// needed. Verified with the real binary against local mock servers (all five packages, keys from the environment).
///
/// The key is never written into opencode.json: `apiKey` is `{env:SUBMAC_BYOK_<ID>}` (opencode's config variable) and
/// the active key travels only in the opencode process environment ([env]).
class ByokOpencode {
  ByokOpencode._();

  /// opencode's provider package per protocol.
  static String npmOf(ByokKind k) => switch (k) {
        ByokKind.openai => '@ai-sdk/openai',
        ByokKind.openaiCompatible => '@ai-sdk/openai-compatible',
        ByokKind.anthropic || ByokKind.anthropicCompatible => '@ai-sdk/anthropic',
        ByokKind.gemini => '@ai-sdk/google',
        ByokKind.openrouter => '@openrouter/ai-sdk-provider',
      };

  /// The environment variable that carries a provider's active key.
  static String envName(String providerId) => 'SUBMAC_BYOK_${providerId.substring(ByokProvider.prefix.length).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '_')}';

  /// Without a known output limit opencode asks for 32,000 output tokens, which many models refuse (seen in the mock
  /// run). Unknown limits get these safer defaults; the user can set the real ones per model.
  static const defaultContext = 128000;
  static const defaultOutput = 8192;

  /// Providers that go into the config: enabled, with at least one enabled model, and a key when one is needed.
  static List<ByokProvider> usable(List<ByokProvider> providers, String? Function(ByokProvider) secretOf) => [
        for (final p in providers)
          if (p.enabled && ByokProvider.idPattern.hasMatch(p.id) && p.enabledModels.isNotEmpty && (!p.needsKey || (secretOf(p) ?? '').isNotEmpty)) p,
      ];

  /// opencode's `provider` entries for [providers] (pure, for tests).
  static Map<String, dynamic> providers(List<ByokProvider> providers, String? Function(ByokProvider) secretOf) {
    final out = <String, dynamic>{};
    for (final p in usable(providers, secretOf)) {
      final hasKey = (secretOf(p) ?? '').isNotEmpty;
      out[p.id] = {
        'npm': npmOf(p.kind),
        'name': p.label,
        'options': {
          'baseURL': p.apiBase,
          if (hasKey) 'apiKey': '{env:${envName(p.id)}}',
          if (p.headers.isNotEmpty) 'headers': p.headers,
        },
        'models': {
          for (final m in p.enabledModels)
            m.id: {
              'name': m.label,
              // Tool calling is what the agent is: assume it unless the provider said no.
              'tool_call': m.tools ?? true,
              if (m.reasoning != null) 'reasoning': m.reasoning,
              if (m.vision != null) 'attachment': m.vision,
              'limit': {'context': m.context ?? defaultContext, 'output': m.output ?? defaultOutput},
            },
        },
      };
    }
    return out;
  }

  /// The process environment with each usable provider's active key.
  static Map<String, String> env(List<ByokProvider> providers, String? Function(ByokProvider) secretOf) => {
        for (final p in usable(providers, secretOf))
          if ((secretOf(p) ?? '').isNotEmpty) envName(p.id): secretOf(p)!,
      };

  /// A short fingerprint of what the engine was started with (providers, models, active keys). When it changes,
  /// the engine restarts before the next turn. Keys enter only as a hash.
  static String signature(List<ByokProvider> providers, String? Function(ByokProvider) secretOf) {
    final cfg = jsonEncode(ByokOpencode.providers(providers, secretOf));
    final keys = env(providers, secretOf).entries.map((e) => '${e.key}=${e.value}').join('\n');
    return sha256.convert(utf8.encode('$cfg\n$keys')).toString().substring(0, 16);
  }

  /// From the live store.
  static Map<String, dynamic> providersOf(ByokStore s) => providers(s.providers, s.activeSecret);
  static Map<String, String> envOf(ByokStore s) => env(s.providers, s.activeSecret);
  static String signatureOf(ByokStore s) => signature(s.providers, s.activeSecret);
}
