// Agent loop fixes 2026-10-24 (branch fix/agent-loop). Each case is taken from a real chat in the production logs.
import 'package:agent/services/agent_loop.dart';
import 'package:agent/services/phone_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Checklist: ticks add up', () {
    const steps = ['Create site folder and index.html', 'Add style.css with basic styling', 'Add script.js for form', 'Write README'];

    test('resending the list with only the newest step keeps the earlier ticks', () {
      final todo = <String>[];
      final done = <int>{};
      Checklist.apply(todo, done, steps: steps);
      expect(Checklist.apply(todo, done, steps: steps, doneArg: [1]), isTrue);
      expect(Checklist.apply(todo, done, steps: steps, doneArg: [2]), isTrue);
      expect(done, {0, 1}, reason: 'step 1 stays ticked when step 2 is ticked with the full list resent');
      Checklist.apply(todo, done, steps: steps, doneArg: [3, 4]);
      expect(done.length, todo.length);
    });

    test('the production ping-pong ([1,3,4] then [2]) finishes instead of flipping forever', () {
      final todo = <String>[];
      final done = <int>{};
      Checklist.apply(todo, done, steps: steps);
      Checklist.apply(todo, done, steps: steps, doneArg: [1, 3, 4]);
      Checklist.apply(todo, done, steps: steps, doneArg: [2]);
      expect(done.length, 4);
      // Re-ticking what is already done is not progress (it no longer resets the "carry on" budget).
      expect(Checklist.apply(todo, done, steps: steps, doneArg: [1, 3, 4]), isFalse);
      expect(Checklist.apply(todo, done, steps: steps, doneArg: [2]), isFalse);
    });

    test('a list that drops its first step keeps the ticks of the steps that stayed', () {
      final todo = <String>[];
      final done = <int>{};
      Checklist.apply(todo, done, steps: ['Define content', ...steps], doneArg: [1, 2]);
      Checklist.apply(todo, done, steps: steps, doneArg: [2]);
      expect(todo.first, steps.first);
      expect(done, {0, 1});
    });

    test('a new plan with other steps starts unticked; string numbers and bad numbers are handled', () {
      final todo = <String>[];
      final done = <int>{};
      Checklist.apply(todo, done, steps: steps, doneArg: [1]);
      Checklist.apply(todo, done, steps: ['Book the flight', 'Book the hotel'], doneArg: ['2', 0, 9]);
      expect(done, {1});
    });

    test('a repeated identical todo call is now seen by the loop guard', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        g.record('todo', '{"done":[2]}', '1. [x] a\n2. [x] b');
      }
      expect(g.check().stuck, isTrue);
    });
  });

  group('Announce: a reply that only says what it will do', () {
    test('production replies that announced work and stopped', () {
      expect(Announce.only('Creating a simple to‑do list note.'), isTrue);
      expect(Announce.only('Creating a note with the requested content.'), isTrue);
      expect(Announce.only("I'll create it now."), isTrue);
      expect(Announce.only('On it.'), isTrue);
    });
    test('normal answers and questions are left alone', () {
      expect(Announce.only('Let me know if you need anything else.'), isFalse);
      expect(Announce.only("I'll be here if you need anything."), isFalse);
      expect(Announce.only('Running is good for your heart.'), isFalse);
      expect(Announce.only('Sure, I’ll need a few details to create the landing page.'), isFalse);
      expect(Announce.only('Creating it now. Which colour do you want?'), isFalse);
      expect(Announce.only('Here is your list.\n- milk\n- eggs'), isFalse);
      expect(Announce.only('Creating your page.\n\n```file\n/x/index.html\n```'), isFalse);
    });
  });

  group('FinalReply: one final answer, cards kept', () {
    test('the replacing reply gets the card only the held reply had', () {
      const old = 'Landing page created.\n\n```file\n/w/sites/a/index.html\n```';
      const now = 'Your landing page is ready and can be opened or published.';
      final out = FinalReply.carryCards(old, now);
      expect(out, startsWith(now));
      expect(out, contains('```file\n/w/sites/a/index.html\n```'));
    });
    test('a card already in the new reply is not added twice', () {
      const card = '```file\n/w/a.wav\n```';
      expect(FinalReply.carryCards('Old\n\n$card', 'New\n\n$card'), 'New\n\n$card');
      expect(FinalReply.carryCards('Old, no card', 'New'), 'New');
    });
  });

  group('open_link with a file on the phone', () {
    test('file:// links get a file card note instead of FileUriExposedException', () {
      final n = PhoneTools.localFileNote(Uri.parse('file:///data/user/0/com.submac.agent/app_flutter/workspace/sites/a/index.html'));
      expect(n, startsWith('Error:'));
      expect(n, contains('```file\n/data/user/0/com.submac.agent/app_flutter/workspace/sites/a/index.html\n```'));
      expect(PhoneTools.localFileNote(Uri.parse('https://example.com')), isNull);
    });
  });
}
