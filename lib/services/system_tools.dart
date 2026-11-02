import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import 'bots.dart';
import 'live_session.dart';
import 'system_bridge.dart';
import 'wake_word.dart';

Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': name,
        'description': desc,
        'parameters': <String, dynamic>{'type': 'object', 'properties': props, if (req.isNotEmpty) 'required': req},
      },
    };

Map<String, dynamic> _s(String d, [List<String>? e]) => <String, dynamic>{'type': 'string', 'description': d, if (e != null) 'enum': e};

/// Tools that reach the phone itself: SubMac's settings, phone control (Accessibility),
/// text messages and scheduled tasks.
class SystemTools {
  static final settingsTool = _fn(
    'app_settings',
    'See or change SubMac settings when the user asks ("turn on dark mode", "make the wake word more sensitive", '
        '"stop asking me before actions", "use the Puck voice"). action=list shows every setting with its value; '
        'set changes one. open_permission opens the Android screen where the user allows a permission '
        '(overlay, accessibility, sms, notifications, battery, microphone, app). Passwords cannot be read or changed here.',
    {
      'action': _s('list, get, set or open_permission', ['list', 'get', 'set', 'open_permission']),
      'key': _s('Setting key from list (for get/set), or the permission name (for open_permission)'),
      'value': _s('New value for set (true/false, a number, or one of the allowed values)'),
    },
    ['action'],
  );

  static final phoneTools = [
    _fn('phone_screen',
        'Read what is on the phone screen right now as a numbered list. Every other phone_ action already returns the new screen, '
            'so you only need this at the start or after waiting. For a website, use browser_task instead of the phone.',
        {}),
    _fn('phone_tap', 'Tap an element: by number from the latest screen (id), or by its visible text (text, e.g. "Send", "Search").', {
      'id': <String, dynamic>{'type': 'integer', 'description': 'Element number'},
      'text': _s('Visible text or label to tap instead of a number'),
      'about': _s('Only if this tap sends, buys, posts or deletes something: say what it will do'),
    }),
    _fn('phone_long_press', 'Long-press element number id from the latest screen.', {
      'id': <String, dynamic>{'type': 'integer', 'description': 'Element number'},
    }, [
      'id'
    ]),
    _fn('phone_type',
        'Type text into field number id (replaces what is there). Leave out id to type into the focused or first field. '
            'Set enter true to press the keyboard enter/search/send key after typing.',
        {
          'id': <String, dynamic>{'type': 'integer', 'description': 'Field number (optional)'},
          'text': _s('Text to type'),
          'enter': <String, dynamic>{'type': 'boolean', 'description': 'Press enter after typing'},
        },
        ['text']),
    _fn('phone_scroll',
        'Scroll to see more: down shows what is further down, up goes back, left/right moves between pages, tabs or stories. '
            'Scrolls the main list, or list number id. Says plainly when nothing moved (the end of the list).',
        {
          'direction': _s('down, up, left or right', ['down', 'up', 'left', 'right']),
          'id': <String, dynamic>{'type': 'integer', 'description': 'A List element to scroll (optional)'},
          'amount': _s('little, page (default) or lots', ['little', 'page', 'lots']),
        },
        ['direction']),
    _fn('phone_gesture',
        'Tap, long-press or swipe at a position given in percent of the screen (0-100), for things without a number '
            '(games, maps, image areas, custom controls).',
        {
          'kind': _s('tap, long_press or swipe', ['tap', 'long_press', 'swipe']),
          'x': <String, dynamic>{'type': 'number', 'description': 'Percent from the left'},
          'y': <String, dynamic>{'type': 'number', 'description': 'Percent from the top'},
          'x2': <String, dynamic>{'type': 'number', 'description': 'Swipe end, percent from the left'},
          'y2': <String, dynamic>{'type': 'number', 'description': 'Swipe end, percent from the top'},
        },
        ['kind', 'x', 'y']),
    _fn('phone_nav', 'Press a phone button: back, home, recents, notifications, quick_settings, screenshot or lock.',
        {'action': _s('Which button', ['back', 'home', 'recents', 'notifications', 'quick_settings', 'screenshot', 'lock'])},
        ['action']),
    _fn('phone_wait', 'Wait for the app to finish loading (up to seconds, default 3), then return the screen.',
        {'seconds': <String, dynamic>{'type': 'number', 'description': 'Max seconds to wait (1-15)'}}),
  ];

