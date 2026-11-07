import 'byok.dart';
import 'byok_fetch.dart';
import 'bots.dart';
import 'cloud.dart';
import 'llm_client.dart';
import 'oc_lanes.dart';
import '../models.dart' show ModelRef, ProviderConfig, ToolCall;

/// Where one of a bot's model calls goes (owner 2026-11-06: "bots do not use the model set in their profile").
///
/// opencode turns already named the bot's model per prompt (OcLane.pick), but every plain one-answer call outside
/// opencode was sent to SubMac's own model whatever the bot's profile said: a team's "who speaks" decision, the lead's
/// plan and combined answer, a bot's instant reply in the team chat, a bot asked for its expert view (bot_ask) and the
/// yes/no check before a check-in wake. A bot on one of the owner's own models (BYOK) therefore answered half its team
/// work on another model, and when the bots' share of SubMac's allowance was used up its check-ins stopped although
/// its own model was not billed by SubMac. This is the one place that decides it, from the same setting OcLane uses:
///  - the bot's own model (`byok-…|model`) when usable here: that provider, directly from the phone;
///  - Default (`auto`): the owner's chat model (which may itself be one of their own models);
///  - SubMac (or anything unusable): SubMac's model.
class BotModelRoute {
  const BotModelRoute(this.byok, this.submacModel, this.setting);

  /// The owner's own provider and model this bot runs on, or null for SubMac.
  final ByokPick? byok;

  /// The SubMac model name when [byok] is null.
  final String submacModel;

  /// The setting it came from (after Default and unusable models are resolved).
  final String setting;

  bool get isByok => byok != null;

  /// The route of bot [b] (its profile's model). [userModel]: the owner's chat model (default: the saved choice).
  static BotModelRoute of(Bot b, {String? userModel, ByokStore? store}) => ofSetting(b.model, userModel: userModel, store: store);

  static BotModelRoute ofSetting(String? botModel, {String? userModel, ByokStore? store}) {
    final st = store ?? ByokStore.I;
    final setting = OcLane.botSetting(botModel, userModel: userModel, store: st);
    return BotModelRoute(st.resolve(setting), OcLane.modelFor(setting), setting);
  }

  /// The same choice as opencode's prompt `model` for this bot (OcLane.pick), so both paths always agree.
  Map<String, String> asOcModel({bool background = true, bool officeWork = false}) => byok != null
      ? {'providerID': byok!.provider.id, 'modelID': byok!.model.id}
      : {'providerID': background ? (officeWork ? OcLane.office : OcLane.bot) : OcLane.fg, 'modelID': submacModel};

  @override
  String toString() => byok != null ? '${byok!.provider.id}|${byok!.model.id}' : 'submac|$submacModel';
}

/// A bot's plain one-answer model call on the bot's own model ([BotModelRoute]).
class BotLlm {
  BotLlm._();

  /// The call to one of the owner's own providers (tests replace it).
  static Future<String> Function(ByokPick pick, List<Map<String, dynamic>> messages, {int? maxTokens}) byokCall = _byok;

  /// The call to SubMac's model (tests replace it). [background]: billed to the bots' share.
  static Future<String> Function(String model, List<Map<String, dynamic>> messages,
      {int? maxTokens, int continues, String source, bool background, ProviderConfig? provider}) cloudCall = _cloud;

  /// [maxTokens] within what the model can write (its listed output limit; Anthropic needs a value it accepts).
  static int? capFor(ByokPick pick, int? maxTokens) {
    if (maxTokens == null) return null;
    final out = pick.model.output;
    if (out != null && out > 0) return out < maxTokens ? out : maxTokens;
    return pick.provider.kind.isAnthropic && maxTokens > 8192 ? 8192 : maxTokens;
  }

  static Future<String> _byok(ByokPick pick, List<Map<String, dynamic>> messages, {int? maxTokens}) async {
    final st = ByokStore.I;
    try {
      return await ByokFetch.I.complete(pick.provider, st.activeSecret(pick.provider), pick.model.id, messages, maxTokens: capFor(pick, maxTokens));
    } on ByokError catch (e) {
      // A refused or exhausted key: the provider's next key takes over for the next call (as in opencode turns).
      await st.rotateAfter(pick.provider.id, e.message).catchError((Object _) => null);
      rethrow;
    }
  }

  static Future<String> _cloud(String model, List<Map<String, dynamic>> messages,
          {int? maxTokens, int continues = 0, String source = 'bot', bool background = false, ProviderConfig? provider}) =>
      (LlmClient()..background = background).complete(
          source: source, maxTokens: maxTokens, continues: continues, provider: provider ?? Cloud.provider, model: model, messages: messages);

