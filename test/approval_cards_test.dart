// Approval cards bug hunt (2026-10-24): ids that collided, cards that outlived their stopped task, "Allow always" that
// left the other asks waiting, sheets that stacked or popped twice, and words the cards showed only in English.
import 'dart:async';

import 'package:agent/app_state.dart';
import 'package:agent/services/confirm_queue.dart';
import 'package:agent/services/full_access.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/services/trust.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/i18n.dart';
import 'package:agent/widgets/approval_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Approval _ask(String title, {String conv = '', String group = 'change', String kind = 'change', String bot = 'b1'}) =>
    Approval(id: Approval.newId(), botId: bot, title: title, group: group, kind: kind, convId: conv);

Widget _app(Widget home, {TextDirection dir = TextDirection.ltr}) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        // Above the navigator, so the sheets get reduced motion and the text direction too.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: Directionality(textDirection: dir, child: child!),
        ),
        home: home,
      ),
    );

void _screen(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FullAccess.I.set(false);
    Offices.I.clearApprovals();
    AppLang.I.choice = 'en';
  });

  group('asks and their answers', () {
    test('ids never repeat, even when asked in the same instant', () {
      final ids = {for (var i = 0; i < 2000; i++) Approval.newId()};
      expect(ids.length, 2000);
    });

    test('two asks at once are answered separately (no ask waits for hours)', () async {
      final a = _ask('Send the invoice');
      final b = _ask('Send the reminder');
      final fa = Offices.I.ask(a);
      final fb = Offices.I.ask(b);
      await Future<void>.delayed(Duration.zero);
      expect(Offices.I.pending.length, 2);
      await Offices.I.answer(b.id, false);
      await Offices.I.answer(a.id, true);
      expect(await fa.timeout(const Duration(seconds: 1)), isTrue);
      expect(await fb.timeout(const Duration(seconds: 1)), isFalse);
    });

    test('stopping a task drops its asks and its run stops waiting; other chats keep theirs', () async {
      final mine = _ask('Post the update', conv: 'c1');
      final other = _ask('Post elsewhere', conv: 'c2');
      final fm = Offices.I.ask(mine);
      unawaited(Offices.I.ask(other));
      await Future<void>.delayed(Duration.zero);
      await Offices.I.expireFor('c1');
      expect(await fm.timeout(const Duration(seconds: 1)), isFalse);
      expect(mine.status, 'expired');
      expect(Offices.I.pending.map((a) => a.id), [other.id]);
      // A late tap on the gone card changes nothing.
      await Offices.I.answer(mine.id, true);
      expect(mine.status, 'expired');
    });

    test('Full access going on lets every waiting ask go ahead, except payments', () async {
      final change = _ask('Rename the file');
      final pay = _ask('Pay the invoice', group: 'money', kind: 'money');
      final mailPay = _ask('Pay by email', group: 'email', kind: 'money');
      final fc = Offices.I.ask(change);
      unawaited(Offices.I.ask(pay));
      unawaited(Offices.I.ask(mailPay));
      await Future<void>.delayed(Duration.zero);
      await FullAccess.I.set(true);
      await Future<void>.delayed(Duration.zero);
      expect(await fc.timeout(const Duration(seconds: 1)), isTrue);
      expect(change.status, 'approved');
      expect(Offices.I.pending.map((a) => a.id).toSet(), {pay.id, mailPay.id});
    });

    test('an ask made while Full access is on goes ahead without a card (money still waits)', () async {
      await FullAccess.I.set(true);
      expect(await Offices.I.ask(_ask('Rename')).timeout(const Duration(seconds: 1)), isTrue);
      expect(Offices.I.pending, isEmpty);
      final pay = _ask('Pay', group: 'money', kind: 'money');
      unawaited(Offices.I.ask(pay));
      await Future<void>.delayed(Duration.zero);
      expect(Offices.I.pending.single.id, pay.id);
    });

    test('signing out answers every waiting ask with no', () async {
      final f = Offices.I.ask(_ask('Delete the draft'));
      await Future<void>.delayed(Duration.zero);
      Offices.I.clearApprovals();
      expect(await f.timeout(const Duration(seconds: 1)), isFalse);
      expect(Offices.I.approvals, isEmpty);
    });

    test('trimming the history never cuts an ask that still waits', () async {
      final old = _ask('Oldest, still waiting');
      unawaited(Offices.I.ask(old));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 70; i++) {
        Offices.I.approvals.add(_ask('done $i')..status = 'approved');
      }
      await Offices.I.save();
      expect(Offices.I.approvals.length, 60);
      expect(Offices.I.pending.single.id, old.id);
    });

    test('the chat and the kind survive a restart', () {
      final a = Approval(id: 'x', botId: 'b', title: 't', convId: 'c9', kind: 'money', group: 'email');
      final b = Approval.fromJson(a.toJson());
      expect(b.convId, 'c9');
      expect(b.kind, 'money');
      expect(b.isMoney, isTrue);
    });
  });

  group('the in-app sheet queue', () {
    test('asks wait their turn', () async {
      final q = ConfirmQueue();
      final first = Completer<bool>();
      var secondShown = false;
      final f1 = q.run('c1', () => first.future);
      final f2 = q.run('c2', () async {
        secondShown = true;
        return true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(q.openConv, 'c1');
      expect(secondShown, isFalse);
      first.complete(false);
      expect(await f1, isFalse);
      expect(await f2, isTrue);
      expect(secondShown, isTrue);
    });

    test('a stopped task closes its open sheet and skips its queued asks', () async {
      final q = ConfirmQueue();
      final open = Completer<bool>();
      final f1 = q.run('c1', () => open.future);
      var queuedShown = false;
      final f2 = q.run('c1', () async {
        queuedShown = true;
        return true;
      });
      await Future<void>.delayed(Duration.zero);
      q.onClose(() => open.complete(false));
      q.stopped('c1');
      expect(await f1, isFalse);
      expect(await f2, isFalse);
      expect(queuedShown, isFalse);
      // A new ask after the stop is shown as normal.
      expect(await q.run('c1', () async => true), isTrue);
    });
  });

  group('the inline approval card (thin, under the task\'s message — never a sheet)', () {
    Future<void> open(WidgetTester t, ActionRequest req, {Size size = const Size(400, 860), TextDirection dir = TextDirection.ltr}) async {
      _screen(t, size);
      await t.pumpWidget(_app(
        Scaffold(body: SingleChildScrollView(child: ConfirmInline(request: req, onAnswer: (_) {}))),
        dir: dir,
      ));
      await t.pumpAndSettle();
    }

    testWidgets('a double tap on Approve answers exactly once', (t) async {
      var answered = 0;
      final req = ActionRequest(title: 'Push the changes?', body: 'Fix', detail: 'main', confirmLabel: 'Push');
      await t.pumpWidget(_app(Scaffold(
        body: ConfirmInline(request: req, onAnswer: (_) => answered++),
      )));
      await t.pumpAndSettle();
      final approve = find.byKey(const ValueKey('confirm-approve'));
      await t.tap(approve);
      await t.tap(approve, warnIfMissed: false);
      await t.pumpAndSettle();
      expect(answered, 1);
    });

    testWidgets('no "Show details" when there are no details', (t) async {
      await open(t, ActionRequest(title: 'Restore the snapshot?', body: 'Saved first.', detail: ''));
      expect(find.text('Show details'), findsNothing);
    });

    testWidgets('a payment the router named never offers Allow always, whatever its words', (t) async {
      final req = ActionRequest(title: 'Run the shop tool?', body: '', detail: 'item 4')..kind = 'money';
      await open(t, req);
      expect(find.byKey(const ValueKey('allow-always')), findsNothing);
    });

    testWidgets('labels and buttons are English', (t) async {
      await open(t, ActionRequest(title: 'X?', body: 'y', detail: 'z', confirmLabel: 'Send'));
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Show details'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Allow always (Full access)'), findsOneWidget);
    });

    testWidgets('fits a small phone', (t) async {
      final req = ActionRequest(
          title: 'Send this long message to the whole customer group right now?', body: 'A long body ' * 12, detail: 'd ' * 80, confirmLabel: 'Take offline');
      await open(t, req, size: const Size(320, 568));
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('allow-always')), findsOneWidget);
      expect(find.byKey(const ValueKey('confirm-not-now')), findsOneWidget);
    });

    testWidgets('Edit on an ask with editable text opens the field in place; Cancel folds it back', (t) async {
      final req = ActionRequest(title: 'Send this to Amal?', body: '', detail: '', confirmLabel: 'Send').withEdit('Hi Amal');
      await open(t, req);
      await t.tap(find.text('Edit'));
      await t.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(req.edit!.edited, isFalse);
    });
  });

  group('the approval card', () {
    testWidgets('Allow always approves this card, turns on Full access and lets the other waiting asks go', (t) async {
      final a = _ask('Rename the report', bot: 'b1');
      final b = _ask('Delete the old draft', group: 'delete', kind: 'delete', bot: 'b2');
      final pay = _ask('Pay 5 USD', group: 'money', kind: 'money', bot: 'b3');
      final fa = Offices.I.ask(a);
      final fb = Offices.I.ask(b);
      unawaited(Offices.I.ask(pay));
      await t.pump();
      await t.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: ApprovalList(botId: 'b1')))));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('allow-always')));
      await t.pumpAndSettle();
      expect(await fa, isTrue);
      expect(await fb, isTrue);
      expect(FullAccess.I.on, isTrue);
      expect(Offices.I.pending.single.id, pay.id);
      Offices.I.clearApprovals();
      await t.pump();
    });

    testWidgets('a payment card offers no Allow always', (t) async {
      unawaited(Offices.I.ask(_ask('Pay 5 USD', group: 'money', kind: 'money')));
      await t.pump();
      await t.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: ApprovalList()))));
      await t.pump();
      expect(find.text('Pay 5 USD'), findsOneWidget);
      expect(find.byKey(const ValueKey('allow-always')), findsNothing);
      Offices.I.clearApprovals();
      await t.pump();
    });

    testWidgets('the group card fits a small phone', (t) async {
      for (var i = 0; i < 5; i++) {
        unawaited(Offices.I.ask(_ask('Email number $i with a long subject line that runs on', group: 'email', kind: 'send', bot: 'b$i')));
      }
      await t.pump();
      _screen(t, const Size(320, 568));
      await t.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: ApprovalList()))));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('5 emails to send'), findsOneWidget);
      expect(find.text('and 2 more'), findsOneWidget);
      Offices.I.clearApprovals();
      await t.pump();
    });

    test('group words are English', () {
      final g = ApprovalGroup('email', [_ask('a', group: 'email'), _ask('b', group: 'email')]);
      expect(g.labelTr, '2 emails to send');
      expect(g.label, '2 emails to send');
    });
  });

  testWidgets('an open grouped card stays open when a new ask joins it', (t) async {
    unawaited(Offices.I.ask(_ask('Rename a.txt')));
    unawaited(Offices.I.ask(_ask('Rename b.txt')));
    await t.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: ApprovalList()))));
    await t.pump();
    expect(find.byType(ApprovalGroupCard), findsOneWidget);
    await t.tap(find.text('Review'));
    await t.pump();
    expect(find.text('Rename a.txt'), findsOneWidget);
    unawaited(Offices.I.ask(_ask('Rename c.txt')));
    await t.pump();
    expect(find.text('Review'), findsNothing, reason: 'the open review must not fold back up');
    expect(find.text('Rename c.txt'), findsOneWidget);
    Offices.I.clearApprovals();
  });
}