  static final deviceTool = _fn(
    'phone_settings',
    'Quick phone controls without opening apps: status (battery, storage, network, volume), clipboard_read, clipboard_write, '
        'flashlight_on, flashlight_off, volume (0-100), brightness (0-100), ringer (normal, vibrate, silent), '
        'media (play, pause, next, previous) and open_settings (wifi, bluetooth, mobile_data, airplane, display, sound, battery, '
        'location, apps, storage, dnd, hotspot, nfc, date, language). Android does not let apps switch Wi-Fi, Bluetooth or airplane mode '
        'directly: open that settings page and tap the switch with phone control.',
    {
      'action': _s('What to do', [
        'status', 'clipboard_read', 'clipboard_write', 'flashlight_on', 'flashlight_off', 'volume', 'brightness', 'ringer', 'media', 'open_settings'
      ]),
      'value': _s('Text to copy, a percent, a ringer mode, a media command or a settings page'),
    },
    ['action'],
  );

  static final notifTool = _fn(
    'read_notifications',
    'Read the notifications other apps showed recently (WhatsApp, bank, delivery, missed calls...), newest first, kept only on '
        'the phone. Use for "what did I miss?", "did the bank message me?", or to summarise unread chats.',
    {
      'query': _s('Words to look for (optional)'),
      'app': _s('App name to filter, e.g. WhatsApp (optional)'),
      'limit': <String, dynamic>{'type': 'integer', 'description': 'How many (default 30, max 150)'},
    },
  );

  static final smsTool = _fn(
    'read_sms',
    'Read the user\'s text messages (SMS), newest first. Use query to find messages from a sender or containing words '
        '(for example a bank, a code, a delivery). Never read messages aloud unless the user asked.',
    {
      'query': _s('Sender or words to look for (optional)'),
      'limit': <String, dynamic>{'type': 'integer', 'description': 'How many (default 15, max 100)'},
      'box': _s('inbox, sent or all', ['inbox', 'sent', 'all']),
    },
  );

  // Calendar and contacts on the phone (plan 4, tier A): every account on the device, no sign-in.
  static final calendarTools = [
    _fn(
      'phone_calendar',
      'Read the events in the calendars on this phone (Google and every other account on the device). '
          'Use for "what\'s on today/tomorrow/this week", "when is my dentist", or to check a time is free.',
      {
        'from': _s('Local start date, ISO like 2026-10-20 (default today)'),
        'days': <String, dynamic>{'type': 'integer', 'description': 'How many days from the start (default 7, max 366)'},
        'query': _s('Words to look for in the title, place or notes (optional)'),
      },
    ),
    _fn(
      'phone_calendar_add',
      'Add an event straight into the phone\'s main calendar (it syncs to their Google or other account). '
          'Only when the user asked for it; say what you added.',
      {
        'title': _s('Event title'),
        'start': _s('Local start, ISO like 2026-10-20T15:00 (or 2026-10-20 for all day)'),
        'end': _s('Local end, ISO (optional, default one hour later)'),
        'all_day': <String, dynamic>{'type': 'boolean', 'description': 'true for an all-day event'},
        'place': _s('Where (optional)'),
        'notes': _s('Notes (optional)'),
      },
      ['title', 'start'],
    ),
  ];

  static final contactsTool = _fn(
    'phone_contacts',
    'Find people in the phone\'s contacts by name, number or email. Use before calling, texting or emailing someone the user names.',
    {
      'query': _s('Name, number or email to look for'),
      'limit': <String, dynamic>{'type': 'integer', 'description': 'How many (default 10, max 50)'},
    },
  );

  static final scheduleTools = [
    _fn(
      'schedule_task',
      'Schedule a task for SubMac to do later, once or repeating (for example "every morning at 7 send me the news", '
          '"remind me at 5pm to call mum", "every Friday check my email for invoices"). SubMac runs it at that time, '
          'even with the app closed, and sends a notification with the result.',
      {
        'task': _s('What to do, written as a complete instruction'),
        'when': _s('Local date and time to run first, ISO format like 2026-10-15T07:00'),
        'in_minutes': <String, dynamic>{'type': 'integer', 'description': 'For "in N minutes": minutes from now (instead of when)'},
        'repeat': _s('none, hourly, every_3_hours, daily, weekdays or weekly',
            ['none', 'hourly', 'every_3_hours', 'daily', 'weekdays', 'weekly']),
        'watch': {
          'type': 'boolean',
          'description': 'true for a watcher: check repeatedly and notify ONLY when something new or changed turns up '
              '(a price drops, a job is posted, a reply arrives, results are out). Defaults to every 3 hours.'
        },
      },
      ['task'],
    ),
    _fn('list_scheduled', 'List the scheduled tasks with their ids and next run time.', {}),
    _fn('cancel_scheduled', 'Cancel a scheduled task by id.', {'id': _s('Task id from list_scheduled')}, ['id']),
  ];

