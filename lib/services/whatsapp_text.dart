/// Pure helpers for the WhatsApp tools (no Flutter, no plugins), so they are unit tested.
library;

class WaText {
  static const personal = 'com.whatsapp';
  static const business = 'com.whatsapp.w4b';

  /// Which WhatsApp to use: "business" / "w4b" -> WhatsApp Business, "personal" / "whatsapp" -> WhatsApp,
  /// anything else -> [fallback] (the user's default).
  static String pkgFor(String app, String fallback) {
    final a = app.trim().toLowerCase();
    if (a.isEmpty) return fallback;
    if (a.contains('business') || a.contains('w4b') || a == 'biz') return business;
    if (a.contains('personal') || a == 'whatsapp' || a == 'normal' || a == 'com.whatsapp') return personal;
    return fallback;
  }

  static String appName(String pkg) => pkg == business ? 'WhatsApp Business' : 'WhatsApp';

  /// True when [s] is meant as a phone number rather than a chat name.
  static bool looksLikePhone(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    final digits = t.replaceAll(RegExp(r'\D'), '');
    final rest = t.replaceAll(RegExp(r'[\d\s+\-().]'), '');
    return digits.length >= 6 && rest.isEmpty;
  }

  /// A number as WhatsApp wants it: digits with the country code, no "+" (e.g. "252615123456").
  /// "+252 61 512 3456" and "00252..." work; a number without a country code returns null, because guessing
  /// one could message a stranger. Use the full international number.
  static String? phoneDigits(String s) {
    var t = s.trim().replaceAll(RegExp(r'[\s\-().]'), '');
    if (t.isEmpty) return null;
    var intl = false;
    if (t.startsWith('+')) {
      intl = true;
      t = t.substring(1);
    } else if (t.startsWith('00')) {
      intl = true;
      t = t.substring(2);
    }
    if (!RegExp(r'^\d+$').hasMatch(t)) return null;
    if (t.startsWith('0')) return null;
    if (intl) return t.length >= 8 && t.length <= 15 ? t : null;
    return t.length >= 11 && t.length <= 15 ? t : null;
  }

  /// The click-to-chat link (opens the chat with [text] typed in).
  static String chatLink(String digits, {String text = ''}) =>
      'https://wa.me/$digits${text.isEmpty ? '' : '?text=${Uri.encodeComponent(text)}'}';

  static final _money = RegExp(
      r'(\$|€|£|usd|dollar|price|cost|how much|pay|paid|payment|invoice|bill|transfer|send money|balance|debt|loan|refund|deposit|'
      r'evc|zaad|e-?dahab|sahal|m-?pesa|lacag|qiimo|imisa|lacagta|bixi|dir lacag|deyn|سعر|كم|دفع|فلوس|حوالة|فاتورة|مبلغ|دولار)',
      caseSensitive: false);
  static final _order = RegExp(
      r'\b(order|buy|available|in stock|delivery|deliver|book|booking|reserve|size|catalog|menu|dalab|iibso|iibsan|jira|keen|gaarsii|'
      r'ma haysaan|ma jiraa)\b|طلب|اشتري|متوفر|توصيل|حجز',
      caseSensitive: false);
  static final _urgent = RegExp(r'\b(urgent|asap|emergency|now|immediately|help|degdeg|hadda|caawi|fadlan)\b|عاجل|ضروري|الآن|ساعد',
      caseSensitive: false);
  static final _meet = RegExp(r'\b(meet|meeting|call me|tomorrow|today|tonight|appointment|kulan|berri|maanta|wac)\b|اجتماع|موعد|بكرة|غدا|اتصل',
      caseSensitive: false);

  /// What stands out in a message: money, order (a customer wants something), urgent, question, meeting.
  static List<String> flags(String text) {
    final t = text.toLowerCase();
    return [
      if (_money.hasMatch(t)) 'money',
      if (_order.hasMatch(t)) 'order',
      if (_urgent.hasMatch(t)) 'urgent',
      if (t.contains('?') || t.contains('؟')) 'question',
      if (_meet.hasMatch(t)) 'meeting',
    ];
  }

