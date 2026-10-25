import 'ai_keys.dart';
import 'connector_catalog.dart';

/// Every tool result passes through here before it is saved to the chat, synced, journaled or sent to the model:
/// the user's saved connector secrets (an error can carry a URL with a token in it) and anything shaped like an API key
/// are hidden. A key found this way is kept on the phone and replaced by its `key_ref:` reference (see [AiKeys]).
class ToolOutputClean {
  ToolOutputClean._();

  static String clean(String out) {
    if (out.isEmpty) return out;
    return AiKeys.redact(ConnectorCatalog.scrub(out)).text;
  }
}