  static const names = {
    'app_settings',
    'phone_screen',
    'phone_tap',
    'phone_long_press',
    'phone_type',
    'phone_scroll',
    'phone_nav',
    'phone_gesture',
    'phone_wait',
    'phone_settings',
    'read_sms',
    'read_notifications',
    'phone_calendar',
    'phone_calendar_add',
    'phone_contacts',
    'schedule_task',
    'list_scheduled',
    'cancel_scheduled',
  };

  // Permission states, refreshed when the app comes back to the front.
  static Map<String, bool> perms = {};
  static Future<void> refreshPerms() async => perms = await SystemBridge.I.permissions();
  static bool get phoneControl => perms['accessibility'] == true;
  static bool get sms => perms['sms'] == true;
  static bool get notifRead => perms['notifRead'] == true;
  static bool get calendar => perms['calendar'] == true;
  static bool get contacts => perms['contacts'] == true;

  static List<Map<String, dynamic>> definitions() => [
        settingsTool,
        ...scheduleTools,
        ...phoneTools,
        deviceTool,
        if (sms) smsTool,
        if (notifRead) notifTool,
        if (calendar) ...calendarTools,
        if (contacts) contactsTool,
      ];

  /// Labels from the latest phone_screen, so a risky tap can be confirmed first.
  static final Map<int, String> screenLabels = {};

  static String labelFor(int id) => screenLabels[id] ?? '';

  static const _phoneOff = 'Phone control is off. Ask the user to turn on "Phone control" '
      '(app_settings open_permission accessibility), then try again.';

  static const _phoneStalled = 'Phone control is switched on, but Android has stopped it (this happens after an update or when '
      'battery saving closes apps). Tell the user in one short sentence: open Accessibility, turn SubMac off and on once, and set '
      'SubMac\'s battery use to Unrestricted so it stays on. Offer to open it (app_settings open_permission accessibility).';

  static String _offText = _phoneOff;

  static Future<bool> _phoneOn() async {
    final state = await SystemBridge.I.a11yState();
    perms['accessibility'] = state == 'on';
    _offText = state == 'stalled' ? _phoneStalled : _phoneOff;
    return state == 'on';
  }

  /// Waits until the screen stops changing (an app loading, a page opening), up to [max].
  static Future<void> settle({Duration max = const Duration(milliseconds: 2500)}) => _settle(max: max);

