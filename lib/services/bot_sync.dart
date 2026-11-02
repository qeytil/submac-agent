import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'bot_package.dart';
import 'bots.dart';
import 'offices.dart';
import 'skill_library.dart';

/// Plan 2.1 part A: every bot is kept in the owner's account (Supabase), so it survives a reinstall, comes back
/// on a new phone, and can later keep working in the cloud (`bot-run`, part B). Design: docs/plans-2026-10.md
/// "2.1 design". Tables: cloud_bots, cloud_bot_memory, cloud_bot_desk, cloud_bot_journal
/// (supabase/migrations/20261019_bot_cloud.sql).
///
/// - Up: a few seconds after any change (Bots.save / saveKnowledge), only what changed since the last round:
///   setup and knowledge by hash, memory lines and desk tasks one row each (removed ones become tombstones),
///   journal entries appended. A removed bot becomes a tombstone row and its lines are deleted.
/// - Down: on sign-in (all rows the first time on this phone, then only newer ones) and on every round.
///   Journal entries a cloud run made are added to the journal, and its message (`chat`) is posted in the bot's chat.
/// - Conflicts: the same item changed here and elsewhere since the last round: this phone's change wins (it is sent
///   right after). Different items merge. A removed bot is removed everywhere. The journal only grows.
/// - Never sent: phone-only data (texts, contacts, notification contents, screen), logins, keys (setup text passes
///   BotPackage.scrubSecrets), budget counters.
///
/// Bots belong to the account, not to the phone. Signing out, or another account signing in, takes every bot and
/// team off this phone (anything still waiting is sent first, while the session is still that account's), and
/// signing back in brings them back: from the copy this phone kept for that account (hidden from every other account;
/// teams are only kept there), then from the account. Deleting the account keeps nothing. No account ever sees or
/// sends up another account's bots.
/// What the last sync round is doing. Shown in the bot's profile so a sync can never fail in silence.
enum BotSyncState {
  /// Nothing has run yet in this session.
  idle,

  /// A round is running.
  syncing,

  /// The last round finished and the account is up to date.
  ok,

  /// The last round threw. [BotSync.lastError] says what.
  failed,
}

class BotSync {
  BotSync._();
  static final BotSync I = BotSync._();

  SupabaseClient get _c => debugClient ?? Supabase.instance.client;

  /// Tests: a client on a fake account (PostgREST over a mock http client), and who is signed in.
  @visibleForTesting
  static SupabaseClient? debugClient;
  @visibleForTesting
  static String? Function()? debugUid;

  /// The signed-in account on this phone right now.
  String? get _authUid => debugUid != null ? debugUid!() : _c.auth.currentUser?.id;
  SharedPreferences? _p;
  Timer? _timer;
  bool _busy = false;
  bool _again = false;
  /// The round running now, if any: leaving waits for it, so a round never writes while bots are taken off.
  Future<void>? _round;

  /// The account is leaving this phone: no round may start or write anything back.
  bool _leaving = false;
  String _uid = '';
  String _device = '';

  /// The last round's state, for the UI and for support. A sync never fails silently.
  final ValueNotifier<BotSyncState> status = ValueNotifier(BotSyncState.idle);

  /// Why the last round failed ('' when it did not).
  final ValueNotifier<String> lastError = ValueNotifier('');


  /// state: {owner, pulled, cur: {bots, mem, desk, jr}, b: {botId: {s, k, sc, m: {key: 1}, d: {id: hash}, jx: [ids]}}}
  Map<String, dynamic> _st = {};

  /// Whether the cloud runner (part B) is live. Until it is, the phone runs every routine itself.
  bool runnerLive = false;

  /// When the last round finished without a problem.
  DateTime? lastSync;

  /// Posts a message a bot wrote in the cloud into its chat (set by AppState).
  /// [id] is the same on every phone for the same cloud entry, so the chat gets it once.
  Future<void> Function(Bot b, String text, String id)? postToChat;

  /// A job the cloud could not do itself (it needs an app, the browser, the phone or an approval) and handed over:
  /// the phone runs the whole job now and tells the user the result (owner 2026-11-02: a bot does its scheduled work
  /// and notifies; it never leaves the user a "starting…" message to chase).
  void Function(Bot b, String instruction, String kind, String needs)? onHandoff;

  /// The handed-over jobs in a bot row's run_state that this phone has not taken yet; marks them taken.
  List<({String id, String instruction, String kind, String needs})> takeHandoffs(String botId, Map? runState) {
    final h = runState?['handoff'];
    if (h is! Map || h.isEmpty) return const [];
    final s = _bs(botId);
    final taken = ((s['ho'] ??= <dynamic>[]) as List);
    final out = <({String id, String instruction, String kind, String needs})>[];
    for (final e in h.entries) {
      final id = '${e.key}';
      final v = e.value;
      if (taken.contains(id) || v is! Map) continue;
      final at = DateTime.tryParse('${v['at'] ?? ''}');
      taken.add(id);
      // Older than a day: too late to be useful now.
      if (at != null && DateTime.now().toUtc().difference(at.toUtc()) > const Duration(hours: 24)) continue;
      final ins = '${v['do'] ?? ''}'.trim();
      out.add((id: id, instruction: ins, kind: '${v['kind'] ?? 'work'}', needs: '${v['needs'] ?? ''}'));
    }
    while (taken.length > 100) {
      taken.removeAt(0);
    }
    return out;
  }

