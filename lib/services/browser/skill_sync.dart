import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'playbook.dart';
import 'site_skills.dart';

/// Site skills follow the account: a flow learned on one phone replays on another (and comes back after a
/// reinstall). Table and merge rules: supabase/migrations/20261031_browser_skill_sync.sql.
///
/// - Up: a few seconds after a skill is saved, replayed (its run/win count) or forgotten. Only what changed
///   since the last round, and only the rows this phone knows about — a phone that has just claimed the
///   folder sends nothing it did not record, so restoring never wipes the account.
/// - Down: on sign-in and whenever the app comes back to the screen: rows the account holds that this phone
///   does not have, or has an older copy of. A tombstone removes the skill here too.
/// - Merge (in the database, one statement): run and win counts only ever grow, so the same phone can send
///   the same skill every round without inflating them; the newest recording wins the steps; a removal wins
///   over anything older. A push returns the merged row, so a phone that was behind catches up at once.
/// - Whose skills: the folder belongs to the account that claimed it ([SiteSkills.claim]). Another account
///   signing in sets it aside and starts clean, so one account's flows are never uploaded as another's.
/// - Never sent: passwords. A saved playbook cannot contain a password field at all
///   ([compressSteps] drops them); the login is offered to the person at replay time instead.
class SkillSync {
  SkillSync._();
  static final SkillSync I = SkillSync._();

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

  /// A row the account already holds is being written here: that is not a change to send back.
  bool _applying = false;

  String _uid = '';
  String _device = '';

  /// state: {owner, sent: {skillId: utc iso of the last `at` this phone wrote up}}
  Map<String, dynamic> _st = {};

  /// Rows read per round. An account keeps at most 200 skills (the database refuses more), so one round
  /// always sees the whole account.
  static const _page = 1000;

  /// Why the last round failed ('' when it did not). A sync never fails in silence.
  final ValueNotifier<String> lastError = ValueNotifier('');

  /// When the last round finished without a problem.
  DateTime? lastSync;

