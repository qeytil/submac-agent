import 'offices.dart';
import '../ui/i18n.dart';

/// Plan 5.2: trust levels instead of switches, and one approval card for every ask.
///
/// A bot starts **New**: it asks before every action that changes something (a tap that sends, an app change, a file
/// it replaces...). Once it is **Trusted** it does routine changes on its own, but it still asks before anything that
/// spends money, sends or posts something to other people, or deletes. Trusted is offered after [promoteAfter]
/// approvals in a row that the owner did not edit. WhatsApp keeps its own explicit rule (every message asks unless the
/// owner trusted that bot for WhatsApp), and a trusted team keeps its own rule too.
class BotTrust {
  static const levelNew = 'new';
  static const levelTrusted = 'trusted';
  static const promoteAfter = 10;

  static const labels = {levelNew: 'Asks first', levelTrusted: 'On its own'};
  static const blurbs = {
    levelNew: 'Asks before every action that changes something.',
    levelTrusted: 'Does everyday work on its own. Still asks before money, sending or deleting.',
  };

  static final _money = RegExp(
      r'\b(pay|pays|paid|payment|buy|purchase|order|checkout|check out|place order|charge|refund|invoice|transfer|donate|subscribe|subscription|book|booking|tip|wallet|send money)\b',
      caseSensitive: false);
  static final _send = RegExp(
      r'\b(confirm|send|sends|sent|email|e-mail|mail|message|reply|respond|post|posts|publish|tweet|share|submit|apply|comment|invite|forward|dm|text|sms|call|announce|upload)\b',
      caseSensitive: false);
  static final _delete = RegExp(r'\b(delete|deletes|remove|erase|destroy|trash|wipe|drop|archive|cancel|unsubscribe|rm|rmdir|shred|kill)\b',
      caseSensitive: false);

  /// What kind of action this is: money | send | delete | change. [text] is what the action says about itself (the
  /// card's title and details, a tapped button's label, the tool name with underscores as spaces).
  static String kindOf(String tool, String text, {bool destructive = false}) {
    final t = '${tool.replaceAll(RegExp(r'[_\-]+'), ' ')} $text';
    if (_money.hasMatch(t)) return 'money';
    if (destructive || tool == 'delete_file' || _delete.hasMatch(t)) return 'delete';
    if (tool == 'email_send' || tool == 'whatsapp' || _send.hasMatch(t)) return 'send';
    return 'change';
  }

  /// Does this level still ask before an action of [kind]? New asks for everything; Trusted only for money,
  /// sending and deleting.
  static bool needsAsk(String level, String kind) => level != levelTrusted || kind != 'change';

  /// The clean-approval count after the owner answered one ask: an approval without edits adds one, an edit (or
  /// "change it first") starts over, "Not now" leaves it as it was.
  static int afterAnswer(int clean, {required bool approved, required bool edited}) {
    if (edited) return 0;
    return approved ? clean + 1 : clean;
  }

  /// Offer Trusted now? Only to a New bot that reached [offerAt] clean approvals.
  static bool shouldOffer(String level, int clean, int offerAt) => level != levelTrusted && clean >= offerAt;

  /// "Not yet": ask again after another [promoteAfter] clean approvals.
  static int snooze(int clean) => clean + promoteAfter;
}

/// Similar asks shown as one card: "3 emails to send".
class ApprovalGroup {
  ApprovalGroup(this.key, this.items);
  final String key;
  final List<Approval> items;

  int get count => items.length;

  /// The card's headline: the ask itself when there is one, else "3 emails to send".
  String get label => count == 1 ? items.first.title : '$count ${ApprovalGroups.noun(key, count)}';

  /// [label] in the app's language (the card); [label] itself stays English for the notification.
  String get labelTr => count == 1 ? items.first.title : tr(ApprovalGroups.manyKey(key), {'n': '$count'});

  /// Who asks: "Nova", "Nova and Rank", "Nova and 2 others".
  String who(String Function(String botId) name) {
    final names = <String>[];
    for (final a in items) {
      final n = name(a.botId);
      if (!names.contains(n)) names.add(n);
    }
    if (names.length <= 1) return names.isEmpty ? '' : names.first;
    if (names.length == 2) return tr('{a} and {b}', {'a': names[0], 'b': names[1]});
    return tr('{a} and {n} others', {'a': names[0], 'n': '${names.length - 1}'});
  }
}

class ApprovalGroups {
  /// The group an ask belongs to, from its tool and kind: email, whatsapp, send, money, delete, change.
  static String keyFor(String tool, String kind) {
    if (tool == 'email_send' || (RegExp(r'(gmail|outlook|mail)', caseSensitive: false).hasMatch(tool) && kind == 'send')) return 'email';
    if (tool == 'whatsapp') return 'whatsapp';
    return kind;
  }

  static String noun(String key, int n) => switch (key) {
        'email' => n == 1 ? 'email to send' : 'emails to send',
        'whatsapp' => n == 1 ? 'WhatsApp message to send' : 'WhatsApp messages to send',
        'send' => n == 1 ? 'message or post to send' : 'messages and posts to send',
        'money' => n == 1 ? 'payment to approve' : 'payments to approve',
        'delete' => n == 1 ? 'thing to delete' : 'things to delete',
        _ => n == 1 ? 'change to approve' : 'changes to approve',
      };

  /// The card's "3 emails to send", as a translation key with a {n} hole.
  static String manyKey(String key) => switch (key) {
        'email' => '{n} emails to send',
        'whatsapp' => '{n} WhatsApp messages to send',
        'send' => '{n} messages and posts to send',
        'money' => '{n} payments to approve',
        'delete' => '{n} things to delete',
        _ => '{n} changes to approve',
      };

  /// Pending asks grouped by kind, oldest group first. Asks of the same kind always share one card.
  static List<ApprovalGroup> group(Iterable<Approval> pending) {
    final out = <ApprovalGroup>[];
    for (final a in pending) {
      final key = a.group.isEmpty ? 'change' : a.group;
      final g = out.where((g) => g.key == key).firstOrNull;
      if (g == null) {
        out.add(ApprovalGroup(key, [a]));
      } else {
        g.items.add(a);
      }
    }
    return out;
  }
}