  static Future<void> _settle({Duration max = const Duration(milliseconds: 2500)}) async {
    final until = DateTime.now().add(max);
    await Future.delayed(const Duration(milliseconds: 250));
    while (DateTime.now().isBefore(until)) {
      final idle = await SystemBridge.I.a11yIdle();
      if (idle >= 450) return;
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  static Future<String> readScreen() => _readScreen();

  /// Set by the agent loop: take a marked-up screenshot with each screen read (only when the model can see).
  static bool wantShots = false;
  /// The newest phone screenshot, waiting to be attached after the tool call that made it.
  static Uint8List? pendingShot;

  static Future<String> _readScreen() async {
    final out = await SystemBridge.I.a11y('a11yScreen');
    if (out == 'PHONE_CONTROL_STALLED') return _phoneStalled;
    screenLabels.clear();
    for (final m in RegExp(r'^\[(\d+)\] \w+(?: "(.*)")?', multiLine: true).allMatches(out)) {
      screenLabels[int.parse(m.group(1)!)] = m.group(2) ?? '';
    }
    if (wantShots) {
      try {
        pendingShot = await SystemBridge.I.a11yShot();
      } catch (_) {}
    }
    return out;
  }

  /// Every action hands back the fresh screen, so the agent sees the result without another step.
  static Future<String> _after(String result) async {
    if (result == 'PHONE_CONTROL_STALLED') return _phoneStalled;
    await _settle();
    return '$result\n\nScreen now:\n${await _readScreen()}';
  }

  static Future<String> execute(AppState app, String name, Map<String, dynamic> a) async {
    int id() => a['id'] is num ? (a['id'] as num).toInt() : int.tryParse('${a['id']}') ?? -1;
    switch (name) {
      case 'app_settings':
        return _settings(app, a);
      case 'phone_screen':
        if (!await _phoneOn()) return _offText;
        return _readScreen();
      case 'phone_wait':
        if (!await _phoneOn()) return _offText;
        final secs = (a['seconds'] is num ? (a['seconds'] as num).toDouble() : 3.0).clamp(1.0, 15.0);
        await _settle(max: Duration(milliseconds: (secs * 1000).round()));
        return _readScreen();
      case 'phone_tap':
        if (!await _phoneOn()) return _offText;
        final t = '${a['text'] ?? ''}'.trim();
        final r = (a['id'] == null && t.isNotEmpty)
            ? await SystemBridge.I.a11y('a11yTapText', {'text': t})
            : await SystemBridge.I.a11y('a11yTap', {'id': id()});
        return _after(r);
      case 'phone_long_press':
        if (!await _phoneOn()) return _offText;
        return _after(await SystemBridge.I.a11y('a11yLongPress', {'id': id()}));
      case 'phone_type':
        if (!await _phoneOn()) return _offText;
        final txt = '${a['text'] ?? ''}';
        var r = a['id'] == null
            ? await SystemBridge.I.a11y('a11yTypeFocused', {'text': txt})
            : await SystemBridge.I.a11y('a11yType', {'id': id(), 'text': txt});
        if (a['enter'] == true) {
          await Future.delayed(const Duration(milliseconds: 250));
          r = '$r ${await SystemBridge.I.a11y('a11yEnter')}';
        }
        return _after(r);
      case 'phone_scroll':
        if (!await _phoneOn()) return _offText;
        return _after(await SystemBridge.I.a11y('a11yScroll', {
          'direction': '${a['direction'] ?? 'down'}',
          if (a['id'] != null) 'id': id(),
          'amount': '${a['amount'] ?? 'page'}',
        }));
      case 'phone_gesture':
        if (!await _phoneOn()) return _offText;
        double n(String k, double d) => a[k] is num ? (a[k] as num).toDouble().clamp(0.0, 100.0) : d;
        final kind = '${a['kind'] ?? 'tap'}';
        final r = kind == 'swipe'
            ? await SystemBridge.I.a11y('a11ySwipe', {'x1': n('x', 50), 'y1': n('y', 70), 'x2': n('x2', 50), 'y2': n('y2', 30)})
            : await SystemBridge.I.a11y('a11yTapAt', {'x': n('x', 50), 'y': n('y', 50), 'long': kind == 'long_press'});
        return _after(r);
      case 'phone_nav':
        if (!await _phoneOn()) return _offText;
        return _after(await SystemBridge.I.a11y('a11yGlobal', {'action': '${a['action'] ?? 'back'}'}));
      case 'phone_settings':
        return SystemBridge.I.device('${a['action'] ?? 'status'}', '${a['value'] ?? ''}');
      case 'read_notifications':
        final lim = (a['limit'] is num ? (a['limit'] as num).toInt() : 30).clamp(1, 150);
        final raw = await SystemBridge.I.notifList(limit: lim, query: '${a['query'] ?? ''}', app: '${a['app'] ?? ''}');
        if (raw.isEmpty) {
          return notifRead
              ? 'No matching notifications since SubMac was allowed to see them.'
              : 'Notification reading is off. Ask the user to allow it (app_settings open_permission notifRead).';
        }
        final nb = StringBuffer();
        for (final m in raw) {
          final d = DateTime.fromMillisecondsSinceEpoch((m['time'] as num?)?.toInt() ?? 0);
          nb.writeln('${m['app']} · ${d.toString().substring(0, 16)} · ${m['title']}: ${m['text']}');
        }
        return nb.toString();
      case 'read_sms':
        final limit = (a['limit'] is num ? (a['limit'] as num).toInt() : 15).clamp(1, 100);
        final list = await SystemBridge.I.readSms(limit: limit, query: '${a['query'] ?? ''}', box: '${a['box'] ?? 'inbox'}');
        if (list.isEmpty) return 'No matching text messages.';
        final sb = StringBuffer();
        for (final m in list) {
          final d = DateTime.fromMillisecondsSinceEpoch((m['date'] as num?)?.toInt() ?? 0);
          sb.writeln('${m['sent'] == true ? 'To' : 'From'} ${m['from']} · ${d.toString().substring(0, 16)}${m['read'] == false ? ' · unread' : ''}');
          sb.writeln('  ${m['body']}');
        }
        return sb.toString();
      case 'phone_calendar':
        if (!calendar) return 'Calendar access is off. Ask the user to allow it in Apps > On this phone.';
        final now = DateTime.now();
        final from = DateTime.tryParse('${a['from'] ?? ''}') ?? DateTime(now.year, now.month, now.day);
        final days = (a['days'] is num ? (a['days'] as num).toInt() : 7).clamp(1, 366);
        final evs = await SystemBridge.I.calendarEvents(from: DateTime(from.year, from.month, from.day), days: days, query: '${a['query'] ?? ''}');
        if (evs.isEmpty) return 'No events in that time.';
        final cb = StringBuffer();
        for (final e in evs) {
          final s = DateTime.fromMillisecondsSinceEpoch((e['start'] as num?)?.toInt() ?? 0);
          final en = DateTime.fromMillisecondsSinceEpoch((e['end'] as num?)?.toInt() ?? 0);
          final when = e['allDay'] == true
              ? '${s.toUtc().toString().substring(0, 10)} (all day)'
              : '${s.toString().substring(0, 16)}-${en.toString().substring(11, 16)}';
          cb.writeln('$when · ${e['title']}${'${e['place']}'.isEmpty ? '' : ' · ${e['place']}'} [${e['calendar']}]');
          if ('${e['notes']}'.isNotEmpty) cb.writeln('  ${e['notes']}');
        }
        return cb.toString();
      case 'phone_calendar_add':
        if (!calendar) return 'Calendar access is off. Ask the user to allow it in Apps > On this phone.';
        final title = '${a['title'] ?? ''}'.trim();
        final startRaw = '${a['start'] ?? ''}'.trim();
        final start = DateTime.tryParse(startRaw);
        if (title.isEmpty || start == null) return 'Error: give a title and a start like 2026-10-20T15:00.';
        final allDay = a['all_day'] == true || !startRaw.contains('T');
        final endP = DateTime.tryParse('${a['end'] ?? ''}');
        final st = allDay ? DateTime.utc(start.year, start.month, start.day) : start;
        final en = allDay
            ? (endP == null ? st.add(const Duration(days: 1)) : DateTime.utc(endP.year, endP.month, endP.day).add(const Duration(days: 1)))
            : endP;
        final r = await SystemBridge.I.calendarAdd(title: title, start: st, end: en, allDay: allDay, place: '${a['place'] ?? ''}', notes: '${a['notes'] ?? ''}');
        if (r == 'error:no_calendar') return 'There is no calendar on this phone that accepts new events. Ask the user to add a Google account in Android settings.';
        if (r.startsWith('error:')) return 'Error: the calendar did not save the event.';
        return 'Added "$title" on ${allDay ? '${st.toString().substring(0, 10)} (all day)' : st.toString().substring(0, 16)} to the phone calendar.';
      case 'phone_contacts':
        if (!contacts) return 'Contacts access is off. Ask the user to allow it in Apps > On this phone.';
        final lim = (a['limit'] is num ? (a['limit'] as num).toInt() : 10).clamp(1, 50);
        final people = await SystemBridge.I.contacts(query: '${a['query'] ?? ''}', limit: lim);
        if (people.isEmpty) return 'No matching contacts.';
        return [
          for (final c in people)
            '${c['name']}${(c['phones'] as List?)?.isNotEmpty == true ? ' · ${(c['phones'] as List).join(', ')}' : ''}'
                '${(c['emails'] as List?)?.isNotEmpty == true ? ' · ${(c['emails'] as List).join(', ')}' : ''}'
        ].join('\n');
      case 'schedule_task':
        // Without notification permission the user would never hear back: ask now (Android 13+).
        try {
          final st = await Permission.notification.status;
          if (!st.isGranted && !st.isPermanentlyDenied) await Permission.notification.request();
        } catch (_) {}
        return Scheduler.I.add('${a['task'] ?? ''}', '${a['when'] ?? ''}', '${a['repeat'] ?? 'none'}',
            watch: a['watch'] == true, inMinutes: int.tryParse('${a['in_minutes'] ?? ''}'));
      case 'list_scheduled':
        return Scheduler.I.describe();
      case 'cancel_scheduled':
        return Scheduler.I.cancel('${a['id'] ?? ''}');
    }
    return 'Unknown tool $name';
  }

  // ---------------- settings ----------------
  static List<Map<String, String>> _list(AppState app) {
    final w = WakeWord.I;
    String themeName(ThemeMode m) => m.name;
    return [
      {'key': 'theme', 'value': themeName(app.themeMode), 'allowed': 'system, light, dark'},
      {'key': 'reply_language', 'value': app.replyLanguage, 'allowed': 'auto, Somali, English, Arabic'},
      {'key': 'approval_mode', 'value': app.approvalMode, 'allowed': 'ask (New: confirm every change), full (Trusted: routine changes without asking; still confirms money, sending and deleting)'},
      {'key': 'actions_enabled', 'value': '${app.agentEnabled}', 'allowed': 'true, false (lets SubMac take actions)'},
      {'key': 'memory', 'value': '${app.memoryEnabled}', 'allowed': 'true, false'},
      {'key': 'live_voice', 'value': app.liveVoice, 'allowed': LiveSession.voices.join(', ')},
      {'key': 'wake_word', 'value': '${w.enabled}', 'allowed': 'true, false ("Hello SubMac")'},
      {'key': 'wake_sensitivity', 'value': w.sensitivity.toStringAsFixed(2), 'allowed': '0.1 (strict) to 0.95 (very sensitive)'},
      {'key': 'wake_screen_off', 'value': '${w.screenOff}', 'allowed': 'true, false (listen with the screen off)'},
      {'key': 'notify_when_done', 'value': '${app.notifyWhenDone}', 'allowed': 'true, false (notification when a task finishes)'},
      {'key': 'about_you', 'value': app.aboutYou, 'allowed': 'free text'},
      {'key': 'how_to_respond', 'value': app.howToRespond, 'allowed': 'free text'},
    ];
  }

  static bool? _bool(String v) {
    final t = v.trim().toLowerCase();
    if (['true', 'on', 'yes', '1', 'enable', 'enabled'].contains(t)) return true;
    if (['false', 'off', 'no', '0', 'disable', 'disabled'].contains(t)) return false;
    return null;
  }

  static Future<String> _settings(AppState app, Map<String, dynamic> a) async {
    final action = '${a['action'] ?? 'list'}';
    final key = '${a['key'] ?? ''}'.trim();
    final value = '${a['value'] ?? ''}'.trim();
    final all = _list(app);
    if (action == 'list') {
      return all.map((e) => '${e['key']} = ${e['value']}   (${e['allowed']})').join('\n');
    }
    if (action == 'open_permission') {
      final p = key.toLowerCase();
      if (p == 'microphone' || p == 'sms') {
        await SystemBridge.I.openPermission('app');
      } else {
        await SystemBridge.I.openPermission(p);
      }
      return 'Opened the Android screen for "$key". Tell the user what to switch on there.';
    }
    final row = all.where((e) => e['key'] == key).firstOrNull;
    if (row == null) return 'Unknown setting "$key". Use action=list to see them.';
    if (action == 'get') return '$key = ${row['value']}';
    String bad() => 'Not a valid value for $key. Allowed: ${row['allowed']}';
    final b = _bool(value);
    switch (key) {
      case 'reply_language':
        const ok = {'auto': 'auto', 'somali': 'Somali', 'english': 'English', 'arabic': 'Arabic'};
        final v = ok[value.toLowerCase().trim()];
        if (v == null) return bad();
        app.setReplyLanguage(v);
        break;
      case 'theme':
        final m = {'system': ThemeMode.system, 'light': ThemeMode.light, 'dark': ThemeMode.dark}[value.toLowerCase()];
        if (m == null) return bad();
        app.setThemeMode(m);
        break;
      case 'approval_mode':
        final v = value.toLowerCase().startsWith('f') ? 'full' : (value.toLowerCase().startsWith('a') ? 'ask' : '');
        if (v.isEmpty) return bad();
        app.setApprovalMode(v);
        break;
      case 'actions_enabled':
        if (b == null) return bad();
        app.setAgentEnabled(b);
        break;
      case 'memory':
        if (b == null) return bad();
        app.setMemoryEnabled(b);
        break;
      case 'live_voice':
        final v = LiveSession.voices.where((x) => x.toLowerCase() == value.toLowerCase()).firstOrNull;
        if (v == null) return bad();
        app.setLiveVoice(v);
        return 'live_voice = $v (used from the next Live call).';
      case 'wake_word':
        if (b == null) return bad();
        await WakeWord.I.setEnabled(b);
        if (b && WakeWord.I.setup != WakeSetup.ready) return 'Turned on. The voice pack (about 40 MB) is downloading now; it starts listening when done.';
        break;
      case 'wake_sensitivity':
        final d = double.tryParse(value);
        if (d == null) return bad();
        await WakeWord.I.setSensitivity(d.clamp(0.1, 0.95));
        break;
      case 'wake_screen_off':
        if (b == null) return bad();
        await WakeWord.I.setScreenOff(b);
        break;
      case 'notify_when_done':
        if (b == null) return bad();
        app.setNotifyWhenDone(b);
        break;
      case 'about_you':
        await app.saveCustomInstructions(value, app.howToRespond);
        break;
      case 'how_to_respond':
        await app.saveCustomInstructions(app.aboutYou, value);
        break;
    }
    final now = _list(app).firstWhere((e) => e['key'] == key);
    return 'Done: $key = ${now['value']}';
  }
}

/// Tasks SubMac runs later (once or repeating), even when the app is closed.
class ScheduledTask {
  final String id;
  final String task;
  DateTime next;
  final String repeat; // none | hourly | every_3_hours | daily | weekdays | weekly
  /// A watcher only notifies when something new turns up; [last] is what it found last time.
  final bool watch;
  String last;
  /// The one chat this task writes its results into, so repeats never fill the sidebar.
  String convId;
  /// The account (signed-in user id) this task belongs to. Empty only for tasks saved before v1.13.77.
  String uid;
  /// The bot that scheduled it (from its own chat): the bot itself wakes, does the work and notifies, instead of
  /// SubMac running it in a separate "Scheduled:" chat (owner 2026-11-02: "the bot should be a bot").
  String bot;
  ScheduledTask(this.id, this.task, this.next, this.repeat,
      {this.watch = false, this.last = '', this.convId = '', this.uid = '', this.bot = ''});

  Map<String, dynamic> toJson() => {
        'id': id, 'task': task, 'next': next.toIso8601String(), 'repeat': repeat, 'watch': watch, 'last': last,
        'conv': convId, 'uid': uid, if (bot.isNotEmpty) 'bot': bot,
      };
  static ScheduledTask fromJson(Map<String, dynamic> j) =>
      ScheduledTask('${j['id']}', '${j['task']}', DateTime.parse('${j['next']}'), '${j['repeat'] ?? 'none'}',
          watch: j['watch'] == true, last: '${j['last'] ?? ''}', convId: '${j['conv'] ?? ''}', uid: '${j['uid'] ?? ''}',
          bot: '${j['bot'] ?? ''}');

  DateTime? following() {
    switch (repeat) {
      case 'hourly':
        return next.add(const Duration(hours: 1));
      case 'every_3_hours':
        return next.add(const Duration(hours: 3));
      case 'daily':
        return next.add(const Duration(days: 1));
      case 'weekly':
        return next.add(const Duration(days: 7));
      case 'weekdays':
        var d = next.add(const Duration(days: 1));
        while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
          d = d.add(const Duration(days: 1));
        }
        return d;
    }
    return null;
  }
}

/// Scheduled tasks belong to the ACCOUNT, not the phone (owner decision 2026-10-23, ISSUES T-03).
/// [tasks] holds only the signed-in account's tasks; other accounts' tasks stay saved on this phone, unarmed,
/// until that account signs in again. Signed out, nothing is armed and nothing runs.
class Scheduler extends ChangeNotifier {
  Scheduler._();
  static final I = Scheduler._();
  @visibleForTesting
  Scheduler.forTest();
  final List<ScheduledTask> tasks = [];
  /// Tasks of other accounts on this phone, kept as saved and never armed or run here.
  final List<ScheduledTask> _others = [];
  SharedPreferences? _p;
  String _uid = '';
  Future<void>? _loading;

