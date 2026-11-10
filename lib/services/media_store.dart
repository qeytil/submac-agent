import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import 'tools.dart';

/// Where the pictures and files in a chat live, so they open on any phone.
///
/// Bug (v1.13.87, owner 2026-10-24 "images and files say not on this device"): cards kept only the absolute path the
/// file had on the phone that made it (`/data/user/0/<app>/app_flutter/workspace/media/x.png`). Chats are backed up
/// and come back on a new phone, after a reinstall, or in the dev build (another app id), but the files never left the
/// first phone, so every card there said "Not found on this phone" and pictures showed nothing. Relative paths were also
/// missed on a fresh start because the workspace folder was not known yet.
///
/// Now:
///  * every file a card shows is uploaded once to the user's private `attachments` bucket under
///    `<user id>/workspace/<path inside the workspace>` (the bucket's own RLS: first folder = the user id);
///  * a card whose file is missing here finds it by the same key, downloads it back to the same place in this
///    phone's workspace (so the agent can use it again) and shows it;
///  * only when the file is in neither place does the card say it is not available.
class MediaStore {
  MediaStore._();
  static final MediaStore I = MediaStore._();

  static const bucket = 'attachments';

  /// Files bigger than this stay on the phone only (storage limit and data use).
  static const maxUpload = 25 * 1024 * 1024;

  // ---- seams (tests swap these) ----
  Future<String> Function() workspace = AgentTools.workspaceDir;
  String? Function() userId = _signedInUser;
  Future<Uint8List> Function(String key) download = _download;
  Future<void> Function(String key, File file, String mime) upload = _upload;
  Future<String> Function() cacheDir = _cacheDir;

  static String? _signedInUser() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _download(String key) => Supabase.instance.client.storage.from(bucket).download(key);

  static Future<void> _upload(String key, File f, String mime) async {
    await Supabase.instance.client.storage.from(bucket).upload(
          key,
          f,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
  }

  static Future<String> _cacheDir() async {
    final ws = await AgentTools.workspaceDir();
    return '$ws/.cloud';
  }

  // ---- paths ----

  static bool isRemote(String s) => s.startsWith('http://') || s.startsWith('https://');

  /// A path as the model or an older app wrote it: `file://` links, %20, quotes and backticks are cleaned.
  static String normalize(String raw) {
    var p = raw.trim();
    while (p.length > 1 && '"\'`<'.contains(p[0]) && '"\'`>'.contains(p[p.length - 1])) {
      p = p.substring(1, p.length - 1).trim();
    }
    if (isRemote(p)) return p;
    if (p.toLowerCase().startsWith('file://')) {
      p = p.substring(7);
      // file://localhost/path and file:///path
      if (p.startsWith('localhost/')) p = p.substring(9);
    }
    if (p.contains('%')) {
      try {
        p = Uri.decodeFull(p);
      } catch (_) {}
    }
    return p;
  }

  /// The part of [path] inside Telesia's workspace (`media/x.png`), the same on every phone; null when the file
  /// lives elsewhere on the phone. A relative path is already inside the workspace.
  static String? workspaceRel(String path) {
    final p = normalize(path);
    if (p.isEmpty || isRemote(p)) return null;
    if (!p.startsWith('/')) {
      final rel = p.replaceFirst(RegExp(r'^(\./)+'), '').replaceFirst(RegExp(r'^workspace/'), '');
      return rel.isEmpty || rel.split('/').contains('..') ? null : rel;
    }
    final m = RegExp(r'/workspace/(.+)$').firstMatch(p);
    if (m == null) return null;
    final rel = m.group(1)!;
    return rel.split('/').contains('..') ? null : rel;
  }

  /// Where a file outside the workspace is kept in the account: one folder per original path.
  static String outsideRel(String path) {
    final p = normalize(path);
    final h = sha1.convert(utf8.encode(p)).toString().substring(0, 12);
    return 'phone/$h/${p.split('/').last}';
  }

  static String _safe(String segment) => segment.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// The storage key for [path] of user [uid] (`<uid>/workspace/media/x.png`).
  static String keyFor(String uid, String path) {
    final rel = workspaceRel(path) ?? outsideRel(path);
    return '$uid/workspace/${rel.split('/').where((s) => s.isNotEmpty).map(_safe).join('/')}';
  }

  static String mimeOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const m = {
      'mp4': 'video/mp4', 'webm': 'video/webm', 'mov': 'video/quicktime', 'm4v': 'video/mp4', '3gp': 'video/3gpp',
      'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'ogg': 'audio/ogg',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'zip': 'application/zip', 'html': 'text/html', 'htm': 'text/html', 'svg': 'image/svg+xml', 'bmp': 'image/bmp',
    };
    return m[ext] ?? Attachment.mimeFor(name);
  }

