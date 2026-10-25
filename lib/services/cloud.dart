import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models.dart';
import 'context_window.dart';
import 'somali.dart';
import 'events.dart';
import 'billing/billing_models.dart';
import 'billing/billing_service.dart';
import 'house_rules.dart';

/// Where today's allowance stands, in plain terms for the UI.
class CloudUsage {
  /// 0..1 of today's allowance used.
  final double ratio;

  /// 'ok' | 'notice' (getting close) | 'light' (shorter replies for the rest of the day) | 'limit' (rests until tomorrow).
  final String state;
  final String message;
  final DateTime? checkedAt;
  const CloudUsage({this.ratio = 0, this.state = 'ok', this.message = '', this.checkedAt});

  bool get near => state == 'notice';
  bool get light => state == 'light';
  bool get resting => state == 'limit';

  /// One friendly line for Settings.
  String get line {
    switch (state) {
      case 'limit':
        return message.isNotEmpty ? message : 'You\'ve done a lot today! SubMac is resting until tomorrow.';
      case 'light':
        return 'Busy day! Replies are a little shorter until tomorrow.';
      case 'notice':
        return 'Most of today\'s allowance is used. It refreshes tomorrow.';
    }
    if (ratio < 0.01) return 'Plenty left for today';
    return '${(100 - ratio * 100).round()}% of today left';
  }
}

/// Today's call minutes (Live voice has its own daily limit, apart from the allowance). Resets at midnight UTC.
class CallMinutes {
  final int limitMinutes;
  final int secondsLeft;
  final int usedSeconds;
  final bool enabled;
  /// Midnight UTC, when the minutes come back.
  final DateTime? resetsAt;
  final DateTime? checkedAt;
  const CallMinutes({this.limitMinutes = 15, this.secondsLeft = 15 * 60, this.usedSeconds = 0, this.enabled = true, this.resetsAt, this.checkedAt});

  static CallMinutes? fromJson(Object? j) {
    if (j is! Map) return null;
    int n(Object? v, int d) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? d;
    return CallMinutes(
      limitMinutes: n(j['limit_minutes'], 15),
      secondsLeft: n(j['seconds_left'], 0),
      usedSeconds: n(j['used_seconds'], 0),
      enabled: j['live_enabled'] != false && j['enabled'] != false,
      resetsAt: DateTime.tryParse('${j['resets_at'] ?? ''}')?.toUtc(),
      checkedAt: DateTime.now(),
    );
  }

  /// From yesterday (the day has turned over since): not to be trusted.
  bool get stale => resetsAt != null && DateTime.now().toUtc().isAfter(resetsAt!);

  /// No calls left today (or calls are off for this account), as far as the app last heard.
  bool get out => checkedAt != null && !stale && (!enabled || secondsLeft <= 0);

  /// Whole minutes left, rounded up (59 s left is "1 min").
  int get minutesLeft => (secondsLeft / 60).ceil();

  /// Minutes used, so that used + left always adds up to the limit.
  int get minutesUsed => stale ? 0 : (limitMinutes - minutesLeft).clamp(0, limitMinutes).toInt();

  /// "Calls: 3 of 15 min today" for Settings.
  String get line => !enabled ? 'Calls: switched off for your account' : 'Calls: $minutesUsed of $limitMinutes min today';

  /// When the minutes come back, in the phone's own time ("at 3:00 AM").
  String get resetText {
    final r = (resetsAt ?? _nextUtcMidnight()).toLocal();
    return 'at $resetClock${r.day == DateTime.now().day ? '' : ' tomorrow'}';
  }

  /// The local time of the daily reset, like "3:00 AM" (midnight UTC).
  String get resetClock {
    final r = (resetsAt ?? _nextUtcMidnight()).toLocal();
    final h = r.hour % 12 == 0 ? 12 : r.hour % 12;
    return '$h:${r.minute.toString().padLeft(2, '0')} ${r.hour < 12 ? 'AM' : 'PM'}';
  }

  /// The friendly line when there are no minutes left.
  String get usedUpMessage => !enabled
      ? 'Calls are switched off for your account. You can still type to SubMac.'
      : 'Today\'s call minutes are used up. They come back $resetText. You can still type to SubMac.';

  static DateTime _nextUtcMidnight() {
    final n = DateTime.now().toUtc();
    return DateTime.utc(n.year, n.month, n.day).add(const Duration(days: 1));
  }
}

