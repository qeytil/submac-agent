import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One item in "From SubMac": a message from the SubMac team, a reward grant, or an earned-reward notice.
class InboxItem {
  final String id;
  final String kind; // admin_message | reward_grant | reward_earned
  String title;
  String body;
  final bool inChat;
  DateTime? readAt;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.inChat,
    required this.readAt,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get unread => readAt == null;

  factory InboxItem.fromJson(Map<String, dynamic> j) => InboxItem(
        id: '${j['id']}',
        kind: '${j['kind'] ?? 'admin_message'}',
        title: '${j['title'] ?? ''}',
        body: '${j['body'] ?? ''}',
        inChat: j['in_chat'] == true,
        readAt: DateTime.tryParse('${j['read_at'] ?? ''}')?.toLocal(),
        deleted: j['deleted'] == true,
        createdAt: DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal() ?? DateTime.now(),
        updatedAt: DateTime.tryParse('${j['updated_at'] ?? ''}')?.toLocal() ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'body': body,
        'in_chat': inChat,
        'read_at': readAt?.toUtc().toIso8601String(),
        'deleted': deleted,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}

/// "From SubMac": everything the SubMac team sends this account (Supabase `user_inbox`, read-only for the user;
/// read/unread through `inbox_mark`). Cached on the phone so it opens offline. Messages sent "in chat" are also
/// posted into the SubMac team chat by [onChatItems] (set by AppState), and edits/deletes made by the team follow.
class Inbox extends ChangeNotifier {
  Inbox._();
  static final I = Inbox._();

  static const _cacheKey = 'inbox_cache';

  final List<InboxItem> _all = [];
  final unread = ValueNotifier<int>(0);
  bool loading = false;
  DateTime? fetched;
  // Lives as long as the app (a singleton following sign-in), so it is never cancelled.
  // ignore: cancel_subscriptions
  StreamSubscription<AuthState>? _auth;
  Timer? _timer;

  /// Visible items, newest first.
  List<InboxItem> get items => [for (final i in _all) if (!i.deleted) i];

  /// AppState mirrors in-chat items into the SubMac team chat (all items, including deleted ones, so it can remove them).
  Future<void> Function(List<InboxItem> all)? onChatItems;

  SupabaseClient? get _c {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_cacheKey);
      if (raw != null && raw.isNotEmpty) {
        _all
          ..clear()
          ..addAll([for (final e in jsonDecode(raw) as List) if (e is Map) InboxItem.fromJson(Map<String, dynamic>.from(e))]);
        _count();
      }
    } catch (_) {}
    final c = _c;
    if (c == null) return;
    _auth ??= c.auth.onAuthStateChange.listen((s) {
      if (s.session != null && (s.event == AuthChangeEvent.signedIn || s.event == AuthChangeEvent.initialSession)) {
        unawaited(refresh());
      }
      if (s.event == AuthChangeEvent.signedOut) unawaited(clear());
    }, onError: (_) {});
    // While the app is open, look for new items now and then (pushes also trigger a refresh when tapped).
    _timer ??= Timer.periodic(const Duration(minutes: 10), (_) => unawaited(refresh()));
  }

  void _count() {
    unread.value = items.where((i) => i.unread).length;
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_cacheKey, jsonEncode([for (final i in _all.take(200)) i.toJson()]));
    } catch (_) {}
  }

  Future<void> clear() async {
    _all.clear();
    _count();
    notifyListeners();
    try {
      (await SharedPreferences.getInstance()).remove(_cacheKey);
    } catch (_) {}
  }

  /// Pulls the newest 200 items. Never throws.
  Future<void> refresh() async {
    final c = _c;
    if (c == null || c.auth.currentUser == null || loading) return;
    loading = true;
    notifyListeners();
    try {
      final rows = await c
          .from('user_inbox')
          .select('id,kind,title,body,in_chat,read_at,deleted,created_at,updated_at')
          .order('created_at', ascending: false)
          .limit(200)
          .timeout(const Duration(seconds: 20));
      _all
        ..clear()
        ..addAll([for (final r in rows) InboxItem.fromJson(Map<String, dynamic>.from(r))]);
      fetched = DateTime.now();
      _count();
      await _save();
      final cb = onChatItems;
      if (cb != null) unawaited(cb(List.of(_all)));
    } catch (e) {
      debugPrint('inbox: $e');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  InboxItem? byId(String id) => _all.where((i) => i.id == id).firstOrNull;

  /// Marks items read (or unread) here and on the server.
  Future<void> mark(List<String> ids, {bool read = true}) async {
    if (ids.isEmpty) return;
    for (final i in _all) {
      if (ids.contains(i.id)) i.readAt = read ? (i.readAt ?? DateTime.now()) : null;
    }
    _count();
    notifyListeners();
    unawaited(_save());
    try {
      await _c?.rpc('inbox_mark', params: {'p_ids': ids, 'p_read': read}).timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('inbox mark: $e');
    }
  }

  Future<void> markAllRead() => mark([for (final i in items) if (i.unread) i.id]);
}
