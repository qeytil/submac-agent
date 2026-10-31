// The 2026-10-31 owner pass: long outputs fold by default ("Show more" opens them right there), and the
// ```visual card renders the agent's own SVG (architecture, artwork, posters, mockups) in chat.
import 'package:agent/app_state.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/hark_style.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:agent/widgets/visual_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _host(Widget child) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 860), disableAnimations: true),
          child: Directionality(textDirection: TextDirection.ltr, child: Scaffold(body: SingleChildScrollView(child: child))),
        ),
      ),
    );

const _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 60">'
    '<rect width="100" height="60" fill="#f4f0e7"/><circle cx="50" cy="30" r="20" fill="#c2361b"/></svg>';

const _long = '# Meeting summary\n\n${'We agreed on the budget and the dates for the trip. ' * 40}';

void main() {
  test('```visual takes SVG and nothing else', () {
    expect(VisualCard.isSvg(_svg), isTrue);
    expect(VisualCard.isSvg('<svg><circle/></svg>'), isTrue, reason: 'unclosed inner tags are still worth trying; the tile catches the failure');
    expect(VisualCard.isSvg('draw me a house'), isFalse);
    expect(VisualCard.isSvg('{}'), isFalse);
    expect(cardLanguages, contains('visual'));
    expect(buildOutputCard('visual', _svg), isA<VisualCard>());
    expect(buildOutputCard('visual', 'draw me a house'), isNull, reason: 'falls back to a code block');
  });

  testWidgets('a ```visual card renders the drawing', (t) async {
    await t.pumpWidget(_host(buildOutputCard('visual', _svg)!));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(VisualCard), findsOneWidget);
  });

  testWidgets('a long summary is folded by default; Show more opens it right there, not the reader', (t) async {
    await t.pumpWidget(_host(buildOutputCard('summary', _long)!));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Show more'), findsOneWidget);
    expect(find.byType(HarkOverlay), findsNothing);
    await t.tap(find.text('Show more'));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Show less'), findsOneWidget);
    expect(find.byType(HarkOverlay), findsNothing, reason: 'the fold opens in place; the reader stays behind the card tap');
    await t.tap(find.text('Show less'));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Show more'), findsOneWidget);
  });

  testWidgets('the folded summary still opens the reader on a tap of the preview', (t) async {
    await t.pumpWidget(_host(buildOutputCard('summary', _long)!));
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.byType(SummaryCard));
    await t.pumpAndSettle();
    expect(find.byType(HarkOverlay), findsOneWidget);
  });
}
