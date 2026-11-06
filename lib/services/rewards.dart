import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// Plan 2.4: referral and creator rewards, as the app sees them.
///
/// - Every account has a personal invite link (submac.site/download?ref=CODE) and code. When a NEW person signs up
///   through it (the link's ref, a hire link's ref, or the code typed at sign-up), the inviter gets extra daily allowance
///   for a few days. The claim happens once, server-side (`claim_referral`), right after sign-in.
/// - When someone hires your published Bot Store bot for the first time, you get a bonus too (`bot_store_hired`).
/// - Amounts, days and caps live in the server's settings; the app only shows what `my_rewards` returns.
class Rewards {
  Rewards._();
  static final I = Rewards._();

  static const _refKey = 'reward_pending_ref';
  static const _refSrcKey = 'reward_pending_src';
  static const _codeKey = 'reward_my_code';
  // The same install id the bot sync uses (random per install, survives sign-out): it lets the server spot several
  // accounts on one phone rewarding each other.
  static const _deviceKey = 'bot_sync_device';

  /// What the server last said (null until the first refresh).
  final state = ValueNotifier<RewardState?>(null);

  SharedPreferences? _p;
  String _device = '';
  String? _myCode;
  // Lives as long as the app (a singleton following sign-in), so it is never cancelled.
  // ignore: cancel_subscriptions
  StreamSubscription<AuthState>? _auth;
  bool _claiming = false;

  SupabaseClient? get _c {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<SharedPreferences> _prefs() async => _p ??= await SharedPreferences.getInstance();

  /// This phone's install id (made once).
  Future<String> deviceId() async {
    if (_device.isNotEmpty) return _device;
    final p = await _prefs();
    _device = p.getString(_deviceKey) ?? '';
    if (_device.isEmpty) {
      final r = math.Random.secure();
      _device = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await p.setString(_deviceKey, _device);
    }
    return _device;
  }

  /// My invite code as last seen (for links and footers without waiting on the network).
  String? get myCode => _myCode;

  /// Call once at startup.
  Future<void> init() async {
    final p = await _prefs();
    _myCode = p.getString(_codeKey);
    final c = _c;
    if (c == null) return;
    _auth ??= c.auth.onAuthStateChange.listen((s) {
      if (s.session != null && (s.event == AuthChangeEvent.signedIn || s.event == AuthChangeEvent.initialSession)) {
        unawaited(onSignedIn());
      }
      if (s.event == AuthChangeEvent.signedOut) {
        state.value = null;
        _myCode = null;
        unawaited(p.remove(_codeKey));
      }
    }, onError: (_) {});
    if (c.auth.currentSession != null) unawaited(onSignedIn());
  }

  /// A referral code from a link (invite or hire link) or typed at sign-up. Kept until claimed after sign-in.
  /// A newer code never replaces one already waiting (the first link that brought the person wins).
  Future<void> setRef(String code, {String source = 'link', bool replace = false, bool claimNow = true}) async {
    final clean = code.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (clean.length < 6 || clean.length > 12) return;
    final p = await _prefs();
    if (!replace && (p.getString(_refKey) ?? '').isNotEmpty) return;
    await p.setString(_refKey, clean);
    await p.setString(_refSrcKey, source);
    if (claimNow && _c?.auth.currentSession != null) unawaited(claimPending());
  }

  Future<void> onSignedIn() async {
    final c = _c;
    if (c == null) return;
    try {
      await c.rpc('touch_device', params: {'p_device': await deviceId(), 'p_version': AppConfig.version, 'p_platform': defaultTargetPlatform.name});
    } catch (e) {
      debugPrint('rewards: touch_device: $e');
    }
    await claimPending();
    await refresh();
  }

  /// Claims a waiting referral once. Returns the server's reason (null = counted), or 'offline'.
  Future<String?> claimPending() async {
    if (_claiming) return 'busy';
    final c = _c;
    final p = await _prefs();
    final code = p.getString(_refKey) ?? '';
    if (c == null || c.auth.currentSession == null || code.isEmpty) return 'no_code';
    _claiming = true;
    try {
      final r = await c.rpc('claim_referral', params: {
        'p_code': code,
        'p_source': p.getString(_refSrcKey) ?? 'link',
        'p_device': await deviceId(),
      }).timeout(const Duration(seconds: 20));
      // Any answer from the server is final (counted, already, self, not new...): never try the same code again.
      await p.remove(_refKey);
      await p.remove(_refSrcKey);
      final reason = r is Map ? r['reason'] : null;
      return reason == null ? null : '$reason';
    } catch (e) {
      debugPrint('rewards: claim later: $e');
      return 'offline';
    } finally {
      _claiming = false;
    }
  }

  /// Fetches today's bonus, invite link and active rewards. Never throws.
  Future<void> refresh() async {
    final c = _c;
    if (c == null || c.auth.currentSession == null) return;
    try {
      var r = await c.rpc('my_rewards').timeout(const Duration(seconds: 20));
      if (r is Map && (r['invite_code'] == null)) {
        await c.rpc('my_invite').timeout(const Duration(seconds: 20));
        r = await c.rpc('my_rewards').timeout(const Duration(seconds: 20));
      }
      if (r is! Map) return;
      final s = RewardState.fromJson(Map<String, dynamic>.from(r));
      state.value = s;
      if (s.inviteCode != null && s.inviteCode != _myCode) {
        _myCode = s.inviteCode;
        await (await _prefs()).setString(_codeKey, s.inviteCode!);
      }
    } catch (e) {
      debugPrint('rewards: $e');
    }
  }

  /// My invite link (fetched or made on first use). Null when offline and never fetched.
  Future<String?> inviteLink() async {
    if (state.value?.inviteLink == null) await refresh();
    return state.value?.inviteLink ?? (_myCode == null ? null : linkFor(_myCode!));
  }

  static String linkFor(String code) => 'https://submac.site/download?ref=$code';

  /// The public page of a bot (listing id or share code), carrying my invite code so a newcomer counts for me.
  String botLink(String key) {
    final ref = _myCode;
    return 'https://submac.site/b/${Uri.encodeComponent(key)}${ref == null ? '' : '?ref=$ref'}';
  }

  /// The text people share to invite a friend.
  static String inviteText(String link, String code) =>
      'I use Telesia, an AI agent with bots that work for me. Get it here: $link\nWhen you sign up, use my invite code $code.';
}

class ActiveReward {
  final String kind; // referral | creator | admin_grant
  final int amount;
  final DateTime? expiresAt;
  final String? note;
  const ActiveReward(this.kind, this.amount, this.expiresAt, this.note);
}

class RewardState {
  final int bonus;
  final int cap;
  final int base;
  final int joined;
  final int hires;
  final String? inviteCode;
  final String? inviteLink;
  final bool enabled;
  final int referralTokens, referralDays, creatorTokens, creatorDays;
  final int activeReferral, activeCreator, activeGrant;
  final List<ActiveReward> rewards;

