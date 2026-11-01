import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'doc_text.dart';
import 'media_store.dart';
import 'doc_tools.dart';
import 'readable.dart';

/// Tools the agent can call. Everything runs on-device inside the app sandbox.
class AgentTools {
  static const maxOutput = 12000;

  static final List<Map<String, dynamic>> definitions = [
    _fn('run_shell', 'Run a shell command (Android toybox sh) in the workspace: ls, find, grep, sed, sort, cut, tr, wc, tar, '
        'gzip, base64, md5sum, date, xargs. No curl, no python here: use fetch_url or code_run. Returns exit code, stdout and stderr.', {
      'command': {'type': 'string', 'description': 'The shell command to run.'},
      'timeout_seconds': {'type': 'integer', 'description': 'Max seconds to wait (default 60, max 300).'},
    }, ['command']),
    _fn('read_file', 'Read a UTF-8 text file. Relative paths are resolved from the workspace. Long files: offset reads on; '
        'start_line/end_line give numbered lines.', {
      'path': {'type': 'string'},
      'offset': {'type': 'integer'},
      'start_line': {'type': 'integer'},
      'end_line': {'type': 'integer'},
    }, ['path']),
    _fn('write_file', 'Create or overwrite a text file. Relative paths are resolved from the workspace. '
        'Keep one call under about 150 lines: for a longer file, write the first part here, then add the rest with append_file.', {
      'path': {'type': 'string'},
      'content': {'type': 'string'},
    }, ['path', 'content']),
    _fn('append_file', 'Add text to the end of a file (creates it if missing). Use it to build a long file in parts of about 150 lines.', {
      'path': {'type': 'string'},
      'content': {'type': 'string'},
    }, ['path', 'content']),
    _fn('edit_file', 'Change part of a text file: replaces the exact text `find` with `replace`. '
        '`find` must match the file exactly (spaces and line breaks included) and only once, unless all is true. '
        'Prefer this to rewriting a whole file for a small change.', {
      'path': {'type': 'string'},
      'find': {'type': 'string', 'description': 'The exact text to change. Include a few surrounding lines so it matches only once.'},
      'replace': {'type': 'string', 'description': 'The new text (may be empty to delete).'},
      'all': {'type': 'boolean', 'description': 'Replace every match (default false).'},
    }, ['path', 'find', 'replace']),
    _fn('list_dir', 'List files in a directory (default: the workspace root).', {
      'path': {'type': 'string'},
    }, []),
    _fn('delete_file', 'Safely delete a file or folder by moving it to the SubMac Trash (restorable for 30 days). '
        'Always use this instead of rm.', {
      'path': {'type': 'string'},
    }, ['path']),
    _fn('fetch_url', 'Read a web page, API URL or document link (PDF, Word, Excel...) as plain text ($fetchChars characters at a time; pass offset to read further). '
        'For pages that need JavaScript, a login or clicks, use browser_task instead.', {
      'url': {'type': 'string'},
      'offset': {'type': 'integer', 'description': 'Character to start from, to read the next part (default 0).'},
    }, ['url']),
  ];

  static final Map<String, dynamic> imageTool = _fn(
      'generate_image',
      'Create an image from a text description. Write a rich, specific prompt (subject, style, lighting, composition). '
          'The image is shown to the user automatically and saved to their Library.',
      {
        'prompt': {'type': 'string', 'description': 'Detailed description of the image.'},
        'aspect': {'type': 'string', 'enum': ['1:1', '3:4', '4:3', '9:16', '16:9'], 'description': 'Shape. Default 1:1.'},
      },
      ['prompt']);

