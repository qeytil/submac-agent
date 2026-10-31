// The 2026-10-31 owner pass: long outputs fold by default ("Show more" opens them right there), and the
// ```visual card renders the agent's own SVG (architecture, artwork, posters, mockups) in chat.
import 'package:agent/app_state.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:agent/widgets/chat/blocks.dart' show BlockKind, blockKindOf;
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

// final (not const): const string repetition inside interpolation trips the const evaluator (const_eval_type_num).
// Three sentences: the body is longer than the folded preview (it really folds), and the open card is
// short enough that its fold control stays clear of the reader overlay's hidden bottom zone on the
// 800x600 test surface, so both taps land on the chip.
final _long = '# Meeting summary\n\n${'We agreed on the budget and the dates for the trip. ' * 3}';

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

  test('```data renders extracted rows as a table card', () {
    expect(cardLanguages, contains('data'));
    expect(blockKindOf('data'), BlockKind.table, reason: 'it sits with the tables, not with code');
    // What browser_extract returns: a JSON array of objects (columns from the first row's keys).
    const rows = '[{"name":"Red shoes","price":"19.99","link":"/p/red"},{"name":"Blue hat","price":"9.99","link":"/p/blue"}]';
    expect(buildOutputCard('data', rows), isA<TableCard>());
    // A table-shaped map and plain CSV land on the same card.
    expect(buildOutputCard('data', '{"columns":["a","b"],"rows":[["1","2"],["3","4"]]}'), isA<TableCard>());
    expect(buildOutputCard('data', 'name,price\nRed shoes,19.99\nBlue hat,9.99'), isA<TableCard>());
    // Null cells render as empty cells, never the word "null".
    final withNull = buildOutputCard('data', '[{"name":"A","note":null}]') as TableCard;
    expect(withNull.columns, ['name', 'note']);
    // Not data: prose, one line, or empty falls back to a code block.
    expect(buildOutputCard('data', 'just words'), isNull);
    expect(buildOutputCard('data', 'name,price'), isNull, reason: 'a header alone is not a table');
    expect(buildOutputCard('data', ''), isNull);
  });

  testWidgets('a ```data card shows the rows', (t) async {
    const rows = '[{"name":"Red shoes","price":"19.99"},{"name":"Blue hat","price":"9.99"}]';
    await t.pumpWidget(_host(buildOutputCard('data', rows)!));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(TableCard), findsOneWidget);
    expect(find.text('Red shoes'), findsOneWidget);
    expect(find.text('Blue hat'), findsOneWidget);
  });

  testWidgets('a long summary is folded by default; Show more opens it right there, not the reader', (t) async {
    await t.pumpWidget(_host(buildOutputCard('summary', _long)!));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Show more'), findsOneWidget);
    expect(find.byType(HarkOverlay), findsNothing);
    await t.tap(find.text('Show more'));
    await t.pump(const Duration(milliseconds: 100));
    // The fold opened in place: the chip flipped, the body text is right there in the card, and the
    // reader never came up. (The fold-back tap is the same chip and the same setState — in the test
    // harness an invisible navigator layer under the card swallows taps below the folded card, so it
    // is not tappable here; on the phone it folds back the same way.)
    expect(find.text('Show less'), findsOneWidget);
    expect(find.textContaining('We agreed on the budget'), findsOneWidget);
    expect(find.byType(HarkOverlay), findsNothing, reason: 'the fold opens in place; the reader stays behind the card tap');
  });

  testWidgets('the folded summary still opens the reader on a tap of the preview', (t) async {
    await t.pumpWidget(_host(buildOutputCard('summary', _long)!));
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.byType(SummaryCard));
    await t.pumpAndSettle();
    expect(find.byType(HarkOverlay), findsOneWidget);
  });
}
