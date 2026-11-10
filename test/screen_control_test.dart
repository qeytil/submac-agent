import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/screen_control.dart';

void main() {
  final t0 = DateTime(2026, 10, 19, 20, 0, 0);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  group('ScreenControl: the badge comes down when the task ends', () {
    test('a run ending drops its owner at once', () {
      final sc = ScreenControl();
      sc.stepStarted('c1', 'Opening WhatsApp', at(0));
      sc.pin('c1', at(0));
      sc.stepFinished('c1', at(1));
      expect(sc.any, isTrue);
      expect(sc.end('c1'), isTrue);
      expect(sc.any, isFalse);
      expect(sc.end('c1'), isFalse);
    });

    test('a quiet owner with no run is dropped after the idle time', () {
      final sc = ScreenControl();
      sc.stepStarted(ScreenControl.live, 'Tap', at(0));
      sc.stepFinished(ScreenControl.live, at(1));
      expect(sc.prune(at(30)), isEmpty);
      expect(sc.prune(at(47)), [ScreenControl.live]);
      expect(sc.any, isFalse);
    });

    test('a pinned run gets the longer watchdog', () {
      final sc = ScreenControl();
      sc.stepStarted('c1', 'Tap', at(0));
      sc.pin('c1', at(0));
      sc.stepFinished('c1', at(1));
      expect(sc.prune(at(60)), isEmpty);
      expect(sc.prune(at(122)), ['c1']);
    });

    test('a step that never reports back is dropped after stepMax', () {
      final sc = ScreenControl();
      sc.stepStarted('c1', 'Sending', at(0));
      sc.pin('c1', at(0));
      expect(sc.prune(at(80)), isEmpty);
      expect(sc.prune(at(91)), ['c1']);
    });

    test('an owner waiting on the user is kept', () {
      final sc = ScreenControl();
      sc.stepStarted('c1', 'Tap', at(0));
      sc.stepFinished('c1', at(1));
      expect(sc.prune(at(600), waiting: (id) => id == 'c1'), isEmpty);
      expect(sc.prune(at(600)), ['c1']);
    });

    test('clear ends every owner (Stop)', () {
      final sc = ScreenControl();
      sc.stepStarted('c1', 'a', at(0));
      sc.stepStarted('c2', 'b', at(0));
      sc.clear();
      expect(sc.any, isFalse);
    });
  });

  group('the bubble', () {
    test('focus is the most recent owner with a chat, never Live', () {
      final sc = ScreenControl();
      sc.stepStarted('c1', 'a', at(0));
      sc.stepStarted(ScreenControl.live, 'b', at(5));
      sc.stepStarted('c2', 'c', at(3));
      expect(sc.focus()?.id, 'c2');
      sc.end('c1');
      sc.end('c2');
      expect(sc.focus(), isNull);
    });

    test('shows only outside the app, with a task, and not over Live', () {
      expect(bubbleAllowed(appVisible: false, hasFocus: true, liveFloating: false), isTrue);
      expect(bubbleAllowed(appVisible: true, hasFocus: true, liveFloating: false), isFalse);
      expect(bubbleAllowed(appVisible: false, hasFocus: false, liveFloating: false), isFalse);
      expect(bubbleAllowed(appVisible: false, hasFocus: true, liveFloating: true), isFalse);
    });

    test('lines keep user and assistant text, newest four, trimmed', () {
      final msgs = <(String, String)>[
        ('user', 'one'),
        ('tool', 'ignored'),
        ('assistant', 'two ```code``` here'),
        ('assistant', ''),
        ('user', 'three'),
        ('assistant', 'four'),
        ('user', 'x' * 400),
      ];
      final l = bubbleLines(msgs);
      expect(l.length, 4);
      expect(l.first.text, 'two here');
      expect(l.last.me, isTrue);
      expect(l.last.text.length, 220);
      expect(l.last.text.endsWith('…'), isTrue);
    });

    test('step line is short and never empty', () {
      expect(bubbleStep('  '), 'Working on it');
      expect(bubbleStep('a' * 100).length, 48);
    });

    test('Edit opens the text when there is text to change, otherwise asks for a change', () {
      const a = BubbleAsk(id: '1', kind: 'approval', who: 'Ada', title: 'Send reply', editText: 'Hi');
      const b = BubbleAsk(id: '2', kind: 'confirm', who: 'Telesia', title: 'Delete');
      expect(bubbleEditMode(a), BubbleEdit.inPlace);
      expect(bubbleEditMode(b), BubbleEdit.askForChange);
      expect(a.toJson()['editable'], isTrue);
      expect(b.toJson()['editable'], isFalse);
    });

    test('sign-ins never go in the bubble', () {
      const q = BubbleAsk(id: 'q', kind: 'question', who: 'Telesia', title: 'Sign in', needsApp: true);
      final s = bubbleState(owner: 'c1', who: 'Telesia', step: 'Signing in', lines: const [], ask: q);
      expect((s['ask'] as Map)['needsApp'], isTrue);
      expect(s['owner'], 'c1');
      expect(s['canType'], isTrue);
    });
  });
}