  const RewardState({
    this.bonus = 0,
    this.cap = 0,
    this.base = 0,
    this.joined = 0,
    this.hires = 0,
    this.inviteCode,
    this.inviteLink,
    this.enabled = true,
    this.referralTokens = 30000,
    this.referralDays = 7,
    this.creatorTokens = 30000,
    this.creatorDays = 7,
    this.activeReferral = 0,
    this.activeCreator = 0,
    this.activeGrant = 0,
    this.rewards = const [],
  });

  static int _n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

  factory RewardState.fromJson(Map<String, dynamic> j) {
    final a = j['active'] is Map ? Map<String, dynamic>.from(j['active'] as Map) : const <String, dynamic>{};
    return RewardState(
      bonus: _n(j['bonus']),
      cap: _n(j['cap']),
      base: _n(j['base']),
      joined: _n(j['joined']),
      hires: _n(j['hires']),
      inviteCode: j['invite_code'] as String?,
      inviteLink: j['invite_link'] as String?,
      enabled: j['enabled'] != false,
      referralTokens: _n(j['referral_tokens']),
      referralDays: _n(j['referral_days']),
      creatorTokens: _n(j['creator_tokens']),
      creatorDays: _n(j['creator_days']),
      activeReferral: _n(a['referral']),
      activeCreator: _n(a['creator']),
      activeGrant: _n(a['admin_grant']),
      rewards: [
        for (final r in (j['rewards'] as List? ?? const []))
          if (r is Map)
            ActiveReward('${r['kind']}', _n(r['amount']), DateTime.tryParse('${r['expires_at'] ?? ''}'), r['note'] as String?),
      ],
    );
  }

  /// "50k" / "1.2M" / "800".
  static String short(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M';
    if (n >= 1000) return '${(n / 1000).floor()}k';
    return '$n';
  }

  /// "+60k today from 1 join and 2 hires", or null when there is no bonus today.
  String? get line {
    if (bonus <= 0) return null;
    final parts = <String>[
      if (activeReferral > 0) '$activeReferral ${activeReferral == 1 ? 'friend who joined' : 'friends who joined'}',
      if (activeCreator > 0) '$activeCreator ${activeCreator == 1 ? 'hire' : 'hires'} of your bots',
      if (activeGrant > 0) activeGrant == 1 ? 'a gift from Telesia' : '$activeGrant gifts from Telesia',
    ];
    return '+${short(bonus)} today from ${parts.isEmpty ? 'rewards' : _join(parts)}';
  }

  /// What one invite earns, in plain words.
  String get offer => 'Each friend who joins with your link gives you +${short(referralTokens)} a day for $referralDays days.';

  static String _join(List<String> p) => p.length == 1 ? p.first : '${p.sublist(0, p.length - 1).join(', ')} and ${p.last}';
}
