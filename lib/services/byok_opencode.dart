import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'byok.dart';
import 'output_limits.dart';

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

  /// Without a known output limit opencode asks for 32,000 output tokens, which some servers refuse (seen in the mock
  /// run). A model the provider gave no output limit for gets its family's known maximum, else
  /// [OutputLimits.fallback] (it was a flat 8,192 before 2026-11-06, which cut long replies short: OpenAI's model list
  /// carries no limits at all).
  static const defaultContext = 128000;
  static const defaultOutput = OutputLimits.fallback;

  /// The output limit written for [m]: the provider's own figure, else the family's maximum, else the fallback; never
  /// more than half the model's window. opencode keeps `context - output` tokens for the chat itself and compacts the
  /// chat when it is over that: an output limit as big as the window (a GPT-5 with no listed window gets the 128,000
  /// default) would make it compact on every step.
  static int outputOf(ByokModel m) {
    final out = OutputLimits.forModel(m.id, known: m.output);
    final half = (m.context ?? defaultContext) ~/ 2;
    return out > half && half > 0 ? half : out;
  }

  /// The largest output limit of the usable models (opencode's own ceiling must not be below it).
  static int maxOutput(List<ByokProvider> providers, String? Function(ByokProvider) secretOf) {
    var m = 0;
    for (final p in usable(providers, secretOf)) {
      for (final x in p.enabledModels) {
        final o = outputOf(x);
        if (o > m) m = o;
      }
    }
    return m;
  }

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
              // A model the user brought can take attachments unless the provider said it cannot. Most
              // providers' model lists do not say, and opencode replaces an image with "cannot read image"
              // for any model it believes is text-only (owner 2026-11-09).
              'attachment': m.vision ?? true,
              'limit': {'context': m.context ?? defaultContext, 'output': outputOf(m)},
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
  static int maxOutputOf(ByokStore s) => maxOutput(s.providers, s.activeSecret);
}