/// Plan 2.2 background lane: bots and offices have their own share of the daily allowance (about 30%), so they
/// never block the user's own chats. When the share is used they pause until the next UTC day.
class BackgroundShare {
  /// 0..1 of the bots' share used today.
  final double ratio;
  /// The server said "background_paused" (or the share is used up) today.
  final bool paused;
  /// UTC day ('2026-10-19') this reading belongs to; a new day starts fresh.
  final String day;
  const BackgroundShare({this.ratio = 0, this.paused = false, this.day = ''});

  static String today() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

  /// From an earlier UTC day: the share has come back since.
  bool get stale => day.isNotEmpty && day != today();

  /// Bot and office work should wait for tomorrow.
  bool get pausedNow => paused && !stale;

  /// "Bots: 12% of their share today" for Settings.
  String get line {
    if (pausedNow) return 'Bots: paused until tomorrow to save your daily allowance';
    final pct = stale ? 0 : (ratio * 100).round().clamp(0, 100);
    return 'Bots: $pct% of their share today';
  }
}

/// What the cloud can do right now (switched on and off from the server, no app update needed).
class CloudFeatures {
  final bool live;
  final bool transcribe;
  final bool image;
  final bool video;
  final List<String> voices;
  const CloudFeatures({this.live = true, this.transcribe = true, this.image = false, this.video = false, this.voices = defaultVoices});
  static const defaultVoices = ['Kore', 'Puck', 'Charon', 'Aoede', 'Fenrir', 'Leda', 'Orus', 'Zephyr'];
}

class CloudException implements Exception {
  final String message;
  final int status;
  final String code;
  /// Vendor and model names are scrubbed here, so a server message never names a provider on screen.
  CloudException(String message, {this.status = 0, this.code = ''}) : message = HouseRules.scrub(message);
  @override
  String toString() => message;
}

/// SubMac Cloud: every model call goes through SubMac's own server. Users never set up models or keys;
/// the server picks the model, switches when one is busy, and keeps a fair daily allowance.
class Cloud {
  static const providerId = 'submac';

  /// The one name the app asks for. The server maps it to the health-gated chain and swaps
  /// only when a model fails. Every user gets the same model: coins and passes buy allowance,
  /// never a different model.
  static const submac = 'submac';

  /// Making a picture is a different capability, not a different tier. The app asks for it only
  /// when the user asks for a picture, and it is not something the user ever picks.
  static const imageModel = 'submac-image';

  static String get _base => '${AppConfig.supabaseUrl}/functions/v1/ai-chat';

  /// The one provider the app talks to. Its "key" is the signed-in user's session, added per request.
  static final ProviderConfig provider = ProviderConfig(
    id: providerId,
    name: 'SubMac',
    baseUrl: _base,
    defaultModel: submac,
    models: [submac, imageModel],
  );

  static bool isCloud(ProviderConfig p) => p.id == providerId;

  static final usage = ValueNotifier<CloudUsage>(const CloudUsage());
  static final features = ValueNotifier<CloudFeatures>(const CloudFeatures());
  static final calls = ValueNotifier<CallMinutes>(const CallMinutes());
  static final background = ValueNotifier<BackgroundShare>(const BackgroundShare());

  /// Background work was refused today (429 background_paused): bots and offices wait for the next UTC day.
  static void markBackgroundPaused() =>
      background.value = BackgroundShare(ratio: 1, paused: true, day: BackgroundShare.today());

  /// Time until the share comes back (midnight UTC), plus a few minutes so the server has turned the day too.
  static Duration untilBackgroundResets() {
    final n = DateTime.now().toUtc();
    return DateTime.utc(n.year, n.month, n.day + 1, 0, 5).difference(n);
  }

  static void _readCalls(Object? j) {
    final c = CallMinutes.fromJson(j);
    if (c != null) calls.value = c;
  }

  /// A fresh access token for the signed-in user (refreshed shortly before it expires).
  static Future<String> token() async {
    final auth = Supabase.instance.client.auth;
    var s = auth.currentSession;
    if (s == null) throw CloudException('Please sign in again.', status: 401, code: 'auth');
    final exp = s.expiresAt;
    final soon = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90;
    if (exp != null && exp < soon) {
      try {
        s = (await auth.refreshSession()).session ?? s;
      } catch (_) {}
    }
    return s!.accessToken;
  }

