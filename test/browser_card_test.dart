import 'package:agent/services/browser_agent.dart';
import 'package:agent/services/browser_jobs.dart';
import 'package:agent/ui/i18n.dart';
import 'package:agent/widgets/browser_card.dart';
import 'package:agent/widgets/browser_layer.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {TextDirection dir = TextDirection.ltr, bool still = false}) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(400, 900), disableAnimations: still),
        child: Directionality(textDirection: dir, child: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child))),
      ),
    );

void main() {
  tearDown(() => AppLang.I.choice = 'en');

  group('live browser card', () {
    testWidgets('domain, one status line that changes in place, tap to open', (t) async {
      var opened = 0;
      Widget card(String s) => host(BrowserCardView(host: 'amazon.com', status: s, onOpen: () => opened++));
      await t.pumpWidget(card('Opening amazon.com'));
      expect(find.text('amazon.com'), findsOneWidget);
      expect(find.text('Opening amazon.com'), findsOneWidget);
      await t.pumpWidget(card('Tapping "Add to cart"'));
      await t.pumpAndSettle();
      expect(find.text('Tapping "Add to cart"'), findsOneWidget);
      expect(find.text('Opening amazon.com'), findsNothing, reason: 'no step list: the line is replaced, not appended');
      await t.tap(find.byKey(BrowserCardView.cardKey));
      expect(opened, 1);
    });

    testWidgets('soft rounded opaque card; the page picture is opaque and clipped to its corners', (t) async {
      await t.pumpWidget(host(const BrowserCardView(host: 'x.test', status: 'Working')));
      final m = t.widget<Material>(find.byKey(BrowserCardView.cardKey));
      expect((m.color!.a * 255).round(), 255);
      final shape = m.shape as RoundedRectangleBorder;
      final r = (shape.borderRadius as BorderRadius).topLeft.x;
      expect(r, inInclusiveRange(20, 24));
      final thumb = find.byKey(BrowserCardView.thumbKey);
      final clip = t.widget<ClipRRect>(find.descendant(of: thumb, matching: find.byType(ClipRRect)));
      expect((clip.borderRadius as BorderRadius).topLeft.x, greaterThanOrEqualTo(12));
      final box = t.widget<ColoredBox>(find.descendant(of: thumb, matching: find.byType(ColoredBox)).first);
      expect((box.color.a * 255).round(), 255);
    });

    testWidgets('reduced motion: the new status shows at once', (t) async {
      await t.pumpWidget(host(const BrowserCardView(host: 'x.test', status: 'One'), still: true));
      await t.pumpWidget(host(const BrowserCardView(host: 'x.test', status: 'Two'), still: true));
      await t.pump();
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('One'), findsNothing);
    });

    testWidgets('right to left: the picture sits on the right', (t) async {
      await t.pumpWidget(host(const BrowserCardView(host: 'x.test', status: 'Working'), dir: TextDirection.rtl));
      final thumbX = t.getCenter(find.byKey(BrowserCardView.thumbKey)).dx;
      final textX = t.getCenter(find.text('Working')).dx;
      expect(thumbX, greaterThan(textX));
    });

    testWidgets('Arabic and Somali words', (t) async {
      AppLang.I.choice = 'ar';
      await t.pumpWidget(host(BrowserCardView(host: '', status: tr('Opening {site}', {'site': 'amazon.com'}))));
      expect(find.text('المتصفح'), findsOneWidget);
      expect(find.text('جارٍ فتح amazon.com'), findsOneWidget);
      AppLang.I.choice = 'so';
      await t.pumpWidget(host(BrowserCardView(host: '', status: tr('Opening {site}', {'site': 'amazon.com'}))));
      expect(find.text('Biraawsar'), findsOneWidget);
      expect(find.text('Furaya amazon.com'), findsOneWidget);
    });

    testWidgets('an approval appears on the card as a small form, and its answer goes back', (t) async {
      final ask = InlineAsk(convId: 'c', title: 'Post this on LinkedIn?', detail: 'linkedin.com', money: false);
      await t.pumpWidget(host(BrowserCardView(host: 'linkedin.com', status: 'Waiting for your OK', form: BrowserApprovalForm(ask: ask))));
      expect(find.text('Post this on LinkedIn?'), findsOneWidget);
      expect(find.text('Allow always'), findsOneWidget);
      await t.tap(find.text('Allow'));
      final r = await ask.done.future;
      expect(r.ok, isTrue);
    });

    testWidgets('a payment never offers "Allow always"', (t) async {
      final ask = InlineAsk(convId: 'c', title: 'Place your order on shop.test?', detail: '', money: true);
      await t.pumpWidget(host(BrowserCardView(host: 'shop.test', status: 'Waiting', form: BrowserApprovalForm(ask: ask))));
      expect(find.text('Allow always'), findsNothing);
      await t.tap(find.text('Not now'));
      expect((await ask.done.future).ok, isFalse);
    });
  });

  group('result card', () {
    testWidgets('a finished task collapses to a compact result with the page link', (t) async {
      final w = buildOutputCard('browser', '{"status":"done","url":"https://www.shop.test/order/42","title":"Order 42","summary":"Ordered 2 pairs.","secs":75}');
      expect(w, isA<BrowserResultCard>());
      expect(cardLanguages, contains('browser'));
      await t.pumpWidget(host(w!));
      expect(find.text('Order 42'), findsOneWidget);
      expect(find.text('shop.test  Done 1:15'), findsOneWidget);
      expect(find.text('Ordered 2 pairs.'), findsOneWidget);
      expect(buildOutputCard('browser', 'not json'), isNull);
    });
  });

  group('browser layer (the sky bleed fix)', () {
    late Widget Function(BrowserTab) saved;
    setUp(() {
      saved = BrowserLayer.webViewBuilder;
      BrowserLayer.webViewBuilder = (tab) => const ColoredBox(key: ValueKey('page'), color: Color(0xFFFF0000), child: SizedBox.expand());
      final b = BrowserAgent.I;
      b.tabs
        ..clear()
        ..add(BrowserTab(1));
      b.current = 0;
      b.active = true;
      b.windowOpen = false;
      b.sheetUp = false;
    });
    tearDown(() {
      BrowserLayer.webViewBuilder = saved;
      final b = BrowserAgent.I;
      b.tabs.clear();
      b.active = false;
      b.windowOpen = false;
      b.expanded = false;
    });

    // A stand-in for the app: a see-through screen over the sky (like the real app).
    Widget app() => MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          builder: (context, child) => BrowserLayer(child: Stack(children: [const Positioned.fill(child: ColoredBox(key: ValueKey('sky'), color: Color(0xFF3366CC))), child!])),
          home: const Scaffold(backgroundColor: Colors.transparent, body: Center(child: Text('chat'))),
        );

    List<Key?> layers(WidgetTester t) => t.widget<Stack>(find.byKey(BrowserLayer.stackKey)).children.map((w) => w.key).toList();

    testWidgets('hidden page lies UNDER the app and its sky, on an opaque floor', (t) async {
      await t.pumpWidget(app());
      expect(find.byKey(const ValueKey('page')), findsOneWidget, reason: 'the page stays laid out for screenshots');
      final order = layers(t);
      expect(order.indexOf(BrowserLayer.hiddenKey), lessThan(order.indexOf(BrowserLayer.appPosKey)));
      final floor = t.widget<ColoredBox>(find.descendant(of: find.byKey(BrowserLayer.appKey), matching: find.byType(ColoredBox)).first);
      expect((floor.color.a * 255).round(), 255, reason: 'nothing under the app can show through its see-through screens');
      // Touches never reach the hidden page (the agent drives it with its own touches).
      final guards = t.widgetList<IgnorePointer>(find.ancestor(of: find.byKey(const ValueKey('page')), matching: find.byType(IgnorePointer)));
      expect(guards.any((g) => g.ignoring), isTrue);
    });

    testWidgets('the live view is above the sky, opaque and clipped to its rounded card', (t) async {
      await t.pumpWidget(app());
      BrowserAgent.I.openWindow();
      await t.pumpAndSettle();
      final order = layers(t);
      expect(order.contains(BrowserLayer.hiddenKey), isFalse);
      expect(order.indexOf(BrowserLayer.fullKey), greaterThan(order.indexOf(BrowserLayer.appPosKey)));
      final full = t.widget<Material>(find.descendant(of: find.byKey(BrowserLayer.fullKey), matching: find.byType(Material)).first);
      expect((full.color!.a * 255).round(), 255);
      final clip = t.widget<ClipRRect>(find.byKey(BrowserLayer.surfaceKey));
      expect((clip.borderRadius as BorderRadius).topLeft.x, BrowserLayer.radius);
      // The page is inside the clipped surface.
      expect(find.descendant(of: find.byKey(BrowserLayer.surfaceKey), matching: find.byKey(const ValueKey('page'))), findsOneWidget);
      final surface = t.getRect(find.byKey(BrowserLayer.surfaceKey));
      final page = t.getRect(find.byKey(const ValueKey('page')));
      expect(surface.contains(page.center), isTrue);
      // Closing returns the page under the app without rebuilding the app.
      final chatBefore = t.element(find.text('chat'));
      BrowserAgent.I.hideWindow();
      await t.pumpAndSettle();
      expect(t.element(find.text('chat')), same(chatBefore));
    });

    testWidgets('Stop in the live view stops the task at once', (t) async {
      final j = BrowserJob('bl1', 'goal', '', 'chatS', 20);
      BrowserJobs.I.jobs.add(j);
      await t.pumpWidget(app());
      BrowserAgent.I.openWindow();
      await t.pumpAndSettle();
      await t.tap(find.text('Stop'));
      await t.pump();
      expect(j.status, 'stopped');
      expect(BrowserAgent.I.windowOpen, isFalse);
      BrowserJobs.I.jobs.clear();
    });
  });
}
