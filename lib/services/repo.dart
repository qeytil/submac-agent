import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';
import 'chat_store.dart';

const _uuid = Uuid();

/// Chats, settings and attachments.
///
/// v1.12: chats are phone-first. Every chat lives in full on the phone (ChatStore) and opens
/// from there. The account (Supabase) is only a backup so the user can sign in on another phone:
///  - only new or changed rows are sent (per-chat "waiting" sets), a few seconds after a change;
///  - tool results are never sent: a tool row keeps its tool name and a short note
///    ([toolNoteChars]); user and assistant text goes in full; compact summaries go too;
///  - a new phone pulls the chat list first and a chat's rows (in pages of [pageSize])
///    only when that chat is opened;
///  - chats untouched for [archiveAfterDays] days, and everything past the [backupRecentChats]
///    most recent chats, are packed into one gzipped JSON file in the private
///    `chat-archives` bucket (`<user id>/<chat id>.json.gz`); the database keeps only the
///    chat row and its summary.
class Repo {
  /// Most recent chats whose messages stay in the account database. Older ones are packed into files.
  static const backupRecentChats = 50;

  /// Chats untouched this long are packed into a file.
  static const archiveAfterDays = 30;

  /// Longest note a backed-up tool row keeps (the full result stays on the phone).
  static const toolNoteChars = 300;

  /// Longest tool-call input sent to the backup (longer ones are kept on the phone only).
  static const toolInputChars = 2000;

  /// Rows fetched per request when a chat is pulled from the backup.
  static const pageSize = 50;

  /// Chats packed per archiver run.
  static const archiveBatch = 15;

  static const archiveBucket = 'chat-archives';
  static const _convCols = 'id,title,model,pinned,archived,created_at,updated_at,archive_path,stored_at';
  static const _msgCols = 'id,role,content,tool_calls,tool_call_id,name,attachments,created_at';

  SupabaseClient get _c => Supabase.instance.client;
  final store = ChatStore();

  /// Test seam: a signed-in user id without Supabase (the backup is then never contacted).
  @visibleForTesting
  String? testUserId;

  String? get userId => testUserId ?? _c.auth.currentUser?.id;

  /// CB-18: chats deleted on this phone this session. A late write from a run that was still finishing (a step that
  /// ignored stop) is ignored instead of bringing the chat back as an unknown entry that syncs to the backup again.
  final Set<String> _deletedHere = {};

  @visibleForTesting
  bool wasDeletedHere(String id) => _deletedHere.contains(id);
  String? get email => _c.auth.currentUser?.email;

  Future<ChatStore> _s() async {
    await store.open(userId ?? '');
    return store;
  }

  /// When the last backup round finished without a problem (this session).
  DateTime? lastBackup;
  bool get backupWaiting => store.index.values.any((m) => m['_pending'] == true || m['_dirty'] == true || m['_remote'] != true);

  // ---------- chat list ----------
  static Conversation _conv(Map<String, dynamic> m) => Conversation.fromJson(m);

  /// The chats on this phone, newest first. Instant, works offline.
  Future<List<Conversation>> localConversations() async {
    final s = await _s();
    // A chat known only by id (not yet seen in the backup's list) shows once the list confirms it.
    final l = [for (final m in s.index.values) if (m['_unknown'] != true) _conv(m)];
    l.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l;
  }

