import 'package:flutter_test/flutter_test.dart';
import 'package:agent/widgets/chat_logic.dart';

void main() {
  test('a repeated file card in one reply draws once', () {
    const t = 'Here is your site.\n\n```file\n/data/sites/a/index.html\n```\n\nOpen it.\n\n```file\n/data/sites/a/index.html\n```';
    final out = dropRepeatPageCards(t, <String>{});
    expect('```file'.allMatches(out).length, 1);
    expect(out, contains('Open it.'));
    expect(splitMarkdownChunks(t).where((c) => c.contains('```file')).length, 1);
  });

  test('a one-line repeat card is dropped too', () {
    const t = '```file\n/x/index.html\n```\n\n```file /x/index.html```';
    expect('```file'.allMatches(dropRepeatPageCards(t, <String>{})).length, 1);
  });

  test('a card shown earlier in the run is not shown again', () {
    final seen = <String>{};
    dropRepeatPageCards('Done.\n\n```file\n/x/index.html\n```', seen);
    final later = dropRepeatPageCards('All set, here it is again.\n\n```file\n/x/index.html\n```', seen);
    expect(later.contains('```file'), isFalse);
    expect(later, contains('All set'));
  });

  test('different files and other cards stay', () {
    const t = '```file\n/x/index.html\n```\n\n```file\n/x/menu.pdf\n```\n\n```table\n{"columns":[],"rows":[]}\n```';
    final out = dropRepeatPageCards(t, <String>{});
    expect('```file'.allMatches(out).length, 2);
    expect(out, contains('```table'));
  });

  test('an identical inline page card draws once', () {
    const t = '```page\n<html><title>A</title></html>\n```\n\n```page\n<html><title>A</title></html>\n```';
    expect('```page'.allMatches(dropRepeatPageCards(t, <String>{})).length, 1);
  });
}
