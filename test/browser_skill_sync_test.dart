// Site skills follow the account: learned on one phone, replayed on the next (and back after a reinstall).
//
// The fake below is PostgREST over a mock http client with the production rules of
// supabase/migrations/20261031_browser_skill_sync.sql: RLS by user, read-only for the client (every write goes
// through browser_skill_push), and the merge — counters only grow, the newest `at` wins the steps, a removal
// wins over anything older. Run: flutter test test/browser_skill_sync_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent/services/browser/playbook.dart';
import 'package:agent/services/browser/site_skills.dart';
import 'package:agent/services/browser/skill_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// cloud_browser_skills + browser_skill_push(), as the database behaves.
class FakeSkills {
  FakeSkills(this.uid);

  String uid;

  /// skill_id -> row (the whole account's table, every user).
  final rows = <String, Map<String, dynamic>>{};

  /// How many pushes the app made (a tombstone that repeats shows up here).
  int pushes = 0;

  /// Bodies the app sent, for assertions about what never left the phone.
  final sent = <Map<String, dynamic>>[];

  var _tick = 0;

  DateTime _at() => DateTime.utc(2026, 10, 31, 9).add(Duration(seconds: ++_tick));

  List<Map<String, dynamic>> get mine => [for (final r in rows.values) if (r['user_id'] == uid) r];

  /// Puts a row in the account without going through the app (another phone recorded it).
  Map<String, dynamic> seed(String id,
      {String name = 'Seeded',
      String site = 'shop.test',
      List<Map<String, dynamic>>? steps,
      int runs = 0,
      int wins = 0,
      String at = '',
      bool deleted = false}) {
    final r = <String, dynamic>{
      'user_id': uid,
      'skill_id': id,
      'name': name,
      'site': site,
      'goal': '',
      'steps': steps ?? [{'do': 'click', 'k': 'button', 't': 'Go'}],
      'runs': runs,
      'wins': wins,
      'at': at.isEmpty ? _at().toIso8601String() : at,
      'deleted': deleted,
      'device_id': 'other',
      'updated_at': _at().toIso8601String(),
    };
    rows[id] = r;
    return r;
  }

  Map<String, dynamic> _push(Map<String, dynamic> p) {
    pushes++;
    sent.add(p);
    final id = '${p['p_id']}';
    final at = DateTime.parse('${p['p_at']}').toUtc();
    final runs = (p['p_runs'] as num).toInt();
    final wins = (p['p_wins'] as num).toInt();
    final old = rows[id];
    if (old == null) {
      final r = <String, dynamic>{
        'user_id': uid,
        'skill_id': id,
        'name': '${p['p_name'] ?? ''}',
        'site': '${p['p_site'] ?? ''}',
        'goal': '${p['p_goal'] ?? ''}',
        'steps': p['p_steps'] ?? const [],
        'runs': runs,
        'wins': min(wins, runs),
        'at': at.toIso8601String(),
        'deleted': p['p_deleted'] == true,
        'device_id': '${p['p_device'] ?? ''}',
        'updated_at': _at().toIso8601String(),
      };
      rows[id] = r;
      return r;
    }
    // Counters only grow, whatever the times are.
    final grown = max(old['runs'] as int, runs);
    old['runs'] = grown;
    old['wins'] = min(max(old['wins'] as int, wins), grown);
    // The newest recording wins everything else.
    if (at.isAfter(DateTime.parse('${old['at']}'))) {
      old['name'] = '${p['p_name'] ?? ''}';
      old['site'] = '${p['p_site'] ?? ''}';
      old['goal'] = '${p['p_goal'] ?? ''}';
      old['steps'] = p['p_steps'] ?? const [];
      old['deleted'] = p['p_deleted'] == true;
      old['device_id'] = '${p['p_device'] ?? ''}';
      old['at'] = at.toIso8601String();
    }
    old['updated_at'] = _at().toIso8601String();
    return old;
  }