  /// Headers for a cloud request. [source] lets the server tell chat, bots and offices apart in its stats.
  /// [background] marks work nobody is watching (bot wakes, office work): it uses the bots' share of the allowance.
  static Future<Map<String, String>> headers({String source = 'agent', bool json = true, bool background = false}) async => {
        if (json) 'Content-Type': 'application/json',
        'Authorization': 'Bearer ${await token()}',
        'apikey': AppConfig.supabaseAnonKey,
        'x-submac-source': source,
        'x-region': AppConfig.edgeRegion,
        if (background) 'x-submac-lane': 'background',
      };

  static bool _regionLogged = false;

  /// Diagnosis: the region that actually ran the proxy (`x-sb-edge-region`), logged once per app run as an
  /// `edge_region` event (props: from = region, v = whether it matched the pin). No PII.
  static void _noteRegion(Map<String, String> h) {
    if (_regionLogged) return;
    final region = h['x-sb-edge-region'];
    if (region == null || region.isEmpty) return;
    _regionLogged = true;
    Events.I.log('edge_region', props: {'from': region, 'v': region == AppConfig.edgeRegion ? 'pinned' : 'other'});
  }

  /// The server reports today's allowance on every reply. [filtered]: the request carried pictures or tools (CB-23).
  static void readHeaders(Map<String, String> h, {bool filtered = false}) {
    _noteRegion(h);
    // How much SubMac can read at once (the smallest healthy route's window, PLAN 1.6): compaction follows it.
    ContextWindow.note(h['x-submac-window'], filtered: filtered);
    // Billing (when on): weighted tokens left. Absent with billing off, so nothing changes then.
    Billing.I.noteHeaders(h);
    final bg = double.tryParse(h['x-submac-bg'] ?? '');
    if (bg != null) {
      final cur = background.value;
      // A "paused" reading stays for the rest of the UTC day; a fresh day starts from the server's number.
      if (!cur.pausedNow) background.value = BackgroundShare(ratio: bg, paused: bg >= 1, day: BackgroundShare.today());
    }
    final r = double.tryParse(h['x-submac-usage'] ?? '');
    final st = h['x-submac-state'];
    if (r == null && st == null) return;
    final cur = usage.value;
    usage.value = CloudUsage(ratio: r ?? cur.ratio, state: st ?? cur.state, message: cur.message, checkedAt: DateTime.now());
  }

  /// Turns a cloud error body into a calm message (never a provider name or raw error).
  static CloudException errorFrom(int status, String body) {
    String code = '', msg = '';
    // Billing refusals carry a `billing` block (reason, reset time, buy options). Never present with billing off.
    BillingNotice? notice;
    try {
      notice = BillingNotice.tryParse(status, jsonDecode(body));
    } catch (_) {}
    try {
      final j = jsonDecode(body);
      final e = j is Map ? j['error'] : null;
      if (e is Map) {
        code = '${e['code'] ?? ''}';
        msg = '${e['message'] ?? ''}';
      }
    } catch (_) {}
    if (status == 401 && code.isEmpty) code = 'auth';
    if ((code == 'call_minutes' || code == 'live_off') && notice == null) {
      // Out of call minutes (or calls are off): the body carries the minute fields; say when they come back.
      try {
        final j = jsonDecode(body);
        if (j is Map) _readCalls(j);
      } catch (_) {}
      msg = calls.value.usedUpMessage;
    }
    if (code == 'background_paused') {
      markBackgroundPaused();
      if (msg.isEmpty) msg = 'Paused until tomorrow to save your daily allowance.';
    }
    if (code == 'daily_limit' || code == 'limit_daily' || code == 'limit_total' || code == 'no_plan') {
      usage.value = CloudUsage(ratio: 1, state: 'limit', message: msg, checkedAt: DateTime.now());
    }
    if (notice != null && msg.isNotEmpty) Billing.I.noteNotice(notice, key: msg);
    if (msg.isEmpty) {
      msg = status == 401
          ? 'Please sign in again.'
          : status == 429
              ? 'SubMac is very busy right now. Please try again in a moment.'
              : status >= 500 || status == 0
                  ? 'SubMac couldn\'t get an answer just now. Please try again in a moment.'
                  : 'Something went wrong. Please try again.';
    }
    return CloudException(msg, status: status, code: code);
  }

  static DateTime _lastStatus = DateTime.fromMillisecondsSinceEpoch(0);