  /// The chat list joined with the account backup (chats made on another phone appear,
  /// without their messages until opened). Throws when the backup cannot be reached.
  Future<List<Conversation>> listConversations() async {
    final s = await _s();
    if (userId == null) return localConversations();
    List<Map<String, dynamic>> rows;
    try {
      rows = await _c.from('conversations').select(_convCols).order('updated_at', ascending: false).limit(1000);
    } on PostgrestException {
      // Backup not upgraded yet (no archive columns): the old row shape still loads.
      rows = await _c.from('conversations').select().order('updated_at', ascending: false).limit(1000);
    }
    for (final r0 in rows) {
      final r = Map<String, dynamic>.from(r0);
      final id = r['id'];
      if (id is! String) continue;
      if (s.deleteAllPending || s.deletedChats.containsKey(id)) continue;
      r['updated_at'] = ChatStore.norm(r['updated_at']);
      r['created_at'] = ChatStore.norm(r['created_at']);
      final m = s.index[id];
      if (m == null) {
        s.index[id] = {...r, '_remote': true, '_local': false};
        continue;
      }
      m['_remote'] = true;
      if (r.containsKey('archive_path')) m['archive_path'] = r['archive_path'];
      if (r.containsKey('stored_at')) m['stored_at'] = r['stored_at'] == null ? null : ChatStore.norm(r['stored_at']);
      if (m['_dirty'] != true || m['_unknown'] == true) {
        for (final k in const ['title', 'model', 'pinned', 'archived']) {
          m[k] = r[k];
        }
        m.remove('_unknown');
      }
      final theirs = DateTime.tryParse('${r['updated_at']}');
      final mine = DateTime.tryParse('${m['updated_at'] ?? ''}');
      if (theirs != null && (mine == null || theirs.isAfter(mine.add(const Duration(seconds: 2))))) {
        // Another phone added to this chat: pull what is new next time it opens.
        m['updated_at'] = r['updated_at'];
        if (m['_local'] == true) m['_stale'] = true;
      }
    }
    s.markIndex();
    return localConversations();
  }

  Future<Conversation> createConversation({String title = 'New chat', String? model}) async {
    final s = await _s();
    final now = ChatStore.iso(DateTime.now());
    final id = _uuid.v4();
    s.index[id] = {
      'id': id,
      'title': title,
      'model': model,
      'pinned': false,
      'archived': false,
      'created_at': now,
      'updated_at': now,
      '_remote': false,
      '_dirty': true,
      '_local': true,
    };
    await s.chatOrNew(id);
    s.markChanged(id);
    _kick();
    return _conv(s.index[id]!);
  }

  Future<void> updateConversation(String id, Map<String, dynamic> fields, {bool touch = true}) async {
    final s = await _s();
    final m = s.index[id];
    if (m == null) return;
    m.addAll(fields);
    if (touch) m['updated_at'] = ChatStore.iso(DateTime.now());
    m['_dirty'] = true;
    s.markIndex();
    _kick();
  }

  /// [keepWritable]: a chat whose id is reused afterwards (a bot's chat), so later writes to it are allowed.
  Future<void> deleteConversation(String id, {bool keepWritable = false}) async {
    if (!keepWritable) _deletedHere.add(id);
    final s = await _s();
    final m = s.index[id];
    if (m == null || m['_remote'] != false) s.deletedChats[id] = (m?['archive_path'] ?? '') as String;
    await s.forget(id);
    _kick();
  }

  /// [keepWritable]: chat ids reused afterwards (bots' chats), so later writes to them are allowed.
  Future<void> deleteAllConversations({Set<String> keepWritable = const {}}) async {
    if (userId == null) return;
    final s = await _s();
    _deletedHere.addAll(s.index.keys.where((id) => !keepWritable.contains(id)));
    s.deleteAllPending = true;
    await s.wipe();
    _kick(const Duration(milliseconds: 200));
  }

  // ---------- messages ----------
  static List<ChatMessage> _msgs(LocalChat c) => [for (final r in c.rows) ChatStore.messageOf(r)];

