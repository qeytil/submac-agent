import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'bots.dart';
import 'system_bridge.dart';
import 'tools.dart';
import 'whatsapp_text.dart';

export 'whatsapp_text.dart';

/// WhatsApp and WhatsApp Business on the user's own phone: read new messages from notifications, quick-reply,
/// send to anyone, read a chat, send a file, start a call, and let bots watch chats. No WhatsApp Web, no
/// unofficial client, no Meta API: SubMac uses the phone the way the user would, with their permission.
///
/// One tool ("whatsapp", with an action) keeps the toolbox lean. Sends, files and calls always pass the
/// approval card in AppState (see [approvalFor]) unless the user trusted that bot for WhatsApp.
class WhatsAppTools {
  static const tool = 'whatsapp';
  static const names = {tool};

  /// Actions that reach another person: they need the user's OK.
  static const outgoing = {'send', 'reply', 'send_bulk', 'send_file', 'call'};

  static SharedPreferences? _p;
  static final limiter = WaLimiter();

  static Future<void> init() async {
    _p ??= await SharedPreferences.getInstance();
  }

  /// Bots the user lets send on WhatsApp without asking each time (kept on this phone only).
  static Set<String> get trustedBots => {...(_p?.getStringList('wa_trusted') ?? const <String>[])};
  static bool trusted(String botId) => trustedBots.contains(botId);
  static Future<void> setTrusted(String botId, bool on) async {
    await init();
    final s = trustedBots;
    on ? s.add(botId) : s.remove(botId);
    await _p!.setStringList('wa_trusted', s.toList());
  }

  /// "personal" or "business": which WhatsApp to use when the user does not say.
  static String get defaultApp => _p?.getString('wa_default') ?? 'personal';
  static Future<void> setDefaultApp(String v) async {
    await init();
    await _p!.setString('wa_default', v);
  }

  static Map<String, dynamic> _fn(String desc, Map<String, dynamic> props) => {
        'type': 'function',
        'function': {
          'name': tool,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': ['action']},
        },
      };

  static const _desc = 'WhatsApp and WhatsApp Business on this phone. '
      'inbox: new messages per chat (from notifications). read: open a chat and read it. '
      'reply: answer a chat (instant from its notification when possible). send: message a number (with country code) or a chat name. '
      'send_bulk: same message to up to 20 people. send_file: a file you made (pdf, image, doc). call: voice/video call (the user talks, you cannot). '
      'watch: (bots) wake when a chat or keyword arrives. status: what is set up. The user approves every message, file and call.';

  static const _props = {
    'action': {
      'type': 'string',
      'enum': ['inbox', 'read', 'reply', 'send', 'send_bulk', 'send_file', 'call', 'watch', 'status'],
    },
    'to': {'type': 'string', 'description': 'Chat or contact name, or number with country code (+252...).'},
    'message': {'type': 'string', 'description': 'Text to send. Short, natural, in the chat\'s language.'},
    'recipients': {'type': 'array', 'items': {'type': 'string'}, 'description': 'send_bulk: numbers or chat names (max 20).'},
    'path': {'type': 'string', 'description': 'send_file: the file path.'},
    'video': {'type': 'boolean'},
    'more': {'type': 'boolean', 'description': 'read: scroll up for older messages.'},
    'unread_only': {'type': 'boolean'},
    'app': {'type': 'string', 'enum': ['personal', 'business'], 'description': 'Default: the user\'s choice.'},
    'keyword': {'type': 'string', 'description': 'watch: word to wake on.'},
    'instruction': {'type': 'string', 'description': 'watch: what to do then; op: add|remove|list in "op".'},
    'op': {'type': 'string', 'enum': ['add', 'remove', 'list']},
  };

  static final Map<String, dynamic> definition = _fn(_desc, _props);

  /// How to be good at WhatsApp. Rides along in the tool description only when the chat is about WhatsApp.
  static const guide = '\nHOW TO USE WHATSAPP WELL:\n'
      '- Start with inbox to see who wrote. For one chat\'s history, read (it opens WhatsApp; more:true for older).\n'
      '- Answering someone who just wrote: reply (sends from the notification, no screen needed, works when locked). '
      'Someone new or no notification: send with their full number (+country code) or exact chat name.\n'
      '- Write like a person on WhatsApp: short lines, no headings, no markdown links, no tables. *bold*, _italic_, ~strike~ '
      'work. One or two emoji at most, only if the chat uses them.\n'
      '- Reply in the language the chat is in (Somali, Arabic, English...). Natural everyday Somali, not formal. Arabic right '
      'to left is fine as is.\n'
      '- Groups: only reply when asked; address the person by name; never forward private chat content to a group.\n'
      '- Business chats: greet, answer the exact question (price, stock, delivery, location), give a clear next step, sign '
      'off politely. Never invent prices or promises: ask the owner when unsure.\n'
      '- Never spam: no bulk messages unless the user asked, max 20 people, same message only when it fits everyone, '
      'and never to people who did not contact the user or agree to hear from them.\n'
      '- Calls: you cannot talk in a WhatsApp call; say the call is ringing and the user speaks.\n'
      '- Sending: the user sees an approval card first (they can edit). If it says "opened for the user", the message is '
      'typed in WhatsApp and they tap Send.';