  Map<String, dynamic> get _sent => (_st['sent'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  // ---------------------------------------------------------------- times

  /// A time as the account keeps it (UTC), or null when it cannot be read.
  static DateTime? when(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty ? null : DateTime.tryParse(s)?.toUtc();
  }

  static String _iso(DateTime d) => d.toUtc().toIso8601String();

  /// A time as this phone writes it into a playbook file (local, no offset — what [SiteSkills.save] writes),
  /// so the files stay in one format and still sort together.
  static String _localIso(Object? v) => (when(v) ?? DateTime.now()).toLocal().toIso8601String();

  /// A playbook from a row of the account (null when it holds no steps: nothing to replay).
  static Playbook? playbookOf(Map<String, dynamic> m) {
    final id = '${m['skill_id'] ?? ''}'.trim();
    final steps = [
      for (final s in (m['steps'] as List? ?? const []))
        if (s is Map) PlayStep.fromJson(s),
    ].whereType<PlayStep>().toList();
    if (id.isEmpty || steps.isEmpty) return null;
    return Playbook(
      id: id,
      name: '${m['name'] ?? ''}'.trim().isEmpty ? id : '${m['name']}'.trim(),
      site: '${m['site'] ?? ''}',
      goal: '${m['goal'] ?? ''}',
      steps: steps,
      runs: (m['runs'] as num?)?.toInt() ?? 0,
      wins: (m['wins'] as num?)?.toInt() ?? 0,
      at: _localIso(m['at']),
    );
  }

  // ---------------------------------------------------------------- state

  Future<void> _load() async {
    _p ??= await SharedPreferences.getInstance();
    _device = _p!.getString('browser_skill_device') ?? '';
    if (_device.isEmpty) {
      final r = Random.secure();
      _device = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await _p!.setString('browser_skill_device', _device);
    }
    try {
      _st = Map<String, dynamic>.from(jsonDecode(_p!.getString('browser_skill_sync_v1') ?? '{}') as Map);
    } catch (_) {
      _st = {};
    }
  }

  Future<void> _saveState() async => _p?.setString('browser_skill_sync_v1', jsonEncode(_st));

  /// Tests: forget everything this session held (the singleton outlives a test).
  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _p = null;
    _st = {};
    _uid = '';
    _device = '';
    _busy = false;
    _again = false;
    _applying = false;
    lastSync = null;
    lastError.value = '';
    SiteSkills.I.onChanged = null;
  }

  // ---------------------------------------------------------------- lifecycle

  /// After sign-in: claim this phone's skills for the account, then a first round (a new phone gets them
  /// back here). Sends nothing when the folder belongs to another account.
  Future<void> start() async {
    final uid = _authUid;
    if (uid == null || uid.isEmpty) return;
    await _load();
    if (!await SiteSkills.I.claim(uid)) {
      debugPrint('skill sync: the skills on this phone belong to another account');
      return;
    }
    if ('${_st['owner'] ?? ''}' != uid) {
      _st = {'owner': uid, 'sent': <String, dynamic>{}};
      await _saveState();
    }
    _uid = uid;
    SiteSkills.I.onChanged = changed;
    await syncNow();
  }

  /// A skill changed here: send it in a few seconds (changes close together go as one round).
  void changed() {
    if (_uid.isEmpty || _applying) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 6), () => unawaited(syncNow()));
  }

  /// The app came back to the screen: pick up what another phone did, soon.
  void resumed() {
    if (_uid.isEmpty) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () => unawaited(syncNow()));
  }

  /// Sends what is waiting now (before sign-out).
  Future<void> flush() async {
    if (_uid.isEmpty) return;
    _timer?.cancel();
    // A round already running has to finish, or the changes it carries go with the session.
    for (var i = 0; i < 16 && _busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (_busy) return;
    try {
      await syncNow().timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// The account's session ended on this phone: stop. The skills stay (they are the account's own folder,
  /// set aside the moment another account claims it).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _uid = '';
    lastSync = null;
    lastError.value = '';
    SiteSkills.I.onChanged = null;
  }

  Future<bool> syncNow() async {
    if (_uid.isEmpty || _authUid != _uid) return false;
    if (_busy) {
      _again = true;
      return false;
    }
    _busy = true;
    var ok = true;
    try {
      debugPrint('skill sync: DIAG client=${debugClient != null} uid=$_uid auth=${_authUid}');
      final rows = await _pull();
      debugPrint('skill sync: DIAG pulled ${rows.length}');
      await _apply(rows);
      debugPrint('skill sync: DIAG applied');
      await _push(rows);
      debugPrint('skill sync: DIAG pushed');
      lastSync = DateTime.now();
      lastError.value = '';
    } catch (e, st) {
      ok = false;
      lastError.value = '$e';
      debugPrint('skill sync: $e');
      debugPrint('skill sync trace: ${st.toString().split('\n').take(14).join(' | ')}');
    } finally {
      await _saveState();
      _busy = false;
    }
    if (_again) {
      _again = false;
      changed();
    }
    return ok;
  }

  // ---------------------------------------------------------------- down

  Future<List<Map<String, dynamic>>> _pull() async {
    final data = await _c
        .from('cloud_browser_skills')
        .select('skill_id, name, site, goal, steps, runs, wins, at, deleted')
        .order('updated_at')
        .limit(_page);
    return [for (final r in data) Map<String, dynamic>.from(r)];
  }

  /// Writes what the account holds that is newer than this phone's copy, and drops what it removed.
  Future<void> _apply(List<Map<String, dynamic>> rows) async {
    final here = await SiteSkills.I.all();
    final local = {for (final p in here) p.id: p};
    _applying = true;
    try {
      for (final m in rows) {
        final raw = '${m['skill_id'] ?? ''}'.trim();
        if (raw.isEmpty) continue;
        final key = playbookId(raw);
        final remoteAt = when(m['at']);
        final l = local[key];
        final localAt = l == null ? null : when(l.at);
        if (m['deleted'] == true) {
          if (l == null) {
            _sent.remove(key);
            continue;
          }
          // An older tombstone never removes a skill recorded here after it.
          if (localAt != null && remoteAt != null && remoteAt.isBefore(localAt)) continue;
          await SiteSkills.I.forget(key, notify: false);
          local.remove(key);
          _sent.remove(key);
          continue;
        }
        // A skill this phone forgot is not adopted back from the account: its tombstone is on its way up
        // (see _push). Without this a forgotten skill would return on the very next round.
        if (l == null && _sent.containsKey(key)) continue;
        // This phone's copy is the same age or newer: it is the one that goes up (see _push).
        if (l != null && localAt != null && (remoteAt == null || !remoteAt.isAfter(localAt))) continue;
        final p = playbookOf(m);
        if (p == null) continue;
        if (await SiteSkills.I.save(p, at: _localIso(m['at']), notify: false) != null) continue;
        local[key] = p;
        _sent[key] = _iso(remoteAt ?? DateTime.now());
      }
    } finally {
      _applying = false;
    }
  }

  // ---------------------------------------------------------------- up

  Future<void> _push(List<Map<String, dynamic>> rows) async {
    final here = await SiteSkills.I.all();
    final local = {for (final p in here) p.id: p};
    final dead = <String>{
      for (final m in rows)
        if (m['deleted'] == true && '${m['skill_id'] ?? ''}'.trim().isNotEmpty)
          playbookId('${m['skill_id']}'.trim()),
    };
    for (final p in local.values) {
      final at = _iso(when(p.at) ?? DateTime.now());
      // Unchanged since it was last written up, and not removed over there: nothing to say.
      if (_sent[p.id] == at && !dead.contains(p.id)) continue;
      final row = await _pushOne(p);
      if (row == null) continue;
      _sent[p.id] = _iso(when(row['at']) ?? DateTime.now());
      // The account may already hold a newer recording from another phone: take it now.
      await _take(row);
    }
    // A skill this phone forgot: one tombstone, so the other phones drop it too (and it never comes back).
    // Only for skills this phone wrote up itself — a folder it has just claimed must send no tombstones, or
    // a new phone would wipe the very account it is restoring from.
    for (final id in _sent.keys.toList()) {
      if (local.containsKey(id) || dead.contains(id)) continue;
      final row = await _pushOne(null, id: id);
      if (row == null) continue;
      _sent.remove(id);
    }
  }

  Future<Map<String, dynamic>?> _pushOne(Playbook? p, {String? id}) async {
    try {
      final r = await _c.rpc('browser_skill_push', params: {
        'p_id': p?.id ?? id ?? '',
        'p_name': p?.name ?? '',
        'p_site': p?.site ?? '',
        'p_goal': p?.goal ?? '',
        'p_steps': [for (final s in (p?.steps ?? const <PlayStep>[])) s.toJson()],
        'p_runs': p?.runs ?? 0,
        'p_wins': p?.wins ?? 0,
        'p_at': _iso(when(p?.at) ?? DateTime.now()),
        'p_deleted': p == null,
        'p_device': _device,
      });
      if (r is Map) return Map<String, dynamic>.from(r);
      if (r is List && r.isNotEmpty && r.first is Map) return Map<String, dynamic>.from(r.first as Map);
      return null;
    } catch (e) {
      debugPrint('skill sync: could not send ${p?.id ?? id}: $e');
      return null;
    }
  }

  /// A merged row the account returned: newer steps, or a count another phone got ahead of, come back here.
  Future<void> _take(Map<String, dynamic> row) async {
    if (row['deleted'] == true) return;
    final id = '${row['skill_id'] ?? ''}'.trim();
    if (id.isEmpty) return;
    final at = when(row['at']);
    final l = await SiteSkills.I.byId(id);
    final localAt = l == null ? null : when(l.at);
    if (l != null && localAt != null && (at == null || !at.isAfter(localAt))) return;
    final p = playbookOf(row);
    if (p == null) return;
    _applying = true;
    try {
      await SiteSkills.I.save(p, at: _localIso(row['at']), notify: false);
    } finally {
      _applying = false;
    }
  }
}
