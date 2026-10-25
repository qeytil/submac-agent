import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/offices.dart';

/// An office saved by 1.13.27 or older (before Teams): no folder, no version, docs on the old shelf.
Map<String, dynamic> _oldOffice() => {
      'id': 'o1',
      'name': 'Hodan Coffee',
      'goal': 'Sell more coffee',
      'icon': 'payments',
      'm': ['b1', 'b2'],
      'chief': 'b1',
      'mode': 'supervised',
      'every': 120,
      'wf': 9,
      'wt': 18,
      'dg': '08:00',
      'dgc': true,
      'trust': 'trusted',
      'lim': 25,
      'rules': 'Ask me before paying',
      'tasks': [
        {'id': 'k1', 't': 'Price list', 's': 'doing', 'o': 'b2', 'p': 'high'},
        {'id': 'k2', 't': 'Old task', 's': 'done', 'o': 'b1'},
      ],
      'posts': [
        {'id': 'p1', 'f': 'you', 't': 'Hi team', 'k': 'chat'},
      ],
      'brief': ['We sell in Mogadishu'],
      'dec': ['Prices in USD'],
      'kpi': [
        {'n': 'Orders a week', 'v': 12, 't': 50, 'u': '', 'h': [['2026-10-18', 12]]},
      ],
      'docs': [
        {'id': 'd1', 't': 'Market research', 'b': 'Long text', 'a': 'Nova'},
        {'id': 'd2', 't': 'menu.pdf', 'b': '', 'f': '/x/office_docs/o1/1_menu.pdf', 'fn': 'menu.pdf', 'a': 'You'},
      ],
      'un': 3,
    };

void main() {
  group('offices become teams, in place (no data loss)', () {
    test('an old office loads with everything it had', () {
      final o = Office.fromJson(_oldOffice());
      expect(o.v, 1);
      expect(o.folder, '');
      expect(o.name, 'Hodan Coffee');
      expect(o.chiefId, 'b1');
      expect(o.members, ['b1', 'b2']);
      expect(o.mode, 'supervised');
      expect(o.trust, 'trusted');
      expect(o.digestCall, isTrue);
      expect(o.tasks.length, 2);
      expect(o.tasks.first.priority, 'high');
      expect(o.posts.single.text, 'Hi team');
      expect(o.brief, ['We sell in Mogadishu']);
      expect(o.decisions, ['Prices in USD']);
      expect(o.kpis.single.history.length, 1);
      expect(o.docs.length, 2);
      expect(o.unread, 3);
    });

    test('a migrated team keeps every field and adds its folder', () {
      final o = Office.fromJson(_oldOffice())
        ..folder = TeamFolder.folderFor('Hodan Coffee', const [])
        ..v = 2;
      o.docs.first.saved = 'Market research.md';
      final back = Office.fromJson(o.toJson());
      expect(back.v, 2);
      expect(back.folder, 'Teams/Hodan Coffee');
      expect(back.docs.first.saved, 'Market research.md');
      expect(back.docs.first.body, 'Long text');
      expect(back.tasks.map((t) => t.id).toList(), ['k1', 'k2']);
      expect(back.rules, 'Ask me before paying');
      expect(back.dailyLimit, 25);
      expect(back.workFrom, 9);
      expect(back.checkMinutes, 120);
    });

    test('folder names are safe and unique', () {
      expect(TeamFolder.safe('Hodan / Coffee: "Best"?'), 'Hodan Coffee Best');
      expect(TeamFolder.safe('   '), 'Team');
      expect(TeamFolder.safe('..hidden'), 'hidden');
      expect(TeamFolder.safe('x' * 90).length, 60);
      expect(TeamFolder.folderFor('Shop', const []), 'Teams/Shop');
      expect(TeamFolder.folderFor('Shop', const ['Teams/shop']), 'Teams/Shop 2');
      expect(TeamFolder.folderFor('Shop', const ['Teams/Shop', 'Teams/Shop 2']), 'Teams/Shop 3');
    });

    test('each document gets its own file name in the folder', () {
      final used = <String>{};
      OfficeDoc d(String t, {String fn = ''}) => OfficeDoc(id: t, title: t, fileName: fn, author: 'You');
      expect(TeamFolder.fileFor(d('Market research'), used), 'Market research.md');
      expect(TeamFolder.fileFor(d('Market research'), used), 'Market research (2).md');
      expect(TeamFolder.fileFor(d('notes.md'), used), 'notes.md');
      expect(TeamFolder.fileFor(d('menu', fn: 'menu.pdf'), used), 'menu.pdf');
      expect(TeamFolder.fileFor(d('menu', fn: 'menu.pdf'), used), 'menu (2).pdf');
      expect(TeamFolder.fileFor(d('a/b'), used), 'a b.md');
    });

    test('readable files in the folder', () {
      expect(TeamFolder.readable('notes.md'), isTrue);
      expect(TeamFolder.readable('prices.CSV'), isTrue);
      expect(TeamFolder.readable('photo.jpg'), isFalse);
      expect(TeamFolder.readable('menu.pdf'), isFalse);
    });
  });
}
