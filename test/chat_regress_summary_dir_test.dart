// CB-9 (summary-card path): a long structured Arabic reply is split into a short lead bubble and a summary card
// (longReplySplit -> SummaryCard). The lead already took its words' direction (MessageText); the card did not, so its
// Arabic title and preview drew left-to-right inside a left-to-right chat (emulator run a16: 36 Arabic runs, 3 rtl).
// These tests fail on the old SummaryCard / _SummaryBody (no Directionality, title without a text direction).
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/chat_logic.dart' show longReplySplit;
import 'package:agent/widgets/output_cards.dart';
import 'package:agent/widgets/reply_blocks.dart';
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

const _para = 'هذه فقرة طويلة باللغة العربية تشرح الخطوات بالتفصيل، وتذكر الأسعار والمواعيد والملاحظات المهمة للمستخدم. ';

/// A long, structured Arabic answer: a short lead, then two or more headings and a long document part.
final _arabicReply = 'إليك الخطة الكاملة للرحلة.\n\n'
    '## الخطة الكاملة\n\n${_para * 4}\n\n'
    '## الميزانية\n\n${_para * 4}\n\n'
    '## ملاحظات\n\n- ${_para * 2}\n- ${_para * 2}';

/// The text direction every painted run of [text] under [of] ends up with.
List<TextDirection> _dirsOfRuns(WidgetTester t, Finder of, String text) => t
    .elementList(find.descendant(of: of, matching: find.byType(RichText)))
    .where((e) => (e.widget as RichText).text.toPlainText().contains(text))
    .map((e) => (e.widget as RichText).textDirection ?? Directionality.of(e))
    .toList();

void main() {
  test('the Arabic long reply really takes the summary-card path', () {
    final split = longReplySplit(_arabicReply);
    expect(split, isNotNull);
    expect(split!.$2, startsWith('# الخطة الكاملة'));
  });

  testWidgets('CB-9: the split-out summary card of a long Arabic reply is right-to-left (title and body)', (t) async {
    final m = ChatMessage(id: 'ar1', role: 'assistant', content: _arabicReply);
    await t.pumpWidget(_host(ReplyView(message: m)));
    await t.pump(const Duration(milliseconds: 400));
    final card = find.byType(SummaryCard);
    expect(card, findsOneWidget);
    final title = _dirsOfRuns(t, card, 'الخطة الكاملة');
    final body = _dirsOfRuns(t, card, 'هذه فقرة طويلة');
    expect(title, isNotEmpty);
    expect(body, isNotEmpty);
    expect(title.toSet(), {TextDirection.rtl}, reason: 'the card title drew left-to-right');
    expect(body.toSet(), {TextDirection.rtl}, reason: 'the card preview drew left-to-right');
    // The card's own Directionality is right-to-left (alignment, bullets and padding follow it).
    final dirs = t.widgetList<Directionality>(find.descendant(of: card, matching: find.byType(Directionality))).map((d) => d.textDirection);
    expect(dirs, contains(TextDirection.rtl));
  });

  testWidgets('CB-9: the summary reader opened from the card is right-to-left too', (t) async {
    final m = ChatMessage(id: 'ar2', role: 'assistant', content: _arabicReply);
    await t.pumpWidget(_host(ReplyView(message: m)));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byType(SummaryCard));
    await t.pumpAndSettle();
    final overlay = find.byType(HarkOverlay);
    expect(overlay, findsOneWidget);
    final body = _dirsOfRuns(t, overlay, 'هذه فقرة طويلة');
    expect(body, isNotEmpty);
    expect(body.toSet(), {TextDirection.rtl});
  });

  testWidgets('CB-9: a ```summary card with Arabic words is right-to-left; an English one stays left-to-right', (t) async {
    await t.pumpWidget(_host(Column(children: [
      buildOutputCard('summary', '# ملخص الاجتماع\n\n${_para * 3}')!,
      buildOutputCard('summary', '# Meeting summary\n\n${'We agreed on the budget and the dates for the trip. ' * 6}')!,
    ])));
    await t.pump(const Duration(milliseconds: 200));
    final cards = find.byType(SummaryCard);
    expect(cards, findsNWidgets(2));
    expect(_dirsOfRuns(t, cards.at(0), 'ملخص الاجتماع').toSet(), {TextDirection.rtl});
    expect(_dirsOfRuns(t, cards.at(0), 'هذه فقرة طويلة').toSet(), {TextDirection.rtl});
    expect(_dirsOfRuns(t, cards.at(1), 'Meeting summary').toSet(), {TextDirection.ltr});
    expect(_dirsOfRuns(t, cards.at(1), 'We agreed').toSet(), {TextDirection.ltr});
  });

  test('summaryDirOf follows the majority of strong letters (a brand name in an Arabic title stays rtl)', () {
    expect(summaryDirOf('iPhone 16 مراجعة كاملة', _para), TextDirection.rtl);
    expect(summaryDirOf('', 'Somali: Waan ku faraxsanahay. السلام عليكم'), TextDirection.ltr);
  });
}
