import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


AR = 'lib/state/agent_runner.dart'

OLD = """  Future<List<Map<String, dynamic>>> _partsFor(ChatMessage m) async {
    final ws = await AgentTools.workspaceDir();
    final parts = <Map<String, dynamic>>[];
    if (m.content.trim().isNotEmpty) parts.add({'type': 'text', 'text': m.content});
    for (final a in m.attachments) {
      final local = a.localPath;
      if (local != null && local.isNotEmpty) {
        final abs = local.startsWith('/') ? local : '$ws/$local';
        parts.add({'type': 'file', 'mime': a.mime, 'filename': a.name, 'url': Uri.file(abs).toString()});
      } else if (a.bytes != null) {
        parts.add({
          'type': 'file',
          'mime': a.mime,
          'filename': a.name,
          'url': 'data:${a.mime};base64,${base64Encode(a.bytes!)}',
        });
      } else if (a.extractedText != null) {
        parts.add({'type': 'text', 'text': '${a.name}:\\n${a.extractedText}'});
      }
    }
    if (parts.isEmpty) parts.add({'type': 'text', 'text': m.content});
    return parts;
  }"""

NEW = """  /// How much of a text file is put in the message itself; a longer one stays in the workspace for the agent's tools.
  static const int _attachTextCap = 256 * 1024;

  Future<List<Map<String, dynamic>>> _partsFor(ChatMessage m) async {
    final ws = await AgentTools.workspaceDir();
    final parts = <Map<String, dynamic>>[];
    if (m.content.trim().isNotEmpty) parts.add({'type': 'text', 'text': m.content});
    for (final a in m.attachments) {
      final local = a.localPath;
      final abs = (local != null && local.isNotEmpty) ? (local.startsWith('/') ? local : '$ws/$local') : null;
      // Only pictures and PDFs go to the model as a file part. The model providers refuse any other media type, and the
      // whole message failed to send (owner 2026-11-24: a zip or a .md showed an error). Text is carried as words;
      // any other file is named with the workspace path its tools can open.
      final asFile = (a.mime.startsWith('image/') || a.mime == 'application/pdf') && (abs != null || a.bytes != null);
      if (asFile) {
        parts.add(abs != null
            ? {'type': 'file', 'mime': a.mime, 'filename': a.name, 'url': Uri.file(abs).toString()}
            : {'type': 'file', 'mime': a.mime, 'filename': a.name, 'url': 'data:${a.mime};base64,${base64Encode(a.bytes!)}'});
        continue;
      }
      if (a.extractedText != null && a.extractedText!.trim().isNotEmpty) {
        parts.add({'type': 'text', 'text': '${a.name}:\\n${a.extractedText}'});
        continue;
      }
      final text = await _fileText(a, abs);
      if (text != null && text.trim().isNotEmpty) {
        parts.add({'type': 'text', 'text': '${a.name}:\\n$text'});
      } else {
        final kb = ((a.bytes?.length ?? 0) / 1024).round();
        final where = abs == null ? 'saved on the phone' : 'saved in the workspace at $abs';
        parts.add({
          'type': 'text',
          'text': 'The user attached ${a.name} (${a.mime}${kb > 0 ? ', $kb KB' : ''}), $where. Open it with your tools.'
        });
      }
    }
    if (parts.isEmpty) parts.add({'type': 'text', 'text': m.content});
    return parts;
  }

  /// The words of a small text file (a .md, .csv, source code, ...), or null when it is binary or too big to carry.
  Future<String?> _fileText(Attachment a, String? abs) async {
    if (!a.isText) return null;
    try {
      if (a.bytes != null) {
        if (a.bytes!.length > _attachTextCap) return null;
        return utf8.decode(a.bytes!, allowMalformed: true);
      }
      if (abs != null) {
        final f = File(abs);
        if (!f.existsSync() || f.lengthSync() > _attachTextCap) return null;
        return await f.readAsString();
      }
    } catch (_) {}
    return null;
  }"""

sub(AR, OLD, NEW)
print('attachments: images/PDFs as file parts; text in words; other files named by workspace path')
