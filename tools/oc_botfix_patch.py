import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n))
        sys.exit(1)
    p.write_text(s.replace(old, new))
    print("patched", path)

old = '''  static List<Map<String, dynamic>>? _capTools(List<Map<String, dynamic>>? tools) {
    if (tools == null) return null;
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final t in tools) {
      final n = '${(t['function'] as Map?)?['name']}';
      if (seen.add(n)) out.add(t);
      if (out.length >= 120) break;
    }
    return out;
  }'''

new = '''  static List<Map<String, dynamic>>? _capTools(List<Map<String, dynamic>>? tools) {
    if (tools == null) return null;
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    // Keep the app-reach tools (apps_list_tools, apps_run_tool, connectors, api_call) first. A bot's own engine is
    // handed this list and calls tools directly (there is no find/run gateway), so trimming the tail used to drop
    // exactly those and leave every connected app out of reach (owner 2026-11-09). Raw mcp_* tools are trimmed.
    for (final t in tools) {
      final n = '${(t['function'] as Map?)?['name']}';
      if (n.startsWith('mcp_')) continue;
      if (seen.add(n)) out.add(t);
    }
    for (final t in tools) {
      if (out.length >= 120) break;
      final n = '${(t['function'] as Map?)?['name']}';
      if (!n.startsWith('mcp_')) continue;
      if (seen.add(n)) out.add(t);
    }
    if (out.length > 120) out.removeRange(120, out.length);
    return out;
  }'''

patch("lib/app_state.dart", old, new)
