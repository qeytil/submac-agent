import 'dart:convert';
import 'dart:io';

/// Pictures, drawings, charts, pages and videos an opencode turn made, shown in the chat (owner, 2026-11-04: "there is
/// no visual like image or video or graphics output ability, why?").
///
/// opencode does not know SubMac's ```file / ```visual cards (that teaching lived in the old agent's prompt, which is
/// gone). It makes visuals its own way: it writes chart.svg or page.html with its write tool, makes a PNG with a
/// script, and names the file in its answer, or writes `![chart](chart.svg)`. This turns all of those into the cards
/// the chat already draws. Pure (dart:io only for the file checks), so it is tested without the app.
class TurnVisuals {
  /// Files the chat shows as a picture, drawing, page or video.
  static final visualExt = RegExp(r'\.(png|jpe?g|webp|gif|bmp|svg|mp4|webm|mov|m4v|html?)$', caseSensitive: false);

  static bool isVisual(String path) => visualExt.hasMatch(path.split('?').first.split('#').first);

  /// At most this many cards are added to one answer.
  static const maxCards = 6;

  /// opencode's own tools that write a file, and where they keep its path.
  static const _writeTools = {'write', 'edit', 'multiedit', 'patch'};

  /// Visual files the turn's tool calls wrote ([calls] = opencode tool name and input).
  static List<String> written(Iterable<(String, Map<String, dynamic>)> calls) {
    final out = <String>[];
    for (final (tool, input) in calls) {
      if (!_writeTools.contains(tool)) continue;
      final p = '${input['filePath'] ?? input['file_path'] ?? input['path'] ?? ''}'.trim();
      if (p.isNotEmpty && isVisual(p)) out.add(p);
    }
    return out;
  }

  static final _mdTarget = RegExp(r'!?\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)');
  static final _tick = RegExp(r'`([^`\n]+)`');
  static final _bare = RegExp(r'''(?:^|[\s(:"'])((?:file://)?(?:/|\./)?(?:[\w.\-]+/)*[\w.\-]+\.(?:png|jpe?g|webp|gif|bmp|svg|mp4|webm|mov|m4v|html?))(?=$|[\s).,;:!?"'])''',
      caseSensitive: false, multiLine: true);

  /// Local visual files the answer names: markdown image and link targets, `backticked` paths and bare paths. Web
  /// links are left out (a page on the web is a link, not something this turn made). Text inside code fences counts
  /// only for card fences, which [shown] reads.
  static List<String> named(String text) {
    final prose = _outsideFences(text);
    final out = <String>[];
    void add(String raw) {
      final p = raw.trim();
      if (p.isEmpty || p.startsWith('http://') || p.startsWith('https://') || p.startsWith('data:')) return;
      if (isVisual(p) && !out.contains(p)) out.add(p);
    }

    for (final m in _mdTarget.allMatches(prose)) {
      add(m.group(1)!);
    }
    final noLinks = prose.replaceAll(_mdTarget, ' ');
    for (final m in _tick.allMatches(noLinks)) {
      add(m.group(1)!);
    }
    for (final m in _bare.allMatches(noLinks.replaceAll(_tick, ' '))) {
      add(m.group(1)!);
    }
    return out;
  }

  /// Paths the chat already shows: card fences in the text (```file, ```video, ```page, ```images...) and media a
  /// tool result already put on screen (IMAGE_SAVED / VIDEO_SAVED / FILE_SAVED, a MEDIA_CARD's files).
  static Set<String> shown(String text, Iterable<String> toolOutputs) {
    final out = <String>{};
    for (final m in RegExp(r'```(file|video|page|images|photos)[ \t]*\n([\s\S]*?)```').allMatches(text)) {
      for (final l in m.group(2)!.split('\n')) {
        final t = l.trim();
        if (t.isEmpty) continue;
        out.add(t);
        for (final q in RegExp(r'"(?:url|path|src)"\s*:\s*"([^"]+)"').allMatches(t)) {
          out.add(q.group(1)!);
        }
      }
    }
    for (final o in toolOutputs) {
      for (final m in RegExp(r'(?:IMAGE_SAVED|VIDEO_SAVED|FILE_SAVED|AUDIO_SAVED) (\S+)').allMatches(o)) {
        out.add(m.group(1)!);
      }
      if (o.startsWith('MEDIA_CARD ')) {
        try {
          final j = jsonDecode(o.substring(11).split('\n').first);
          if (j is Map && j['files'] is List) out.addAll([for (final f in j['files'] as List) '$f']);
        } catch (_) {}
      }
    }
    return out;
  }

