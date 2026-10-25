import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'bot_package.dart';
import 'bots.dart';
import 'events.dart';
import 'rewards.dart';

/// One bot in the Bot Store (its card; the package downloads when someone hires it).
class StoreBot {
  StoreBot({
    required this.id,
    required this.name,
    required this.role,
    required this.icon,
    required this.blurb,
    this.author = '',
    this.hires = 0,
    this.mine = false,
    this.builtIn = false,
    this.package,
  });
  final String id;
  final String name;
  final String role;
  final String icon;
  final String blurb;
  final String author;
  int hires;
  final bool mine;
  final bool builtIn;
  Map<String, dynamic>? package;

  static StoreBot fromRow(Map<String, dynamic> r, String? me) => StoreBot(
        id: '${r['id']}',
        name: '${r['name'] ?? 'Bot'}',
        role: '${r['role'] ?? ''}',
        icon: '${r['icon'] ?? 'person'}',
        blurb: '${r['blurb'] ?? ''}',
        author: '${r['author_name'] ?? ''}',
        hires: (r['hires'] as num?)?.toInt() ?? 0,
        mine: me != null && '${r['author_id']}' == me,
        package: r['package'] is Map ? Map<String, dynamic>.from(r['package'] as Map) : null,
      );
}

/// The Bot Store: SubMac's own bots plus bots people published. Hiring makes your own copy.
/// Lives in the Supabase table bot_store (see supabase/migrations). When it can't be reached, the Store still shows
/// SubMac's own bots and says so in one plain line.
class BotStore extends ChangeNotifier {
  BotStore._();
  static final BotStore I = BotStore._();

  final List<StoreBot> community = [];
  bool loading = false;
  String? error;
  DateTime? fetched;

  SupabaseClient? get _c {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String? get _me => _c?.auth.currentUser?.id;

  /// Where the next [hire] came from ('store' or 'link'); a public-page link sets 'link' just before hiring.
  /// Sent to bot_store_hired with this phone's install id (plan 2.4 creator rewards).
  String nextHireSource = 'store';

  static const _cols = 'id, author_id, author_name, name, role, icon, blurb, hires, created_at';

  /// SubMac's own bots, always there (they need no internet).
  List<StoreBot> get builtIns => [
        for (final t in BotTemplates.all)
          StoreBot(id: 'builtin:${t.id}', name: t.name, role: t.role, icon: t.icon, blurb: t.pitch, author: 'SubMac', builtIn: true, package: t.export()),
      ];

  static String _plain(Object e) {
    final s = '$e';
    if (s.contains('42P01') || s.contains('PGRST205') || s.contains('does not exist') || s.contains('schema cache')) {
      return 'The community Bot Store is not open yet. SubMac\'s own bots are here.';
    }
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('TimeoutException')) {
      return 'No connection right now. SubMac\'s own bots are here; the rest load when you are back online.';
    }
    return 'The community bots are resting for a moment. SubMac\'s own bots are here.';
  }