  static final Map<String, dynamic> videoTool = _fn(
      'generate_video',
      'Create a short video (about 8 seconds) from a description. Takes 1-5 minutes; tell the user it is on its way. '
          'Describe the scene, motion, camera, style and any sound. The video appears automatically.',
      {
        'prompt': {'type': 'string'},
        'aspect': {'type': 'string', 'enum': ['16:9', '9:16'], 'description': 'Landscape (default) or portrait.'},
      },
      ['prompt']);

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> required) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  static String? _workspace;

  /// Files SubMac itself wrote this session: changing them again needs no "Replace?" question (long builds rewrite
  /// their own files many times). A file the user already had still asks first.
  static final Set<String> _ownFiles = {};

  /// Tools that only change files (used by scope and bot powers).
  static const fileNames = {'run_shell', 'read_file', 'write_file', 'append_file', 'edit_file', 'list_dir', 'delete_file'};

  /// A path the agent put in a ```file card, made openable: relative ("sites/x/index.html") or rooted at the
  /// workspace ("/sites/x/index.html") paths resolve inside the workspace when the file is there.
  /// This phone's workspace folder once it is known (null before the first [workspaceDir] call).
  static String? get knownWorkspace => _workspace;

  /// The local file a card names. `file://` links and %20 are cleaned; a path from another phone or an older
  /// install (`.../workspace/media/x.png`) maps to the same file in this phone's workspace when it is here.
  /// When the file is not on this phone the cleaned path is returned and the card fetches it from the account
  /// (MediaStore).
  static String cardPath(String raw) {
    final p = MediaStore.normalize(raw);
    if (p.isEmpty || MediaStore.isRemote(p)) return p;
    if (p.startsWith('/') && File(p).existsSync()) return p;
    final ws = _workspace;
    if (ws == null) return p;
    final rel = MediaStore.workspaceRel(p);
    if (rel != null) {
      final inWs = '$ws/$rel';
      if (File(inWs).existsSync()) return inWs;
      // Relative paths always mean this workspace, even before the file arrives.
      if (!p.startsWith('/')) return inWs;
    }
    return p;
  }

  static Future<String> workspaceDir() async {
    if (_workspace != null) return _workspace!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/workspace');
    await dir.create(recursive: true);
    _workspace = dir.path;
    return dir.path;
  }

  static Future<String> _resolve(String path) async {
    final ws = await workspaceDir();
    if (path.isEmpty || path == '.') return ws;
    if (path.startsWith('/')) return path;
    return '$ws/$path';
  }

  /// fetch_url returns one page of text at a time, so a long page never floods the chat.
  static const fetchChars = 8000;

  /// One part of [text] from [offset], with a pointer to the next part.
  static String _part(String text, int offset, int size, String what) {
    if (offset < 0) offset = 0;
    if (offset >= text.length) return '(Nothing more: $what has ${text.length} characters.)';
    final end = (offset + size).clamp(0, text.length);
    final head = offset > 0 ? '(characters $offset to $end of ${text.length})\n' : '';
    final more = end < text.length ? '\n…[${text.length - end} more characters: call again with offset $end]' : '';
    return '$head${text.substring(offset, end)}$more';
  }

  /// Readable text from HTML: title, then the body without scripts, styles, menus and tags.
  /// Readable text of a page: the main article with headings, lists and tables ([Readable]); the plain
  /// tag-stripper below stays as the fallback for odd pages.
  static String htmlText(String html) {
    final old = _htmlTextPlain(html);
    try {
      final r = Readable.text(html);
      if (r.length >= 200 || r.length * 2 >= old.length) return r;
    } catch (_) {}
    return old;
  }

  static String _htmlTextPlain(String html) {
    final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?.group(1)?.trim() ?? '';
    var b = html
        .replaceAll(RegExp(r'<(script|style|noscript|svg|head|nav|footer|iframe)[\s\S]*?</\1>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
        .replaceAll(RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    b = b
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
        .replaceAll(RegExp(r'\n\s*\n+'), '\n')
        .trim();
    return t.isEmpty ? b : 'Title: $t\n$b';
  }

  /// True when a page is an empty shell that only fills in with JavaScript.
  static bool needsJs(String html, String text) {
    if (RegExp(r'enable javascript|requires javascript|javascript is (disabled|required)|please turn on javascript', caseSensitive: false)
        .hasMatch(text)) {
      return true;
    }
    return html.length > 5000 && text.length < 400;
  }

  static Future<String> fetchUrl(String url, int offset) async {
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      'Accept-Language': 'en,*;q=0.5',
    }).timeout(const Duration(seconds: 30));
    final ct = resp.headers['content-type'] ?? '';
    // Documents behind a link (PDF, Word, Excel, PowerPoint) are read, not dumped as bytes.
    final b = resp.bodyBytes;
    final path = Uri.tryParse(url)?.path ?? url;
    if (resp.statusCode == 200 && (ct.contains('application/pdf') || (b.length > 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46))) {
      return 'HTTP 200 (PDF)\n${_part(DocTools.pdfText(b, maxChars: 200000), offset, fetchChars, 'this PDF')}';
    }
    if (resp.statusCode == 200 && (ct.contains('officedocument') || ct.contains('opendocument') || ct.contains('epub') ||
        RegExp(r'\.(docx|xlsx|pptx|odt|ods|odp|epub)$', caseSensitive: false).hasMatch(path))) {
      final name = RegExp(r'\.(docx|xlsx|pptx|odt|ods|odp|epub)$', caseSensitive: false).hasMatch(path)
          ? path
          : 'file.${ct.contains('spreadsheet') ? 'xlsx' : ct.contains('presentation') ? 'pptx' : ct.contains('epub') ? 'epub' : 'docx'}';
      try {
        final t = DocText.extract(name, b);
        if (t != null) return 'HTTP 200 (document)\n${_part(t, offset, fetchChars, 'this document')}';
      } on FormatException catch (e) {
        return 'HTTP 200\n${e.message}';
      }
    }
    final body = utf8.decode(b, allowMalformed: true);
    final isHtml = ct.contains('html') || body.trimLeft().toLowerCase().startsWith('<!doctype html') || body.trimLeft().startsWith('<html');
    final text = isHtml ? htmlText(body) : body;
    final blocked = resp.statusCode == 401 ||
        resp.statusCode == 403 ||
        resp.statusCode == 429 ||
        RegExp(r'just a moment|checking your browser|cf-chl|captcha|access denied|are you a robot', caseSensitive: false)
            .hasMatch(text.length > 3000 ? text.substring(0, 3000) : text);
    final hint = blocked
        ? '\n\n(This site blocks simple page reads or needs a sign-in. Use browser_task to open it in your browser.)'
        : (isHtml && needsJs(body, text)
            ? '\n\n(This page builds itself with JavaScript, so there is little text here. Use browser_task to open it in your browser.)'
            : '');
    return 'HTTP ${resp.statusCode}\n${_part(text, offset, fetchChars, 'this page')}$hint';
  }

  /// Lines [from]..[to] (1-based, inclusive) of [text], numbered, at most 400 lines and [maxOutput] characters, with
  /// a footer saying where to read on (core loop v3: read and edit big files by line, like Claude Code's Read).
  static String numberedLines(String text, int from, int? to) {
    final lines = text.split('\n');
    final total = lines.length;
    final a = from < 1 ? 1 : from;
    if (a > total) return 'The file has only $total lines.';
    var b = to == null || to < a ? a + 399 : to;
    if (b - a > 399) b = a + 399;
    if (b > total) b = total;
    final sb = StringBuffer();
    var last = a - 1;
    for (var i = a; i <= b; i++) {
      final row = '${i.toString().padLeft(5)}  ${lines[i - 1]}\n';
      if (sb.length + row.length > maxOutput) break;
      sb.write(row);
      last = i;
    }
    if (last < total) sb.write('…[lines ${last + 1}-$total not shown: read on with start_line ${last + 1}; $total lines in all]');
    return sb.toString();
  }

  static String _truncate(String s) =>
      s.length > maxOutput ? '${s.substring(0, maxOutput)}\n…[truncated ${s.length - maxOutput} chars]' : s;

  static Future<String> execute(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'run_shell':
          final t = (args['timeout_seconds'] as num?)?.toInt() ?? 60;
          return await _shell((args['command'] ?? '').toString(), t.clamp(1, 300));
        case 'read_file':
          final f = File(await _resolve((args['path'] ?? '').toString()));
          if (!await f.exists()) return 'Error: file not found: ${f.path}';
          final from = (args['start_line'] as num?)?.toInt();
          if (from != null) return numberedLines(await f.readAsString(), from, (args['end_line'] as num?)?.toInt());
          return _part(await f.readAsString(), (args['offset'] as num?)?.toInt() ?? 0, maxOutput, 'this file');
        case 'write_file':
          final f = File(await _resolve((args['path'] ?? '').toString()));
          await f.parent.create(recursive: true);
          final content = (args['content'] ?? '').toString();
          await f.writeAsString(content);
          _ownFiles.add(f.path);
          final pageHint = RegExp(r'\.html?$', caseSensitive: false).hasMatch(f.path)
              ? '\nWhen the page is complete, end your reply with a ```file block holding ${f.path} (it has Open and Publish).'
              : '';
          return 'Wrote ${content.length} chars (${'\n'.allMatches(content).length + 1} lines) to ${f.path}$pageHint';
        case 'append_file':
          final f = File(await _resolve((args['path'] ?? '').toString()));
          final existed = await f.exists();
          await f.parent.create(recursive: true);
          final content = (args['content'] ?? '').toString();
          await f.writeAsString(content, mode: FileMode.append);
          if (!existed) _ownFiles.add(f.path);
          final total = await f.length();
          return 'Added ${content.length} chars to ${f.path} (now $total bytes)';
        case 'edit_file':
          final f = File(await _resolve((args['path'] ?? '').toString()));
          if (!await f.exists()) return 'Error: file not found: ${f.path}';
          final find = (args['find'] ?? '').toString();
          final repl = (args['replace'] ?? '').toString();
          if (find.isEmpty) return 'Error: find is empty. Give the exact text to change.';
          final text = await f.readAsString();
          final n = find.allMatches(text).length;
          if (n == 0) return 'Error: that text is not in ${f.path}. read_file it and copy the exact lines (spaces included).';
          final all = args['all'] == true;
          if (n > 1 && !all) return 'Error: that text appears $n times in ${f.path}. Add surrounding lines so it matches once, or set all to true.';
          await f.writeAsString(all ? text.replaceAll(find, repl) : text.replaceFirst(find, repl));
          return 'Changed ${all ? n : 1} place${(all ? n : 1) == 1 ? '' : 's'} in ${f.path}';
        case 'list_dir':
          final d = Directory(await _resolve((args['path'] ?? '').toString()));
          if (!await d.exists()) return 'Error: directory not found: ${d.path}';
          final entries = await d.list().toList();
          if (entries.isEmpty) return '(empty) ${d.path}';
          final lines = <String>[];
          for (final e in entries) {
            final n = e.path.split('/').last;
            if (e is Directory) {
              lines.add('$n/');
            } else if (e is File) {
              lines.add('$n  (${await e.length()} bytes)');
            } else {
              lines.add(n);
            }
          }
          lines.sort();
          return '${d.path}\n${lines.join('\n')}';
        case 'delete_file':
          return await _trash((args['path'] ?? '').toString());
        case 'fetch_url':
          return await fetchUrl((args['url'] ?? '').toString(), (args['offset'] as num?)?.toInt() ?? 0);
        default:
          return 'Error: unknown tool "$name"';
      }
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<String> trashDir() async {
    final ws = await workspaceDir();
    final d = Directory('$ws/.trash');
    await d.create(recursive: true);
    return d.path;
  }

  static Future<String> _trash(String path) async {
    if (path.trim().isEmpty) return 'Error: no path given';
    final full = await _resolve(path);
    final type = await FileSystemEntity.type(full);
    if (type == FileSystemEntityType.notFound) return 'Error: not found: $full';
    final name = full.split('/').where((e) => e.isNotEmpty).last;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = '${await trashDir()}/${stamp}__$name';
    final ent = type == FileSystemEntityType.directory ? Directory(full) : File(full);
    try {
      await ent.rename(dest);
    } catch (_) {
      // Different volume (e.g. shared storage -> app storage): copy then delete.
      if (ent is File) {
        await ent.copy(dest);
        await ent.delete();
      } else {
        final r = await Process.run('/system/bin/sh', ['-c', 'cp -r "$full" "$dest" && rm -rf "$full"']);
        if (r.exitCode != 0) return 'Error: could not move to trash: ${r.stderr}';
      }
    }
    await File('$dest.origin').writeAsString(full);
    return 'Moved "$name" to SubMac Trash (restorable). Original location: $full';
  }

  static final _riskyShell = RegExp(
      r'(^|[;&|\s(])(rm|rmdir|mv|dd|truncate|shred|chmod|chown|mkfs|kill|killall|pkill|reboot|pm|am|settings|setprop|svc|wipe)\b'
      r'|>>?\s*(?!/dev/null|&)\S'
      r'|curl[^\n]*-X\s*(POST|PUT|DELETE|PATCH)'
      r'|sed\s+-i');

  /// Returns a plain-language confirmation request if this action is risky, else null.
  static Future<ActionRequest?> riskFor(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'app_settings':
        return settingsRisk(args);
      case 'run_shell':
        final cmd = (args['command'] ?? '').toString();
        if (!_riskyShell.hasMatch(cmd)) return null;
        return ActionRequest(
          title: describeCommand(cmd, done: false),
          body: 'This may change or remove things on your phone.',
          detail: cmd,
          confirmLabel: 'Allow',
        );
      case 'delete_file':
        final path = (args['path'] ?? '').toString();
        return ActionRequest(
          title: 'Delete ${_short(path)}?',
          body: 'It goes to the SubMac Trash, so you can restore it later.',
          detail: await _resolve(path),
          confirmLabel: 'Delete',
          destructive: true,
        );
      case 'write_file':
        final full = await _resolve((args['path'] ?? '').toString());
        if (!await File(full).exists() || _ownFiles.contains(full)) return null;
        return ActionRequest(
          title: 'Replace ${_short(full)}?',
          body: 'This file already exists and will be overwritten.',
          detail: full,
          confirmLabel: 'Replace',
        );
      case 'edit_file':
        final full = await _resolve((args['path'] ?? '').toString());
        if (!await File(full).exists() || _ownFiles.contains(full)) return null;
        return ActionRequest(
          title: 'Change ${_short(full)}?',
          body: 'SubMac will edit part of this file.',
          detail: full,
          confirmLabel: 'Change',
        );
    }
    return null;
  }

  /// Settings that change how SubMac works for the user: how much it asks, the standing instructions in every prompt,
  /// whether it may act at all, memory, and the always-listening microphone. Changing one always asks.
  static const riskySettings = {
    'approval_mode', 'actions_enabled', 'about_you', 'how_to_respond', 'memory', 'wake_word', 'wake_screen_off', 'wake_sensitivity',
  };

  /// The approval for an app_settings call, or null for a read or a harmless setting (theme, voice…).
  static ActionRequest? settingsRisk(Map<String, dynamic> args) {
    // Every action other than list / get / open_permission changes the setting (see SystemTools._settings).
    final act = '${args['action'] ?? 'list'}';
    final key = '${args['key'] ?? ''}'.trim();
    if (const {'list', 'get', 'open_permission'}.contains(act) || !riskySettings.contains(key)) return null;
    final v = '${args['value'] ?? ''}';
    final shown = v.length > 200 ? '${v.substring(0, 200)}…' : v;
    return ActionRequest(
      title: 'Change the setting "$key"?',
      body: key == 'approval_mode'
          ? 'This changes how often SubMac asks you before acting.'
          : (key == 'about_you' || key == 'how_to_respond')
              ? 'This becomes a standing instruction SubMac follows in every chat.'
              : 'This changes how SubMac works for you.',
      detail: '$key = $shown',
      confirmLabel: 'Change',
      destructive: key == 'approval_mode' || key == 'actions_enabled',
    );
  }

  static String _clip(String s) => s.length > 40 ? '${s.substring(0, 40)}…' : s;

  static String _short(String path) {
    final parts = path.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? 'this' : '"${parts.last}"';
  }

  /// Plain-language label for a tool call, e.g. "Organizing files".
  static String describe(String name, Map<String, dynamic> args, {required bool done}) {
    switch (name) {
      case 'run_shell':
        return describeCommand((args['command'] ?? '').toString(), done: done);
      case 'read_file':
        return '${done ? 'Read' : 'Reading'} ${_short((args['path'] ?? '').toString())}';
      case 'write_file':
      case 'append_file':
        return '${done ? 'Saved' : 'Saving'} ${_short((args['path'] ?? '').toString())}';
      case 'edit_file':
        return '${done ? 'Edited' : 'Editing'} ${_short((args['path'] ?? '').toString())}';
      case 'list_dir':
        return done ? 'Looked through a folder' : 'Looking through a folder';
      case 'delete_file':
        return '${done ? 'Moved' : 'Moving'} ${_short((args['path'] ?? '').toString())} to Trash';
      case 'generate_image':
        return done ? 'Created an image' : 'Creating an image';
      case 'ai_call':
        final m = _clip((args['model'] ?? '').toString());
        final w = switch ((args['task'] ?? '').toString()) {
          'image' || 'image_edit' => done ? 'Made the picture' : 'Making the picture',
          'speech' => done ? 'Made the voice' : 'Making the voice',
          'transcribe' => done ? 'Wrote out the recording' : 'Writing out the recording',
          'video' => done ? 'Made the video' : 'Making the video',
          'music' => done ? 'Made the music' : 'Making the music',
          _ => done ? 'Asked your model' : 'Asking your model',
        };
        return m.isEmpty ? w : '$w with $m';
      case 'ai_providers':
        return done ? 'Checked your AI connections' : 'Checking your AI connections';
      case 'code_media':
        final k = (args['kind'] ?? '').toString();
        return k == 'audio' ? (done ? 'Composed a sound' : 'Composing a sound') : (k == 'video' ? (done ? 'Made an animation' : 'Animating') : (done ? 'Drew a picture' : 'Drawing'));
      case 'fetch_url':
        final host = Uri.tryParse((args['url'] ?? '').toString())?.host ?? 'the web';
        return '${done ? 'Read' : 'Reading'} ${host.isEmpty ? 'a web page' : host}';
      case 'web_search':
        return '${done ? 'Searched' : 'Searching'} the web for "${_clip((args['query'] ?? '').toString())}"';
      case 'get_weather':
        return '${done ? 'Checked' : 'Checking'} the weather in ${_clip((args['place'] ?? '').toString())}';
      case 'wikipedia':
        return '${done ? 'Looked up' : 'Looking up'} "${_clip((args['query'] ?? '').toString())}" on Wikipedia';
      case 'currency_convert':
        return done ? 'Converted currency' : 'Converting currency';
      case 'find_place':
        return '${done ? 'Found' : 'Finding'} places on the map';
      case 'read_rss':
        return done ? 'Read a news feed' : 'Reading a news feed';
      case 'youtube_transcript':
        return done ? 'Read the video transcript' : 'Reading the video transcript';
      case 'remember':
        return done ? 'Saved to memory' : 'Saving to memory';
      case 'forget':
        return done ? 'Removed from memory' : 'Removing from memory';
      case 'list_memories':
        return done ? 'Checked memory' : 'Checking memory';
      case 'set_alarm':
        return done ? 'Opened an alarm' : 'Setting an alarm';
      case 'set_timer':
        return done ? 'Opened a timer' : 'Setting a timer';
      case 'add_calendar_event':
        return done ? 'Opened a calendar event' : 'Adding to your calendar';
      case 'call_number':
        return done ? 'Opened the dialer' : 'Opening the dialer';
      case 'send_sms':
        return done ? 'Drafted a text message' : 'Drafting a text message';
      case 'open_link':
        return done ? 'Opened a link' : 'Opening a link';
      case 'open_app':
        return '${done ? 'Opened' : 'Opening'} ${_clip((args['name'] ?? 'an app').toString())}';
      case 'share_text':
        return done ? 'Opened sharing' : 'Opening sharing';
      case 'phone_screen':
      case 'phone_wait':
        return done ? 'Read the screen' : 'Reading the screen';
      case 'phone_tap':
      case 'phone_long_press':
        return done ? 'Tapped' : 'Tapping';
      case 'phone_type':
        return done ? 'Typed it' : 'Typing';
      case 'phone_scroll':
      case 'phone_gesture':
        return done ? 'Scrolled' : 'Scrolling';
      case 'phone_nav':
        return done ? 'Went back' : 'Navigating';
      case 'whatsapp':
        final act = (args['action'] ?? '').toString();
        final to = _clip((args['to'] ?? '').toString());
        return switch (act) {
          'send' || 'reply' || 'send_bulk' => done ? 'Sent on WhatsApp' : 'Sending on WhatsApp${to.isEmpty ? '' : ' to $to'}',
          'send_file' => done ? 'Sent the file on WhatsApp' : 'Sending the file on WhatsApp',
          'call' => done ? 'Started the WhatsApp call' : 'Calling on WhatsApp',
          'read' => done ? 'Read the WhatsApp chat' : 'Reading WhatsApp',
          _ => done ? 'Checked WhatsApp' : 'Checking WhatsApp',
        };
      case 'read_text_in_image':
        return done ? 'Read the text in a picture' : 'Reading the text in a picture';
      case 'read_pdf':
        return done ? 'Read a PDF' : 'Reading a PDF';
      case 'github_api':
        return done ? 'Worked with GitHub' : 'Working with GitHub';
      case 'notion_api':
        return done ? 'Worked with Notion' : 'Working with Notion';
    }
    if (name.startsWith('mcp_')) {
      final i = name.indexOf('__');
      final tool = i > 0 ? name.substring(i + 2) : name;
      final pretty = tool.replaceAll(RegExp(r'[_-]+'), ' ').toLowerCase();
      return '${done ? 'Used' : 'Using'} ${_clip(pretty)}';
    }
    return done ? 'Done' : 'Working';
  }

  static String describeCommand(String cmd, {required bool done}) {
    final first = cmd.trim().split(RegExp(r'[\s;|&]+')).firstWhere((e) => e.isNotEmpty, orElse: () => '');
    String a, b;
    switch (first) {
      case 'ls':
      case 'find':
      case 'du':
      case 'df':
      case 'stat':
        a = 'Checking files';
        b = 'Checked files';
        break;
      case 'cat':
      case 'head':
      case 'tail':
      case 'grep':
      case 'wc':
        a = 'Reading';
        b = 'Read files';
        break;
      case 'mv':
      case 'cp':
      case 'mkdir':
        a = 'Organizing files';
        b = 'Organized files';
        break;
      case 'rm':
      case 'rmdir':
        a = 'Removing files';
        b = 'Removed files';
        break;
      case 'tar':
      case 'gzip':
      case 'zip':
      case 'unzip':
        a = 'Packing files';
        b = 'Packed files';
        break;
      case 'curl':
      case 'wget':
        a = 'Talking to the web';
        b = 'Fetched from the web';
        break;
      case 'getprop':
      case 'uname':
      case 'cmd':
      case 'dumpsys':
        a = 'Checking your phone';
        b = 'Checked your phone';
        break;
      default:
        a = 'Working on it';
        b = 'Ran a step';
    }
    return done ? b : a;
  }

  static Future<String> _shell(String cmd, int timeoutSec) async {
    if (cmd.trim().isEmpty) return 'Error: empty command';
    final wd = await workspaceDir();
    final shell = File('/system/bin/sh').existsSync() ? '/system/bin/sh' : '/bin/sh';
    final p = await Process.start(shell, ['-c', cmd], workingDirectory: wd, environment: {'HOME': wd});
    final out = StringBuffer();
    final err = StringBuffer();
    final f1 = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write);
    final f2 = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(err.write);
    int code;
    try {
      code = await p.exitCode.timeout(Duration(seconds: timeoutSec));
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
      code = -1;
      err.write('\n[timed out after ${timeoutSec}s]');
    }
    try {
      await Future.wait([f1, f2]).timeout(const Duration(seconds: 2));
    } catch (_) {}
    final sb = StringBuffer('exit_code: $code\n');
    if (out.isNotEmpty) sb.write('stdout:\n${_truncate(out.toString())}\n');
    if (err.isNotEmpty) sb.write('stderr:\n${_truncate(err.toString())}\n');
    return sb.toString();
  }
}