  /// A message id made from a journal entry (UUID shaped).
  static String chatIdFor(String botId, String itemId) {
    final h = _h('bot-journal|$botId|$itemId');
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}';
  }

  static const _overlap = Duration(minutes: 2);
  static const _page = 500;

  static String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

  static String _h(String s) => md5.convert(utf8.encode(s)).toString();

  /// Keys sorted at every level: the account stores setups as jsonb, which reorders keys, so a hash of the
  /// stored setup must not depend on key order (otherwise every round re-applies the same row: SYNC-4).
  static Object? canon(Object? v) => v is Map
      ? {for (final k in (v.keys.map((e) => '$e').toList()..sort())) k: canon(v[k])}
      : v is List
          ? v.map(canon).toList()
          : v;

  /// The order-independent hash of a setup.
  static String setupHash(Map<String, dynamic> setup) => _h(jsonEncode(canon(setup)));

  /// What a pull does with an account row for a bot this phone has. [fresh]: never synced on this phone (a new
  /// install's own Chief, for one) — the account's version wins (SYNC-2). [localChanged]: edited here since the last
  /// round — this phone's version wins and is pushed. [seen]: this exact row was already taken — nothing to do.
  static bool takeRemote({required bool fresh, required bool localChanged, required bool seen, required bool differs}) =>
      !seen && differs && (fresh || !localChanged);

  /// Skills to send: the ones installed here, plus the account's that are still installing here, so a slow or failed
  /// download never wipes them from the account (SYNC-3).
  static List<String> skillsToSend(List<String> installed, List<String> pending) => {...installed, ...pending}.toList();

  // ---------------------------------------------------------------- what is sent

  static const _localOnly = ['mem', 'desk', 'j', 'day', 'mt', 'ct', 'ig', 'lo', 'lu', 'lw', 'td', 'tt'];

  /// The bot's setup as kept in the account: who it is, how it works, routines and follow-ups, powers, budgets and
  /// trust settings, lessons, apps (by name only). No memory, desk or journal (their own rows), no day counters.
  static Map<String, dynamic> setupOf(Bot b) {
    final j = b.toJson();
    for (final k in _localOnly) {
      j.remove(k);
    }
    for (final k in const ['persona', 'mission', 'ins', 'first']) {
      j[k] = BotPackage.scrubSecrets('${j[k] ?? ''}');
    }
    j['skills'] = SkillLibrary.I.of(b.id);
    // R2 item 3: which bot is the Chief belongs to the account too (it was only a setting on the phone).
    if (Bots.I.isChief(b)) j['chief'] = true;
    return j;
  }

  static List<Map<String, dynamic>> knowledgeOf(Bot b) => [for (final k in b.knowledge) k.toJson()];

  static String memKey(String line) => _h(line.trim().toLowerCase()).substring(0, 24);

  static String journalId(JournalEntry e) => _h('${e.at.toUtc().toIso8601String()}|${e.kind}|${e.text}').substring(0, 24);

  /// The jobs the cloud may run for this bot (no phone powers needed), with times the server can read.
  static List<Map<String, dynamic>> scheduleOf(Bot b) {
    final now = DateTime.now();
    return [
      for (final r in b.routines)
        if (!b.needsPhone(r.instruction, r.kind, local: r.local))
          {'id': r.id, 'type': 'routine', 'time': r.time, 'days': r.days, 'kind': r.kind, 'do': r.instruction,
            if (r.next(now) != null) 'next': r.next(now)!.toUtc().toIso8601String()},
      for (final f in b.followups)
        if (!b.needsPhone(f.instruction, f.kind, local: f.local))
          {'id': f.id, 'type': 'followup', 'at': f.at.toUtc().toIso8601String(), 'kind': f.kind, 'do': f.instruction},
      if (b.effectiveHeartbeat > 0)
        {'id': 'hb', 'type': 'heartbeat', 'every_hours': b.effectiveHeartbeat,
          if (Bots.I.nextHeartbeat(b) != null) 'next': Bots.I.nextHeartbeat(b)!.toUtc().toIso8601String()},
    ];
  }

  static DateTime? _nextRun(List<Map<String, dynamic>> jobs) {
    DateTime? best;
    for (final j in jobs) {
      final d = DateTime.tryParse('${j['next'] ?? j['at'] ?? ''}');
      if (d != null && (best == null || d.isBefore(best))) best = d;
    }
    return best;
  }

  // ---------------------------------------------------------------- state

  Map<String, dynamic> _bs(String id) {
    final b = (_st['b'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    return (b[id] ??= <String, dynamic>{'s': '', 'k': '', 'm': <String, dynamic>{}, 'd': <String, dynamic>{}, 'jx': <dynamic>[]})
        as Map<String, dynamic>;
  }

  /// Sync state written before setup hashes ignored key order: re-hash once, so an upgrade does not read every bot
  /// as changed here (and push over the account's newer version).
  void _migrate(Bot b, Map<String, dynamic> s) {
    if (s['v'] == 2) return;
    if ('${s['s']}'.isNotEmpty) s['s'] = setupHash(setupOf(b));
    s['v'] = 2;
  }

  /// Installs the account's skills this phone lacks, and remembers them as pending until they are in.
  void _installSkills(Bot b, Map<String, dynamic> setup) {
    final want = [for (final x in (setup['skills'] as List? ?? const [])) '$x'].where((x) => x.isNotEmpty).toList();
    final missing = want.where((x) => !SkillLibrary.I.of(b.id).contains(x)).toList();
    if (missing.isEmpty) return;
    _bs(b.id)['skp'] = {...[for (final x in (_bs(b.id)['skp'] as List? ?? const [])) '$x'], ...missing}.toList();
    for (final sk in missing) {
      unawaited(SkillLibrary.I.install(b.id, sk).catchError((_) => null));
    }
  }

  Map<String, dynamic> get _cur => (_st['cur'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  Future<void> _load() async {
    _p ??= await SharedPreferences.getInstance();
    _device = _p!.getString('bot_sync_device') ?? '';
    if (_device.isEmpty) {
      final r = Random.secure();
      _device = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await _p!.setString('bot_sync_device', _device);
    }
    try {
      _st = Map<String, dynamic>.from(jsonDecode(_p!.getString('bot_sync_v1') ?? '{}') as Map);
    } catch (_) {
      _st = {};
    }
    runnerLive = _p!.getBool('bot_cloud_runner') ?? false;
  }

  Future<void> _saveState() async => _p?.setString('bot_sync_v1', jsonEncode(_st));

  // ---------------------------------------------------------------- lifecycle

  /// After sign-in: wire up, then a first round (a new phone gets its bots back here).
  Future<void> start() async {
    final uid = _authUid;
    if (uid == null || uid.isEmpty) return;
    await _load();
    for (var i = 0; i < 40 && !Bots.I.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!Bots.I.ready) return;
    final owner = '${_st['owner'] ?? ''}';
    if (owner.isNotEmpty && owner != uid) {
      // Another account used this phone before (its session ended without a sign-out). Its bots are put away under
      // that account (hidden, see [_stash]) and this account never sees them or sends them up as its own.
      await _takeOff(stashFor: owner);
    }
    _leaving = false;
    // R2 item 3: this account signed out on this phone earlier: its bots, teams and their sync state come back
    // exactly as they were, before the account is asked (they were never in the account until the sync fix).
    if (owner != uid) await _unstash(uid);
    _st['owner'] = uid;
    _uid = uid;
    await _saveState();
    Bots.I.onChanged = changed;
    Bots.I.cloudOwns = cloudOwns;
    // Owner (2026-10-31): every account is delivered the built-in Chief with the app. The first account gets it from
    // Bots.init(); a new account (or one whose seed was device-only) gets it here — unless the owner removed the Chief
    // in THIS account. The gate is per-account (this phone's stash for the account), not the device-wide seeded flag.
    Bots.I.onChiefRemoved = () {
      _st['chiefRemoved'] = true;
      unawaited(_saveState());
    };
    if (Bots.I.chief == null && _st['chiefRemoved'] != true) {
      await Bots.I.ensureChief();
    }
    await syncNow();
  }

  /// The account's session ended on this phone (sign-out, or the account was deleted): its bots go with it.
  /// Anything still waiting is sent first, while the session is still that account's, so a sign-out on a
  /// connection loses nothing; signing back in brings every bot back from the account.
  ///
  /// R2 item 3: a sign-out ([send] true) also keeps the account's bots and teams on this phone under that account
  /// (hidden from every other account), so signing back in brings them back even when the account copy is behind.
  /// Deleting the account ([send] false) keeps nothing.
  Future<void> leave({bool send = true}) async {
    if (_p == null) await _load();
    final owner = '${_st['owner'] ?? ''}'.isNotEmpty ? '${_st['owner']}' : (send ? (_authUid ?? '') : '');
    if (send && owner.isNotEmpty && _authUid == owner) await flush();
    await _takeOff(stashFor: send ? owner : '');
  }

  // ---------------------------------------------------------------- per-account keep (sign-out / sign-in)

  static const _stashKey = 'bot_acct_stash_v1';

  /// Accounts kept on this phone at most (the oldest goes first).
  static const maxStashed = 5;

  Map<String, dynamic> _stashes() {
    try {
      return Map<String, dynamic>.from(jsonDecode(_p?.getString(_stashKey) ?? '{}') as Map);
    } catch (_) {
      return {};
    }
  }

  /// Puts this account's bots, their knowledge and skills, the Chief, the teams and the sync state away under [uid].
  Future<void> _stash(String uid) async {
    if (uid.isEmpty || _p == null) return;
    final bots = Bots.I.bots;
    if (bots.isEmpty && Offices.I.offices.isEmpty) return;
    final all = _stashes()..remove(uid);
    all[uid] = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'bots': Bots.I.snapshot(),
      'skills': {for (final b in bots) if (SkillLibrary.I.of(b.id).isNotEmpty) b.id: SkillLibrary.I.of(b.id)},
      'teams': Offices.I.snapshot(),
      'sync': _st,
    };
    while (all.length > maxStashed) {
      final oldest = all.entries.reduce((a, b) => '${(a.value as Map)['at']}'.compareTo('${(b.value as Map)['at']}') <= 0 ? a : b).key;
      all.remove(oldest);
    }
    await _p!.setString(_stashKey, jsonEncode(all));
  }

  /// Brings back what [_stash] kept for [uid] (only for that account), then forgets the kept copy.
  Future<bool> _unstash(String uid) async {
    final all = _stashes();
    final k = all.remove(uid);
    if (k is! Map) return false;
    try {
      final m = Map<String, dynamic>.from(k);
      await Bots.I.adopt(Map<String, dynamic>.from((m['bots'] as Map?) ?? const {}));
      final sk = Map<String, dynamic>.from((m['skills'] as Map?) ?? const {});
      for (final e in sk.entries) {
        SkillLibrary.I.adopt(e.key, [for (final x in (e.value as List)) '$x']);
      }
      await Offices.I.adopt(Map<String, dynamic>.from((m['teams'] as Map?) ?? const {}));
      final st = m['sync'];
      if (st is Map && '${_st['owner'] ?? ''}'.isEmpty) _st = Map<String, dynamic>.from(st);
    } catch (e) {
      debugPrint('bot sync: could not restore kept bots: $e');
    }
    await _p?.setString(_stashKey, jsonEncode(all));
    return true;
  }

  /// Tests: is anything kept on this phone for [uid]?
  @visibleForTesting
  bool hasKeptFor(String uid) => _stashes().containsKey(uid);

  /// Takes every bot and team off this phone and forgets which account they belonged to. Sends nothing.
  /// [stashFor]: the account they belong to; they are kept under it first (see [_stash]).
  Future<void> _takeOff({String stashFor = ''}) async {
    _leaving = true;
    _timer?.cancel();
    _timer = null;
    // A round still running (a slow flush that timed out) must end before any bot comes off, or its push would read
    // the removed bots as deleted and wipe them from the account (SYNC-1).
    try {
      await _round?.timeout(const Duration(seconds: 30));
    } catch (_) {}
    if (stashFor.isNotEmpty) await _stash(stashFor);
    _uid = '';
    // Nothing may schedule a round while they are being removed.
    Bots.I.onChanged = null;
    Bots.I.cloudOwns = null;
    // Taking the Chief off the phone at sign-out is not the owner removing it: it must not mark the account's Chief
    // as removed (that flag would stop the Chief coming back for this account).
    Bots.I.onChiefRemoved = null;
    // Teams first: a team is a group of bots, and its alarms point at them.
    for (final o in List.of(Offices.I.offices)) {
      try {
        await Offices.I.remove(o);
      } catch (e) {
        debugPrint('bot sync: could not stop team ${o.id}: $e');
      }
    }
    Offices.I.offices.clear();
    Offices.I.queue.clear();
    Offices.I.clearApprovals();
    try {
      await Offices.I.save();
    } catch (_) {}
    for (final b in List.of(Bots.I.bots)) {
      try {
        await Bots.I.remove(b);
      } catch (e) {
        debugPrint('bot sync: could not remove bot ${b.id}: $e');
      }
    }
    // A bot whose alarm could not be cancelled is still that account's bot: it must not stay either.
    Bots.I.bots.clear();
    try {
      await Bots.I.save();
    } catch (_) {}
    _st = {};
    await _saveState();
    status.value = BotSyncState.idle;
    lastError.value = '';
  }

  /// Tests: forget everything held in memory, as a fresh app start would. The cached [SharedPreferences] goes too:
  /// `setMockInitialValues` makes a new store, and a kept reference would still read the last test's stash and
  /// sync state (that is how one test's account leaked its bots into the next, bots_restore 7 & 8).
  @visibleForTesting
  void debugReset() {
    stop();
    _p = null;
    _st = {};
    _round = null;
    _leaving = false;
    Bots.I.onChiefRemoved = null;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _uid = '';
    status.value = BotSyncState.idle;
    lastError.value = '';
    Bots.I.onChanged = null;
    Bots.I.cloudOwns = null;
  }

  /// A bot changed: send it in a few seconds (changes close together go as one round).
  void changed() {
    if (_uid.isEmpty || _leaving) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 6), () => unawaited(syncNow()));
  }

  /// The app came back to the screen (maybe from a push): pick up what the cloud did, soon.
  void resumed() {
    if (_uid.isEmpty || _leaving) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () => unawaited(syncNow()));
  }

  /// Sends what is waiting now (before sign-out).
  Future<void> flush() async {
    if (_uid.isEmpty) return;
    _timer?.cancel();
    // A round already running has to finish, or the changes it carries go with the bots.
    for (var i = 0; i < 16 && _busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (_busy) return;
    try {
      await syncNow().timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// The cloud runs this job (part B is live, the bot works in the cloud, the job needs no phone power), so the
  /// phone does not set its own alarm for it.
  bool cloudOwns(Bot b, String job) {
    if (!runnerLive || _uid.isEmpty || !b.active || !b.cloudOn) return false;
    final s = (_st['b'] as Map?)?[b.id] as Map?;
    if (s == null || '${s['s']}'.isEmpty) return false;
    // Only jobs the account already has (the last schedule sent, with the cloud switch on): a job made while
    // offline keeps its phone alarm until it has been sent, so nothing is lost in between.
    try {
      final sent = jsonDecode('${s['sc'] ?? ''}');
      if (sent is! List || sent.length < 2 || sent[0] != true || sent[1] is! List) return false;
      if (!(sent[1] as List).any((j) => j is Map && '${j['id']}' == job)) return false;
    } catch (_) {
      return false;
    }
    if (job == 'hb') return b.effectiveHeartbeat > 0;
    final r = b.routines.where((x) => x.id == job).firstOrNull;
    if (r != null) return !b.needsPhone(r.instruction, r.kind, local: r.local);
    final f = b.followups.where((x) => x.id == job).firstOrNull;
    if (f != null) return !b.needsPhone(f.instruction, f.kind, local: f.local);
    return false;
  }

  Future<bool> syncNow() async {
    if (_leaving) return false;
    if (_uid.isEmpty || _authUid != _uid) return false;
    if (_busy) {
      _again = true;
      return false;
    }
    _busy = true;
    final round = Completer<void>();
    _round = round.future;
    var ok = true;
    status.value = BotSyncState.syncing;
    try {
      await _info();
      final pulled = await _pull();
      final sent = await _push();
      if (pulled || sent) {
        await Bots.I.save();
        await Bots.I.armAll();
      }
      lastSync = DateTime.now();
      lastError.value = '';
    } catch (e) {
      ok = false;
      lastError.value = '$e';
      debugPrint('bot sync: $e');
    } finally {
      // The account left while this round ran: its state is already gone, do not write it back.
      if (!_leaving) await _saveState();
      _busy = false;
      round.complete();
    }
    if (_leaving) return ok;
    status.value = ok ? BotSyncState.ok : BotSyncState.failed;
    if (_again) {
      _again = false;
      changed();
    }
    return ok;
  }

  Future<void> _info() async {
    try {
      final r = await _c.rpc('bot_cloud_info');
      final live = r is Map && r['runner'] == true;
      if (live != runnerLive) {
        runnerLive = live;
        await _p?.setBool('bot_cloud_runner', live);
        await Bots.I.armAll();
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------- down

  Future<List<Map<String, dynamic>>> _rows(String table, String cols, String curKey) async {
    final since = DateTime.tryParse('${_cur[curKey] ?? ''}');
    final out = <Map<String, dynamic>>[];
    // Paged by time, not by offset: a row changed between pages moves to the end instead of shifting every row after
    // it back one place (which skipped a row for good: SYNC-7). Rows sharing the page's last time are skipped by count.
    String? after = since?.subtract(_overlap).toUtc().toIso8601String();
    var skip = 0;
    while (true) {
      var q = _c.from(table).select(cols);
      if (after != null) q = q.gte('updated_at', after);
      final rows = [for (final e in await q.order('updated_at', ascending: true).range(skip, skip + _page - 1)) Map<String, dynamic>.from(e)];
      out.addAll(rows);
      if (rows.length < _page) break;
      final last = '${rows.last['updated_at']}';
      final same = rows.where((r) => '${r['updated_at']}' == last).length;
      skip = last == after ? skip + same : same;
      after = last;
    }
    return out;
  }

  void _advance(String curKey, List<Map<String, dynamic>> rows) {
    for (final r in rows) {
      final t = DateTime.tryParse('${r['updated_at']}');
      final c = DateTime.tryParse('${_cur[curKey] ?? ''}');
      if (t != null && (c == null || t.isAfter(c))) _cur[curKey] = t.toUtc().toIso8601String();
    }
  }

  /// Is this row this phone's own echo? (Skipped, except on the very first pull, e.g. after a reinstall.)
  bool _echo(Map<String, dynamic> r, bool first) => !first && r['device_id'] == _device;

  /// Returns true when anything on the phone changed.
  Future<bool> _pull() async {
    final first = _st['pulled'] != true;
    var touched = false;
    // Bots this pull creates: their memory, desk and journal rows are fetched whole, since the cursors may already
    // be past rows written before the bot row reached this phone (SYNC-6).
    final created = <String>[];

    // Bots (setup, cloud bookkeeping). Knowledge is fetched only for the bots whose knowledge changed.
    final rows = await _rows('cloud_bots',
        'bot_id,setup,knowledge_hash,deleted,run_state,last_run_at,device_id,updated_at', 'bots');
    final needKnowledge = <String>[];
    // The bot the account names as the Chief (setup `chief: true`).
    String? chiefInAccount;
    for (final r in rows) {
      final id = '${r['bot_id']}';
      var b = Bots.I.byId(id);
      final known = (_st['b'] as Map?)?.containsKey(id) ?? false;
      if (r['deleted'] == true) {
        if (b != null && (known || first)) {
          await Bots.I.remove(b);
          touched = true;
        }
        (_st['b'] as Map?)?.remove(id);
        continue;
      }
      final setup = Map<String, dynamic>.from((r['setup'] as Map?) ?? const {});
      if (setup['chief'] == true) chiefInAccount = id;
      if (!_echo(r, first) && setup.isNotEmpty) {
        final s = _bs(id);
        final rh = setupHash(setup);
        if (b == null) {
          if (!known) {
            b = Bot.fromJson({...setup, 'id': id});
            Bots.I.bots.add(b);
            created.add(id);
            _installSkills(b, setup);
            s['s'] = setupHash(setupOf(b));
            s['rs'] = rh;
            touched = true;
          }
        } else {
          _migrate(b, s);
          final localH = setupHash(setupOf(b));
          if (takeRemote(fresh: '${s['s']}'.isEmpty, localChanged: s['s'] != localH, seen: s['rs'] == rh, differs: rh != localH)) {
            // Unchanged here since the last round (or never synced here): take the account's version.
            b.applySetup(setup);
            _installSkills(b, setup);
            s['s'] = setupHash(setupOf(b));
            touched = true;
          }
          s['rs'] = rh;
        }
        if (b != null && '${r['knowledge_hash'] ?? ''}' != '${s['k']}' && (s['k'] == '' || s['k'] == _h(jsonEncode(knowledgeOf(b))))) {
          needKnowledge.add(id);
        }
      }
      // What the cloud did (part B): follow-ups it already ran, when it last worked.
      if (b != null) {
        final done = ((r['run_state'] as Map?)?['done'] as Map?) ?? const {};
        final handed = takeHandoffs(b.id, r['run_state'] as Map?);
        if (handed.isNotEmpty) touched = true;
        for (final x in handed) {
          onHandoff?.call(b, x.instruction, x.kind, x.needs);
        }
        final before = b.followups.length;
        b.followups.removeWhere((f) => done.containsKey(f.id));
        final last = DateTime.tryParse('${r['last_run_at'] ?? ''}')?.toLocal();
        if (last != null && (b.lastWake == null || last.isAfter(b.lastWake!))) b.lastWake = last;
        if (b.followups.length != before) touched = true;
      }
    }
    _advance('bots', rows);
    // A phone that has no Chief (signed back in, a new phone) takes the account's.
    if (chiefInAccount != null && Bots.I.chief == null && Bots.I.byId(chiefInAccount) != null) {
      await Bots.I.adoptChief(chiefInAccount);
      touched = true;
    }
    for (final id in needKnowledge) {
      final b = Bots.I.byId(id);
      if (b == null) continue;
      final k = await _c.from('cloud_bots').select('knowledge,knowledge_hash').eq('bot_id', id).maybeSingle();
      if (k == null) continue;
      b.knowledge
        ..clear()
        ..addAll([
          for (final e in (k['knowledge'] as List? ?? const []))
            BotKnowledge.fromJson(Map<String, dynamic>.from(e as Map))
        ].where((e) => e.text.trim().isNotEmpty));
      await Bots.I.saveKnowledge(b);
      _bs(id)['k'] = _h(jsonEncode(knowledgeOf(b)));
      touched = true;
    }

    Future<List<Map<String, dynamic>>> whole(String table, String cols) async => [
          for (final id in created)
            ...(await _c.from(table).select(cols).eq('bot_id', id)).map((e) => Map<String, dynamic>.from(e)),
        ];

    // Memory lines.
    const memCols = 'bot_id,item_id,data,deleted,device_id,updated_at';
    final mem = await _rows('cloud_bot_memory', memCols, 'mem');
    for (final r in [...await whole('cloud_bot_memory', memCols), ...mem]) {
      if (_echo(r, first)) continue;
      final b = Bots.I.byId('${r['bot_id']}');
      if (b == null) continue;
      final m = (_bs(b.id)['m'] as Map);
      final key = '${r['item_id']}';
      final text = '${(r['data'] as Map?)?['t'] ?? ''}'.trim();
      final here = b.memory.indexWhere((l) => memKey(l) == key);
      if (r['deleted'] == true) {
        if (here >= 0) {
          b.memory.removeAt(here);
          touched = true;
        }
        m.remove(key);
      } else if (here < 0 && !m.containsKey(key) && text.isNotEmpty) {
        b.memory.add(text);
        while (b.memory.length > 150) {
          b.memory.removeAt(0);
        }
        m[key] = 1;
        touched = true;
      } else if (here >= 0) {
        m[key] = 1;
      }
    }
    _advance('mem', mem);

    // Desk tasks.
    final desk = await _rows('cloud_bot_desk', memCols, 'desk');
    for (final r in [...await whole('cloud_bot_desk', memCols), ...desk]) {
      if (_echo(r, first)) continue;
      final b = Bots.I.byId('${r['bot_id']}');
      if (b == null) continue;
      final d = (_bs(b.id)['d'] as Map);
      final id = '${r['item_id']}';
      final i = b.desk.indexWhere((t) => t.id == id);
      final mine = i >= 0 ? _h(jsonEncode(b.desk[i].toJson())) : null;
      final unchangedHere = mine == null ? !d.containsKey(id) : mine == d[id];
      if (r['deleted'] == true) {
        if (i >= 0 && unchangedHere) {
          b.desk.removeAt(i);
          touched = true;
        }
        if (unchangedHere) d.remove(id);
        continue;
      }
      if (!unchangedHere) continue; // changed here too: this phone's version wins
      final t = DeskTask.fromJson(Map<String, dynamic>.from((r['data'] as Map?) ?? const {}));
      if (t.id != id || t.text.trim().isEmpty) continue;
      final theirs = _h(jsonEncode(t.toJson()));
      if (theirs == mine) continue;
      if (i >= 0) {
        b.desk[i] = t;
      } else {
        b.desk.add(t);
      }
      d[id] = _h(jsonEncode(t.toJson()));
      touched = true;
    }
    _advance('desk', desk);

    // Journal: entries from the cloud (and other phones) join the journal; a cloud run's message goes in the chat.
    const jrCols = 'bot_id,item_id,at,kind,text,chat,origin,device_id,updated_at';
    final jr = await _rows('cloud_bot_journal', jrCols, 'jr');
    for (final r in [...await whole('cloud_bot_journal', jrCols), ...jr]) {
      if (_echo(r, first)) continue;
      final b = Bots.I.byId('${r['bot_id']}');
      if (b == null) continue;
      final jx = (_bs(b.id)['jx'] as List);
      final rid = '${r['item_id']}';
      if (jx.contains(rid)) continue;
      final e = JournalEntry(DateTime.tryParse('${r['at']}')?.toLocal() ?? DateTime.now(), '${r['kind'] ?? 'note'}', '${r['text'] ?? ''}');
      final lid = journalId(e);
      jx.add(rid);
      if (lid != rid) jx.add(lid);
      if (!b.journal.any((x) => journalId(x) == lid)) {
        b.journal.add(e);
        b.journal.sort((x, y) => x.at.compareTo(y.at));
        while (b.journal.length > 200) {
          b.journal.removeAt(0);
        }
        touched = true;
      }
      final chat = '${r['chat'] ?? ''}'.trim();
      // On the very first pull (a new phone) the chat already has these messages from the account backup.
      if (!first && r['origin'] == 'cloud' && chat.isNotEmpty && b.convId.isNotEmpty) {
        try {
          await postToChat?.call(b, chat, chatIdFor(b.id, rid));
        } catch (_) {}
      }
      while (jx.length > 450) {
        jx.removeAt(0);
      }
    }
    _advance('jr', jr);
    _st['pulled'] = true;
    return touched;
  }

  // ---------------------------------------------------------------- up

  /// R2 item 3 (root cause): writes rows without ever updating a key column. The account lets the app insert
  /// `bot_id`/`item_id` but update only the other columns (column grants in 20261019_bot_cloud.sql), and a PostgREST
  /// upsert updates EVERY column it sends (`ON CONFLICT … DO UPDATE SET bot_id = EXCLUDED.bot_id, …`), so every
  /// upsert failed with 42501 "permission denied for table cloud_bots" and no bot ever reached the account.
  /// New rows are inserted with ON CONFLICT DO NOTHING (insert rights only); rows that already exist are updated by
  /// their keys with the non-key columns only.
  Future<void> _write(String table, List<Map<String, dynamic>> rows, List<String> keys) async {
    String keyOf(Map r) => [for (final k in keys) '${r[k]}'].join('|');
    for (var i = 0; i < rows.length; i += 200) {
      final chunk = rows.sublist(i, min(i + 200, rows.length));
      final inserted = await _c
          .from(table)
          .upsert(chunk, onConflict: ['user_id', ...keys].join(','), ignoreDuplicates: true)
          .select(keys.join(','));
      final got = {for (final r in inserted) keyOf(r)};
      for (final r in chunk) {
        if (got.contains(keyOf(r))) continue;
        var q = _c.from(table).update({for (final e in r.entries) if (!keys.contains(e.key) && e.key != 'user_id') e.key: e.value});
        for (final k in keys) {
          q = q.eq(k, r[k] as Object);
        }
        await q;
      }
    }
  }

  /// Returns true when a bot's schedule or cloud switch was sent (its alarms may change hands).
  Future<bool> _push() async {
    var sentSchedule = false;
    final mineIds = {for (final b in Bots.I.bots) b.id};

    // Bots removed on this phone: a tombstone row, and their lines go.
    for (final id in [...((_st['b'] ?? const {}) as Map).keys.map((e) => '$e')]) {
      // Signing out takes the bots off this phone, which is not removing them from the account (SYNC-1).
      if (_leaving) return sentSchedule;
      if (mineIds.contains(id)) continue;
      await _write('cloud_bots', [
        {
          'bot_id': id, 'name': '', 'setup': <String, dynamic>{}, 'knowledge': <dynamic>[], 'knowledge_hash': '',
          'schedule': <dynamic>[], 'cloud_enabled': false, 'next_run_at': null, 'deleted': true,
          'device_id': _device, 'origin': 'phone',
        }
      ], const ['bot_id']);
      for (final t in const ['cloud_bot_memory', 'cloud_bot_desk', 'cloud_bot_journal']) {
        await _c.from(t).delete().eq('bot_id', id);
      }
      (_st['b'] as Map).remove(id);
      await _saveState();
    }

    final offset = DateTime.now().timeZoneOffset.inMinutes;
    for (final b in List.of(Bots.I.bots)) {
      if (_leaving) return sentSchedule;
      final s = _bs(b.id);
      _migrate(b, s);
      final setup = setupOf(b);
      final sh = setupHash(setup);
      // Pending installs: drop the ones now installed, send the rest along.
      final pending = [for (final x in (s['skp'] as List? ?? const [])) '$x'].where((x) => !SkillLibrary.I.of(b.id).contains(x)).toList();
      if (pending.isEmpty) {
        s.remove('skp');
      } else {
        s['skp'] = pending;
      }
      setup['skills'] = skillsToSend(SkillLibrary.I.of(b.id), pending);
      final kn = knowledgeOf(b);
      final kh = _h(jsonEncode(kn));
      final jobs = scheduleOf(b);
      final on = b.active && b.cloudOn;
      final sched = jsonEncode([on, jobs, offset]);
      if (sh != s['s'] || kh != s['k'] || sched != s['sc']) {
        try {
        await _write('cloud_bots', [{
          'bot_id': b.id,
          'name': b.name.length > 120 ? b.name.substring(0, 120) : b.name,
          'setup': setup,
          if (kh != s['k']) 'knowledge': kn,
          'knowledge_hash': kh,
          'cloud_enabled': on,
          'schedule': jobs,
          'tz_name': DateTime.now().timeZoneName.length > 64 ? '' : DateTime.now().timeZoneName,
          'tz_offset_min': offset.clamp(-900, 900),
          'next_run_at': on ? _nextRun(jobs)?.toIso8601String() : null,
          'deleted': false,
          'device_id': _device,
          'origin': 'phone',
        }], const ['bot_id']);
        } on PostgrestException catch (e) {
          // The server refuses to bring back a removed bot (SYNC-5): it was removed on another phone, so it goes here too.
          if (e.code != '23514') rethrow;
          await Bots.I.remove(b);
          (_st['b'] as Map?)?.remove(b.id);
          await _saveState();
          continue;
        }
        if (sched != s['sc']) sentSchedule = true;
        s['s'] = sh;
        s['rs'] = setupHash(setup);
        s['k'] = kh;
        s['sc'] = sched;
      }

      // Memory: one row per line; a line gone from the phone becomes a tombstone.
      final m = s['m'] as Map;
      // A line that holds something like a key or password stays on this phone.
      final now = {for (final l in b.memory) if (BotPackage.scrubSecrets(l) == l) memKey(l): l};
      final add = [
        for (final e in now.entries)
          if (!m.containsKey(e.key))
            {'bot_id': b.id, 'item_id': e.key, 'data': {'t': e.value}, 'deleted': false, 'device_id': _device, 'origin': 'phone'}
      ];
      final gone = [for (final k in m.keys.map((e) => '$e')) if (!now.containsKey(k)) k];
      final memRows = [
        ...add,
        for (final k in gone) {'bot_id': b.id, 'item_id': k, 'data': <String, dynamic>{}, 'deleted': true, 'device_id': _device, 'origin': 'phone'},
      ];
      await _write('cloud_bot_memory', memRows, const ['bot_id', 'item_id']);
      for (final r in add) {
        m[r['item_id']] = 1;
      }
      for (final k in gone) {
        m.remove(k);
      }

      // Desk: one row per task, changed ones only; a task gone from the phone becomes a tombstone.
      final d = s['d'] as Map;
      final tasks = {for (final t in b.desk) t.id: t};
      final deskRows = <Map<String, dynamic>>[];
      final hashes = <String, String>{};
      for (final t in tasks.values) {
        final h = _h(jsonEncode(t.toJson()));
        if (d[t.id] == h) continue;
        hashes[t.id] = h;
        final data = t.toJson()
          ..['t'] = BotPackage.scrubSecrets(t.text)
          ..['n'] = BotPackage.scrubSecrets(t.note);
        deskRows.add({'bot_id': b.id, 'item_id': t.id, 'data': data, 'deleted': false, 'device_id': _device, 'origin': 'phone'});
      }
      final deskGone = [for (final k in d.keys.map((e) => '$e')) if (!tasks.containsKey(k)) k];
      for (final k in deskGone) {
        deskRows.add({'bot_id': b.id, 'item_id': k, 'data': <String, dynamic>{}, 'deleted': true, 'device_id': _device, 'origin': 'phone'});
      }
      await _write('cloud_bot_desk', deskRows, const ['bot_id', 'item_id']);
      d.addAll(hashes);
      for (final k in deskGone) {
        d.remove(k);
      }

      // Journal: append what the account has not seen.
      final jx = s['jx'] as List;
      final jrRows = <Map<String, dynamic>>[];
      for (final e in b.journal) {
        final id = journalId(e);
        if (jx.contains(id)) continue;
        jrRows.add({
          'bot_id': b.id, 'item_id': id, 'at': e.at.toUtc().toIso8601String(),
          'kind': const {'work', 'note', 'message', 'call', 'missed', 'learned'}.contains(e.kind) ? e.kind : 'note',
          'text': _cut(BotPackage.scrubSecrets(e.text), 2000),
          'device_id': _device, 'origin': 'phone',
        });
      }
      for (var i = 0; i < jrRows.length; i += 200) {
        await _c.from('cloud_bot_journal').upsert(jrRows.sublist(i, min(i + 200, jrRows.length)),
            onConflict: 'user_id,bot_id,item_id', ignoreDuplicates: true);
      }
      for (final r in jrRows) {
        jx.add(r['item_id']);
      }
      while (jx.length > 450) {
        jx.removeAt(0);
      }
      await _saveState();
    }
    return sentSchedule;
  }
}
