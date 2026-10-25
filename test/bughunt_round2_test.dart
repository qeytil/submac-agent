// Bug hunt round 2 (2026-10-23): background browser tasks, teams, bot cloud sync. Each test failed before its fix.
import 'package:agent/services/bot_sync.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/browser_agent.dart';
import 'package:agent/services/browser_jobs.dart';
import 'package:agent/services/offices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Bot _bot({int quietFrom = 22, int quietTo = 7, bool calls = true}) => Bot(
    id: 'b1', name: 'Ada', role: 'helper', persona: '', quietFrom: quietFrom, quietTo: quietTo, allowCalls: calls, proactivity: 'active');

BrowserJob _job(String id, String conv, String status) => BrowserJob(id, 'goal', '', conv, 20)..status = status;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B-3 browser tasks belong to their chat', () {
    tearDown(() => BrowserJobs.I.jobs.clear());

    test('waiting without an id never returns another chat\'s report', () async {
      BrowserJobs.I.jobs.add(_job('b901', 'chatA', 'done')..result = 'private result of A');
      final out = await BrowserJobs.I.execute('browser_task_wait', {}, 'chatB');
      expect(out, 'No browser tasks.');
    });

    test('a running task of another chat is not waited on, and Stop in one chat never stops the other', () async {
      final a = _job('b902', 'chatA', 'running');
      BrowserJobs.I.jobs.add(a);
      final out = await BrowserJobs.I
          .execute('browser_task_wait', {'id': 'b902'}, 'chatB', parentCancelled: () => true)
          .timeout(const Duration(seconds: 2));
      expect(out, startsWith('Error: no browser task b902'));
      expect(a.status, 'running');
      final st = await BrowserJobs.I.execute('browser_task_status', {}, 'chatB');
      expect(st, 'No browser tasks.');
    });
  });

  group('B-5 stopping a paused task', () {
    tearDown(() => BrowserJobs.I.jobs.clear());

    test('a task waiting for an answer stops when its chat stops', () {
      final j = _job('b903', 'chatA', 'needs');
      BrowserJobs.I.jobs.add(j);
      BrowserJobs.I.stopAllFor('chatA');
      expect(j.status, 'stopped');
    });

    test('browser_task_stop on a task at a check-in stops it', () async {
      final j = _job('b904', 'chatA', 'checkin');
      BrowserJobs.I.jobs.add(j);
      await BrowserJobs.I.execute('browser_task_stop', {'id': 'b904'}, 'chatA');
      expect(j.status, 'stopped');
    });
  });

  group('B-7 closing a tab before the current one', () {
    test('the browser stays on the tab it was on', () {
      final b = BrowserAgent.I;
      b.tabs
        ..clear()
        ..addAll([BrowserTab(1), BrowserTab(2), BrowserTab(3)]);
      b.current = 2;
      b.onCloseWindow(b.tabs[0]);
      expect(b.tabs[b.current].id, 3);
      b.tabs.clear();
      b.current = 0;
    });
  });

  group('T-1 calls respect quiet hours, "calls off" and the daily cap', () {
    test('quiet hours', () {
      expect(Bots.callBlock(_bot(), DateTime(2026, 1, 1, 23)), isNotNull);
      expect(Bots.callBlock(_bot(), DateTime(2026, 1, 1, 12)), isNull);
    });
    test('calls switched off', () {
      expect(Bots.callBlock(_bot(calls: false), DateTime(2026, 1, 1, 12)), isNotNull);
    });
    test('no calls left today', () {
      final b = _bot();
      b.callsToday = 0;
      b.callsLeft; // rolls the day
      b.callsToday = b.callCap;
      expect(Bots.callBlock(b, DateTime(2026, 1, 1, 12)), isNotNull);
    });
    test('an outcome that wants a call drops to a message in quiet hours', () {
      final b = _bot(quietFrom: 0, quietTo: 0, calls: false);
      expect(Bots.I.allow(b, 'call'), isNot('call'));
    });
  });

  group('T-2 Stop on a teammate\'s task', () {
    test('a stopped run does not put the task straight back in line', () {
      expect(Bots.requeueAfterRun(finished: false, kind: 'task', status: 'doing'), isFalse);
      expect(Bots.requeueAfterRun(finished: true, kind: 'task', status: 'doing'), isTrue);
    });
  });

  group('T-3 a wake never takes a chat an office job holds', () {
    test('busy office, a mark already there, or a run going: no', () {
      expect(Bots.wakeMayClaim(officeBusy: true, hasMarker: false, running: false), isFalse);
      expect(Bots.wakeMayClaim(officeBusy: false, hasMarker: true, running: false), isFalse);
      expect(Bots.wakeMayClaim(officeBusy: false, hasMarker: false, running: true), isFalse);
      expect(Bots.wakeMayClaim(officeBusy: false, hasMarker: false, running: false), isTrue);
    });
  });

  group('T-6 Blocked wins over a queued job', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    test('marking a task blocked takes its waiting work job out of the queue', () {
      final o = Office(id: 'o1', name: 'Team', members: ['b1']);
      final t = OfficeTask(id: 'k1', title: 'Write it', owner: 'b1');
      o.tasks.add(t);
      Offices.I.offices.add(o);
      Offices.I.queue.add(OfficeJob(officeId: 'o1', botId: 'b1', kind: 'task', taskId: 'k1'));
      t.status = 'blocked';
      Offices.I.taskChanged(o, t, by: 'you');
      expect(Offices.I.queue.where((q) => q.taskId == 'k1' && q.kind == 'task'), isEmpty);
      Offices.I.offices.remove(o);
      Offices.I.queue.clear();
    });
  });

  group('SYNC-4 no endless re-apply loop', () {
    test('the setup hash ignores key order (jsonb reorders keys)', () {
      final a = {'name': 'Ada', 'id': 'b1', 'routines': [{'time': '09:00', 'id': 'r1'}]};
      final b = {'id': 'b1', 'routines': [{'id': 'r1', 'time': '09:00'}], 'name': 'Ada'};
      expect(BotSync.setupHash(a), BotSync.setupHash(b));
    });
    test('a row already taken is not taken again', () {
      expect(BotSync.takeRemote(fresh: false, localChanged: false, seen: true, differs: true), isFalse);
      expect(BotSync.takeRemote(fresh: false, localChanged: false, seen: false, differs: true), isTrue);
    });
  });

  group('SYNC-2 a new phone takes the account\'s Chief', () {
    test('never synced here: the account wins, even though the local copy differs', () {
      expect(BotSync.takeRemote(fresh: true, localChanged: true, seen: false, differs: true), isTrue);
    });
    test('edited here since the last round: this phone wins', () {
      expect(BotSync.takeRemote(fresh: false, localChanged: true, seen: false, differs: true), isFalse);
    });
  });

  group('SYNC-3 skills still installing are not wiped from the account', () {
    test('pending skills go along with the installed ones', () {
      expect(BotSync.skillsToSend([], ['a']), ['a']);
      expect(BotSync.skillsToSend(['b'], ['a', 'b']).toSet(), {'a', 'b'});
    });
  });

  group('SYNC-8 times survive a change of time zone', () {
    test('journal and follow-up times are written in UTC', () {
      expect(JournalEntry(DateTime(2026, 10, 23, 22, 31), 'note', 'x').toJson()['at'], endsWith('Z'));
      expect(BotFollowup('f1', DateTime(2026, 10, 24, 9), 'do it', 'work').toJson()['at'], endsWith('Z'));
    });
    test('they read back as the same moment', () {
      final at = DateTime(2026, 10, 23, 22, 31);
      final back = JournalEntry.fromJson(JournalEntry(at, 'note', 'x').toJson()).at;
      expect(back.isAtSameMomentAs(at), isTrue);
      expect(back.isUtc, isFalse);
    });
  });
}