  /// A chat's messages: from the phone when it has the chat, otherwise from the backup
  /// (its packed file, if any, plus its rows page by page), kept on the phone afterwards.
  Future<List<ChatMessage>> listMessages(String conversationId) async {
    final s = await _s();
    final id = conversationId;
    var m = s.index[id];
    final lc = await s.chat(id);
    if (lc != null && lc.complete && m?['_stale'] != true) return _msgs(lc);
    if (m == null && lc == null && userId != null) {
      // Not listed on this phone yet (e.g. a bot woken before the chat list loaded): ask the backup.
      m = {'id': id, 'updated_at': '', '_remote': true, '_unknown': true, '_local': false};
      s.index[id] = m;
    }
    if (userId == null || m == null || m['_remote'] != true) {
      return lc == null ? <ChatMessage>[] : _msgs(lc);
    }
    try {
      var theirs = <Map<String, dynamic>>[];
      final ap = (m['archive_path'] ?? '') as String;
      if (lc != null && lc.complete) {
        // Only what another phone added since.
        final last = DateTime.tryParse(lc.lastCreatedAt);
        final stored = DateTime.tryParse('${m['stored_at'] ?? ''}');
        if (ap.isNotEmpty && stored != null && (last == null || stored.isAfter(last))) theirs = await _readArchive(ap);
        theirs = ChatStore.merge(await _pullRows(id, since: last?.subtract(const Duration(minutes: 10))), theirs);
      } else {
        if (ap.isNotEmpty) theirs = await _readArchive(ap);
        theirs = ChatStore.merge(await _pullRows(id), theirs);
      }
      final c = await s.chatOrNew(id, complete: false);
      theirs.removeWhere((r) => c.deletes.contains(r['id']));
      c.rows = ChatStore.merge(c.rows, theirs);
      c.complete = true;
      m['_stale'] = false;
      s.markChanged(id);
      return _msgs(c);
    } catch (e) {
      if (lc != null) return _msgs(lc);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _pullRows(String id, {DateTime? since}) async {
    final out = <Map<String, dynamic>>[];
    var from = 0;
    while (true) {
      var q = _c.from('messages').select(_msgCols).eq('conversation_id', id);
      if (since != null) q = q.gte('created_at', since.toUtc().toIso8601String());
      final rows = await q.order('created_at', ascending: true).range(from, from + pageSize - 1);
      for (final r0 in rows) {
        final r = Map<String, dynamic>.from(r0);
        r['created_at'] = ChatStore.norm(r['created_at']);
        out.add(r);
      }
      if (rows.length < pageSize || from > 50000) break;
      from += pageSize;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _readArchive(String path) async {
    final bytes = await _c.storage.from(archiveBucket).download(path);
    final j = jsonDecode(utf8.decode(gzip.decode(bytes)));
    final list = (j is Map ? j['messages'] : j) as List? ?? const [];
    return [
      for (final e in list)
        if (e is Map) {...Map<String, dynamic>.from(e), 'created_at': ChatStore.norm(e['created_at'])}..remove('conversation_id'),
    ];
  }

  /// Where a just-removed row was, so "remove then save again" (an edit) keeps its place.
  final Map<String, (String, int, String)> _tomb = {};

  Future<void> insertMessage(String conversationId, ChatMessage m) async {
    if (_deletedHere.contains(conversationId)) return;
    final s = await _s();
    final id = conversationId;
    var meta = s.index[id];
    if (meta == null) {
      // A chat this phone has not listed yet (e.g. a bot woken before the list loaded).
      meta = {'id': id, 'updated_at': ChatStore.iso(DateTime.now()), '_remote': true, '_unknown': true, '_local': false};
      s.index[id] = meta;
    }
    final c = await s.chatOrNew(id, complete: meta['_remote'] != true);
    final i = c.rows.indexWhere((r) => r['id'] == m.id);
    final t = _tomb.remove(m.id);
    if (i >= 0) {
      c.rows[i] = ChatStore.rowOf(m, (c.rows[i]['created_at'] ?? s.stamp()) as String);
    } else if (t != null && t.$1 == id) {
      c.rows.insert(t.$2.clamp(0, c.rows.length), ChatStore.rowOf(m, t.$3));
    } else {
      c.rows.add(ChatStore.rowOf(m, s.stamp()));
    }
    c.dirty.add(m.id);
    c.deletes.remove(m.id);
    meta['updated_at'] = ChatStore.iso(DateTime.now());
    meta['_dirty'] = true;
    s.markChanged(id);
    _kick();
  }

  Future<void> deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final s = await _s();
    final left = ids.toSet();
    for (final c in s.loaded) {
      for (var i = c.rows.length - 1; i >= 0; i--) {
        final rid = c.rows[i]['id'];
        if (rid is String && left.contains(rid)) {
          _tomb[rid] = (c.id, i, (c.rows[i]['created_at'] ?? '') as String);
          c.rows.removeAt(i);
          c.dirty.remove(rid);
          c.deletes.add(rid);
          left.remove(rid);
          s.markChanged(c.id);
        }
      }
    }
    if (left.isNotEmpty) {
      s.orphanDeletes.addAll(left);
      s.markIndex();
    }
    if (_tomb.length > 300) _tomb.clear();
    _kick();
  }

  // ---------- backup ----------
  Timer? _kickTimer;
  bool _syncing = false;
  bool _again = false;
  int _fails = 0;

  void _kick([Duration d = const Duration(seconds: 4)]) {
    if (testUserId != null) return;
    _kickTimer?.cancel();
    _kickTimer = Timer(d, () => unawaited(sync()));
  }

  /// Writes waiting chat files to disk now (app going to the background).
  Future<void> flush() => store.flush();

  /// The note a tool row keeps in the backup.
  static String toolNote(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= toolNoteChars) return t;
    var cut = toolNoteChars - 1;
    final u = t.codeUnitAt(cut - 1);
    if (u >= 0xD800 && u <= 0xDBFF) cut--;
    return '${t.substring(0, cut)}…';
  }

  /// A row as the backup keeps it: never a raw tool result.
  static Map<String, dynamic> forBackup(Map<String, dynamic> r, String convId) {
    final role = (r['role'] ?? 'assistant') as String;
    var content = (r['content'] ?? '') as String;
    // WhatsApp results (other people's messages) never leave the phone, not even as a short note.
    if (role == 'tool' && r['name'] == 'whatsapp') content = 'WhatsApp result (kept on the phone only)';
    if (role == 'tool') content = toolNote(content);
    final calls = r['tool_calls'] as List?;
    return {
      'id': r['id'],
      'conversation_id': convId,
      'role': role,
      'content': content,
      'tool_calls': calls == null
          ? null
          : [
              for (final c in calls)
                if (c is Map) _trimCall(Map<String, dynamic>.from(c)),
            ],
      'tool_call_id': r['tool_call_id'],
      'name': r['name'],
      'attachments': r['attachments'],
      'created_at': (r['created_at'] ?? '') == '' ? ChatStore.iso(DateTime.now()) : r['created_at'],
    };
  }

  static Map<String, dynamic> _trimCall(Map<String, dynamic> c) {
    final fn = Map<String, dynamic>.from((c['function'] as Map?) ?? const {});
    final args = (fn['arguments'] ?? '') as String;
    if (fn['name'] == 'whatsapp') {
      // Who and what was messaged on WhatsApp stays on the phone; the backup keeps only the kind of step.
      var act = '';
      try {
        act = '${(jsonDecode(args) as Map)['action'] ?? ''}';
      } catch (_) {}
      fn['arguments'] = jsonEncode({'action': act, 'note': 'kept on the phone only'});
      return {...c, 'function': fn};
    }
    if (args.length > toolInputChars) fn['arguments'] = jsonEncode({'note': 'Long input kept on the phone only'});
    return {...c, 'function': fn};
  }

  static Map<String, dynamic> _convRow(Map<String, dynamic> m) => {
        'id': m['id'],
        'title': (m['title'] ?? 'Chat') as String,
        'model': m['model'],
        'pinned': (m['pinned'] ?? false) as bool,
        'archived': (m['archived'] ?? false) as bool,
        if ((m['created_at'] ?? '') != '') 'created_at': m['created_at'],
        if ((m['updated_at'] ?? '') != '') 'updated_at': m['updated_at'],
      };

  static Iterable<List<T>> _chunks<T>(List<T> l, int n) sync* {
    for (var i = 0; i < l.length; i += n) {
      yield l.sublist(i, i + n > l.length ? l.length : i + n);
    }
  }

  /// Sends what changed on this phone to the account backup. Safe to call any time;
  /// a failed round keeps everything waiting and tries again later.
  Future<bool> sync() async {
    final uid = userId;
    if (uid == null) return false;
    if (_syncing) {
      _again = true;
      return false;
    }
    _syncing = true;
    var ok = true;
    try {
      final s = await _s();
      if (s.uid != uid) return false;
      if (s.deleteAllPending) {
        await _c.from('conversations').delete().eq('user_id', uid);
        try {
          await _removeAllArchives(uid);
        } catch (_) {}
        s.deleteAllPending = false;
        s.deletedChats.clear();
        s.markIndex();
      }
      for (final e in Map.of(s.deletedChats).entries) {
        try {
          await _c.from('conversations').delete().eq('id', e.key);
          try {
            await _c.storage.from(archiveBucket).remove({'$uid/${e.key}.json.gz', if (e.value.isNotEmpty) e.value}.toList());
          } catch (_) {}
          s.deletedChats.remove(e.key);
          s.markIndex();
        } catch (_) {
          ok = false;
        }
      }
      // New chats.
      final fresh = [for (final m in s.index.values) if (m['_remote'] == false) m];
      for (final part in _chunks(fresh, 50)) {
        try {
          await _c.from('conversations').upsert([for (final m in part) _convRow(m)], onConflict: 'id');
          for (final m in part) {
            m['_remote'] = true;
            m['_dirty'] = false;
          }
          s.markIndex();
        } catch (_) {
          ok = false;
        }
      }
      // Changed chats (title, pin, archive, last activity).
      for (final m in [for (final x in s.index.values) if (x['_remote'] == true && x['_dirty'] == true) x]) {
        try {
          final row = _convRow(m)..remove('id')..remove('created_at');
          if (m['_unknown'] == true) row.removeWhere((k, _) => k != 'updated_at');
          await _c.from('conversations').update(row).eq('id', m['id'] as String);
          m['_dirty'] = false;
          s.markIndex();
        } catch (_) {
          ok = false;
        }
      }
      // Rows.
      for (final m in [for (final x in s.index.values) if (x['_pending'] == true && x['_remote'] == true) x]) {
        final id = m['id'] as String;
        final c = await s.chat(id);
        if (c == null) {
          m['_pending'] = false;
          continue;
        }
        try {
          final del = c.deletes.toList();
          for (final part in _chunks(del, 100)) {
            await _c.from('messages').delete().inFilter('id', part);
          }
          c.deletes.removeAll(del);
          final want = c.dirty.toSet();
          final rows = [for (final r in c.rows) if (want.contains(r['id'])) forBackup(r, id)];
          for (final part in _chunks(rows, 100)) {
            await _c.from('messages').upsert(part, onConflict: 'id');
          }
          c.dirty.removeAll(want);
          // Rows marked waiting that are no longer in the chat need nothing.
          c.dirty.retainWhere((x) => c.rows.any((r) => r['id'] == x));
          s.markChanged(id);
        } on PostgrestException catch (e) {
          ok = false;
          if (e.code == '23503') {
            // The backup lost this chat's row (deleted on another phone): send the chat again first.
            m['_remote'] = false;
            m['_dirty'] = true;
            s.markIndex();
          }
        } catch (_) {
          ok = false;
        }
      }
      if (s.orphanDeletes.isNotEmpty) {
        try {
          final del = s.orphanDeletes.toList();
          for (final part in _chunks(del, 100)) {
            await _c.from('messages').delete().inFilter('id', part);
          }
          s.orphanDeletes.removeAll(del);
          s.markIndex();
        } catch (_) {
          ok = false;
        }
      }
      await s.flush();
      if (ok) lastBackup = DateTime.now();
    } catch (_) {
      ok = false;
    } finally {
      _syncing = false;
    }
    if (_again) {
      _again = false;
      _kick();
    } else if (!ok) {
      _fails++;
      _kick(Duration(minutes: _fails > 5 ? 15 : 1 + _fails));
    } else {
      _fails = 0;
    }
    return ok;
  }

  Future<void> _removeAllArchives(String uid) async {
    final b = _c.storage.from(archiveBucket);
    for (var round = 0; round < 20; round++) {
      final files = await b.list(path: uid, searchOptions: SearchOptions(limit: 100));
      if (files.isEmpty) return;
      await b.remove([for (final f in files) '$uid/${f.name}']);
    }
  }

  // ---------- archive ----------
  /// Packs old chats into files and clears their rows from the database: chats untouched for
  /// [archiveAfterDays] days and everything past the [backupRecentChats] most recent ones.
  /// Batched and failure-tolerant; returns how many chats were packed.
  Future<int> archiveOld({Set<String> skip = const {}}) async {
    final uid = userId;
    if (uid == null) return 0;
    final s = await _s();
    if (s.uid != uid) return 0;
    final all = s.index.values.toList()
      ..sort((a, b) => ((b['updated_at'] ?? '') as String).compareTo((a['updated_at'] ?? '') as String));
    final cutoff = DateTime.now().subtract(const Duration(days: archiveAfterDays));
    final todo = <Map<String, dynamic>>[];
    for (var i = 0; i < all.length; i++) {
      final m = all[i];
      if (m['_remote'] != true || m['_dirty'] == true || m['_pending'] == true || m['_unknown'] == true) continue;
      if (skip.contains(m['id'])) continue;
      final up = DateTime.tryParse('${m['updated_at'] ?? ''}');
      if (up == null) continue;
      if (i < backupRecentChats && !up.isBefore(cutoff)) continue;
      final stored = DateTime.tryParse('${m['stored_at'] ?? ''}');
      if (stored != null && !up.isAfter(stored)) continue;
      todo.add(m);
      if (todo.length >= archiveBatch) break;
    }
    var n = 0;
    for (final m in todo) {
      try {
        if (await _archiveOne(uid, s, m)) n++;
      } catch (_) {
        // Tried again next run.
      }
    }
    if (n > 0) s.markIndex();
    return n;
  }

  Future<bool> _archiveOne(String uid, ChatStore s, Map<String, dynamic> m) async {
    final id = m['id'] as String;
    final lc = await s.chat(id);
    final ap = (m['archive_path'] ?? '') as String;
    var rows = <Map<String, dynamic>>[];
    // What the backup holds for this chat right now (only these rows are cleared afterwards).
    final server = await _pullRows(id);
    if (ap.isNotEmpty) rows = await _readArchive(ap);
    rows = ChatStore.merge(server, rows);
    if (lc != null) rows = ChatStore.merge(lc.rows, rows);
    if (rows.isEmpty && server.isEmpty) return false;
    final packed = [for (final r in rows) forBackup(r, id)..remove('conversation_id')];
    var summary = '';
    for (final r in packed.reversed) {
      if (r['role'] == 'system' && '${r['name'] ?? ''}'.startsWith('compact:')) {
        summary = (r['content'] ?? '') as String;
        break;
      }
    }
    if (summary.isEmpty) {
      final first = packed.firstWhere((r) => r['role'] == 'user', orElse: () => const {});
      summary = '${first['content'] ?? ''}';
    }
    if (summary.length > 4000) summary = summary.substring(0, 4000);
    final body = gzip.encode(utf8.encode(jsonEncode({
      'v': 1,
      'chat': _convRow(m),
      'messages': packed,
    })));
    final path = '$uid/$id.json.gz';
    await _c.storage.from(archiveBucket).uploadBinary(path, Uint8List.fromList(body),
        fileOptions: FileOptions(contentType: 'application/gzip', upsert: true));
    final now = ChatStore.iso(DateTime.now());
    await _c.from('conversations').update({'archive_path': path, 'stored_at': now, 'summary': summary}).eq('id', id);
    final inFile = {for (final r in packed) r['id']};
    final gone = [for (final r in server) if (inFile.contains(r['id'])) r['id'] as String];
    for (final part in _chunks(gone, 100)) {
      await _c.from('messages').delete().inFilter('id', part);
    }
    m['archive_path'] = path;
    m['stored_at'] = now;
    return true;
  }

  // ---------- attachments & settings ----------
  Future<String?> uploadAttachment(String conversationId, Attachment a) async {
    final uid = userId;
    if (uid == null || a.bytes == null) return null;
    final safe = a.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$uid/$conversationId/${DateTime.now().millisecondsSinceEpoch}_$safe';
    await _c.storage.from('attachments').uploadBinary(
          path,
          a.bytes!,
          fileOptions: FileOptions(contentType: a.mime, upsert: true),
        );
    return path;
  }

  Future<Uint8List> downloadAttachment(String path) => _c.storage.from('attachments').download(path);

  Future<Map<String, dynamic>> loadSettings() async {
    final uid = userId;
    if (uid == null) return {};
    final row = await _c.from('user_settings').select().eq('user_id', uid).maybeSingle();
    if (row == null) return {};
    return Map<String, dynamic>.from((row['settings'] as Map?) ?? const {});
  }

  Future<void> saveSettings(Map<String, dynamic> settings) async {
    final uid = userId;
    if (uid == null) return;
    await _c.from('user_settings').upsert({
      'user_id': uid,
      'settings': settings,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> signOut() async {
    try {
      await sync().timeout(const Duration(seconds: 8));
    } catch (_) {}
    await store.flush();
    await _c.auth.signOut();
  }
}