  static final Map<String, dynamic> withGuide = _fn(_desc + guide, _props);

  static final hint = RegExp(r'whats ?app|wa\.me|\bwatsap|واتس|واتساب|wasaab|watsab', caseSensitive: false);

  // ---------------------------------------------------------------- approval

  static String _s(Map<String, dynamic> a, String k) => '${a[k] ?? ''}'.trim();

  static List<String> _recipients(Map<String, dynamic> a) =>
      [for (final r in (a['recipients'] is List ? a['recipients'] as List : const [])) '$r'.trim()].where((e) => e.isNotEmpty).toList();

  /// The approval card for an outgoing action, or null when the action reaches nobody.
  static ActionRequest? approvalFor(Map<String, dynamic> a) {
    final act = _s(a, 'action');
    if (!outgoing.contains(act)) return null;
    final to = _s(a, 'to');
    final msg = _s(a, 'message');
    final app = WaText.appName(WaText.pkgFor(_s(a, 'app'), WaText.pkgFor(defaultApp, WaText.personal)));
    switch (act) {
      case 'call':
        return ActionRequest(
          title: '${a['video'] == true ? 'Video' : 'Voice'} call $to on $app?',
          body: 'SubMac opens the chat and starts the call. You do the talking.',
          detail: to,
          confirmLabel: 'Call',
        );
      case 'send_file':
        return ActionRequest(
          title: 'Send ${_s(a, 'path').split('/').last} to $to on $app?',
          body: msg.isEmpty ? 'The file goes to this chat.' : 'With the message below.',
          detail: msg.isEmpty ? _s(a, 'path') : msg,
          confirmLabel: 'Send',
          edit: msg.isEmpty ? null : TextBox(msg),
        );
      case 'send_bulk':
        final r = _recipients(a);
        return ActionRequest(
          title: 'Send this to ${r.length} people on $app?',
          body: r.take(8).join(', ') + (r.length > 8 ? ' and ${r.length - 8} more' : ''),
          detail: msg,
          confirmLabel: 'Send all',
          edit: TextBox(msg),
        );
      default:
        return ActionRequest(
          title: '${act == 'reply' ? 'Reply to' : 'Send to'} $to on $app?',
          body: msg.length > 160 ? '${msg.substring(0, 160)}…' : msg,
          detail: msg,
          confirmLabel: 'Send',
          edit: TextBox(msg),
        );
    }
  }

  // ---------------------------------------------------------------- running

