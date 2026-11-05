import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Talks to SubMac's Android side: wake word, floating Live, phone control, SMS,
/// notifications, scheduled alarms and permission status.
class SystemBridge {
  SystemBridge._();
  static final I = SystemBridge._();
  static const _ch = MethodChannel('submac/system');

  bool get supported => Platform.isAndroid;

  // Events from Android, set by AppState.
  void Function(String phrase)? onWake;
  void Function(String action, String? text)? onOverlay;
  void Function(String state)? onWakeState;
  void Function(String payload)? onNotificationTap;
  void Function(String id)? onAlarm;
  /// A bot's ringing call was declined from the notification.
  void Function(String botId)? onBotDecline;
  /// A bot's call rang out (Android's own timer).
  void Function(String botId)? onBotMissed;
  /// Approve / Deny tapped on an approval notification.
  void Function(String id, bool ok)? onApproval;
  /// The user replied from a bot's notification (to = conv/<id> or office/<id>).
  void Function(String to, String text)? onNotifReply;
  /// A phone notification matched a bot's watch.
  void Function(Map<String, dynamic> e)? onNotifEvent;
  /// The user tapped Stop on the "SubMac is using your phone" badge.
  void Function()? onPhoneStop;
  Future<void> phoneBadge(bool on) async {
    try {
      await _call<bool>('a11yBadge', {'on': on});
    } catch (_) {}
  }

  /// A tap in the floating task bubble: stop, send, option, approve, edit, notnow, open.
  void Function(String action, Map<String, dynamic> m)? onBubble;

  /// Shows or updates the floating task bubble over other apps (state is the JSON built by screen_control.dart).
  Future<void> bubbleShow(String json) async {
    try {
      await _call<bool>('bubbleShow', {'state': json});
    } catch (_) {}
  }

  Future<void> bubbleHide() async {
    try {
      await _call<bool>('bubbleHide');
    } catch (_) {}
  }

  /// No task drives the screen any more: phone steps still queued are cancelled and the badge comes down.
  Future<void> screenHalt() async {
    try {
      await _call<bool>('screenHalt');
    } catch (_) {}
  }

  /// Takes the badge and bubble down and cancels phone steps still queued (the app just started).
  Future<void> screenReset() async {
    try {
      await _call<bool>('screenReset');
    } catch (_) {}
  }

  bool _ready = false;

  Future<void> init() async {
    if (!supported || _ready) return;
    _ready = true;
    _ch.setMethodCallHandler((call) async {
      final a = call.arguments;
      switch (call.method) {
        case 'wake':
          onWake?.call('$a');
          break;
        case 'overlay':
          final m = Map<String, dynamic>.from(a as Map);
          onOverlay?.call('${m['action']}', m['text'] as String?);
          break;
        case 'wakeState':
          onWakeState?.call('$a');
          break;
        case 'notificationTap':
          onNotificationTap?.call('$a');
          break;
        case 'alarm':
          onAlarm?.call('$a');
          break;
        case 'botMissed':
          onBotMissed?.call('$a');
          break;
        case 'botDecline':
          onBotDecline?.call('$a');
          break;
        case 'approval':
          final m = Map<String, dynamic>.from(a as Map);
          onApproval?.call('${m['id']}', m['ok'] == true);
          break;
        case 'notifReply':
          final m = Map<String, dynamic>.from(a as Map);
          onNotifReply?.call('${m['to']}', '${m['text'] ?? ''}');
          break;
        case 'notifEvent':
          try {
            onNotifEvent?.call(Map<String, dynamic>.from(jsonDecode('$a') as Map));
          } catch (_) {}
          break;
        case 'phoneStop':
          onPhoneStop?.call();
          break;
        case 'bubble':
          final m = Map<String, dynamic>.from(a as Map);
          onBubble?.call('${m['action']}', m);
          break;
      }
      return null;
    });
    try {
      await _ch.invokeMethod('ready');
    } catch (_) {}
  }

  /// Sees every call to Android (tests: the foreground line, alarms and notifications a background run asks for).
  @visibleForTesting
  static void Function(String method, Map<String, dynamic>? args)? debugCalls;

