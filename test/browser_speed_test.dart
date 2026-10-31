// Speed (P4, browser-godmode): the view is a patch after a step, waits follow the network, and a
// read-only open answers from a same-session fetch with no render.
import 'package:agent/services/browser/page_model.dart';
import 'package:agent/services/browser/read_page.dart';
import 'package:agent/services/browser_agent.dart';
import 'package:flutter_test/flutter_test.dart';

PageElement el(int id, String kind, String label, {String href = ''}) => PageElement(id: id, kind: kind, label: label, href: href);

PageSnapshot snap(List<PageElement> els, {String url = 'https://shop.test/cart', String text = 'Your cart is empty.'}) =>
    PageSnapshot(url: url, title: 'Cart', elements: els, text: text);

void main() {
  group('htmlToText: the readability pass', () {
    test('scripts, styles and markup go; the words stay', () {
      const html = '<html><head><title>Hargeisa flights | Site</title><style>.a{color:red}</style>'
          '<script>var x = "<p>not text</p>";</script></head><body><h1>Flights</h1>'
          '<p>From Nairobi to Hargeisa, from <b>$180</b>.</p><!-- hidden --><div>Book now</div></body></html>';
      final t = htmlToText(html);
      expect(t, contains('Flights'));
      expect(t, contains('From Nairobi to Hargeisa, from \$180.'));
      expect(t, contains('Book now'));
      expect(t, isNot(contains('var x')));
      expect(t, isNot(contains('color:red')));
      expect(t, isNot(contains('hidden')));
      expect(t, isNot(contains('<p>')));
      expect(htmlTitle(html), 'Hargeisa flights | Site');
    });

    test('entities are decoded, including numeric ones', () {
      expect(htmlToText('<p>Tom &amp; Jerry &lt;3 &quot;ok&quot; &#39;yes&#39;</p>'), contains('Tom & Jerry <3 "ok" \'yes\''));
      expect(htmlToText('<p>caf&#233; &hellip; 5&nbsp;km</p>'), contains('café … 5 km'));
    });

    test('blocks keep their breaks and the text is capped', () {
      final t = htmlToText('<p>one</p><p>two</p><li>three</li>');
      expect(t.split('\n').where((l) => l.trim().isNotEmpty).length, 3);
      final long = htmlToText('<p>${'word ' * 400}</p>', max: 100);
      expect(long.length, lessThan(120));
      expect(long, endsWith('…'));
      expect(htmlTitle('<html><body>no title</body></html>'), '');
    });
  });

  group('describe: the patch, not the whole page', () {
    final before = snap([el(1, 'button', 'Search'), el(2, 'link', 'Cart', href: '/cart'), el(3, 'field(text)', 'Coupon')]);
    final after = snap([el(1, 'button', 'Search'), el(2, 'link', 'Cart (2)', href: '/cart'), el(3, 'field(text)', 'Coupon'), el(4, 'button', 'Checkout')]);

    test('only new or changed elements go out', () {
      final d = after.describe(before: before, diff: true);
      expect(d, contains('[2]'));
      expect(d, contains('[4]'));
      expect(d, isNot(contains('[1] button "Search"')), reason: 'unchanged elements stay out of the patch');
      expect(d, isNot(contains('[3]')), reason: 'an untouched field is not repeated');
      expect(d, contains('2 of 4'));
      expect(d, contains('browser_read full:true'));
    });

    test('unchanged text is not repeated', () {
      final d = after.describe(before: before, diff: true);
      expect(d, contains('Text: unchanged since your last step.'));
      expect(d, isNot(contains('Your cart is empty.')));
      final moved = snap(after.elements, text: 'Coupon applied.').describe(before: before, diff: true);
      expect(moved, contains('Coupon applied.'));
    });

    test('no change at all says so, and a new page lists everything', () {
      final same = before.describe(before: before, diff: true);
      expect(same, contains('no change since your last step'));
      final other = snap([el(9, 'button', 'Pay')], url: 'https://shop.test/pay').describe(before: before, diff: true);
      expect(other, contains('[9]'));
      expect(other, contains('Elements (number, kind, label'), reason: 'a navigation is a full view');
    });

    test('without diff the whole page is sent, as before', () {
      final full = after.describe(before: before);
      expect(full, contains('[1] button "Search"'));
      expect(full, contains('[3]'));
      expect(full, contains('Your cart is empty.'));
    });
  });

  group('the tool surface carries the speed switches', () {
    Map<String, dynamic> props(String name) {
      final d = BrowserAgent.definitions.firstWhere((t) => (t['function'] as Map)['name'] == name);
      return ((d['function'] as Map)['parameters'] as Map)['properties'] as Map<String, dynamic>;
    }

    test('browser_open can read without rendering', () {
      expect(props('browser_open').containsKey('read'), isTrue);
    });

    test('browser_wait can wait for quiet', () {
      expect(props('browser_wait').containsKey('quiet'), isTrue);
    });

    test('browser_read can list everything again', () {
      expect(props('browser_read').containsKey('full'), isTrue);
    });
  });
}