  static String _clock(int ms, DateTime now) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (days == 0) return hm;
    if (days == 1) return 'yesterday $hm';
    return '${d.day}/${d.month} $hm';
  }

  static String _cut(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  /// The inbox as short lines for the model: one block per chat, newest first, flags in [brackets].
  static String inboxText(List<Map<String, dynamic>> chats, {DateTime? now, bool unreadOnly = false}) {
    final n = now ?? DateTime.now();
    if (chats.isEmpty) {
      return unreadOnly
          ? 'No unread WhatsApp messages since Telesia started reading notifications.'
          : 'No WhatsApp messages saved yet. New ones appear here as they arrive (notification access must be on).';
    }
    final sb = StringBuffer();
    var unreadChats = 0;
    for (final c in chats) {
      final unread = (c['unread'] as num?)?.toInt() ?? 0;
      if (unread > 0) unreadChats++;
      final msgs = [for (final m in (c['msgs'] as List? ?? const [])) Map<String, dynamic>.from(m as Map)];
      final incoming = msgs.where((m) => m['me'] != true).map((m) => '${m['t']}').join(' ');
      final f = flags(incoming);
      final group = c['group'] == true;
      final phone = '${c['phone'] ?? ''}';
      sb.write('• ${c['name']}');
      sb.write(' (${[
        group ? 'group' : 'direct',
        if (phone.isNotEmpty) '+$phone',
        if ('${c['app']}' == 'WhatsApp Business') 'Business',
        if (unread > 0) '$unread new' else 'read',
        _clock((c['last'] as num?)?.toInt() ?? 0, n),
        if (c['quickReply'] == true) 'quick reply ready',
      ].join(', ')})');
      if (f.isNotEmpty) sb.write(' [${f.join(', ')}]');
      sb.writeln();
      for (final m in msgs) {
        final who = m['me'] == true ? 'You' : (group ? '${m['f']}' : '${c['name']}');
        sb.writeln('   ${_clock((m['at'] as num?)?.toInt() ?? 0, n)} $who: ${_cut('${m['t']}', 300)}');
      }
    }
    final head = '${chats.length} chat${chats.length == 1 ? '' : 's'}${unreadChats > 0 ? ', $unreadChats with new messages' : ''} '
        '(from notifications, kept on this phone for 7 days):\n';
    return head + sb.toString().trimRight();
  }

  /// A chat read from the screen, as lines.
  static String chatText(Map<String, dynamic> r) {
    final msgs = [for (final m in (r['messages'] as List? ?? const [])) Map<String, dynamic>.from(m as Map)];
    final sb = StringBuffer('Chat: ${r['chat'] ?? ''}${'${r['status'] ?? ''}'.isEmpty ? '' : ' (${r['status']})'}\n');
    if (msgs.isEmpty) sb.writeln('(no messages visible on screen)');
    for (final m in msgs) {
      final who = m['me'] == true ? 'You' : ('${m['from'] ?? ''}'.isEmpty ? '' : '${m['from']}');
      final st = '${m['status'] ?? ''}'.isEmpty ? '' : ' (${m['status']})';
      sb.writeln('${'${m['time'] ?? ''}'.isEmpty ? '' : '${m['time']} '}${who.isEmpty ? '' : '$who: '}${_cut('${m['text']}', 600)}$st');
    }
    return sb.toString().trimRight();
  }
}

/// Keeps WhatsApp sending human-paced, so the user's number is never flagged as spam:
/// at most [maxRecipients] people per action, a pause of [gap] between messages, [perHour] messages an hour.
class WaLimiter {
  WaLimiter({this.gap = const Duration(seconds: 6), this.perHour = 60});
  static const maxRecipients = 20;
  final Duration gap;
  final int perHour;
  final List<DateTime> _sent = [];

  void _trim(DateTime now) => _sent.removeWhere((t) => now.difference(t) > const Duration(hours: 1));

  /// How long to wait before the next message may go (zero when it can go now).
  Duration waitBefore(DateTime now) {
    _trim(now);
    if (_sent.isEmpty) return Duration.zero;
    final since = now.difference(_sent.last);
    return since >= gap ? Duration.zero : gap - since;
  }

  /// True when this hour's allowance is used up.
  bool hourFull(DateTime now) {
    _trim(now);
    return _sent.length >= perHour;
  }

  int leftThisHour(DateTime now) {
    _trim(now);
    return (perHour - _sent.length).clamp(0, perHour);
  }

  void mark(DateTime now) => _sent.add(now);
}
