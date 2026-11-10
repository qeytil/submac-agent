import 'system_bridge.dart';

/// Outbound messages and the approvals around them (chat fix plan PR-3, CB-42 and CB-44).
///
/// CB-42: with no mail account connected, an email "send" opened Gmail, then tapped and typed in it. The approval for
/// that tap was raised inside Telesia while Gmail was in front, so nobody saw it and the run hung. Now:
/// 1. outbound email with no connector is an `email_draft`: a draft card in the chat whose Send button opens the
///    phone's mail app (a mailto: compose intent, ACTION_SENDTO) with everything filled in; the user sends it there;
/// 2. an approval raised while Telesia is in the background posts a high-priority notification (the router does this);
/// 3. for a send goal, taps and typing in another app wait until the draft was approved in this chat;
/// 4. an unanswered approval times out, and the task ends with what it has (sooner for read-only tasks).
class OutboundGuard {
  OutboundGuard._();

  /// The tool that shows an email draft in the chat when there is no email_send to use (no mail account connected, or
  /// "Let it take action" off). It only prepares the draft; the user sends it from their mail app.
  static const draftTool = 'email_draft';

  static const _send = r'send|reply|respond to|forward|post|tweet|publish|dm|u dir|soo dir|ii dir|dir u|jawaab';

  /// The user's words ask Telesia to send something to someone (an email, a text, a post), not just to read or look.
  static final _sendGoal = RegExp(
      '\\b($_send)\\b|\\be-?mail (to|him|her|them|my|the|back|everyone|all)\\b|\\b(text|message|whatsapp|telegram) (him|her|them|my|back|to)\\b|'
      '\\bwrite (an? )?(e-?mail|message|text|reply) to\\b|\\be-?mail\\s+\\S+@\\S+|\\be-?mail \\w+ (that|saying|about|to say|and (tell|ask))\\b',
      caseSensitive: false);

  static final _emailGoal = RegExp(r'\b(e-?mails?|gmail|outlook|mail|inbox)\b|@[\w-]+\.\w', caseSensitive: false);

  /// Mail apps the agent must not drive to send (Gmail, Outlook, the phone's Email app, Yahoo, Proton, Spark...).
  static final _mailApp = RegExp(r'\b(g ?mail|outlook|e-?mail|mail|yahoo|proton ?mail|spark|aqua ?mail|blue ?mail|k-?9)\b', caseSensitive: false);

  static bool isSendGoal(String goal) => goal.trim().isNotEmpty && _sendGoal.hasMatch(goal);
  static bool isEmailGoal(String goal) => _emailGoal.hasMatch(goal);
  static bool isMailApp(String name) => _mailApp.hasMatch(name.trim());

  /// How long an approval waits for an answer before the task gives up on it and ends with what it has.
  static const approvalTimeout = Duration(minutes: 5);

  /// A read-only task (look up, compare, price) answers from what it found after this long.
  static const readOnlyTimeout = Duration(seconds: 60);

  static Duration waitFor({required bool readOnly}) => readOnly ? readOnlyTimeout : approvalTimeout;

  /// Posts the "needs your OK" notification (kind "approval": the high-priority channel that pops up over other apps;
  /// a tap opens Telesia on the chat whose sheet is waiting). Tests swap these to see what was posted.
  static Future<void> Function({required int id, required String title, required String body, required String payload}) notify =
      _post;
  static Future<void> Function(int id) cancelNotice = _cancel;

  static Future<void> _post({required int id, required String title, required String body, required String payload}) async {
    try {
      await SystemBridge.I.notify(id: id, title: title, body: body, payload: payload, kind: 'approval');
    } catch (_) {}
  }

  static Future<void> _cancel(int id) async {
    try {
      await SystemBridge.I.ringCancel(id);
    } catch (_) {}
  }

  /// What the model reads when nobody answered the approval in time.
  static String noAnswer({required bool readOnly}) => readOnly
      ? 'No answer in time, so this step was skipped. Do not try it again or another way. This task only looks things '
          'up: answer the user now from what you already found, and say in one line what you could not check.'
      : 'Not done: the user did not answer in time (they may be away from the phone). Do not retry it or try another way. '
          'End now with a short answer: what you did, and what is still waiting on their OK.';

  static final Map<String, dynamic> draftToolDef = {
    'type': 'function',
    'function': {
      'name': draftTool,
      'description': 'Write an email for the user (you have no email_send). It shows the draft as a card in this chat; '
          'its Send button opens the phone\'s mail app with everything filled in, and the user sends it there. It sends '
          'nothing itself. Use this for every email the user asks you to write or send. Never open Gmail or another mail '
          'app, and never tap or type in one, to send.',
      'parameters': {
        'type': 'object',
        'properties': {
          'to': {'type': 'string', 'description': 'Comma-separated addresses (may be empty if the user did not say)'},
          'cc': {'type': 'string'},
          'subject': {'type': 'string'},
          'body': {'type': 'string', 'description': 'Plain text'},
        },
        'required': ['subject', 'body'],
      },
    },
  };