/// Text the user may change on an approval card before saying yes (the card writes the new text into [value]).
class TextBox {
  TextBox(this.value);
  String value;
  bool edited = false;
}

class ActionRequest {
  final String title;
  final String body;
  final String detail;
  final String confirmLabel;
  final bool destructive;
  /// When set, the card offers Edit: the user can change this text (a message about to be sent) before approving.
  final TextBox? edit;
  /// Set by the card when the owner tapped Edit on an ask with no text to change: "change it first".
  bool wantsChange = false;
  /// Set by the card when the owner tapped "Allow always": approve this and turn on Full access.
  bool allowAlways = false;
  /// What kind of action this is (BotTrust.kindOf with the tool name: money | send | delete | change), set by the
  /// router before it asks, so the card hides "Allow always" on every payment ('' = work it out from the words).
  String kind = '';
  /// The chat this ask comes from when it isn't the one on screen (its title), so a card from a background task or a
  /// browser task in another chat says where it is from ('' = this chat).
  String where = '';
  /// The chat the ask belongs to (set by the router when it asks): the thin inline card lives under that chat's
  /// newest message.
  String? convId;
  /// Nobody answered in time (CB-42): the task moved on, and a sheet still waiting its turn is never shown.
  bool timedOut = false;
  ActionRequest({
    required this.title,
    required this.body,
    required this.detail,
    this.confirmLabel = 'Approve',
    this.destructive = false,
    this.edit,
  });

  /// The same ask with an editable text.
  ActionRequest withEdit(String text) =>
      ActionRequest(title: title, body: body, detail: detail, confirmLabel: confirmLabel, destructive: destructive, edit: TextBox(text));
}

/// The one live approval ask (owner, 2026-10-31): a thin card under the newest message of its own chat —
/// never a modal sheet over half the screen. [answer] resolves the waiting task (true = approved).
class ConfirmAsk {
  ConfirmAsk({required this.convId, required this.req, required this.answer});
  final String? convId;
  final ActionRequest req;
  final void Function(bool ok) answer;
}