  /// One answer for bot [b] from its own model. [background]: SubMac calls bill to the bots' share (a BYOK call is
  /// never billed by SubMac). [route]: an already computed route (the caller checked it for rate limits).
  /// [continues]: SubMac replies cut for length are continued that many times (LlmClient).
  static Future<String> complete(Bot b, List<Map<String, dynamic>> messages,
      {int? maxTokens, int continues = 0, String source = 'bot', bool background = false, BotModelRoute? route, ProviderConfig? provider}) {
    final r = route ?? BotModelRoute.of(b);
    final pick = r.byok;
    if (pick != null) return byokCall(pick, messages, maxTokens: maxTokens);
    return cloudCall(r.submacModel, messages, maxTokens: maxTokens, continues: continues, source: source, background: background, provider: provider);
  }
}

/// Where a bot's browser task thinks (owner 2026-11-07): the browser agent (agent/core.dart) ran on SubMac's model for
/// every caller. It now follows the bot's profile like its other calls ([BotModelRoute]):
///  - a bot on one of the owner's OpenAI-compatible providers: that provider, straight from the phone (tool calls and
///    screenshots in the OpenAI shape; screenshots only when the model is not marked as text-only);
///  - a bot on an Anthropic or Gemini key: SubMac's model (their protocols need the tool shape converted; not done);
///  - a bot on a SubMac model: that model; SubMac's own tasks: SubMac's model as before.
class BotBrowserModel {
  const BotBrowserModel._(this.byok, this.submac, this.note);

  final ByokPick? byok;
  final ModelRef? submac;

  /// Why the bot's own model was not used ('' when it was, or there is no bot).
  final String note;

  bool get onOwnModel => byok != null;

  /// A model with screenshots: a BYOK model marked as text-only gets the page text alone.
  bool get sees => byok == null || byok!.model.vision != false;

  static BotBrowserModel of(Bot? b, ModelRef submacRef, {ByokStore? store}) {
    if (b == null) return BotBrowserModel._(null, submacRef, '');
    final r = BotModelRoute.of(b, store: store);
    final pick = r.byok;
    if (pick != null) {
      if (!ByokFetch.toolChatOk(pick.provider)) {
        return BotBrowserModel._(null, submacRef, '${pick.provider.kind.label} keys are not used for browser steps yet; SubMac\'s model runs them.');
      }
      if (pick.model.tools == false) return BotBrowserModel._(null, submacRef, '${pick.model.label} has no tool calling; SubMac\'s model runs browser steps.');
      return BotBrowserModel._(pick, null, '');
    }
    return BotBrowserModel._(null, ModelRef(submacRef.provider, r.submacModel.isEmpty ? submacRef.model : r.submacModel), '');
  }

  /// [messages] with picture parts taken out (a text-only model gets the page text alone).
  static List<Map<String, dynamic>> withoutImages(List<Map<String, dynamic>> messages) => [
        for (final m in messages)
          if (m['content'] is List)
            {
              ...m,
              'content': [
                for (final p in m['content'] as List)
                  if (!(p is Map && (p['type'] == 'image_url' || p['type'] == 'image'))) p
              ]
            }
          else
            m
      ];

  /// Tests: the BYOK step call.
  static Future<LlmResult> Function(ByokPick pick, List<Map<String, dynamic>> messages, List<Map<String, dynamic>> tools)? stepOverride;

  /// One browser step on the bot's own provider. Throws [LlmException] on a provider error (the task ends with it).
  static Future<LlmResult> byokStep(ByokPick pick, List<Map<String, dynamic>> messages, List<Map<String, dynamic>> tools) async {
    final o = stepOverride;
    if (o != null) return o(pick, messages, tools);
    final st = ByokStore.I;
    try {
      final a = await ByokFetch.I.toolChat(pick.provider, st.activeSecret(pick.provider), pick.model.id, messages, tools,
          maxTokens: BotLlm.capFor(pick, 4096));
      return LlmResult(a.text, [for (final c in a.calls) ToolCall(id: c['id']!, name: c['name']!, arguments: c['arguments']!)], a.finish,
          a.tokens, a.tokensIn, a.tokensOut);
    } on ByokError catch (e) {
      await st.rotateAfter(pick.provider.id, e.message).catchError((Object _) => null);
      throw LlmException(e.message, status: e.status);
    }
  }
}