  /// The account whose tasks are loaded ('' = signed out).
  String get uid => _uid;

  /// Runs a task (set by AppState): starts it in the background and notifies when done.
  Future<void> Function(ScheduledTask t)? runTask;

  static Future<void> _arm(String id, DateTime at) async {
    try {
      await SystemBridge.I.scheduleAlarm(id, at);
    } catch (_) {}
  }

  static Future<void> _disarm(String id) async {
    try {
      await SystemBridge.I.cancelAlarm(id);
    } catch (_) {}
  }

  /// Loads the saved tasks for [uid] (the signed-in user id, or empty when signed out).
  Future<void> init({String? uid}) async {
    _p ??= await SharedPreferences.getInstance();
    await useAccount(uid ?? '');
  }

  /// Switches to [uid]'s tasks: the previous account's alarms are cancelled and only [uid]'s are armed.
  /// Untagged tasks from before v1.13.77 move to the first account that is signed in.
  Future<void> useAccount(String uid) async {
    while (_loading != null) {
      await _loading;
    }
    final c = Completer<void>();
    _loading = c.future;
    try {
      await _useAccount(uid);
    } finally {
      _loading = null;
      c.complete();
    }
  }

  Future<void> _useAccount(String uid) async {
    _p ??= await SharedPreferences.getInstance();
    final p = _p!;
    for (final t in tasks) {
      await _disarm(t.id);
    }
    tasks.clear();
    _others.clear();
    _uid = uid;
    final all = <ScheduledTask>[];
    try {
      for (final e in jsonDecode(p.getString('scheduled') ?? '[]') as List) {
        all.add(ScheduledTask.fromJson(Map<String, dynamic>.from(e as Map)));
      }
    } catch (_) {}
    for (final t in all) {
      if (t.uid.isEmpty && uid.isNotEmpty) t.uid = uid; // one-time migration
      if (uid.isNotEmpty && t.uid == uid) {
        tasks.add(t);
      } else {
        _others.add(t);
        await _disarm(t.id);
      }
    }
    // Catch up anything missed while the phone was off, and re-arm alarms.
    final now = DateTime.now();
    for (final t in List.of(tasks)) {
      if (t.next.isBefore(now.subtract(const Duration(minutes: 30)))) {
        final f = t.following();
        if (f == null) {
          tasks.remove(t);
          continue;
        }
        while (t.next.isBefore(now)) {
          t.next = t.following()!;
        }
      }
      await _arm(t.id, t.next.isBefore(now) ? now.add(const Duration(seconds: 5)) : t.next);
    }
    await _save();
  }