  /// The refusal when a send goal tries to open a mail app.
  static String mailAppNote({required bool connected}) => connected
      ? 'Not done: do not open the mail app to send. An email account is connected: write the email with email_send '
          '(the user sees the draft and approves it in this chat).'
      : 'Not done: do not open Gmail or another mail app to send. No email account is connected, so call email_draft with '
          'to, subject and body: the draft shows in this chat, and its Send button opens the mail app filled in.';

  /// The refusal when a send goal taps or types in another app before its draft was approved in the chat.
  static const draftFirstNote = 'Not done: this task sends something for the user, and they have not approved the draft '
      'in this chat yet. Show the exact message first: for an email, email_draft (or email_send when an account is '
      'connected); for another app, ask_user with the full draft and the options "Send it" and "Change it". Only after '
      'they say yes, tap and type in the other app.';

  // ---- drafts shown, and drafts approved ----

  /// conv -> the goal (the user's request) whose draft the user approved in that chat.
  static final Map<String, String> _approved = {};

  /// Card text -> (conv, goal) of a draft card shown by [draftTool], so a tap on its Send approves that chat.
  static final Map<String, (String, String)> _shown = {};

  static String _key(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static void approve(String convId, String goal) => _approved[convId] = _key(goal);
  static bool isApproved(String convId, String goal) => _approved[convId] == _key(goal);

  /// A draft card was posted in [convId] for [goal].
  static void shown(String convId, String goal, String cardText) => _shown[_key(cardText)] = (convId, goal);

  /// The user tapped Send on a draft card: its chat's send is approved (true when the card came from a task).
  static bool approveDraft(String cardText) {
    final s = _shown[_key(cardText)];
    if (s == null) return false;
    approve(s.$1, s.$2);
    return true;
  }

  static void reset() {
    _approved.clear();
    _shown.clear();
    notify = _post;
    cancelNotice = _cancel;
  }

  /// An answer that says yes to sending ("Send it", "Yes", "OK", "Haa").
  static final _yes = RegExp(r'^\s*(send( it)?|yes|yep|yeah|ok(ay)?|sure|go( ahead)?|approve[d]?|looks good|haa|haye|dir|u dir)\b', caseSensitive: false);
  static bool saysYes(String answer) => _yes.hasMatch(answer);

  // ---- the draft card and the compose intent ----

  /// The draft card's text (a ```draft block the chat renders as Hark's draft card with a Send button).
  static String draftCard({String to = '', String cc = '', required String subject, required String body}) {
    final sb = StringBuffer();
    if (to.trim().isNotEmpty) sb.writeln('To: ${to.trim()}');
    if (cc.trim().isNotEmpty) sb.writeln('Cc: ${cc.trim()}');
    sb.writeln('Subject: ${subject.trim().isEmpty ? '(no subject)' : subject.trim()}');
    sb.writeln();
    sb.write(body.trim());
    return sb.toString();
  }

  /// The parts of a draft card's text: leading To / Cc / Subject lines, then the body.
  static ({String to, String cc, String? subject, String body}) parse(String text) {
    final lines = text.trim().split('\n');
    var to = '', cc = '';
    String? subject;
    var i = 0;
    for (; i < lines.length && i < 4; i++) {
      final l = lines[i].trim();
      final low = l.toLowerCase();
      if (low.startsWith('to:')) {
        to = l.substring(3).trim();
      } else if (low.startsWith('cc:')) {
        cc = l.substring(3).trim();
      } else if (low.startsWith('subject:')) {
        subject = l.substring(8).trim();
      } else {
        break;
      }
    }
    return (to: to, cc: cc, subject: subject, body: lines.sublist(i).join('\n').trim());
  }

  /// A mailto: link that opens the mail app's compose screen with everything filled in (spaces as %20, not +).
  static Uri mailto({String to = '', String cc = '', String subject = '', String body = ''}) {
    String enc(String s) => Uri.encodeComponent(s);
    final q = <String>[
      if (cc.trim().isNotEmpty) 'cc=${enc(cc.trim())}',
      if (subject.trim().isNotEmpty) 'subject=${enc(subject.trim())}',
      if (body.trim().isNotEmpty) 'body=${enc(body.trim())}',
    ];
    final addr = to.split(RegExp(r'[,;\s]+')).where((a) => a.trim().isNotEmpty).map((a) => a.trim()).join(',');
    return Uri.parse('mailto:$addr${q.isEmpty ? '' : '?${q.join('&')}'}');
  }
}
