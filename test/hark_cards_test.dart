import 'package:agent/models.dart';
import 'package:agent/widgets/hark_cards.dart';
import 'package:agent/widgets/markdown_view.dart';
import 'package:agent/widgets/motion.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:agent/widgets/page_cards.dart';
import 'package:agent/widgets/video_inline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {TextDirection dir = TextDirection.ltr, bool still = false}) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(400, 900), disableAnimations: still),
        child: Directionality(
          textDirection: dir,
          child: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(24), child: child)),
        ),
      ),
    );

void main() {
  group('calendar card', () {
    final e = CalendarEvent.fromJson({'title': 'Dinner', 'start': '2026-10-30T19:00:00', 'end': '2026-10-30T21:00:00', 'place': 'Hilltop'})!;

    test('reads the event in plain words and as an .ics file', () {
      expect(e.dateLine, 'Friday, Oct 30');
      expect(e.timeLine, '7:00 – 9:00 PM');
      expect(e.toIcs(), contains('SUMMARY:Dinner'));
      expect(e.toIcs(), contains('LOCATION:Hilltop'));
      final allDay = CalendarEvent.fromJson({'title': 'Trip', 'start': '2026-11-02'})!;
      expect(allDay.allDay, isTrue);
      expect(allDay.timeLine, 'All day');
      expect(CalendarEvent.fromJson({'title': 'x'}), isNull);
    });

    testWidgets('date, time and title; a tap adds it to the calendar', (t) async {
      CalendarEvent? added;
      await t.pumpWidget(host(CalendarCard(event: e, onAdd: (x) async => added = x)));
      expect(find.text('Friday, Oct 30'), findsOneWidget);
      expect(find.text('7:00 – 9:00 PM'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      await t.tap(find.text('Dinner'));
      await t.pump();
      expect(added, same(e));
    });

    test('the event fence becomes the card', () {
      expect(buildOutputCard('event', '{"title":"Dinner","start":"2026-10-30T19:00"}'), isA<CalendarCard>());
      expect(cardLanguages, contains('event'));
    });
  });

  testWidgets('email draft: subject as title, body muted, a Copy corner button', (t) async {
    await t.pumpWidget(host(const DraftCard('Subject: Sink\nHi [Name],\n\nThe sink leaks.')));
    expect(find.text('Sink'), findsOneWidget);
    expect(find.textContaining('The sink leaks.'), findsOneWidget);
    expect(find.bySemanticsLabel('Copy'), findsOneWidget);
  });

  testWidgets('summary: a fixed preview that opens the reader with Close and More', (t) async {
    await t.pumpWidget(host(const SummaryCard('# Istanbul in 3 Days\n\n**Day 1**\n\n- Hagia Sophia\n- Blue Mosque')));
    expect(find.text('Istanbul in 3 Days'), findsOneWidget);
    await t.tap(find.bySemanticsLabel(RegExp('^Open summary')));
    await t.pumpAndSettle();
    expect(find.text('Summary'), findsOneWidget);
    expect(find.bySemanticsLabel('Close'), findsOneWidget);
    expect(find.bySemanticsLabel('More'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Close'));
    await t.pumpAndSettle();
    expect(find.text('Summary'), findsNothing);
  });

  testWidgets('products: rows with a 76px thumb, name, muted specs and the price at the end', (t) async {
    await t.pumpWidget(host(const ProductGridCard(
      title: 'Wireless Earbuds Under \$150',
      columns: ['Name', 'Photo', 'Battery', 'Price'],
      rows: [
        ['Soundcore Liberty 4 NC', '', '50 hrs', '\$79.99'],
        ['Nothing Ear (3a)', '', '42 hrs', '\$99'],
      ],
    )));
    expect(find.text('Wireless Earbuds Under \$150'), findsOneWidget);
    expect(find.text('Soundcore Liberty 4 NC'), findsOneWidget);
    expect(find.text('50 hrs'), findsOneWidget);
    expect(find.text('\$79.99'), findsOneWidget);
    final thumb = t.getSize(find.ancestor(of: find.text('S'), matching: find.byType(Container)).first);
    expect(thumb.width, 76);
  });

  testWidgets('two or three links fan out as a deck; more are rows', (t) async {
    Map<String, dynamic> l(int i) => {'title': 'Cafe $i', 'url': 'https://cafe$i.example.com', 'image': 'https://cafe$i.example.com/a.png'};
    await t.pumpWidget(host(LinksCard([l(1), l(2), l(3)])));
    expect(find.byType(LinkDeck), findsOneWidget);
    expect(find.text('Cafe 2'), findsOneWidget);
    await t.pumpWidget(host(LinksCard([for (var i = 0; i < 5; i++) l(i)])));
    expect(find.byType(LinkDeck), findsNothing);
  });

  testWidgets('code card: language label, Copy, monochrome code', (t) async {
    await t.pumpWidget(host(const CodeBlock(code: 'def r(s):\n    return s[::-1]', language: 'py')));
    expect(find.text('Python'), findsOneWidget);
    expect(find.bySemanticsLabel('Copy'), findsOneWidget);
    expect(find.textContaining('return s[::-1]'), findsOneWidget);
  });

  group('page build card', () {
    ToolCall call(String content) => ToolCall(id: 'w1', name: 'write_file', arguments: '{"path":"site/index.html","content":${_json(content)}}');

    test('only page writes become build cards', () {
      expect(isPageWrite(call('<html>')), isTrue);
      expect(isPageWrite(ToolCall(id: 'x', name: 'write_file', arguments: '{"path":"a.txt","content":"x"}')), isFalse);
      expect(pageTitleOf('<title>Golden Crumb</title>', 'x.html'), 'Golden Crumb');
      expect(pageTitleOf('', '/a/golden-crumb.html'), 'golden crumb');
    });

    testWidgets('writing: title, phase with time, lines, the source as it arrives', (t) async {
      await t.pumpWidget(host(PageBuildCard(call: call('<!doctype html>\n<title>Golden Crumb</title>\n<h1>Hi</h1>'))));
      expect(find.text('Golden Crumb'), findsOneWidget);
      expect(find.text('Building your page'), findsOneWidget);
      expect(find.text('3 lines'), findsOneWidget);
      expect(find.textContaining('writing 0:0'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      expect(find.text('Open page'), findsNothing);
    });

    testWidgets('done: Page built and Open page', (t) async {
      String? opened;
      await t.pumpWidget(host(PageBuildCard(
        call: call('<title>Golden Crumb</title>'),
        result: 'Wrote /data/ws/site/index.html',
        running: false,
        onOpen: (_, p) => opened = p,
      )));
      expect(find.text('Page built'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
      await t.tap(find.text('Open page'));
      expect(opened, '/data/ws/site/index.html');
    });

    testWidgets('right-to-left renders', (t) async {
      await t.pumpWidget(host(PageBuildCard(call: call('<title>x</title>'), result: 'ok', running: false), dir: TextDirection.rtl));
      expect(t.takeException(), isNull);
    });
  });

  test('cards still being written show a status line, not a skeleton', () {
    expect(CardShimmer.lineFor('Summary'), 'Writing a summary');
    expect(CardShimmer.lineFor('Page'), 'Building your page');
    expect(CardShimmer.lineFor('Something'), 'Getting it ready');
  });

  testWidgets('the placeholder pill does not animate (reduced motion safe)', (t) async {
    await t.pumpWidget(host(const CardShimmer(label: 'Table')));
    expect(find.text('Building a table'), findsOneWidget);
    expect(t.hasRunningAnimations, isFalse);
  });

  group('inline video', () {
    testWidgets('a poster frame with a play glyph and a full-screen corner', (t) async {
      var expanded = false;
      await t.pumpWidget(host(InlineVideo(path: '/nowhere/clip.mp4', onExpand: () => expanded = true)));
      expect(find.bySemanticsLabel(RegExp('^Play video clip.mp4')), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Full screen'));
      expect(expanded, isTrue);
    });

    testWidgets('a video that cannot start says so in the status pill', (t) async {
      InlineVideo.debugController = (p) => throw StateError('no player in tests');
      addTearDown(() => InlineVideo.debugController = null);
      await t.pumpWidget(host(const InlineVideo(path: '/nowhere/clip.mp4'), still: true));
      await t.tap(find.bySemanticsLabel(RegExp('^Play video')));
      await t.pump();
      await t.pump();
      expect(find.text('This video won\'t play here'), findsOneWidget);
    });
  });
}

String _json(String s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';