  /// A path as a full path in [workspace] (opencode works there, so a relative path means the workspace).
  static String resolve(String raw, String workspace) {
    var p = raw.trim();
    if (p.toLowerCase().startsWith('file://')) p = p.substring(7);
    if (p.contains('%')) {
      try {
        p = Uri.decodeFull(p);
      } catch (_) {}
    }
    if (p.startsWith('/')) return p;
    p = p.replaceFirst(RegExp(r'^(\./)+'), '');
    final ws = workspace.endsWith('/') ? workspace.substring(0, workspace.length - 1) : workspace;
    return '$ws/$p';
  }

  /// The cards to add under an answer: each visual file the turn wrote, named or made that is on the phone and not
  /// on screen yet, oldest mention first, at most [maxCards]. Empty when there is nothing to add.
  static String cardsFor({
    required String answer,
    required String workspace,
    Iterable<(String, Map<String, dynamic>)> calls = const [],
    Iterable<String> toolOutputs = const [],
    Iterable<String> made = const [],
    bool Function(String path)? exists,
  }) {
    final has = exists ?? (String p) => File(p).existsSync();
    final seen = {for (final s in shown(answer, toolOutputs)) resolve(s, workspace)};
    final out = <String>[];
    for (final raw in [...named(answer), ...written(calls), ...made]) {
      final p = resolve(raw, workspace);
      if (seen.contains(p) || out.contains(p) || !isVisual(p) || !has(p)) continue;
      out.add(p);
      if (out.length >= maxCards) break;
    }
    return out.map((p) => '```file\n$p\n```').join('\n\n');
  }

  /// [answer] with the turn's visuals added as cards under it ([cards] from [cardsFor]).
  static String attach(String answer, String cards) {
    if (cards.isEmpty) return answer;
    final a = answer.trimRight();
    return a.isEmpty ? cards : '$a\n\n$cards';
  }

  /// Folders a turn's new files are never looked for in: tools, caches, the app's own media (its tools show what they
  /// make there themselves) and hidden folders.
  static const _skipDirs = {'node_modules', '.git', 'build', 'dist', '.dart_tool', 'media', '__pycache__', '.cache', 'venv', '.venv'};

  /// Visual files under [root] changed at or after [since] (a script's chart.png, a page opencode built with bash),
  /// newest last. Bounded: at most [maxEntries] entries are looked at, [maxDepth] folders deep.
  ///
  /// [skip] names more top-level folders to leave out (the owner's chat leaves out bots/ and teams/, which other turns
  /// write to at the same time).
  static List<String> madeSince(Directory root, DateTime since,
      {Set<String> skip = const {}, int maxDepth = 4, int maxEntries = 3000, int max = maxCards}) {
    final found = <(DateTime, String)>[];
    var looked = 0;
    void walk(Directory d, int depth) {
      if (depth > maxDepth || looked > maxEntries) return;
      List<FileSystemEntity> list;
      try {
        list = d.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in list) {
        if (++looked > maxEntries) return;
        final name = e.path.split('/').last;
        if (e is Directory) {
          if (name.startsWith('.') || _skipDirs.contains(name) || (depth == 0 && skip.contains(name))) continue;
          walk(e, depth + 1);
        } else if (e is File && isVisual(name)) {
          try {
            final t = e.lastModifiedSync();
            if (!t.isBefore(since)) found.add((t, e.path));
          } catch (_) {}
        }
      }
    }

    if (root.existsSync()) walk(root, 0);
    found.sort((a, b) => a.$1.compareTo(b.$1));
    final paths = [for (final f in found) f.$2];
    return paths.length > max ? paths.sublist(paths.length - max) : paths;
  }

