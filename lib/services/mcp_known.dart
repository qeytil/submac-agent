/// Servers whose address and key header Telesia knows, so a key given in chat connects even when the model guesses
/// the address (2026-11-03: the agent tried mcp.composio.dev, backend.composio.dev/mcp and a session API with a
/// Composio consumer key sent as a Bearer token; none of them work). Pure, so it is tested on its own.
class McpKnown {
  static const composioConnect = 'https://connect.composio.dev/mcp';

  /// The address and the header for [token] to use instead of what the model gave, or the same when nothing is known.
  static ({String url, String header}) fix(String url, String token, String header) {
    final u = Uri.tryParse(url.trim());
    final host = (u?.host ?? '').toLowerCase();
    final t = token.trim();
    final composio = host == 'composio.dev' || host.endsWith('.composio.dev') || (host.isEmpty && url.toLowerCase().contains('composio'));
    if (!composio) return (url: url, header: header);
    // A Composio Connect consumer key (ck_...): one shared endpoint, key in x-consumer-api-key.
    if (t.startsWith('ck_')) return (url: composioConnect, header: 'x-consumer-api-key');
    // A project key (ak_...) works only on a server the user generated (backend.composio.dev/.../mcp/<id>).
    final generated = host == 'backend.composio.dev' && RegExp(r'/mcp/[A-Za-z0-9-]{6,}').hasMatch(u?.path ?? '');
    if (t.startsWith('ak_') || generated) return (url: url, header: header.isEmpty || t.startsWith('ak_') ? 'x-api-key' : header);
    // No key, or an unknown one: the Connect endpoint (it offers its own sign-in).
    return (url: composioConnect, header: t.isEmpty ? header : (header.isEmpty ? 'x-consumer-api-key' : header));
  }
}
