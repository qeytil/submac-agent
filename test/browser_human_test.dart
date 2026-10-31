// P6: hands that look like a person's (typing rhythm, curved strokes with a wobble and an overshoot) and
// self-healing numbers (a control the page redrew is found again by what it looked like).
import 'package:agent/services/browser/heal.dart';
import 'package:agent/services/browser/human_input.dart';
import 'package:agent/services/browser/page_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('typing like a person', () {
    test('every plan types exactly the text, character for character', () {
      for (final t in ['a', 'Red shoes size 42', 'Hello, world. How are you?', 'x' * 200, '  two  spaces  ', 'مرحبا']) {
        final plan = HumanInput.typing(t, seed: 7);
        expect(plan.map((p) => p.chunk).join(), t, reason: 'the chunks must join back to "$t"');
        expect(plan.every((p) => p.chunk.isNotEmpty), isTrue);
        expect(plan.every((p) => p.delayMs > 0), isTrue, reason: 'no key lands in the same instant as the last');
      }
    });

    test('the same seed is the same hands; another seed is another rhythm', () {
      String shape(int seed) => HumanInput.typing('Search flights to Hargeisa', seed: seed)
          .map((p) => '${p.chunk}/${p.delayMs}')
          .join('|');
      expect(shape(3), shape(3));
      expect(shape(3), isNot(shape(4)));
    });

    test('punctuation costs a pause: dotted text takes longer than the same letters', () {
      var dotted = 0, plain = 0;
      for (var s = 1; s <= 60; s++) {
        dotted += HumanInput.typingMs('a.a.a.a.a', seed: s);
        plain += HumanInput.typingMs('aaaaaaaaa', seed: s);
      }
      expect(dotted, greaterThan(plain), reason: 'a full stop is a beat, not another letter');
    });

    test('a long text is not typed key by key', () {
      final long = 'x' * 200;
      final perChar = HumanInput.typingMs(long, seed: 5) / long.length;
      final shortPerChar = HumanInput.typingMs('abcdefghij', seed: 5) / 10;
      expect(perChar, lessThan(shortPerChar));
      expect(HumanInput.typingMs(long, seed: 5), lessThan(6000), reason: '200 characters must not take half a minute');
    });

    test('an empty text is no typing at all', () {
      expect(HumanInput.typing('', seed: 1), isEmpty);
      expect(HumanInput.typingMs('', seed: 1), 0);
    });

    test('a character is never cut in half (an emoji stays one character)', () {
      const text = 'Hi 👋🏽 there 🎉';
      for (var s = 1; s <= 30; s++) {
        final plan = HumanInput.typing(text, seed: s);
        expect(plan.map((p) => p.chunk).join(), text);
        for (final p in plan) {
          final last = p.chunk.codeUnitAt(p.chunk.length - 1);
          expect(last >= 0xD800 && last <= 0xDBFF, isFalse, reason: 'a chunk must not end on half a character');
        }
      }
    });
  });

  group('the shape of a finger', () {
    test('a stroke starts and ends exactly where the finger was told to', () {
      final pts = HumanInput.stroke(0.2, 0.7, 0.8, 0.3, seed: 11);
      expect(pts.length, greaterThan(8));
      expect(pts.first.x, 0.2);
      expect(pts.first.y, 0.7);
      expect(pts.last.x, 0.8);
      expect(pts.last.y, 0.3);
      expect(pts.every((p) => p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1), isTrue);
    });

    test('a stroke is not a laser line', () {
      final pts = HumanInput.stroke(0.1, 0.5, 0.9, 0.5, seed: 2);
      final middle = pts.sublist(1, pts.length - 1);
      expect(middle.any((p) => (p.y - 0.5).abs() > 0.004), isTrue, reason: 'the path bows and wobbles');
      // And it is not a random walk: the wobble stays small.
      expect(middle.every((p) => (p.y - 0.5).abs() < 0.08), isTrue);
    });

    test('a long drag overshoots the target and comes back', () {
      final pts = HumanInput.stroke(0.1, 0.5, 0.9, 0.5, seed: 9);
      expect(pts.any((p) => p.x > 0.902), isTrue, reason: 'the hand goes a little past and corrects');
      expect(pts.last.x, 0.9, reason: 'and settles exactly on the target');
    });

    test('a short flick does not overshoot', () {
      final pts = HumanInput.stroke(0.5, 0.5, 0.58, 0.5, seed: 9);
      expect(pts.every((p) => p.x <= 0.584), isTrue);
    });

    test('the same seed draws the same path', () {
      String shape(int seed) => HumanInput.stroke(0.1, 0.1, 0.9, 0.6, seed: seed)
          .map((p) => '${p.x.toStringAsFixed(5)},${p.y.toStringAsFixed(5)}')
          .join(' ');
      expect(shape(6), shape(6));
      expect(shape(6), isNot(shape(7)));
    });
  });

  group('times a machine would not have', () {
    test('a tap rests for a human moment, never the same twice', () {
      final holds = {for (var s = 1; s <= 24; s++) HumanInput.tapHoldMs(seed: s)};
      expect(holds.length, greaterThan(8));
      expect(holds.every((h) => h >= 42 && h <= 79), isTrue);
    });

    test('a long press stays under the context-menu threshold', () {
      for (var s = 1; s <= 12; s++) {
        final ms = HumanInput.longPressMs(seed: s);
        expect(ms, greaterThanOrEqualTo(620));
        expect(ms, lessThan(800));
      }
    });

    test('a longer swipe takes longer, and no two are the same', () {
      expect(HumanInput.swipeMs(0.1, seed: 1), lessThan(HumanInput.swipeMs(0.9, seed: 1)));
      expect(HumanInput.swipeMs(0.0, seed: 1), greaterThanOrEqualTo(180));
      expect(HumanInput.swipeMs(1.0, seed: 1), lessThanOrEqualTo(620));
      final times = {for (var s = 1; s <= 10; s++) HumanInput.swipeMs(0.4, seed: s)};
      expect(times.length, greaterThan(3));
    });

    test('distance is what a swipe duration is made of', () {
      expect(HumanInput.distance(0, 0, 3, 4), closeTo(5, 0.0001));
      expect(HumanInput.distance(0.5, 0.5, 0.5, 0.5), 0);
    });
  });

  group('self-healing numbers', () {
    test('a healed answer is a new number with the way it was found', () {
      final h = parseHeal({'ok': true, 'id': 15, 'how': 'label', 't': 'Add to cart'}, 12);
      expect(h?.id, 15);
      expect(h?.how, 'label');
      expect(h?.label, 'Add to cart');
      expect('$h', contains('15'));
    });

    test('the same number is not a heal', () {
      expect(parseHeal({'ok': true, 'id': 12, 'how': 'same'}, 12), isNull);
    });

    test('every odd answer is no heal at all (a wrong heal is worse than none)', () {
      expect(parseHeal({'err': 'the control is not on the page any more'}, 12), isNull);
      expect(parseHeal({'ok': true}, 12), isNull);
      expect(parseHeal({'ok': true, 'id': 'nope'}, 12), isNull);
      expect(parseHeal({'ok': true, 'id': -3}, 12), isNull);
      expect(parseHeal({'ok': false, 'id': 20}, 12), isNull);
    });

    test('a missing reason reads as "look", and a long label is trimmed', () {
      expect(parseHeal({'ok': true, 'id': 7, 'how': '', 't': ''}, 12)?.how, 'look');
      expect(parseHeal({'ok': true, 'id': 7, 't': 'y' * 200}, 12)?.label.length, 81);
    });

    test('a string number still heals (the page may send JSON text)', () {
      expect(parseHeal({'ok': true, 'id': '21', 'how': 'link'}, 12)?.id, 21);
    });
  });

  group('the page script', () {
    test('ships the heal ear: v11 remembers every number and can find it again', () {
      final src = PageScript.source;
      expect(src, contains('var VERSION = 11;'));
      expect(src, contains('S.heal = function'), reason: 'the find-it-again API the browser agent calls');
      expect(src, contains('S.sig[id] = '), reason: 'every listed number remembers what it looked like');
      expect(src, contains('kfam('), reason: 'a button never heals into a field');
    });
  });
}