  Future<void> refresh() async {
    final c = _c;
    if (loading) return;
    if (c == null || _me == null) {
      error = 'Sign in to see bots from the community.';
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final rows = await c.from('bot_store').select(_cols).eq('published', true).order('hires', ascending: false).limit(200).timeout(const Duration(seconds: 20));
      community
        ..clear()
        ..addAll([for (final r in rows) StoreBot.fromRow(Map<String, dynamic>.from(r), _me)]);
      fetched = DateTime.now();
    } catch (e) {
      error = _plain(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// The full package of a listing.
  Future<Map<String, dynamic>?> package(StoreBot s) async {
    if (s.package != null) return s.package;
    final c = _c;
    if (c == null) return null;
    try {
      final r = await c.from('bot_store').select('package').eq('id', s.id).maybeSingle().timeout(const Duration(seconds: 25));
      if (r == null || r['package'] is! Map) return null;
      return s.package = Map<String, dynamic>.from(r['package'] as Map);
    } catch (_) {
      return null;
    }
  }

  /// Hires a copy of a listing: it joins the owner's own bots. Returns the new bot, or a plain error.
  Future<(Bot?, String?)> hire(StoreBot s) async {
    final pkg = await package(s);
    if (pkg == null) return (null, '${s.name} needs the internet to arrive. Try again once you\'re online.');
    final warn = s.builtIn ? const <String>[] : BotPackage.warnings(pkg);
    if (warn.isNotEmpty) return (null, 'Not added: ${s.name} looks unsafe (it ${warn.join(', ')}). You can report it.');
    final b = await Bots.I.importBot(pkg, origin: 'store:${s.id}');
    if (b == null) return (null, 'That bot could not be added.');
    if (s.builtIn) {
      // SubMac's own bots work with every app the owner connected, as they always have.
      b.appsScoped = false;
      await Bots.I.save();
    } else {
      try {
        final src = nextHireSource;
        nextHireSource = 'store';
        final n = await _c?.rpc('bot_store_hired', params: {'bot': s.id, 'p_source': src, 'p_device': await Rewards.I.deviceId()});
        if (n is num) s.hires = n.toInt();
        notifyListeners();
      } catch (_) {}
    }
    return (b, null);
  }

  /// Publishes (or updates) the owner's bot in the Store. Returns null when done, or a plain error.
  Future<String?> publish(Bot b, {required String author, String blurb = ''}) async {
    final c = _c;
    if (c == null || _me == null) return 'Sign in first to publish.';
    final pkg = b.export();
    final warn = BotPackage.warnings(pkg);
    if (warn.isNotEmpty) {
      return 'Not published: ${b.name}\'s setup ${warn.join(', ')}. Edit its instructions, knowledge or skills and try again.';
    }
    final row = {
      'author_name': author.trim().isEmpty ? 'A SubMac user' : author.trim().substring(0, math.min(40, author.trim().length)),
      'name': pkg['name'],
      'role': pkg['role'],
      'icon': pkg['icon'],
      'blurb': blurb.trim().isEmpty ? b.pitch : blurb.trim(),
      'package': BotPackage.sanitize({...pkg, 'blurb': blurb.trim().isEmpty ? b.pitch : blurb.trim()}),
      'published': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      if (b.storeId.isNotEmpty) {
        final r = await c.from('bot_store').update(row).eq('id', b.storeId).select('id').maybeSingle();
        if (r != null) {
          await refresh();
          return null;
        }
      }
      final r = await c.from('bot_store').insert({...row}..remove('updated_at')).select('id').single();
      b.storeId = '${r['id']}';
      await Bots.I.save();
      Events.I.log('shared', botId: b.id, props: {'how': 'store'});
      await refresh();
      return null;
    } catch (e) {
      return _plain(e).replaceFirst('The community bots are resting for a moment. SubMac\'s own bots are here.', 'Publishing is resting for a moment. Try again shortly.');
    }
  }

  Future<String?> unpublish(Bot b) async {
    final c = _c;
    if (c == null || b.storeId.isEmpty) return null;
    try {
      await c.from('bot_store').delete().eq('id', b.storeId);
      b.storeId = '';
      await Bots.I.save();
      await refresh();
      return null;
    } catch (e) {
      return 'The Store is resting for a moment. Try removing it again shortly.';
    }
  }

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String _newCode() {
    final r = math.Random.secure();
    return List.generate(8, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
  }

  /// A short code a friend types to hire a copy (the bot stays unlisted). Returns (code, error).
  Future<(String?, String?)> shareCode(Bot b) async {
    final c = _c;
    if (c == null || _me == null) return (null, 'Sign in first to share by code.');
    final pkg = b.export();
    final code = _newCode();
    try {
      await c.from('bot_store').insert({
        'author_name': '',
        'name': pkg['name'],
        'role': pkg['role'],
        'icon': pkg['icon'],
        'blurb': b.pitch,
        'package': pkg,
        'published': false,
        'share_code': code,
      });
      Events.I.log('shared', botId: b.id, props: {'how': 'code'});
      return ('${code.substring(0, 4)}-${code.substring(4)}', null);
    } catch (e) {
      return (null, _plain(e).contains('not open yet') ? 'Sharing by code is not available yet. Share it as a file instead.' : 'The code isn\'t ready right now. Share it as a file instead.');
    }
  }

  /// Adds a bot a friend shared by code. Returns (bot, error).
  Future<(Bot?, String?)> hireByCode(String code) async {
    final c = _c;
    if (c == null || _me == null) return (null, 'Sign in first to add a shared bot.');
    final clean = code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (clean.length != 8) return (null, 'A code has 8 letters and numbers, like ABCD-2345.');
    try {
      final rows = await c.rpc('bot_store_by_code', params: {'code': clean});
      final list = rows is List ? rows : const [];
      if (list.isEmpty) return (null, 'No bot has that code. Check it and try again.');
      final r = Map<String, dynamic>.from(list.first as Map);
      if (r['package'] is! Map) return (null, 'That bot could not be added.');
      final shared = Map<String, dynamic>.from(r['package'] as Map);
      final warn = BotPackage.warnings(shared);
      if (warn.isNotEmpty) return (null, 'Not added: this bot looks unsafe (it ${warn.join(', ')}).');
      final b = await Bots.I.importBot(shared, origin: 'shared');
      if (b != null) {
        Events.I.log('hired_from_share', botId: b.id, props: {'how': 'code'});
        // Counts the hire (and rewards the creator when the bot is also published in the Store).
        if (r['id'] != null) {
          unawaited(Rewards.I.deviceId().then((d) => c.rpc('bot_store_hired', params: {'bot': '${r['id']}', 'p_source': 'code', 'p_device': d})).catchError((_) => 0));
        }
      }
      return b == null ? (null, 'That bot could not be added.') : (b, null);
    } catch (e) {
      return (null, _plain(e).contains('not open yet') ? 'Adding by code is not available yet. Ask for the file instead.' : 'SubMac is resting for a moment. Try again shortly.');
    }
  }

  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
  static String slug(String name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  /// Finds the bot behind a "Hire in SubMac" link (submac.site/b/<code>): a share code, a listing id or a name slug.
  /// For a share code, shareCode is set too: hire it with [hireByCode] (unlisted bots), not [hire]. Returns (listing, shareCode, error).
  Future<(StoreBot?, String?, String?)> resolveLink(String code) async {
    final c = _c;
    if (c == null || _me == null) return (null, null, 'Sign in first to add a bot.');
    final raw = code.trim();
    final compact = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    try {
      Map<String, dynamic>? row;
      if (RegExp(r'^[A-Za-z0-9]{4}-?[A-Za-z0-9]{4}$').hasMatch(raw) && !compact.contains(RegExp('[01IO]'))) {
        // Looks like a share code (ABCD-2345); an 8-letter bot name falls through to the name lookup below.
        final rows = await c.rpc('bot_store_by_code', params: {'code': compact}).timeout(const Duration(seconds: 20));
        if (rows is List && rows.isNotEmpty) {
          final r = Map<String, dynamic>.from(rows.first as Map)..remove('package');
          return (StoreBot.fromRow(r, _me), compact, null);
        }
      }
      if (_uuid.hasMatch(raw)) {
        final r = await c.from('bot_store').select(_cols).eq('id', raw.toLowerCase()).eq('published', true).maybeSingle().timeout(const Duration(seconds: 20));
        if (r != null) row = Map<String, dynamic>.from(r);
      } else {
        final want = slug(raw);
        if (want.isEmpty) return (null, null, 'That link has no bot in it.');
        final rows = await c.from('bot_store').select(_cols).eq('published', true).ilike('name', want.replaceAll('-', '%'))
            .order('hires', ascending: false).limit(20).timeout(const Duration(seconds: 20));
        for (final r in rows) {
          if (slug('${r['name'] ?? ''}') == want) {
            row = Map<String, dynamic>.from(r);
            break;
          }
        }
      }
      if (row == null) return (null, null, 'That bot is no longer in the Bot Store.');
      return (StoreBot.fromRow(row, _me), null, null);
    } catch (e) {
      return (null, null, _plain(e).replaceFirst('The community bots are resting for a moment. SubMac\'s own bots are here.', 'SubMac is resting for a moment. Try again shortly.'));
    }
  }

  /// Is a copy of this listing already on the owner's team?
  Bot? hiredCopy(StoreBot s) => Bots.I.bots.where((b) => b.origin == 'store:${s.id}').firstOrNull ??
      (s.builtIn ? Bots.I.byId(s.id.substring('builtin:'.length)) : null);

  /// Shown on a card before hiring: what comes with it (never anything about its author).
  static List<String> includes(Map<String, dynamic>? pkg) {
    if (pkg == null) return const [];
    final out = <String>[];
    int n(String k) => (pkg[k] is List) ? (pkg[k] as List).length : 0;
    if ('${pkg['instructions'] ?? ''}'.trim().isNotEmpty) out.add('Instructions');
    if (n('knowledge') > 0) out.add('${n('knowledge')} piece(s) of knowledge${pkg['sandbox'] == true ? ' (answers only from it)' : ''}');
    if (n('skills') > 0) out.add('${n('skills')} skill(s)');
    if (n('routines') > 0) out.add('${n('routines')} routine(s)');
    if (n('lessons') > 0) out.add('${n('lessons')} lesson(s) learned');
    final apps = [for (final a in (pkg['apps'] as List? ?? const [])) if (a is Map) '${a['name']}'];
    if (apps.isNotEmpty) out.add('Works with ${apps.join(', ')} (you connect them with your own account)');
    return out;
  }
}