  /// Refreshes today's allowance and what the cloud can do. Cheap; called on open and from Settings.
  static Future<void> refreshStatus({bool force = false}) async {
    if (!force && DateTime.now().difference(_lastStatus) < const Duration(seconds: 30)) return;
    _lastStatus = DateTime.now();
    try {
      final r = await http.get(Uri.parse('$_base/status'), headers: await headers(json: false)).timeout(const Duration(seconds: 15));
      _noteRegion(r.headers);
      if (r.statusCode != 200) return;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      usage.value = CloudUsage(
        ratio: (j['ratio'] as num?)?.toDouble() ?? 0,
        state: '${j['state'] ?? 'ok'}',
        message: '${j['message'] ?? ''}',
        checkedAt: DateTime.now(),
      );
      _readCalls(j['calls']);
      // Billing block only when the server's billing flag is on; otherwise the wallet stays hidden.
      Billing.I.noteStatus(j['billing']);
      final b = j['background'];
      if (b is Map) {
        background.value = BackgroundShare(
            ratio: (b['ratio'] as num?)?.toDouble() ?? 0, paused: b['paused'] == true, day: BackgroundShare.today());
      }
      final f = j['features'];
      if (f is Map) {
        features.value = CloudFeatures(
          live: f['live'] != false,
          transcribe: f['transcribe'] != false,
          image: f['image'] == true,
          video: f['video'] == true,
          voices: f['live_voices'] is List ? [for (final v in f['live_voices'] as List) '$v'] : CloudFeatures.defaultVoices,
        );
      }
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 60), String source = 'agent'}) async {
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('$_base/$path'), headers: await headers(source: source), body: jsonEncode(body))
          .timeout(timeout);
    } on TimeoutException {
      throw CloudException('That took too long. Please try again.', status: 0, code: 'timeout');
    } on SocketException {
      throw CloudException('You\'re offline. Check your connection and try again.', status: 0, code: 'offline');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) throw errorFrom(r.statusCode, r.body);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// A short-lived pass for one Live voice session. The real key never reaches the phone.
  /// [callId] + [seconds]: the call is renewing its line (goAway or a drop), not starting a new call;
  /// the server only allows that while the call is still going. Without them this is a new call.
  static Future<({String token, String model, String wsUrl, String callId, int secondsLeft, int heartbeat})> liveToken(
      {String? callId, int? seconds}) async {
    final resume = callId != null && callId.isNotEmpty;
    final j = await _post('live-token', {if (resume) ...{'resume': true, 'call_id': callId, 'seconds': seconds ?? 0}},
        timeout: const Duration(seconds: 20), source: 'live');
    _readCalls(j);
    return (
      token: '${j['token']}',
      model: '${j['model']}',
      wsUrl: '${j['ws_url']}',
      callId: '${j['call_id'] ?? callId ?? ''}',
      secondsLeft: (j['seconds_left'] as num?)?.toInt() ?? calls.value.secondsLeft,
      heartbeat: (j['heartbeat_seconds'] as num?)?.toInt() ?? 30,
    );
  }

  /// The call's heartbeat: how long it has been connected. [end] on hang-up. Returns null when offline
  /// (the server counts the gap itself on the next heartbeat).
  static Future<({int secondsLeft, bool stop, bool ok})?> liveUsage(String callId, int seconds, {bool end = false}) async {
    try {
      final r = await http
          .post(Uri.parse('$_base/live-usage'),
              headers: await headers(source: 'live'), body: jsonEncode({'call_id': callId, 'seconds': seconds, if (end) 'end': true}))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      _readCalls(j);
      return (secondsLeft: (j['seconds_left'] as num?)?.toInt() ?? 0, stop: j['stop'] == true, ok: j['ok'] != false);
    } catch (_) {
      return null;
    }
  }

  /// A recording turned into text (Somali, Arabic, English and more).
  static Future<String> transcribe(List<int> bytes, {String mime = 'audio/mp4', String? prompt}) async {
    final j = await _post('transcribe', {'audio_base64': base64Encode(bytes), 'mime': mime, 'prompt': prompt ?? Somali.transcribePrompt},
        timeout: const Duration(minutes: 5), source: 'transcribe');
    return '${j['text'] ?? ''}'.trim();
  }

  /// A generated picture, when the server has image models switched on.
  static Future<List<int>> image(String prompt, {String size = '1024x1024'}) async {
    final j = await _post('image', {'prompt': prompt, 'size': size}, timeout: const Duration(minutes: 3), source: 'image');
    final data = j['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first as Map;
      final b64 = first['b64_json'];
      if (b64 is String && b64.isNotEmpty) return base64Decode(b64);
      final url = first['url'];
      if (url is String && url.startsWith('http')) return (await http.get(Uri.parse(url)).timeout(const Duration(minutes: 1))).bodyBytes;
    }
    throw CloudException('No picture came back. Please try again.');
  }
}
