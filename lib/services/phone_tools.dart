import 'dart:async';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'system_bridge.dart';
import 'system_tools.dart';

/// Bridge to the Android side (MainActivity.kt): phone intents and "Share to SubMac".
class NativeBridge {
  static const channel = MethodChannel('submac/native');

  static void Function()? onShared;
  static bool _listening = false;

  static void listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') onShared?.call();
      return null;
    });
  }

  /// Text and files the user shared into SubMac from another app, if any.
  static Future<Map<String, dynamic>?> takeShared() async {
    try {
      final r = await channel.invokeMethod<dynamic>('takeShared');
      if (r is Map) return Map<String, dynamic>.from(r);
    } catch (_) {}
    return null;
  }

  static Future<dynamic> call(String method, [Map<String, dynamic>? args]) => channel.invokeMethod<dynamic>(method, args);
}

/// Phone actions. Each one opens the right app with everything filled in,
/// and the user taps to finish, so nothing happens behind their back.
class PhoneTools {
  static const names = {'set_alarm', 'set_timer', 'add_calendar_event', 'call_number', 'send_sms', 'open_link', 'open_app', 'share_text'};

  /// A file on the phone (a file:// link) cannot be handed to another app as a link: Android
  /// throws FileUriExposedException. The model is told how to show it instead; null for real links.
  static String? localFileNote(Uri u) {
    if (u.scheme != 'file') return null;
    final path = u.path;
    return 'Error: a file on this phone cannot be opened as a link. Show it to the user with a ```file block instead '
        '(it has Open and Share buttons):\n```file\n$path\n```';
  }

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> required) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  static final List<Map<String, dynamic>> definitions = [
    _fn('set_alarm',
        'Set an alarm in the Clock app directly (saved at once, no tapping). It rings at the next time that hour:minute comes, '
            'so "tomorrow 7am" is hour 7 when it is already past 7 today. days repeats it (1=Sunday ... 7=Saturday).', {
      'hour': {'type': 'integer', 'description': '0-23'},
      'minute': {'type': 'integer', 'description': '0-59'},
      'label': {'type': 'string'},
      'days': {'type': 'array', 'items': {'type': 'integer'}, 'description': 'Repeat days, 1=Sunday..7=Saturday (optional)'},
    }, ['hour', 'minute']),
    _fn('set_timer', 'Start a countdown timer in the Clock app right away.', {
      'seconds': {'type': 'integer'},
      'label': {'type': 'string'},
    }, ['seconds']),
    _fn('add_calendar_event', 'Open the Calendar app with a new event filled in for the user to save.', {
      'title': {'type': 'string'},
      'start': {'type': 'string', 'description': 'Local start time, ISO 8601 like 2026-10-20T15:00'},
      'end': {'type': 'string', 'description': 'Local end time (default: one hour after start)'},
      'all_day': {'type': 'boolean'},
      'location': {'type': 'string'},
      'description': {'type': 'string'},
    }, ['title', 'start']),
    _fn('call_number', 'Open the phone dialer with a number ready. The user taps call.', {
      'number': {'type': 'string'},
    }, ['number']),
    _fn('send_sms', 'Open the messages app with a text drafted. The user taps send.', {
      'number': {'type': 'string', 'description': 'Phone number (optional)'},
      'message': {'type': 'string'},
    }, ['message']),
    _fn('open_link', 'Open a web page, map, email (mailto:) or app link on the phone.', {
      'url': {'type': 'string'},
    }, ['url']),
    _fn('open_app', 'Open an installed app by its name, e.g. "WhatsApp" or "Camera".', {
      'name': {'type': 'string'},
    }, ['name']),
    _fn('share_text', 'Open the Android share sheet with some text, so the user can send it with any app.', {
      'text': {'type': 'string'},
      'subject': {'type': 'string'},
    }, ['text']),
  ];

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      switch (name) {
        case 'set_alarm':
          await NativeBridge.call('setAlarm', {
            'hour': (a['hour'] as num?)?.toInt() ?? 7,
            'minute': (a['minute'] as num?)?.toInt() ?? 0,
            'label': (a['label'] ?? '').toString(),
            if (a['days'] is List) 'days': [for (final d in a['days'] as List) if (d is num) d.toInt()],
            'skipUi': true,
          });
          final h = (a['hour'] as num?)?.toInt() ?? 7, mi = (a['minute'] as num?)?.toInt() ?? 0;
          return 'Alarm set for ${h.toString().padLeft(2, '0')}:${mi.toString().padLeft(2, '0')} in the Clock app.';
        case 'set_timer':
          await NativeBridge.call('setTimer', {
            'seconds': ((a['seconds'] as num?)?.toInt() ?? 60).clamp(1, 86400),
            'label': (a['label'] ?? '').toString(),
          });
          return 'Timer started in the Clock app.';
        case 'add_calendar_event':
          final start = DateTime.tryParse((a['start'] ?? '').toString());
          if (start == null) return 'Error: start time must look like 2026-10-20T15:00';
          final end = DateTime.tryParse((a['end'] ?? '').toString()) ?? start.add(const Duration(hours: 1));
          await NativeBridge.call('addEvent', {
            'title': (a['title'] ?? '').toString(),
            'begin': start.millisecondsSinceEpoch,
            'end': end.millisecondsSinceEpoch,
            'allDay': a['all_day'] == true,
            'location': (a['location'] ?? '').toString(),
            'description': (a['description'] ?? '').toString(),
          });
          return 'Opened the Calendar with the event filled in. The user taps save.';
        case 'call_number':
          final n = (a['number'] ?? '').toString().replaceAll(RegExp(r'[^0-9+*#]'), '');
          if (n.isEmpty) return 'Error: no phone number.';
          await launchUrl(Uri(scheme: 'tel', path: n));
          return 'Opened the dialer with $n. The user taps call.';
        case 'send_sms':
          final n = (a['number'] ?? '').toString().replaceAll(RegExp(r'[^0-9+]'), '');
          final body = (a['message'] ?? '').toString();
          final uri = Uri.parse('sms:$n?body=${Uri.encodeComponent(body)}');
          await launchUrl(uri);
          return 'Opened Messages with the text drafted. The user taps send.';
        case 'open_link':
          final u = Uri.tryParse((a['url'] ?? '').toString());
          if (u == null || !u.hasScheme) return 'Error: that is not a full link.';
          final local = PhoneTools.localFileNote(u);
          if (local != null) return local;
          final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
          return ok ? 'Opened ${u.host.isEmpty ? u.toString() : u.host}.' : 'Error: no app can open that link.';
        case 'open_app':
          final r = await NativeBridge.call('openApp', {'name': (a['name'] ?? '').toString()});
          if (r == null) return 'Error: could not find that app.';
          if (!await SystemBridge.I.a11yEnabled()) return 'Opened $r.';
          await SystemTools.settle(max: const Duration(milliseconds: 3500));
          return 'Opened $r.\n\nScreen now:\n${await SystemTools.readScreen()}';
        case 'share_text':
          await SharePlus.instance.share(ShareParams(text: (a['text'] ?? '').toString(), subject: (a['subject'] as String?)));
          return 'Opened the share sheet.';
      }
      return 'Error: unknown tool "$name"';
    } on PlatformException catch (e) {
      return 'Error: ${e.message ?? e.code}';
    } on MissingPluginException {
      return 'Error: this phone action is not available in this build.';
    } catch (e) {
      return 'Error: $e';
    }
  }
}
