import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/roles.dart';
import 'package:agent/services/trust.dart';

Approval _a(String id, String group, {String bot = 'b1', String title = 'Ask'}) =>
    Approval(id: id, botId: bot, title: title, group: group);

void main() {
  group('trust levels (plan 5.2)', () {
    test('kinds of action', () {
      expect(BotTrust.kindOf('email_send', 'Send this email to a@b.co?'), 'send');
      expect(BotTrust.kindOf('phone_tap', 'Tap "Place order" on your phone?'), 'money');
      expect(BotTrust.kindOf('browser_click', 'Tap "Pay now" on shop.com?'), 'money');
      expect(BotTrust.kindOf('delete_file', 'Delete "a.txt"?'), 'delete');
      expect(BotTrust.kindOf('run_shell', 'rm -rf old'), 'delete');
      expect(BotTrust.kindOf('mcp_notion__update_page', 'Let Notion do this?'), 'change');
      expect(BotTrust.kindOf('mcp_gmail__send_message', 'Let Gmail do this?'), 'send');
      expect(BotTrust.kindOf('mcp_x__create_post', 'Let X do this?'), 'send');
      expect(BotTrust.kindOf('mcp_stripe__create_refund', 'Let Stripe do this?'), 'money');
      expect(BotTrust.kindOf('write_file', 'Replace "notes.md"?'), 'change');
      expect(BotTrust.kindOf('anything', 'Something', destructive: true), 'delete');
    });

    test('New asks for everything, Trusted only for money, sending and deleting', () {
      for (final k in ['money', 'send', 'delete', 'change']) {
        expect(BotTrust.needsAsk(BotTrust.levelNew, k), isTrue, reason: k);
      }
      expect(BotTrust.needsAsk(BotTrust.levelTrusted, 'change'), isFalse);
      expect(BotTrust.needsAsk(BotTrust.levelTrusted, 'money'), isTrue);
      expect(BotTrust.needsAsk(BotTrust.levelTrusted, 'send'), isTrue);
      expect(BotTrust.needsAsk(BotTrust.levelTrusted, 'delete'), isTrue);
    });

    test('Trusted is offered after ten clean approvals; an edit starts over; Not now changes nothing', () {
      var clean = 0;
      for (var i = 0; i < 9; i++) {
        clean = BotTrust.afterAnswer(clean, approved: true, edited: false);
      }
      expect(BotTrust.shouldOffer(BotTrust.levelNew, clean, BotTrust.promoteAfter), isFalse);
      clean = BotTrust.afterAnswer(clean, approved: false, edited: false);
      expect(clean, 9);
      clean = BotTrust.afterAnswer(clean, approved: true, edited: false);
      expect(BotTrust.shouldOffer(BotTrust.levelNew, clean, BotTrust.promoteAfter), isTrue);
      expect(BotTrust.shouldOffer(BotTrust.levelTrusted, clean, BotTrust.promoteAfter), isFalse);
      expect(BotTrust.afterAnswer(clean, approved: true, edited: true), 0);
      // "Not yet": offered again ten clean approvals later.
      final at = BotTrust.snooze(clean);
      expect(BotTrust.shouldOffer(BotTrust.levelNew, clean, at), isFalse);
      expect(BotTrust.shouldOffer(BotTrust.levelNew, clean + 10, at), isTrue);
    });

    test('bot keeps its level, count and report choice through save and sync', () {
      final b = Bot(id: 'u1', name: 'Nova', role: 'Researcher', persona: 'x')
        ..trust = 'trusted'
        ..cleanOk = 4
        ..trustOfferAt = 20
        ..report = 'weekly'
        ..roleId = 'researcher';
      final c = Bot.fromJson(b.toJson());
      expect(c.level, 'trusted');
      expect(c.cleanOk, 4);
      expect(c.trustOfferAt, 20);
      expect(c.report, 'weekly');
      expect(c.roleId, 'researcher');
      final d = Bot(id: 'u1', name: 'Old', role: '', persona: '')..applySetup(b.toJson());
      expect(d.level, 'trusted');
      expect(d.report, 'weekly');
    });

    test('a bot saved by an older app has no level yet and reads as New', () {
      final old = Bot.fromJson({'id': 'u2', 'name': 'Amal', 'role': 'Legal', 'persona': ''});
      expect(old.trust, '');
      expect(old.level, BotTrust.levelNew);
      expect(old.report, 'daily');
      expect(old.trustOfferAt, BotTrust.promoteAfter);
    });
  });

  group('one approval card, batched', () {
    test('similar asks share one card', () {
      final g = ApprovalGroups.group([
        _a('1', 'email'),
        _a('2', 'whatsapp'),
        _a('3', 'email', bot: 'b2'),
        _a('4', 'email'),
        _a('5', ''),
      ]);
      expect(g.map((x) => x.key).toList(), ['email', 'whatsapp', 'change']);
      expect(g.first.count, 3);
      expect(g.first.label, '3 emails to send');
      expect(g[1].label, 'Ask');
      expect(g.first.who((id) => id == 'b1' ? 'Nova' : 'Rank'), 'Nova and Rank');
    });

    test('group keys and nouns', () {
      expect(ApprovalGroups.keyFor('email_send', 'send'), 'email');
      expect(ApprovalGroups.keyFor('mcp_gmail__send_message', 'send'), 'email');
      expect(ApprovalGroups.keyFor('whatsapp', 'send'), 'whatsapp');
      expect(ApprovalGroups.keyFor('phone_tap', 'money'), 'money');
      expect(ApprovalGroups.noun('whatsapp', 2), 'WhatsApp messages to send');
      expect(ApprovalGroups.noun('money', 1), 'payment to approve');
    });

    test('an approval keeps its group, details and edit through a restart', () {
      final a = Approval(id: 'a1', botId: 'b', title: 'Send this email?', group: 'email', detail: 'To: x', editText: 'Hi')
        ..status = 'approved'
        ..edited = 'Hello';
      final b = Approval.fromJson(a.toJson());
      expect(b.group, 'email');
      expect(b.detail, 'To: x');
      expect(b.editText, 'Hi');
      expect(b.editable, isTrue);
      expect(b.edited, 'Hello');
      final old = Approval.fromJson({'id': 'x', 'b': 'b', 't': 'Old ask', 's': 'pending'});
      expect(old.group, '');
      expect(old.editable, isFalse);
    });
  });

  group('hire flow', () {
    test('schedule answers', () {
      expect(RoleHire.scheduleFrom('Every morning', '08:00'), ('08:00', 'daily'));
      expect(RoleHire.scheduleFrom('Weekdays only', '07:30'), ('07:30', 'weekdays'));
      expect(RoleHire.scheduleFrom('Once a week', '09:00'), ('09:00', 'mon'));
      expect(RoleHire.scheduleFrom('Every evening', '08:00'), ('19:00', 'daily'));
      expect(RoleHire.scheduleFrom('Every Sunday', '19:00'), ('19:00', 'sun'));
      expect(RoleHire.scheduleFrom('at 7:15', '08:00'), ('07:15', 'daily'));
      expect(RoleHire.scheduleFrom('8pm on weekends', '08:00'), ('20:00', 'weekends'));
      expect(RoleHire.scheduleFrom('Only when something big happens', '08:00'), isNull);
      expect(RoleHire.scheduleFrom('When I ask', '08:00'), isNull);
      expect(RoleHire.scheduleFrom('', '08:00'), ('08:00', 'daily'));
    });

    test('a role and three answers make a ready colleague with a first job', () {
      final r = BotRoles.byId('researcher')!;
      final s = RoleHire.spec(r, {'topic': 'coffee prices in Kenya', 'when': 'Weekdays only', 'style': 'Short bullets'});
      expect(s['name'], 'Nova');
      expect(s['role'], 'Researcher');
      expect(s['first_task'], contains('coffee prices in Kenya'));
      expect(s['first_task'], isNot(contains('{')));
      final routines = s['routines'] as List;
      expect(routines.length, 1);
      expect(routines.first['days'], 'weekdays');
      expect(routines.first['time'], '08:00');
      expect(routines.first['do'], contains('coffee prices in Kenya'));
      expect((s['memory'] as List).length, 3);
      expect(s['instructions'], contains('Short bullets'));
    });

    test('skipped answers fall back and leave no placeholders', () {
      for (final r in BotRoles.all) {
        final s = RoleHire.spec(r, const {});
        expect('${s['first_task']}', isNot(contains('{')), reason: r.id);
        for (final x in s['routines'] as List) {
          expect('${x['do']}', isNot(contains('{')), reason: r.id);
        }
        expect((s['memory'] as List), isEmpty, reason: r.id);
        expect(r.questions.length, 3, reason: r.id);
      }
      final legal = RoleHire.spec(BotRoles.byId('legal')!, const {'country': 'Somalia'});
      expect('${legal['first_task']}', isNot(contains('filled in')));
    });

    test('"only when something big happens" means no fixed routine', () {
      final s = RoleHire.spec(BotRoles.byId('researcher')!, {'when': 'Only when something big happens'});
      expect(s['routines'], isEmpty);
    });

    test('described colleague extras and free names', () {
      final e = RoleHire.customExtras({'start': 'my weekly sales sheet', 'when': 'Every evening'});
      expect(e['first_task'], contains('my weekly sales sheet'));
      expect((e['routines'] as List).first['time'], '19:00');
      expect(RoleHire.customExtras({'when': 'Only when I ask'})['routines'], isEmpty);
      expect(RoleHire.freeName('Nova', ['Amal']), 'Nova');
      expect(RoleHire.freeName('Nova', ['nova', 'Nova 2']), 'Nova 3');
    });
  });

  group('reports like a person', () {
    test('nothing to say means no note', () {
      expect(BotReports.compose(weekly: false, done: [], sent: 0, working: ['x'], needs: []), '');
    });
    test('daily note', () {
      final t = BotReports.compose(weekly: false, done: ['Brief on coffee'], sent: 1, working: ['Price table'], needs: ['Your login'], waiting: 2, next: 'tomorrow 08:00');
      expect(t, contains('Today I finished: Brief on coffee.'));
      expect(t, contains('Working on: Price table.'));
      expect(t, contains('Need you for: 2 asks waiting for your OK; Your login.'));
      expect(t, contains('Next: tomorrow 08:00.'));
    });
    test('weekly note leads with the week', () {
      final t = BotReports.compose(weekly: true, done: ['A', 'B'], sent: 3, working: [], needs: [], week: 'Nova this week: 2 tasks done.');
      expect(t.split('\n').first, 'Nova this week: 2 tasks done.');
      expect(t, contains('Finished: A; B.'));
    });
    test('report times', () {
      final mon = DateTime(2026, 10, 19, 10); // a Monday
      expect(BotReports.nextAt('daily', mon), DateTime(2026, 10, 19, 19));
      expect(BotReports.nextAt('daily', DateTime(2026, 10, 19, 20)), DateTime(2026, 10, 20, 19));
      expect(BotReports.nextAt('weekly', mon), DateTime(2026, 10, 25, 19));
      expect(BotReports.nextAt('off', mon), isNull);
    });
    test('presence', () {
      final b = Bot(id: 'u', name: 'N', role: '', persona: '', quietFrom: 0, quietTo: 0);
      expect(b.presence(false), 'off');
      b.active = true;
      expect(b.presence(false), 'free');
      expect(b.presence(true), 'working');
    });
  });
}
