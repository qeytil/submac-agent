// Chat fix plan PR-3 fix/approvals-outbound: CB-41 (a pending ask showed in every chat), CB-42 (an email "send" drove
// the Gmail app and hid the approval) and CB-44 (a cookie-banner "Continue" stalled a read-only research task).
import 'dart:async';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/browser/actions.dart';
import 'package:agent/services/browser/page_model.dart';
import 'package:agent/services/full_access.dart';
import 'package:agent/services/outbound_guard.dart';
import 'package:agent/services/tool_scope.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/i18n.dart';
import 'package:agent/widgets/ask_bar.dart';
import 'package:agent/widgets/hark_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: c!),
        home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
      ),
    );

ChatMessage _user(String text) => ChatMessage(id: 'u${text.hashCode}', role: 'user', content: text);

List<String> _toolNames(List<Map<String, dynamic>> tools) => [for (final t in tools) '${(t['function'] as Map?)?['name']}'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FullAccess.I.set(false);
    AppLang.I.choice = 'en';
    OutboundGuard.reset();
  });

  // ---------------------------------------------------------------- CB-41
  group('CB-41 a task\'s question shows only in its own chat', () {
    UserAsk ask(String conv, {String kind = 'text'}) =>
        UserAsk(kind: kind, convId: conv, title: 'Which size do you want?', prompt: '', options: const ['Small', 'Large']);

    testWidgets('an ask in chat A has no answer buttons in chat B, only a quiet chip that opens A', (t) async {
      final s = AppState();
      s.conversations = [
        Conversation(id: 'A', title: 'Shoes', updatedAt: DateTime(2026, 10, 25)),
        Conversation(id: 'B', title: 'Dinner', updatedAt: DateTime(2026, 10, 25)),
      ];
      s.currentId = 'B';
      s.asks.add(ask('A'));
      await t.pumpWidget(_host(const AskBar(), s));
      await t.pump();
      expect(find.text('Small'), findsNothing, reason: 'CB-41: the answer buttons of chat A must not show in chat B');
      expect(find.text('Which size do you want?'), findsNothing);
      expect(find.byKey(const ValueKey('ask-bar')), findsNothing);
      expect(find.byKey(const ValueKey('ask-elsewhere')), findsOneWidget);
      expect(find.textContaining('Shoes', findRichText: true), findsOneWidget);
      expect(find.textContaining('is waiting for you', findRichText: true), findsOneWidget);
    });

    testWidgets('in its own chat the same ask shows with its answers', (t) async {
      final s = AppState();
      s.currentId = 'A';
      s.asks.add(ask('A'));
      await t.pumpWidget(_host(const AskBar(), s));
      await t.pump();
      expect(find.text('Small'), findsOneWidget);
      expect(find.byKey(const ValueKey('ask-elsewhere')), findsNothing);
    });

    test('sign-in, code and connect asks, and asks with no chat, stay global', () {
      expect(AskBar.showsHere(ask('A', kind: 'login'), 'B'), isTrue);
      expect(AskBar.showsHere(ask('A', kind: 'login_confirm'), 'B'), isTrue);
      expect(AskBar.showsHere(ask('A', kind: 'connect'), 'B'), isTrue);
      expect(AskBar.showsHere(ask(''), 'B'), isTrue);
      expect(AskBar.showsHere(ask('A'), 'B'), isFalse);
      expect(AskBar.showsHere(ask('A'), 'A'), isTrue);
    });

    test('the chip words are translated, with the chat name kept in place', () {
      AppLang.I.choice = 'so';
      expect(tr('A task in {chat} is waiting for you', {'chat': 'Kabaha'}), contains('Kabaha'));
      expect(tr('A task in {chat} is waiting for you', {'chat': 'Kabaha'}), isNot(startsWith('A task')));
      AppLang.I.choice = 'en';
    });
  });

  // ---------------------------------------------------------------- CB-42
  group('CB-42 an email send with no connector is a draft card, never the Gmail app', () {
    late AppState app;
    setUp(() async {
      app = AppState();
      await app.local.init();
    });

    test('a send goal with no connector produces a draft card and no open_app', () async {
      app.listsForTest['c42'] = [_user('Email ali@example.com that I will be 10 minutes late')];
      expect(_toolNames(app.allToolsForTest('c42')), contains(OutboundGuard.draftTool));

      // The agent tries the old way: open Gmail. It is refused and pointed at the draft card.
      final open = await app.toolGate('open_app', {'name': 'Gmail'}, 'c42');
      expect(open.blocked, isNotNull, reason: 'CB-42: a send must never open the mail app');
      expect(open.blocked, contains('email_draft'));

      final out = await app.runToolWithApproval(
          OutboundGuard.draftTool, {'to': 'ali@example.com', 'subject': 'Running late', 'body': 'Hi Ali,\n\nI will be 10 minutes late.'},
          convId: 'c42');
      expect(out, contains('Do not open the mail app'));
      final last = app.listsForTest['c42']!.last;
      expect(last.role, 'assistant');
      expect(last.content, startsWith('```draft'));
      expect(last.content, contains('To: ali@example.com'));
      expect(last.content, contains('Subject: Running late'));
    });

    test('taps and typing in another app wait until the draft is approved in the chat', () async {
      app.listsForTest['c42b'] = [_user('Send an email to sara@example.com saying the report is done')];
      final tap = await app.toolGate('phone_tap', {'id': 4}, 'c42b');
      expect(tap.blocked, OutboundGuard.draftFirstNote);
      final type = await app.toolGate('phone_type', {'text': 'The report is done'}, 'c42b');
      expect(type.blocked, OutboundGuard.draftFirstNote);

      await app.runToolWithApproval(OutboundGuard.draftTool, {'to': 'sara@example.com', 'subject': 'Report', 'body': 'The report is done.'},
          convId: 'c42b');
      final card = app.listsForTest['c42b']!.last.content.replaceAll('```draft', '').replaceAll('```', '');
      // The user taps Send on the card: that is their OK for this request.
      expect(OutboundGuard.approveDraft(card), isTrue);
      expect((await app.toolGate('phone_type', {'text': 'The report is done'}, 'c42b')).blocked, isNull);
      // A new request in the chat needs its own OK.
      app.listsForTest['c42b']!.add(_user('Now send one to my boss too'));
      expect((await app.toolGate('phone_tap', {'id': 4}, 'c42b')).blocked, OutboundGuard.draftFirstNote);
    });

    test('reading or looking is never blocked', () async {
      app.listsForTest['c42c'] = [_user('What did Ali say in his last email?')];
      expect((await app.toolGate('open_app', {'name': 'Gmail'}, 'c42c')).blocked, isNull);
      expect((await app.toolGate('phone_tap', {'id': 2}, 'c42c')).blocked, isNull);
      expect(OutboundGuard.isSendGoal('Read my latest Telegram messages'), isFalse);
      expect(OutboundGuard.isSendGoal('Reply to Ali on Telegram: see you at 5'), isTrue);
      expect(OutboundGuard.isSendGoal('Email ali@example.com that I am late'), isTrue);
      expect(OutboundGuard.isSendGoal('Email Ali that I am late'), isTrue);
    });

    test('the Send button opens a mailto compose with everything filled in', () {
      final u = OutboundGuard.mailto(to: 'ali@example.com', subject: 'Running late', body: 'Hi Ali, see you at 5 & thanks');
      expect(u.scheme, 'mailto');
      expect(u.toString(), startsWith('mailto:ali@example.com?'));
      expect(u.toString(), contains('subject=Running%20late'));
      expect(u.toString(), isNot(contains('+')));
      expect(u.toString(), contains('%26'));
      final d = OutboundGuard.parse(OutboundGuard.draftCard(to: 'ali@example.com', cc: 'bo@example.com', subject: 'Hi', body: 'Body'));
      expect((d.to, d.cc, d.subject, d.body), ('ali@example.com', 'bo@example.com', 'Hi', 'Body'));
    });

    testWidgets('the draft card shows Send for an email draft, not for a plain draft', (t) async {
      final s = AppState();
      await t.pumpWidget(_host(const DraftCard('To: ali@example.com\nSubject: Running late\n\nHi Ali'), s));
      expect(find.byKey(const ValueKey('draft-send')), findsOneWidget);
      expect(find.text('Running late'), findsOneWidget);
      expect(find.text('To ali@example.com'), findsOneWidget);
      await t.pumpWidget(_host(const DraftCard('Subject: Note\n\nJust a note'), s));
      expect(find.byKey(const ValueKey('draft-send')), findsNothing);
      expect(find.text('Note'), findsOneWidget);
    });

    testWidgets('an approval raised in the background posts a notification that opens the chat', (t) async {
      final posted = <String>[];
      final cancelled = <int>[];
      OutboundGuard.notify = ({required int id, required String title, required String body, required String payload}) async =>
          posted.add('$id|$body|$payload');
      OutboundGuard.cancelNotice = (id) async => cancelled.add(id);
      addTearDown(OutboundGuard.reset);
      final s = AppState();
      s.appVisible = false;
      final answer = Completer<bool>();
      s.confirmCallback = (_) => answer.future;
      final req = ActionRequest(title: 'Tap "Send" on your phone?', body: 'This may send something.', detail: 'Send')..kind = 'send';
      bool? ok;
      unawaited(s.presentApproval(ToolGate(ask: req, kind: 'send', refusal: 'no'), 'phone_tap', {'id': 3}, 'c42d').then((v) => ok = v));
      await t.pump();
      expect(posted, hasLength(1), reason: 'CB-42: an ask raised while another app is in front must be seen');
      expect(posted.single, contains('conv/c42d'));
      expect(posted.single, contains('Tap "Send" on your phone?'));
      answer.complete(true);
      await t.pump();
      expect(ok, isTrue);
      expect(cancelled, hasLength(1), reason: 'the notification goes once the ask is answered');
    });

    testWidgets('no notification while Telesia is on screen', (t) async {
      final posted = <String>[];
      OutboundGuard.notify = ({required int id, required String title, required String body, required String payload}) async => posted.add(body);
      addTearDown(OutboundGuard.reset);
      final s = AppState();
      s.confirmCallback = (_) async => true;
      final req = ActionRequest(title: 'Delete it?', body: '', detail: '')..kind = 'delete';
      bool? ok;
      unawaited(s.presentApproval(ToolGate(ask: req, kind: 'delete', refusal: 'no'), 'delete_file', const {}, 'c42e').then((v) => ok = v));
      await t.pump();
      expect(ok, isTrue);
      expect(posted, isEmpty);
    });

    testWidgets('an unanswered approval times out and the task ends with a partial answer', (t) async {
      final s = AppState();
      s.listsForTest['c42f'] = [_user('Post the update on the team page')];
      s.confirmCallback = (_) => Completer<bool>().future; // nobody answers
      final req = ActionRequest(title: 'Post this?', body: '', detail: '')..kind = 'send';
      final g = ToolGate(ask: req, kind: 'send', refusal: 'The user said no.');
      bool? ok;
      unawaited(s.presentApproval(g, 'mcp_post', const {}, 'c42f').then((v) => ok = v));
      await t.pump(const Duration(minutes: 4));
      expect(ok, isNull, reason: 'still waiting before the limit');
      await t.pump(OutboundGuard.approvalTimeout);
      await t.pump();
      expect(ok, isFalse);
      expect(req.timedOut, isTrue);
      expect(g.refusal, contains('did not answer in time'));
      expect(g.refusal, isNot(contains('said no')));
    });
  });

  // ---------------------------------------------------------------- CB-42 (actions off)
  group('CB-42 drafting an email works with "Let it take action" off; a real send stays behind it', () {
    late AppState app;
    setUp(() async {
      app = AppState();
      await app.local.init();
      app.agentEnabled = false; // the emulator harness runs this way (run 40222543795: no draft tool, 3 guessed names)
    });

    test('email_draft is offered with actions off; phone, browser, open_app and email_send are not', () {
      app.listsForTest['c42g'] = [_user('Write an email to ali@example.com saying I will be 10 minutes late')];
      final names = _toolNames(app.allToolsForTest('c42g'));
      expect(names, contains(OutboundGuard.draftTool), reason: 'CB-42: with actions off the model had no way to write the draft');
      for (final gated in ['email_send', 'open_app', 'phone_tap', 'phone_type', 'browser_task']) {
        expect(names, isNot(contains(gated)), reason: '$gated must stay behind "Let it take action"');
      }
    });

    test('an email request opens the group email_draft is in, so the scoped toolbox carries it', () {
      expect(ToolScope.groupOf(OutboundGuard.draftTool), ToolScope.apps);
      expect(ToolScope.hinted('Write an email to Ali saying I will be late'), contains(ToolScope.apps));
      final scoped = ToolScope.filter(app.allToolsForTest('c42h'), {ToolScope.apps});
      expect(_toolNames(scoped), contains(OutboundGuard.draftTool));
    });

    test('with actions off the draft needs no approval and lands in the chat as a draft card', () async {
      var asked = 0;
      app.confirmCallback = (_) async {
        asked++;
        return true;
      };
      app.listsForTest['c42i'] = [_user('Email ali@example.com that I will be 10 minutes late')];
      final g = await app.toolGate(OutboundGuard.draftTool, {'to': 'ali@example.com', 'subject': 'Late', 'body': 'Hi Ali'}, 'c42i');
      expect(g.blocked, isNull);
      expect(g.ask, isNull, reason: 'a draft sends nothing, so it never asks');
      final out = await app.runToolWithApproval(
          OutboundGuard.draftTool, {'to': 'ali@example.com', 'subject': 'Running late', 'body': 'Hi Ali,\n\nI will be 10 minutes late.'},
          convId: 'c42i');
      expect(out, contains('they press send there themselves'));
      expect(asked, 0);
      final last = app.listsForTest['c42i']!.last;
      expect(last.role, 'assistant');
      expect(last.content, startsWith('```draft'));
      expect(last.content, contains('To: ali@example.com'));
    });

    test('the draft tool says it sends nothing and works without a connected account', () {
      final d = '${(OutboundGuard.draftToolDef['function'] as Map)['description']}';
      expect(d, contains('sends nothing itself'));
      expect(d, isNot(contains('when no email account is connected')));
    });

    test('with actions on and no mail account, email_draft is still offered (unchanged)', () {
      app.agentEnabled = true;
      expect(_toolNames(app.allToolsForTest('c42j')), contains(OutboundGuard.draftTool));
    });
  });

  // ---------------------------------------------------------------- CB-44
  group('CB-44 a cookie banner never stalls a read-only task; real checkout still asks', () {
    PageSnapshot page({bool card = false, Map<String, dynamic>? banner, bool modal = false}) => PageSnapshot(
          url: 'https://shop.example.com/buy/phone-15',
          title: 'Phone 15',
          elements: [
            PageElement(id: 3, kind: 'button', label: 'Continue'),
            PageElement(id: 7, kind: 'button', label: 'Continue to payment'),
            PageElement(id: 8, kind: 'button', label: 'Accept all cookies'),
            PageElement(id: 9, kind: 'button', label: 'Pay now'),
            PageElement(id: 10, kind: 'button', label: 'Next'),
          ],
          cardFields: card,
          banner: banner,
          modal: modal,
        );
    ({String title, String label})? click(PageSnapshot p, int id, {bool readOnly = false}) =>
        BrowserGate.check('browser_click', {'id': id}, p.labels, p, readOnly: readOnly);

    test('a cookie "Continue" on /buy/ needs no OK, "Continue to payment" does', () {
      final p = page(banner: {'id': 3, 'name': 'Continue', 'kind': 'accept'});
      expect(p.moneyPage, isTrue);
      expect(click(p, 3), isNull, reason: 'CB-44: the cookie banner button moves no money');
      expect(click(p, 7), isNotNull);
      expect(click(p, 9), isNotNull);
      expect(PageRisk.pressNeedsOk('Continue', moneyPage: true, consent: true), isFalse);
      expect(PageRisk.pressNeedsOk('Continue to payment', moneyPage: true, consent: true), isTrue);
      expect(PageRisk.pressNeedsOk('Accept and subscribe', moneyPage: true, consent: true), isTrue);
    });

    test('a consent button in a dialog needs no OK; on a card page only a cookie button does', () {
      expect(click(page(modal: true), 8), isNull);
      expect(click(page(modal: true, card: true), 8), isNull);
      expect(click(page(modal: true, card: true), 3), isNotNull);
      expect(click(page(), 3), isNotNull, reason: 'no banner and no dialog: a "Continue" on a money page still asks');
      expect(click(page(modal: true), 3), isNotNull, reason: 'a plain "Continue" in a dialog is not a consent button');
    });

    test('a read-only task does not gate plain flow buttons; card fields and money words still ask', () {
      final p = page();
      expect(click(p, 3), isNotNull, reason: 'a task that may buy still asks for "Continue" on a money page');
      expect(click(p, 3, readOnly: true), isNull);
      expect(click(p, 10, readOnly: true), isNull);
      expect(click(p, 7, readOnly: true), isNotNull);
      expect(click(p, 9, readOnly: true), isNotNull);
      expect(click(page(card: true), 3, readOnly: true), isNotNull, reason: 'card fields on the page: never loosened');
      expect(BrowserGate.check('browser_press', {'key': 'Enter'}, p.labels, p, readOnly: true), isNotNull);
      expect(BrowserGate.check('browser_tap_at', {'x': 50, 'y': 50}, p.labels, p, readOnly: true), isNotNull);
    });

    test('read-only goals are lookups, never buying or sending', () {
      expect(PageRisk.readOnlyGoal('Compare prices of the Phone 15 on Amazon and Jumia'), isTrue);
      expect(PageRisk.readOnlyGoal('Find the cheapest flight from Mogadishu to Nairobi next week'), isTrue);
      expect(PageRisk.readOnlyGoal('Buy the cheapest Phone 15'), isFalse);
      expect(PageRisk.readOnlyGoal('Find a hotel in Nairobi and book it'), isFalse);
      expect(PageRisk.readOnlyGoal(''), isFalse);
    });

    testWidgets('an approval left waiting 60 s in a read-only task answers from what was found', (t) async {
      final s = AppState();
      s.listsForTest['c44'] = [_user('Look up the price of the Phone 15 on shop.example.com')];
      s.confirmCallback = (_) => Completer<bool>().future;
      final req = ActionRequest(title: 'Tap "Continue"?', body: '', detail: '')..kind = 'change';
      final g = ToolGate(ask: req, kind: 'change', refusal: 'The user said no.');
      bool? ok;
      unawaited(s.presentApproval(g, 'phone_tap', const {}, 'c44').then((v) => ok = v));
      await t.pump(const Duration(seconds: 30));
      expect(ok, isNull);
      await t.pump(const Duration(seconds: 31));
      await t.pump();
      expect(ok, isFalse);
      expect(g.refusal, contains('answer the user now from what you already found'));
    });
  });
}
