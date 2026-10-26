import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models.dart';

/// One chat as it lives on the phone: every row in full (raw tool results too),
/// plus what still has to reach the backup.
class LocalChat {
  final String id;

  /// Message rows in chat order. Each is the message's JSON plus 'created_at' (UTC ISO).
  List<Map<String, dynamic>> rows;

  /// Rows changed on this phone that the backup has not seen yet.
  Set<String> dirty;

  /// Rows removed on this phone that the backup still holds.
  Set<String> deletes;

  /// True when this phone holds the whole chat (not just rows written here before it was ever opened).
  bool complete;

  LocalChat(this.id, {List<Map<String, dynamic>>? rows, Set<String>? dirty, Set<String>? deletes, this.complete = true})
      : rows = rows ?? [],
        dirty = dirty ?? {},
        deletes = deletes ?? {};

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        'complete': complete,
        'dirty': dirty.toList(),
        'deletes': deletes.toList(),
        'rows': rows,
      };

  factory LocalChat.fromJson(Map<String, dynamic> j) => LocalChat(
        (j['id'] ?? '') as String,
        rows: [for (final r in (j['rows'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)],
        dirty: {for (final x in (j['dirty'] as List? ?? const [])) '$x'},
        deletes: {for (final x in (j['deletes'] as List? ?? const [])) '$x'},
        complete: (j['complete'] ?? true) as bool,
      );

  String get lastCreatedAt => rows.isEmpty ? '' : (rows.last['created_at'] ?? '') as String;
}

/// Phone-first chat storage. The phone is the source of truth; the account backup
/// (see Repo) only mirrors it. Files live in the app's own folder, one per chat,
/// under a folder per signed-in account so two accounts never mix.
class ChatStore {
  Directory? _dir;
  String _uid = '';
  Future<void>? _opening;

  /// Chat list: id -> conversation fields (same keys as the server row) plus local flags:
  ///   _remote  the account backup has this chat row
  ///   _dirty   the chat's title/pin/archive/time changed here and the backup has not seen it
  ///   _stale   another phone added to this chat since this phone last pulled it
  final Map<String, Map<String, dynamic>> index = {};

  /// Chats deleted here that the backup still has: id -> archive path ('' when none).
  final Map<String, String> deletedChats = {};
  bool deleteAllPending = false;

  /// Removed rows whose chat was not loaded at the time (sent to the backup as deletes).
  final Set<String> orphanDeletes = {};

  final Map<String, LocalChat> _chats = {};
  final Set<String> _unsaved = {};
  bool _indexUnsaved = false;
  Timer? _saveTimer;
  DateTime _lastStamp = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  String get uid => _uid;

  Future<void> open(String uid) async {
    if (_dir != null && uid == _uid) return;
    if (_opening != null) {
      await _opening;
      if (_dir != null && uid == _uid) return;
    }
    final f = _open(uid);
    _opening = f;
    try {
      await f;
    } finally {
      _opening = null;
    }
  }

  Future<void> _open(String uid) async {
    await flush();
    _chats.clear();
    index.clear();
    deletedChats.clear();
    deleteAllPending = false;
    orphanDeletes.clear();
    final base = await getApplicationDocumentsDirectory();
    final safe = uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final d = Directory('${base.path}/chats/${safe.isEmpty ? 'local' : safe}');
    await d.create(recursive: true);
    _dir = d;
    _uid = uid;
    // The chat list, or its last good copy when the list is missing or broken (CB-14).
    for (final f in [File('${d.path}/index.json'), File('${d.path}/index.json.bak')]) {
      try {
        if (!await f.exists()) continue;
        final j = jsonDecode(await f.readAsString()) as Map;
        for (final e in (j['chats'] as List? ?? const [])) {
          final m = Map<String, dynamic>.from(e as Map);
          if (m['id'] is String) index[m['id'] as String] = m;
        }
        final del = j['deleted'];
        if (del is Map) {
          del.forEach((k, v) => deletedChats['$k'] = '${v ?? ''}');
        }
        deleteAllPending = (j['delete_all'] ?? false) as bool;
        for (final x in (j['orphan_deletes'] as List? ?? const [])) {
          orphanDeletes.add('$x');
        }
        break;
      } catch (_) {
        // A broken list: try the last good copy; with neither, it is rebuilt from the backup on the next refresh.
        index.clear();
        deletedChats.clear();
        deleteAllPending = false;
        orphanDeletes.clear();
      }
    }
  }

  File _chatFile(String id) => File('${_dir!.path}/${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json');

  /// A UTC timestamp that is always later than the last one handed out, so rows keep their order.
  String stamp() {
    var t = DateTime.now().toUtc();
    if (!t.isAfter(_lastStamp)) t = _lastStamp.add(const Duration(microseconds: 1000));
    _lastStamp = t;
    return iso(t);
  }

  /// Fixed-width UTC time ("2026-10-17T09:05:01.000123Z") so text order is time order.
  static String iso(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final frac = (u.millisecond * 1000 + u.microsecond).toString().padLeft(6, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${frac}Z';
  }

  /// Any time text from the backup, in the same fixed form ('' stays '').
  static String norm(Object? s) {
    final t = DateTime.tryParse('${s ?? ''}');
    return t == null ? '' : iso(t);
  }

  /// Chats read into memory this session.
  Iterable<LocalChat> get loaded => _chats.values;

  bool hasLocal(String id) => index[id]?['_local'] == true;

  Future<LocalChat?> chat(String id) async {
    final c = _chats[id];
    if (c != null) return c;
    if (_dir == null) return null;
    // CB-14: the main file first; when it is missing or broken (a write cut off by a kill), the last good copy.
    final f = _chatFile(id);
    for (final file in [f, File('${f.path}.bak')]) {
      try {
        if (!await file.exists()) continue;
        final lc = LocalChat.fromJson(Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map));
        _chats[id] = lc;
        return lc;
      } catch (_) {
        // Broken: try the next copy.
      }
    }
    return null;
  }

  /// The chat on the phone, made if missing (incomplete when the backup may hold older rows).
  Future<LocalChat> chatOrNew(String id, {bool complete = true}) async {
    final c = await chat(id);
    if (c != null) return c;
    final n = LocalChat(id, complete: complete);
    _chats[id] = n;
    return n;
  }

  void markChanged(String chatId) {
    _unsaved.add(chatId);
    final m = index[chatId];
    if (m != null) {
      final c = _chats[chatId];
      m['_local'] = c?.complete ?? false;
      m['_pending'] = (c?.dirty.isNotEmpty ?? false) || (c?.deletes.isNotEmpty ?? false);
    }
    _indexUnsaved = true;
    _scheduleSave();
  }

  void markIndex() {
    _indexUnsaved = true;
    _scheduleSave();
  }

  Future<void> forget(String chatId) async {
    _chats.remove(chatId);
    _unsaved.remove(chatId);
    index.remove(chatId);
    _indexUnsaved = true;
    await _idle();
    final f = _chatFile(chatId);
    // The last good copy and a half-written one go too, or a deleted chat could come back from them.
    for (final file in [f, File('${f.path}.bak'), File('${f.path}.tmp')]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    _scheduleSave();
  }

  Future<void> wipe() async {
    _chats.clear();
    _unsaved.clear();
    index.clear();
    deletedChats.clear();
    _indexUnsaved = true;
    // A flush already writing holds the old rows: let it finish before the files go, or it writes one back.
    await _idle();
    try {
      if (_dir != null) {
        await for (final e in _dir!.list()) {
          final p = e.path;
          final chatFile = p.endsWith('.json') || p.endsWith('.json.bak') || p.endsWith('.json.tmp');
          if (e is File && chatFile && !p.contains('index.json')) await e.delete();
        }
      }
    } catch (_) {}
    await flush();
  }

  void _scheduleSave() {
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  /// Writes [text] to `<file>.tmp`, keeps the current file as `<file>.bak` (the last good copy), then moves the new
  /// file into place. Both renames stay in the same folder, so each one is atomic.
  Future<void> _writeAtomic(File f, String text) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    if (await f.exists()) {
      try {
        await f.rename('${f.path}.bak');
      } catch (_) {
        // No last good copy this time; the new file still replaces the old one below.
      }
    }
    await tmp.rename(f.path);
  }

  /// The flush writing now, and the one queued behind it (at most one waits: it writes whatever is newest when it runs).
  Future<void>? _flushing;
  Future<void>? _flushQueued;

  /// Writes everything waiting to disk now (also called when the app goes to the background).
  ///
  /// CB-14: flushes never overlap. The 400 ms save timer, "app went to the background" and the end of a backup round
  /// all call this; a second call while one is writing waits for it and then writes the newest state, so the last
  /// snapshot always wins and two writers never share `<chat>.json.tmp`.
  Future<void> flush() {
    _saveTimer?.cancel();
    final queued = _flushQueued;
    if (queued != null) return queued;
    final running = _flushing;
    if (running == null) return _startFlush();
    late final Future<void> next;
    next = running.catchError((Object _) {}).then((_) {
      if (identical(_flushQueued, next)) _flushQueued = null;
      return _startFlush();
    });
    _flushQueued = next;
    return next;
  }

  /// Waits for the flush that is writing now, if any.
  Future<void> _idle() async {
    final f = _flushing;
    if (f == null) return;
    try {
      await f;
    } catch (_) {}
  }

  Future<void> _startFlush() {
    late final Future<void> f;
    f = _flushNow().whenComplete(() {
      if (identical(_flushing, f)) _flushing = null;
    });
    _flushing = f;
    return f;
  }

  Future<void> _flushNow() async {
    if (_dir == null) return;
    final ids = _unsaved.toList();
    _unsaved.clear();
    for (final id in ids) {
      final c = _chats[id];
      if (c == null) continue;
      try {
        await _writeAtomic(_chatFile(id), jsonEncode(c.toJson()));
      } catch (_) {
        _unsaved.add(id);
      }
    }
    if (_indexUnsaved) {
      _indexUnsaved = false;
      try {
        await _writeAtomic(
            File('${_dir!.path}/index.json'),
            jsonEncode({
              'v': 1,
              'chats': index.values.toList(),
              'deleted': deletedChats,
              'delete_all': deleteAllPending,
              'orphan_deletes': orphanDeletes.toList(),
            }));
      } catch (_) {
        _indexUnsaved = true;
      }
    }
  }

  // ---------- rows ----------
  static Map<String, dynamic> rowOf(ChatMessage m, String createdAt) => {
        'id': m.id,
        'role': m.role,
        'content': m.content,
        'tool_calls': m.toolCalls?.map((e) => e.toJson()).toList(),
        'tool_call_id': m.toolCallId,
        'name': m.name,
        'attachments': m.attachments.isEmpty ? null : m.attachments.map((e) => e.toJson()).toList(),
        'created_at': createdAt,
      };

  static ChatMessage messageOf(Map<String, dynamic> r) => ChatMessage.fromJson(r);

  /// Joins rows from the phone and from the backup: the phone's copy of a row wins (it has the full tool results).
  static List<Map<String, dynamic>> merge(List<Map<String, dynamic>> mine, Iterable<Map<String, dynamic>> theirs) {
    final byId = <String, Map<String, dynamic>>{};
    for (final r in theirs) {
      final id = r['id'];
      if (id is String) byId[id] = r;
    }
    for (final r in mine) {
      final id = r['id'];
      if (id is String) byId[id] = r;
    }
    final out = byId.values.toList();
    // Stable by time; rows with the same time keep the order they came in.
    final order = <String, int>{};
    var i = 0;
    for (final r in [...theirs, ...mine]) {
      order.putIfAbsent(r['id'] as String? ?? '', () => i++);
    }
    out.sort((a, b) {
      final c = ((a['created_at'] ?? '') as String).compareTo((b['created_at'] ?? '') as String);
      return c != 0 ? c : (order[a['id']] ?? 0).compareTo(order[b['id']] ?? 0);
    });
    return out;
  }
}