  Future<T?> _call<T>(String m, [Map<String, dynamic>? args]) async {
    debugCalls?.call(m, args);
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<T>(m, args);
    } on MissingPluginException {
      return null;
    }
  }

  /// Saves a file into the phone's Pictures / Movies / Music / Download (SubMac folder).
  /// Returns the place it went, or a message starting with "error:".
  /// [folder] 'documents' puts any file in Documents/SubMac, 'downloads' in Download/SubMac.
  Future<String> saveMedia(String path, {required String mime, String? name, String folder = ''}) async {
    final r = await _call<String>('saveMedia', {'path': path, 'mime': mime, 'name': name ?? path.split('/').last, 'folder': folder});
    return r ?? 'error: saving is only available on Android';
  }

  // ---- permissions ----
  Future<Map<String, bool>> permissions() async {
    final m = await _call<Map>('permissions');
    if (m == null) return {};
    return {for (final e in m.entries) '${e.key}': e.value == true};
  }

  Future<void> openPermission(String name) => _call('openPermission', {'name': name});

  // ---- wake word ----
  Future<void> wakeStart(String modelDir, double sensitivity, {bool screenOff = true}) =>
      _call('wakeStart', {'model': modelDir, 'sensitivity': sensitivity, 'screenOff': screenOff});
  Future<void> wakeStop() => _call('wakeStop');
  Future<void> wakePause() => _call('wakePause');
  Future<void> wakeResume() => _call('wakeResume');
  Future<void> wakeSensitivity(double v) => _call('wakeSensitivity', {'value': v});
  Future<String> wakeState() async => (await _call<String>('wakeState')) ?? 'off';
  Future<void> unzip(String zip, String dest) => _ch.invokeMethod('unzip', {'zip': zip, 'dest': dest});
  Future<void> chime() => _call('chime');
  /// Keeps a microphone service running while Live is on, so it hears you from any app.
  Future<void> liveHold(bool on) => _call('liveHold', {'on': on});

  // ---- floating Live ----
  Future<bool> overlayShow(String mode) async => (await _call<bool>('overlayShow', {'mode': mode})) ?? false;
  Future<void> overlayUpdate({
    required String status,
    required double level,
    String caption = '',
    String you = '',
    bool muted = false,
    bool thinking = false,
  }) =>
      _call('overlayUpdate', {
        'status': status,
        'level': level,
        'caption': caption,
        'you': you,
        'muted': muted,
        'thinking': thinking,
      });
  Future<void> overlayHide() => _call('overlayHide');
  Future<void> moveToBack() => _call('moveToBack');
  Future<void> bringToFront({String? route}) => _call('bringToFront', {'route': route});
  Future<bool> isForeground() async => (await _call<bool>('isForeground')) ?? true;

  // ---- notifications, background, alarms ----
  /// kind: done | scheduled | attention | paused | info (sets the small red kicker line).
  Future<void> notify({required int id, required String title, required String body, String payload = '', String kind = 'done'}) =>
      _call('notify', {'id': id, 'title': title, 'body': body, 'payload': payload, 'kind': kind});
  Future<String?> takeLaunchPayload() => _call<String>('takeLaunchPayload');
  /// Real touch / keyboard input into the browser tab showing [url]. Returns "ok", or "no-view" when the
  /// tab's native view could not be found (the caller falls back to page script).
  /// [hold]: how long the finger rests on the screen (a tap is not always the same length).
  Future<String> webTouch(String url, String kind, double x, double y,
      {double? x2, double? y2, int ms = 320, int hold = 55, String mark = ''}) async {
    try {
      final r = await _call('webTouch', {
        'url': url,
        'mark': mark,
        'kind': kind,
        'x': x,
        'y': y,
        'x2': x2 ?? x,
        'y2': y2 ?? y,
        'ms': ms,
        'hold': hold,
      }).timeout(const Duration(seconds: 6));
      return '${r ?? 'no-view'}';
    } catch (_) {
      return 'no-view';
    }
  }

  /// One real finger stroke through many points: a curved drag with a human wobble (P6). [pts] are fractions
  /// of the visible page; the native side sends down, move, move…, up as ONE gesture.
  Future<String> webStroke(String url, List<({double x, double y})> pts, {int ms = 320, int hold = 30, String mark = ''}) async {
    if (pts.isEmpty) return 'no-view';
    try {
      final r = await _call('webStroke', {
        'url': url,
        'mark': mark,
        'ms': ms,
        'hold': hold,
        'pts': [
          for (final p in pts) [p.x, p.y],
        ],
      }).timeout(const Duration(seconds: 10));
      return '${r ?? 'no-view'}';
    } catch (_) {
      return 'no-view';
    }
  }

  Future<String> webType(String url, String text, {String mark = ''}) async {
    try {
      return '${await _call('webType', {'url': url, 'mark': mark, 'text': text}).timeout(const Duration(seconds: 6)) ?? 'no-view'}';
    } catch (_) {
      return 'no-view';
    }
  }

  Future<String> webKey(String url, String key, {String mark = ''}) async {
    try {
      return '${await _call('webKey', {'url': url, 'mark': mark, 'key': key}).timeout(const Duration(seconds: 6)) ?? 'no-view'}';
    } catch (_) {
      return 'no-view';
    }
  }

  Future<void> clearTaskNotifications() async {
    try {
      await _call('clearTasks');
    } catch (_) {}
  }
  Future<void> keepAlive(bool on, {String text = 'Working on your task'}) => _call('keepAlive', {'on': on, 'text': text});
  /// [label]: the line the foreground service shows when the alarm starts SubMac ("<Bot name> · <task title>").
  Future<void> scheduleAlarm(String id, DateTime at, {String label = ''}) =>
      _call('scheduleAlarm', {'id': id, 'at': at.millisecondsSinceEpoch, if (label.isNotEmpty) 'label': label});
  Future<void> cancelAlarm(String id) => _call('cancelAlarm', {'id': id});

  // ---- bots ----
  /// A bot calls: rings like a phone call, at the top of the screen or full screen.
  Future<void> ring({required int id, required String botId, required String name, required String reason, bool fullScreen = false}) =>
      _call('ring', {'id': id, 'bot': botId, 'name': name, 'reason': reason, 'full': fullScreen});
  Future<void> ringCancel(int id) => _call('ringCancel', {'id': id});
  /// A message from a bot: its name and one short line, like a text from a colleague.
  /// [reply] adds a Reply field right in the notification.
  Future<void> notifyBot({required int id, required String name, required String body, required String payload, bool reply = false}) =>
      _call('notifyBot', {'id': id, 'name': name, 'body': body, 'payload': payload, 'reply': reply});
  /// A result or message from the agent ([channel] NotifChannels.agent: "SubMac", red) or a bot (NotifChannels.bots:
  /// its name, a round face of [initial] on [color]). [body] is already the short summary (NotifText). [reply] adds
  /// an inline Reply that works with SubMac closed; [high] pops up (it needs the owner).
  Future<void> notifyFrom(
          {required int id,
          required String channel,
          required String title,
          required String body,
          required String payload,
          bool reply = false,
          String initial = '',
          int color = 0,
          bool high = false}) =>
      _call('notifyFrom', {
        'id': id,
        'channel': channel,
        'title': title,
        'body': body,
        'payload': payload,
        'reply': reply,
        'initial': initial,
        'color': color,
        'high': high,
      });
  /// A team chat post: titled with the team's name, "<Bot>: message" in one conversation per team, inline Reply.
  /// [needs]: a "[needs you]" post (pops up).
  Future<void> notifyTeam(
          {required int id,
          required String teamId,
          required String team,
          required String sender,
          required String text,
          String initial = '',
          int color = 0,
          bool needs = false}) =>
      _call('notifyTeam', {
        'id': id,
        'team': teamId,
        'name': team,
        'sender': sender,
        'text': text,
        'initial': initial,
        'color': color,
        'needs': needs,
      });
  /// A bot asks before doing something risky: Approve / Deny right in the notification.
  Future<void> notifyApproval({required int id, required String approvalId, required String name, required String title, String body = ''}) =>
      _call('notifyApproval', {'id': id, 'approval': approvalId, 'name': name, 'title': title, 'body': body});
  /// The notification watches the phone should report (JSON list of {bot,id,app,kw}).
  Future<void> setNotifWatches(String json) => _call('setNotifWatches', {'json': json});

  // ---- phone control ----
  Future<Uint8List?> a11yShot() async => await _call<Uint8List>('a11yShot');
  Future<String> device(String action, [String value = '']) async =>
      (await _call<String>('device', {'action': action, 'value': value})) ?? 'Not available on this phone.';
  Future<int> a11yIdle() async => (await _call<int>('a11yIdle')) ?? 99999;
  Future<bool> a11yEnabled() async => (await _call<bool>('a11yEnabled')) ?? false;
  /// on, off, or stalled (switched on in Settings but Android stopped the service).
  Future<String> a11yState() async {
    try {
      return (await _call<String>('a11yState')) ?? 'off';
    } catch (_) {
      return await a11yEnabled() ? 'on' : 'off';
    }
  }
  Future<String> a11y(String method, [Map<String, dynamic>? args]) async {
    try {
      return (await _call<String>(method, args).timeout(const Duration(seconds: 20))) ??
          'Phone control is not available on this device.';
    } on TimeoutException {
      return 'The phone did not answer in time. Read the screen again, then try once more.';
    } catch (e) {
      return 'Phone control hit an error ($e). Read the screen again and try another way.';
    }
  }

  // ---- WhatsApp on this phone (see WhatsAppTools) ----
  Future<T?> waCall<T>(String m, [Map<String, dynamic>? args]) => _call<T>(m, args).timeout(const Duration(seconds: 15));
  /// A WhatsApp step that opens WhatsApp and presses its buttons (JSON {ok, state, detail}).
  Future<String?> waAct(Map<String, dynamic> args) => _call<String>('waAct', args).timeout(const Duration(seconds: 80));
  Future<void> waCapture(bool on) async => _call('waCapture', {'on': on});
  Future<void> waClear() async => _call('waClear');

  // ---- SMS ----
  Future<List<Map<String, dynamic>>> notifList({int limit = 30, String query = '', String app = ''}) async {
    final s = await _call<String>('notifList', {'limit': limit, 'query': query, 'app': app});
    if (s == null || s.isEmpty) return [];
    try {
      return [for (final e in jsonDecode(s) as List) Map<String, dynamic>.from(e as Map)];
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> readSms({int limit = 20, String query = '', String box = 'inbox'}) async {
    final l = await _call<List>('readSms', {'limit': limit, 'query': query, 'box': box});
    return [for (final e in (l ?? const [])) Map<String, dynamic>.from(e as Map)];
  }

  Future<List<Map<String, dynamic>>> calendarEvents({required DateTime from, int days = 7, String query = '', int limit = 50}) async {
    final l = await _call<List>('calendarEvents', {'from': from.millisecondsSinceEpoch, 'days': days, 'query': query, 'limit': limit});
    return [for (final e in (l ?? const [])) Map<String, dynamic>.from(e as Map)];
  }

  /// Returns the new event id, or a text starting with "error:".
  Future<String> calendarAdd({required String title, required DateTime start, DateTime? end, bool allDay = false, String place = '', String notes = ''}) async {
    final r = await _call<String>('calendarAdd', {
      'title': title,
      'start': start.millisecondsSinceEpoch,
      'end': (end ?? start.add(const Duration(hours: 1))).millisecondsSinceEpoch,
      'allDay': allDay,
      'place': place,
      'notes': notes,
    });
    return r ?? 'error:unavailable';
  }

  Future<List<Map<String, dynamic>>> contacts({String query = '', int limit = 20}) async {
    final l = await _call<List>('contacts', {'query': query, 'limit': limit});
    return [for (final e in (l ?? const [])) Map<String, dynamic>.from(e as Map)];
  }
}