  /// Files a reply or a tool result shows: ```file / ```video blocks, `/paths` in ```photos/images blocks, and
  /// IMAGE_SAVED / AUDIO_SAVED / VIDEO_SAVED / FILE_SAVED lines.
  static List<String> pathsIn(String text) {
    final out = <String>{};
    for (final m in RegExp(r'```(file|video|photos|images|page)[^\n]*\n([\s\S]*?)```').allMatches(text)) {
      final lang = m.group(1)!;
      final body = m.group(2)!;
      if (lang == 'file' || lang == 'video' || lang == 'page') {
        final first = body.trim().split('\n').first.trim();
        if (first.isNotEmpty && !first.startsWith('<') && !isRemote(first)) out.add(normalize(first));
      } else {
        for (final l in body.split('\n')) {
          final t = l.trim();
          if (t.startsWith('/') || t.toLowerCase().startsWith('file://')) out.add(normalize(t));
        }
        for (final j in RegExp(r'"(?:url|path|src)"\s*:\s*"((?:/|file://)[^"]+)"').allMatches(body)) {
          out.add(normalize(j.group(1)!));
        }
      }
    }
    for (final m in RegExp(r'(?:IMAGE|AUDIO|VIDEO|FILE)_SAVED (\S+)').allMatches(text)) {
      out.add(normalize(m.group(1)!));
    }
    return out.where((p) => p.isNotEmpty).toList();
  }

  // ---- finding a file ----

  /// The file on this phone right now, without waiting (the path itself or the same file in this workspace).
  File? localNow(String raw) {
    final p = normalize(raw);
    if (p.isEmpty || isRemote(p)) return null;
    if (p.startsWith('/')) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    final ws = AgentTools.knownWorkspace;
    final rel = workspaceRel(p);
    if (ws != null && rel != null) {
      final f = File('$ws/$rel');
      if (f.existsSync()) return f;
    }
    return null;
  }

  final Map<String, Future<File?>> _inflight = {};

  /// Keys looked up this session and not found anywhere (so a list of cards does not ask the server on every
  /// rebuild). [resolve] with `retry: true` asks again.
  final Set<String> _gone = {};

  /// The file behind [raw]: on this phone, the same file in this phone's workspace, or a copy downloaded from the
  /// account into this workspace. Null only when it is in neither place (or the user is signed out).
  Future<File?> resolve(String raw, {bool retry = false}) async {
    final p = normalize(raw);
    if (p.isEmpty || isRemote(p)) return null;
    if (p.startsWith('/')) {
      final f = File(p);
      if (await f.exists()) return f;
    }
    final ws = await workspace();
    final rel = workspaceRel(p);
    if (rel != null) {
      final f = File('$ws/$rel');
      if (await f.exists()) return f;
    }
    final target = rel != null ? File('$ws/$rel') : File('${await cacheDir()}/${outsideRel(p)}');
    if (await target.exists()) return target;
    final uid = userId();
    if (uid == null) return null;
    final key = keyFor(uid, p);
    if (retry) _gone.remove(key);
    if (_gone.contains(key)) return null;
    return _inflight[key] ??= () async {
      try {
        final bytes = await download(key).timeout(const Duration(seconds: 60));
        if (bytes.isEmpty) throw const FileSystemException('empty');
        await target.parent.create(recursive: true);
        final part = File('${target.path}.part');
        await part.writeAsBytes(bytes, flush: true);
        await part.rename(target.path);
        return target;
      } catch (_) {
        _gone.add(key);
        return null;
      } finally {
        _inflight.remove(key);
      }
    }();
  }