  /// The account was deleted: its tasks are cancelled and removed from this phone.
  Future<void> dropAccount() async {
    for (final t in tasks) {
      await _disarm(t.id);
    }
    tasks.clear();
    _uid = '';
    await _save();
  }

  Future<void> _save() async {
    _p ??= await SharedPreferences.getInstance();
    await _p!.setString('scheduled', jsonEncode([...tasks, ..._others].map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> setLast(String id, String text) async {
    final t = tasks.where((e) => e.id == id).firstOrNull;
    if (t == null) return;
    t.last = text.length > 1200 ? text.substring(0, 1200) : text;
    await _save();
  }

  Future<String> add(String task, String when, String repeat, {bool watch = false, String bot = '', int? inMinutes}) async {
    if (task.trim().isEmpty) return 'Error: say what the task should do.';
    if (_uid.isEmpty) return 'Error: sign in first; scheduled tasks belong to your account.';
    // "In N minutes" is counted here, from the real clock: the model's own idea of "now" can be off.
    final at = inMinutes != null && inMinutes > 0
        ? DateTime.now().add(Duration(minutes: inMinutes))
        : DateTime.tryParse(when.trim().replaceAll(' ', 'T'));
    if (at == null) return 'Error: give in_minutes, or "when" as a date and time like 2026-10-15T07:00.';
    if (at.isBefore(DateTime.now()) && repeat == 'none') return Bots.pastTimeError(when, DateTime.now());
    var first = at;
    if (watch && repeat == 'none') repeat = 'every_3_hours';
    final t = ScheduledTask('s${DateTime.now().millisecondsSinceEpoch}', task.trim(), first, repeat, watch: watch, uid: _uid, bot: bot);
    while (t.next.isBefore(DateTime.now())) {
      final f = t.following();
      if (f == null) break;
      t.next = f;
    }
    tasks.add(t);
    await _arm(t.id, t.next);
    await _save();
    return 'Scheduled (${t.id}): "${t.task}" at ${_fmt(t.next)}${repeat == 'none' ? '' : ', repeating $repeat'}. '
        '${watch ? 'It is a watcher: it is checked each time and notifies only when something new turns up.' : bot.isNotEmpty ? 'You will be woken then to do it yourself and message the result.' : 'SubMac will run it and send a notification.'}';
  }

  Future<String> cancel(String id) async {
    final t = tasks.where((e) => e.id == id).firstOrNull;
    if (t == null) return 'No scheduled task with id $id.';
    tasks.remove(t);
    await _disarm(id);
    await _save();
    return 'Cancelled "${t.task}".';
  }

  String describe() {
    if (tasks.isEmpty) return 'No scheduled tasks.';
    return tasks.map((t) => '${t.id}: "${t.task}" next ${_fmt(t.next)}${t.repeat == 'none' ? '' : ' (${t.repeat})'}${t.watch ? ' [watcher]' : ''}').join('\n');
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> setConv(String id, String conv) async {
    final t = tasks.where((e) => e.id == id).firstOrNull;
    if (t == null || t.convId == conv) return;
    t.convId = conv;
    await _save();
  }

  /// The alarm fired.
  Future<void> fire(String id) async {
    // Only the signed-in account's own tasks ever run; another account's alarm is cancelled and ignored.
    final t = _uid.isEmpty ? null : tasks.where((e) => e.id == id && e.uid == _uid).firstOrNull;
    if (t == null) {
      if (_others.any((e) => e.id == id)) await _disarm(id);
      await SystemBridge.I.keepAlive(false);
      return;
    }
    final f = t.following();
    if (f == null) {
      tasks.remove(t);
    } else {
      t.next = f;
      await _arm(t.id, t.next);
    }
    await _save();
    await runTask?.call(t);
  }
}
