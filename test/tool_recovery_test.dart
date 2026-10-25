import 'package:flutter_test/flutter_test.dart';

import 'package:agent/services/agent_loop.dart';

void main() {
  group('ToolRecovery.isError', () {
    test('spots the failures tools actually return', () {
      expect(ToolRecovery.isError('Error: no such file'), isTrue);
      expect(ToolRecovery.isError('Failed to send the message'), isTrue);
      expect(ToolRecovery.isError('Could not reach the site'), isTrue);
      expect(ToolRecovery.isError('Nothing found for that name'), isTrue);
      expect(ToolRecovery.isError('The page took too long'), isTrue);
      expect(ToolRecovery.isError('HTTP 503 from the server'), isTrue);
      expect(ToolRecovery.isError('status 429'), isTrue);
    });

    test('leaves real results alone', () {
      expect(ToolRecovery.isError('Done. Message sent to Sara.'), isFalse);
      expect(ToolRecovery.isError('12 files in the folder'), isFalse);
      expect(ToolRecovery.isError(''), isFalse);
      expect(ToolRecovery.isError('A page about error handling in Dart, which loaded fine'), isFalse);
    });

    test('only reads the head of a long result', () {
      final long = List.filled(400, 'x').join() + String.fromCharCode(10) + 'Error: broke at the end';
      expect(ToolRecovery.isError(long), isFalse);
    });
  });

  group('ToolRecovery.alternatives', () {
    const families = [
      'browser_click', 'browser_swipe', 'phone_tap', 'phone_calendar', 'biz_sale', 'health_log',
      'money_add', 'docs_read', 'skill_search', 'code_run', 'office_board', 'bot_call',
      'apps_run_tool', 'web_search', 'fetch_url', 'email_send', 'send_sms', 'call_number',
      'add_calendar_event', 'generate_image', 'run_shell', 'read_file', 'write_file', 'share_text',
      'read_sms', 'read_pdf', 'schedule_task',
    ];

    test('gives a second route for every family of tools', () {
      for (final name in families) {
        expect(ToolRecovery.alternatives(name), isNotEmpty, reason: name);
      }
    });

    test('says nothing rather than inventing a route', () {
      expect(ToolRecovery.alternatives('finish'), isEmpty);
      expect(ToolRecovery.alternatives('zzz_unknown'), isEmpty);
    });

    test('reads as one plain sentence', () {
      for (final name in families) {
        final a = ToolRecovery.alternatives(name);
        expect(a.contains(String.fromCharCode(10)), isFalse, reason: name);
        expect(a.trim(), equals(a), reason: name);
        expect(a.endsWith('.'), isFalse, reason: name);
      }
    });
  });

  group('ToolRecovery.withHint', () {
    test('adds the route after a failure and keeps the original text', () {
      final out = ToolRecovery.withHint('web_search', 'Error: no results');
      expect(out, startsWith('Error: no results'));
      expect(out, contains('Another way:'));
      expect(out, contains('wikipedia'));
    });

    test('leaves success untouched', () {
      expect(ToolRecovery.withHint('web_search', 'Found 3 pages'), 'Found 3 pages');
    });

    test('does not invent a route for a tool without one', () {
      expect(ToolRecovery.withHint('finish', 'Error: missing summary'), 'Error: missing summary');
    });

    test('leaves an empty result alone', () {
      expect(ToolRecovery.withHint('web_search', '   '), '   ');
    });

    test('never stacks a second hint', () {
      final once = ToolRecovery.withHint('web_search', 'Error: no results');
      expect(ToolRecovery.withHint('web_search', once), once);
    });
  });
}