  // ---- keeping a copy in the account ----

  static const _prefsKey = 'media_uploaded_v1';
  Map<String, String>? _stamps;
  final Map<String, Future<String?>> _uploading = {};

  Future<Map<String, String>> _loadStamps() async {
    if (_stamps != null) return _stamps!;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefsKey);
      _stamps = raw == null ? {} : Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      _stamps = {};
    }
    return _stamps!;
  }

  Future<void> _saveStamps() async {
    final s = _stamps;
    if (s == null) return;
    while (s.length > 800) {
      s.remove(s.keys.first);
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefsKey, jsonEncode(s));
    } catch (_) {}
  }

  /// Uploads [raw] to the account once (again only when the file changed). Returns its key, or null when there is
  /// nothing to send (no file here, too big, signed out) or the upload failed (tried again next time it shows).
  Future<String?> keep(String raw) async {
    final p = normalize(raw);
    final f = localNow(p);
    final uid = userId();
    if (f == null || uid == null) return null;
    final key = keyFor(uid, f.path);
    return _uploading[key] ??= () async {
      try {
        final st = await f.stat();
        if (st.size <= 0 || st.size > maxUpload) return null;
        final stamp = '${st.size}:${st.modified.millisecondsSinceEpoch}';
        final stamps = await _loadStamps();
        if (stamps[key] == stamp) return key;
        await upload(key, f, mimeOf(f.path)).timeout(const Duration(seconds: 120));
        stamps.remove(key);
        stamps[key] = stamp;
        _gone.remove(key);
        await _saveStamps();
        return key;
      } catch (_) {
        return null;
      } finally {
        _uploading.remove(key);
      }
    }();
  }

  /// Keeps every file [text] shows (a finished reply, a tool result). Never throws.
  Future<void> keepAllIn(String text) async {
    final paths = pathsIn(text);
    if (paths.isEmpty || userId() == null) return;
    await Future.wait([for (final p in paths) keep(p).catchError((_) => null)]);
  }

  // ---- files the user attached ----

  /// A file on this phone for an attachment, to preview, save or share: its workspace copy, its bytes written to a
  /// cache file, or a download of its storage copy. Null when it is gone everywhere.
  Future<File?> attachmentFile(Attachment a, {Future<Uint8List> Function(String path)? fetch}) async {
    final lp = a.localPath;
    if (lp != null && lp.isNotEmpty) {
      final f = File(lp);
      if (await f.exists()) return f;
    }
    var bytes = a.bytes;
    if (bytes == null && a.path != null) {
      try {
        bytes = await (fetch ?? _attachmentDownload)(a.path!).timeout(const Duration(seconds: 60));
        if (bytes.isNotEmpty) a.bytes = bytes;
      } catch (_) {
        bytes = null;
      }
    }
    if (bytes == null || bytes.isEmpty) return null;
    final name = a.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final tag = sha1.convert(utf8.encode(a.path ?? '${a.name}:${bytes.length}')).toString().substring(0, 10);
    final f = File('${await cacheDir()}/attached/$tag/$name');
    if (!await f.exists() || await f.length() != bytes.length) {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    }
    return f;
  }

  static Future<Uint8List> _attachmentDownload(String path) => Supabase.instance.client.storage.from(bucket).download(path);

  /// For tests.
  void resetForTest() {
    _inflight.clear();
    _gone.clear();
    _uploading.clear();
    _stamps = {};
  }
}