  /// The reply with each markdown image of a local file, an SVG data URI or a web picture lifted into the card the
  /// chat draws for it (```file, ```visual, ```images), so `![chart](chart.svg)` shows the drawing instead of nothing.
  /// Only images that stand on their own line are lifted; an image inside a sentence stays for the markdown view.
  static String liftImages(String text) {
    if (!text.contains('![')) return text;
    final lines = text.split('\n');
    final out = <String>[];
    String? fence;
    final only = RegExp(r'^\s*!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)\s*$');
    for (final line in lines) {
      final f = RegExp(r'^\s{0,3}(```+|~~~+)').firstMatch(line)?.group(1);
      if (fence != null) {
        if (f != null && line.trim().replaceAll(fence[0], '').isEmpty) fence = null;
        out.add(line);
        continue;
      }
      if (f != null) {
        fence = f;
        out.add(line);
        continue;
      }
      final m = only.firstMatch(line);
      final card = m == null ? null : _cardFor(m.group(2)!, m.group(1)!);
      out.add(card ?? line);
    }
    return out.join('\n');
  }

  static String? _cardFor(String src, String alt) {
    final s = src.trim();
    if (s.startsWith('data:image/svg+xml')) {
      final svg = _dataText(s);
      return svg == null ? null : '```visual\n${svg.trim()}\n```';
    }
    if (s.startsWith('data:')) return null; // a PNG data URI: the markdown view draws it
    if (s.startsWith('http://') || s.startsWith('https://')) {
      return '```images\n${jsonEncode([
            {'url': s, if (alt.trim().isNotEmpty) 'caption': alt.trim()}
          ])}\n```';
    }
    return isVisual(s) ? '```file\n$s\n```' : null;
  }

  /// The text inside a data: URI (base64 or percent-encoded), or null.
  static String? _dataText(String uri) {
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    final head = uri.substring(0, comma);
    final body = uri.substring(comma + 1);
    try {
      return head.endsWith(';base64') ? utf8.decode(base64Decode(body)) : Uri.decodeComponent(body);
    } catch (_) {
      return null;
    }
  }

  /// The bytes of a data: URI picture (for the markdown view), or null.
  static List<int>? dataBytes(String uri) {
    final comma = uri.indexOf(',');
    if (!uri.startsWith('data:') || comma < 0) return null;
    final head = uri.substring(0, comma);
    try {
      return head.endsWith(';base64') ? base64Decode(uri.substring(comma + 1)) : utf8.encode(Uri.decodeComponent(uri.substring(comma + 1)));
    } catch (_) {
      return null;
    }
  }

  /// Text outside ``` fences.
  static String _outsideFences(String text) {
    final sb = StringBuffer();
    String? fence;
    for (final line in text.split('\n')) {
      final f = RegExp(r'^\s{0,3}(```+|~~~+)').firstMatch(line)?.group(1);
      if (fence != null) {
        if (f != null && line.trim().replaceAll(fence[0], '').isEmpty) fence = null;
        continue;
      }
      if (f != null) {
        fence = f;
        continue;
      }
      sb.writeln(line);
    }
    return sb.toString();
  }

  /// Size for generate_image from the shape asked for ("16:9", "portrait"...) or an explicit WxH.
  static String sizeFor(Map<String, dynamic> args) {
    final size = '${args['size'] ?? ''}'.trim();
    if (RegExp(r'^\d{3,4}x\d{3,4}$').hasMatch(size)) return size;
    final a = '${args['aspect'] ?? args['aspect_ratio'] ?? ''}'.trim().toLowerCase();
    return switch (a) {
      '16:9' || '4:3' || '3:2' || 'landscape' || 'wide' => '1536x1024',
      '9:16' || '3:4' || '2:3' || 'portrait' || 'tall' => '1024x1536',
      _ => '1024x1024',
    };
  }
}