  /// postgrest reads `response.request!.method`, so every response has to carry the request it answers
  /// (the same reason test/bots_restore_test.dart wraps its responses this way).
  http.Client client() => MockClient((req) async {
        final r = await _handle(req);
        return http.Response.bytes(r.bodyBytes, r.statusCode, headers: r.headers, request: req);
      });

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/rpc/browser_skill_push')) {
      final body = Map<String, dynamic>.from(jsonDecode(req.body) as Map);
      return _json(_push(body));
    }
    if (path.endsWith('/cloud_browser_skills') && req.method == 'GET') {
      final list = mine..sort((a, b) => '${a['updated_at']}'.compareTo('${b['updated_at']}'));
      return _json([for (final r in list) r]);
    }
    return _json({'code': '42P01', 'message': 'relation does not exist'}, status: 404);
  }

  http.Response _json(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
}

Playbook playbook({
  String id = 'book-a-flight',
  String name = 'Book a flight',
  String site = 'shop.test',
  int runs = 0,
  int wins = 0,
  List<PlayStep>? steps,
}) =>
    Playbook(
      id: id,
      name: name,
      site: site,
      goal: 'get to Hargeisa',
      runs: runs,
      wins: wins,
      steps: steps ?? [PlayStep(act: 'click', kind: 'button', label: 'Go')],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late FakeSkills fake;

  SupabaseClient clientOn(FakeSkills f) => SupabaseClient(
        'http://fake.local',
        'anon-key',
        httpClient: f.client(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );

  void signInAs(FakeSkills f) {
    fake = f;
    SkillSync.debugClient = clientOn(f);
    SkillSync.debugUid = () => f.uid;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('skill_sync_test');
    final d = Directory('${tmp.path}/browser_skills')..createSync(recursive: true);
    SiteSkills.I.setDirForTest(d);
    SkillSync.I.resetForTest();
    signInAs(FakeSkills('user-a'));
  });

  tearDown(() async {
    SkillSync.I.resetForTest();
    SkillSync.debugClient = null;
    SkillSync.debugUid = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('up: a flow learned here reaches the account', () {
    test('a saved skill is sent with its run and win counts', () async {
      expect(await SiteSkills.I.save(playbook(runs: 2, wins: 1)), isNull);
      await SkillSync.I.start();
      final row = fake.rows['book-a-flight'];
      expect(row, isNotNull);
      expect(row!['user_id'], 'user-a');
      expect(row['site'], 'shop.test');
      expect(row['runs'], 2);
      expect(row['wins'], 1);
      expect((row['steps'] as List).length, 1);
      expect(row['deleted'], false);
    });

    test('a password never leaves the phone', () async {
      // compressSteps drops a password field, so a playbook cannot carry one at all.
      final steps = compressSteps([
        {'do': 'click', 'k': 'link', 't': 'Sign in'},
        {'do': 'type', 'k': 'field(password)', 't': 'Password', 'v': 'hunter2'},
        {'do': 'type', 'k': 'field(text)', 't': 'Email', 'v': 'me@shop.test'},
      ]);
      expect(steps.every((s) => !s.kind.contains('password')), isTrue);
      await SiteSkills.I.save(playbook(steps: steps));
      await SkillSync.I.start();
      expect(jsonEncode(fake.rows['book-a-flight']!['steps']), isNot(contains('hunter2')));
    });

    test('a skill forgotten here leaves one tombstone, not one every round', () async {
      await SiteSkills.I.save(playbook());
      await SkillSync.I.start();
      expect(fake.rows['book-a-flight']!['deleted'], false);
      await SiteSkills.I.forget('book-a-flight');
      await SkillSync.I.syncNow();
      expect(fake.rows['book-a-flight']!['deleted'], true);
      expect((fake.rows['book-a-flight']!['steps'] as List), isEmpty);
      final before = fake.pushes;
      await SkillSync.I.syncNow();
      expect(fake.pushes, before, reason: 'a tombstone is sent once');
    });

    test('sending the same skill twice does not inflate the counters', () async {
      await SiteSkills.I.save(playbook(runs: 1, wins: 1));
      await SkillSync.I.start();
      await SiteSkills.I.save(playbook(runs: 2, wins: 2)); // one more replay here
      await SkillSync.I.syncNow();
      await SkillSync.I.syncNow();
      expect(fake.rows['book-a-flight']!['runs'], 2);
      expect(fake.rows['book-a-flight']!['wins'], 2);
    });
  });

  group('down: a flow learned elsewhere comes back', () {
    test('a skill the account has lands on this phone', () async {
      fake.seed('book-a-flight', name: 'From the account', runs: 3, wins: 2);
      await SkillSync.I.start();
      final p = await SiteSkills.I.byId('book-a-flight');
      expect(p, isNotNull);
      expect(p!.name, 'From the account');
      expect(p.site, 'shop.test');
      expect(p.steps.length, 1);
      expect(p.runs, 3);
      expect(p.wins, 2);
    });

    test('an older row never overwrites a newer copy recorded here', () async {
      await SiteSkills.I.save(playbook(name: 'Recorded here'));
      fake.seed('book-a-flight', name: 'Old copy', at: '2026-10-01T00:00:00Z');
      await SkillSync.I.start();
      expect((await SiteSkills.I.byId('book-a-flight'))!.name, 'Recorded here');
      expect(fake.rows['book-a-flight']!['name'], 'Recorded here', reason: 'the newer copy goes up instead');
    });

    test('a tombstone removes the skill here too', () async {
      await SiteSkills.I.save(playbook());
      await SkillSync.I.start();
      expect(await SiteSkills.I.byId('book-a-flight'), isNotNull);
      final r = fake.rows['book-a-flight']!;
      r['deleted'] = true;
      r['at'] = DateTime.utc(2027).toIso8601String();
      await SkillSync.I.syncNow();
      expect(await SiteSkills.I.byId('book-a-flight'), isNull);
    });

    test('the merged row comes back at once when another phone got ahead', () async {
      await SiteSkills.I.save(playbook(runs: 1, wins: 0));
      // Another phone has replayed it more, and recorded newer steps.
      fake.seed('book-a-flight',
          name: 'Recorded elsewhere',
          runs: 9,
          wins: 7,
          at: DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String());
      await SkillSync.I.start();
      final p = await SiteSkills.I.byId('book-a-flight');
      expect(p!.runs, 9, reason: 'counters are merged, not replaced');
      expect(p.name, 'Recorded elsewhere');
    });
  });

  group('whose skills these are', () {
    test('another account signing in sets the folder aside instead of uploading it', () async {
      await SiteSkills.I.save(playbook(name: 'A private flow'));
      await SkillSync.I.start();
      expect(fake.rows.length, 1);

      // B signs in on the same phone.
      signInAs(FakeSkills('user-b'));
      await SkillSync.I.start();

      expect(fake.rows, isEmpty, reason: 'nothing of A is uploaded as B');
      expect(await SiteSkills.I.all(), isEmpty, reason: 'B starts with the account copy, not A\'s files');
      expect(Directory('${tmp.path}/browser_skills.off.user-a').existsSync(), isTrue, reason: 'A\'s folder is kept');

      // A signs back in: its own folder comes back.
      signInAs(FakeSkills('user-a'));
      await SkillSync.I.start();
      expect((await SiteSkills.I.all()).map((p) => p.name), contains('A private flow'));
    });

    test('a phone that has just claimed the folder sends no tombstones', () async {
      // The account holds skills this phone has never seen (a reinstall).
      fake.seed('one', name: 'One');
      fake.seed('two', name: 'Two');
      await SkillSync.I.start();
      expect(fake.rows['one']!['deleted'], false);
      expect(fake.rows['two']!['deleted'], false);
      expect((await SiteSkills.I.all()).length, 2);
    });
  });

  group('reading the account', () {
    test('times are read as UTC whatever the phone wrote', () {
      expect(SkillSync.when('2026-10-31T12:00:00Z'), DateTime.utc(2026, 10, 31, 12));
      expect(SkillSync.when('2026-10-31T12:00:00+00:00'), DateTime.utc(2026, 10, 31, 12));
      expect(SkillSync.when('2026-10-31T12:00:00.123'), isNotNull, reason: 'a local time with no offset');
      expect(SkillSync.when(''), isNull);
      expect(SkillSync.when(null), isNull);
    });

    test('a row without steps is not a skill', () {
      expect(SkillSync.playbookOf({'skill_id': 'x', 'steps': const []}), isNull);
      expect(SkillSync.playbookOf({'skill_id': '', 'steps': const [{'do': 'click'}]}), isNull);
      expect(SkillSync.playbookOf({'skill_id': 'x', 'steps': const [{'do': 'click', 't': 'Go'}]}), isNotNull);
    });
  });
}