  static Future<Map<String, dynamic>> status() async {
    try {
      final s = await SystemBridge.I.waCall<String>('waStatus');
      if (s != null) return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {}
    return {};
  }

  static String statusText(Map<String, dynamic> st) {
    if (st.isEmpty) return 'WhatsApp tools are not available in this build or on this device.';
    final apps = [if (st['personal'] == true) 'WhatsApp', if (st['business'] == true) 'WhatsApp Business'];
    return [
      apps.isEmpty ? 'WhatsApp is not installed on this phone.' : 'Installed: ${apps.join(' and ')} (default: ${WaText.appName(WaText.pkgFor(defaultApp, WaText.personal))}).',
      'Notification access: ${st['notifRead'] == true ? 'on (new messages are read)' : 'off (needed for inbox, reply and watches)'}.',
      'Phone control: ${st['phoneControl'] == true ? 'on (can open chats and press Send/Call)' : 'off (needed for send, read, files and calls)'}.',
      if (st['capture'] == false) 'Keeping messages is switched off by the user.',
      if (st['locked'] == true) 'The phone is locked right now: only quick replies from notifications work.',
      'Saved chats: ${st['chats'] ?? 0}.',
      if (st['notifRead'] != true || st['phoneControl'] != true) 'The user can switch these on in SubMac > Apps > WhatsApp.',
    ].join('\n');
  }

  static Future<String> _resolvePath(String p) async {
    if (p.startsWith('/')) return p;
    return '${await AgentTools.workspaceDir()}/$p';
  }

  /// Runs one WhatsApp step on the phone. [act] is send_phone | send_name | open_phone | open_name | read | call | share | title.
  static Future<Map<String, dynamic>> _act(String act, String pkg, Map<String, dynamic> extra) async {
    try {
      final s = await SystemBridge.I.waAct({'action': act, 'pkg': pkg, ...extra});
      if (s == null) return {'ok': false, 'state': 'unavailable', 'detail': 'WhatsApp actions are not available in this build.'};
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } on TimeoutException {
      return {'ok': false, 'state': 'timeout', 'detail': 'WhatsApp took too long. Check the phone screen.'};
    } catch (e) {
      return {'ok': false, 'state': 'error', 'detail': '$e'};
    }
  }

  static String _explain(Map<String, dynamic> r, String what) {
    final st = '${r['state']}';
    final d = '${r['detail'] ?? ''}';
    switch (st) {
      case 'sent':
        return 'Sent on WhatsApp$what${'${r['chat'] ?? ''}'.isEmpty ? '' : ' (chat: ${r['chat']})'}.';
      case 'pending':
        return 'Queued on WhatsApp$what: it goes as soon as the phone is online.';
      case 'opened_for_user':
        return 'Not sent yet$what: $d Tell the user to tap Send in WhatsApp.';
      case 'locked':
        return 'Error: the phone is locked, so WhatsApp cannot be opened$what. Ask the user to unlock it (a reply to a chat that just wrote can still go from its notification).';
      case 'not_installed':
        return 'Error: $d';
      case 'phone_control_off':
        return 'Error: phone control is off, so SubMac cannot press Send$what. Ask the user to turn it on in SubMac > Apps > WhatsApp, or use a number (then WhatsApp opens with the text ready for them).';
      case 'not_found':
        return 'Error$what: ${d.isEmpty ? 'that chat was not found' : d} Ask the user for the exact chat name or the number with country code.';
      default:
        return 'Error$what: ${d.isEmpty ? st : d}';
    }
  }

  static Future<Map<String, dynamic>> _chatInfo(String q, String pkg) async {
    try {
      final s = await SystemBridge.I.waCall<String>('waChat', {'query': q, 'pkg': pkg});
      return s == null ? {} : Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return {};
    }
  }

  /// Sends [msg] to [to] (a number or a chat name), paced by [limiter].
  static Future<String> _sendOne(String to, String msg, String pkg) async {
    final now = DateTime.now();
    if (limiter.hourFull(now)) {
      return 'Error: ${limiter.perHour} WhatsApp messages went out in the last hour. Wait before sending more, so the number is not flagged as spam.';
    }
    final w = limiter.waitBefore(now);
    if (w > Duration.zero) await Future<void>.delayed(w);
    Map<String, dynamic> r;
    if (WaText.looksLikePhone(to)) {
      final d = WaText.phoneDigits(to);
      if (d == null) return 'Error: "$to" has no country code. Ask the user for the full number, like +252 61 234 5678.';
      r = await _act('send_phone', pkg, {'phone': d, 'text': msg});
    } else {
      final info = await _chatInfo(to, pkg);
      final ph = '${info['phone'] ?? ''}';
      r = ph.isNotEmpty && info['group'] != true
          ? await _act('send_phone', pkg, {'phone': ph, 'text': msg})
          : await _act('send_name', pkg, {'name': '${info['name'] ?? to}', 'text': msg});
    }
    if (r['ok'] == true) limiter.mark(DateTime.now());
    return _explain(r, ' to $to');
  }

  /// [convId] is the chat the call came from (bots are found by it); [afterUi] brings SubMac back after WhatsApp
  /// was opened on screen.
  static Future<String> execute(Map<String, dynamic> a, {String? convId, Future<void> Function()? afterUi}) async {
    await init();
    if (!Platform.isAndroid) return 'Error: WhatsApp actions work on Android phones only.';
    final act = _s(a, 'action');
    final st = await status();
    if (st.isEmpty) return 'Error: WhatsApp tools are not available in this build.';
    final def = WaText.pkgFor(defaultApp, WaText.personal);
    var pkg = WaText.pkgFor(_s(a, 'app'), def);
    // Only one WhatsApp installed: use it whatever the default says.
    if (pkg == WaText.personal && st['personal'] != true && st['business'] == true) pkg = WaText.business;
    if (pkg == WaText.business && st['business'] != true && st['personal'] == true && _s(a, 'app').isEmpty) pkg = WaText.personal;
    final to = _s(a, 'to');
    final msg = _s(a, 'message');
    const needNotif = 'Error: notification access is off, so SubMac cannot see WhatsApp messages. Ask the user to switch it on in SubMac > Apps > WhatsApp.';
    switch (act) {
      case 'status':
        return statusText(st);
      case 'inbox':
        if (st['notifRead'] != true) return needNotif;
        final s = await SystemBridge.I.waCall<String>('waInbox', {
          'pkg': _s(a, 'app').isEmpty ? '' : pkg,
          'query': to,
          'unread': a['unread_only'] == true,
          'limit': 15,
          'per': to.isEmpty ? 4 : 20,
        });
        final list = s == null ? <Map<String, dynamic>>[] : [for (final e in jsonDecode(s) as List) Map<String, dynamic>.from(e as Map)];
        return WaText.inboxText(list, unreadOnly: a['unread_only'] == true);
      case 'read':
        if (st['phoneControl'] != true) {
          if (st['notifRead'] == true && to.isNotEmpty) {
            final s = await SystemBridge.I.waCall<String>('waInbox', {'pkg': '', 'query': to, 'unread': false, 'limit': 1, 'per': 30});
            final list = s == null ? <Map<String, dynamic>>[] : [for (final e in jsonDecode(s) as List) Map<String, dynamic>.from(e as Map)];
            if (list.isNotEmpty) {
              return '${WaText.inboxText(list)}\n(Only messages that came in as notifications. Turn on phone control in SubMac > Apps > WhatsApp to read the whole chat.)';
            }
          }
          return 'Error: phone control is off, so SubMac cannot open WhatsApp chats. Ask the user to turn it on in SubMac > Apps > WhatsApp.';
        }
        if (to.isNotEmpty) {
          final o = await _open(to, pkg);
          if (o != null) return o;
        }
        final r = await _act('read', pkg, {'pages': a['more'] == true ? 2 : 0});
        await afterUi?.call();
        if (r['ok'] != true) return _explain(r, '');
        return '${WaText.chatText(r)}\n(From the screen. more:true reads older messages.)';
      case 'reply':
        if (to.isEmpty || msg.isEmpty) return 'Error: reply needs "to" (the chat) and "message".';
        if (st['notifRead'] == true) {
          final q = await SystemBridge.I.waCall<String>('waQuickReply', {'chat': to, 'pkg': _s(a, 'app').isEmpty ? '' : pkg, 'text': msg}) ?? '';
          if (q.startsWith('sent:')) {
            limiter.mark(DateTime.now());
            return 'Replied on WhatsApp to ${q.substring(5)} (from the notification, without opening WhatsApp).';
          }
        }
        final r1 = await _sendOne(to, msg, pkg);
        await afterUi?.call();
        return r1;
      case 'send':
        if (to.isEmpty || msg.isEmpty) return 'Error: send needs "to" (a number with country code, or a chat name) and "message".';
        final r2 = await _sendOne(to, msg, pkg);
        await afterUi?.call();
        return r2;
      case 'send_bulk':
        final rs = _recipients(a);
        if (rs.isEmpty || msg.isEmpty) return 'Error: send_bulk needs "recipients" and "message".';
        if (rs.length > WaLimiter.maxRecipients) {
          return 'Error: at most ${WaLimiter.maxRecipients} people per bulk send (got ${rs.length}). Split it, and only message people who expect it.';
        }
        final left = limiter.leftThisHour(DateTime.now());
        if (rs.length > left) return 'Error: only $left more WhatsApp messages are allowed this hour (anti-spam). Send fewer, or later.';
        final out = <String>[];
        var ok = 0;
        for (final r in rs.toSet()) {
          final line = await _sendOne(r, msg, pkg);
          if (line.startsWith('Sent') || line.startsWith('Queued')) ok++;
          out.add('- $r: $line');
        }
        await afterUi?.call();
        return 'Bulk send: $ok of ${rs.toSet().length} went out.\n${out.join('\n')}';
      case 'send_file':
        if (to.isEmpty || _s(a, 'path').isEmpty) return 'Error: send_file needs "to" and "path".';
        final path = await _resolvePath(_s(a, 'path'));
        if (!File(path).existsSync()) return 'Error: no file at $path.';
        var phone = WaText.looksLikePhone(to) ? WaText.phoneDigits(to) : null;
        if (WaText.looksLikePhone(to) && phone == null) return 'Error: "$to" has no country code. Ask for the full number.';
        var name = to;
        if (phone == null) {
          final info = await _chatInfo(to, pkg);
          if ('${info['phone'] ?? ''}'.isNotEmpty && info['group'] != true) phone = '${info['phone']}';
          if ('${info['name'] ?? ''}'.isNotEmpty) name = '${info['name']}';
        }
        final rf = await _act('share', pkg, {'path': path, 'phone': phone ?? '', 'name': name, 'caption': msg});
        if (rf['ok'] == true) limiter.mark(DateTime.now());
        await afterUi?.call();
        if (rf['state'] == 'no-file') return 'Error: the file could not be read.';
        if (rf['state'] == 'too-big') return 'Error: the file is too big for WhatsApp (max about 95 MB here).';
        return _explain(rf, ' (${path.split('/').last} to $to)').replaceFirst('Sent on WhatsApp', 'Sent the file on WhatsApp');
      case 'call':
        if (to.isEmpty) return 'Error: call needs "to".';
        if (st['phoneControl'] != true) return 'Error: phone control is off, so SubMac cannot start WhatsApp calls. Ask the user to turn it on in SubMac > Apps > WhatsApp.';
        final o = await _open(to, pkg);
        if (o != null) return o;
        final rc = await _act('call', pkg, {'video': a['video'] == true});
        if (rc['ok'] != true) return _explain(rc, ' (call)');
        return 'The WhatsApp ${a['video'] == true ? 'video' : 'voice'} call to $to is starting on the phone. You cannot speak in it: '
            'the user talks. Do not keep acting on the screen during the call.';
      case 'watch':
        return _watch(a, convId);
    }
    return 'Error: unknown WhatsApp action "$act".';
  }

  /// Opens a chat by number or name. Returns an error text, or null when the chat is open.
  static Future<String?> _open(String to, String pkg) async {
    Map<String, dynamic> r;
    if (WaText.looksLikePhone(to)) {
      final d = WaText.phoneDigits(to);
      if (d == null) return 'Error: "$to" has no country code. Ask the user for the full number.';
      r = await _act('open_phone', pkg, {'phone': d});
    } else {
      final info = await _chatInfo(to, pkg);
      r = '${info['phone'] ?? ''}'.isNotEmpty && info['group'] != true
          ? await _act('open_phone', pkg, {'phone': '${info['phone']}'})
          : await _act('open_name', pkg, {'name': '${info['name'] ?? to}'});
    }
    return r['ok'] == true ? null : _explain(r, ' (opening $to)');
  }

  static Future<String> _watch(Map<String, dynamic> a, String? convId) async {
    final b = Bots.I.byConv(convId);
    if (b == null) {
      return 'Error: watches belong to bots. Ask the user to give this job to a bot (it then wakes on new WhatsApp messages).';
    }
    final op = _s(a, 'op').isEmpty ? 'add' : _s(a, 'op');
    final mine = b.watches.where((w) => w.app.toLowerCase().contains('whatsapp')).toList();
    switch (op) {
      case 'list':
        return mine.isEmpty
            ? 'No WhatsApp watches.'
            : mine.map((w) => '${w.id}: ${w.chat.isEmpty ? 'any chat' : w.chat}${w.keyword.isEmpty ? '' : ' "${w.keyword}"'} → ${w.instruction}').join('\n');
      case 'remove':
        final id = _s(a, 'to');
        final before = b.watches.length;
        b.watches.removeWhere((w) => w.app.toLowerCase().contains('whatsapp') && (w.id == id || (id.isNotEmpty && w.chat.toLowerCase() == id.toLowerCase())));
        await Bots.I.save();
        return 'Removed ${before - b.watches.length} WhatsApp watch(es).';
      default:
        final chat = _s(a, 'to');
        final kw = _s(a, 'keyword');
        final ins = _s(a, 'instruction');
        if (ins.isEmpty) return 'Error: say what to do when it arrives ("instruction").';
        final app = WaText.pkgFor(_s(a, 'app'), '') == WaText.business ? 'WhatsApp Business' : 'WhatsApp';
        final w = BotWatch('w${DateTime.now().millisecondsSinceEpoch % 100000}', app, kw, ins, chat: chat);
        b.watches.add(w);
        await Bots.I.save();
        final st = await status();
        return 'Watching $app${chat.isEmpty ? '' : ' chat "$chat"'}${kw.isEmpty ? '' : ' for "$kw"'} (${w.id}). '
            'You wake on each new matching message (at most every 2 minutes per chat). Draft replies go to the owner to approve.'
            '${st['notifRead'] == true ? '' : ' Notification access is off: ask the owner to turn it on in SubMac > Apps > WhatsApp.'}';
    }
  }
}
