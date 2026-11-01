// R2 item 3: an account's bots come back when the owner signs out and signs back in to the SAME account.
//
// Root cause (production, 2026-10-26): the account lets the app INSERT bot_id/item_id but UPDATE only the other columns
// (column grants in supabase/migrations/20261019_bot_cloud.sql). BotSync wrote every row with a PostgREST upsert, which
// is `INSERT … ON CONFLICT … DO UPDATE SET <every column sent>` including bot_id, so Postgres refused every write with
// 42501 "permission denied for table cloud_bots" and cloud_bots stayed empty (0 rows for every user). Signing out then
// took the bots off the phone and signing in found nothing to bring back.
//
// The fake account below is PostgREST over a mock http client with the production rules: row level security by user,
// the same column grants (an upsert that would update a key column is refused with 42501), the child-row foreign key,
// and the "no undelete" trigger. Run: flutter test test/bots_restore_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:convert';

import 'package:agent/services/bot_sync.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A fake Supabase REST endpoint for the cloud_bot* tables, enforcing the production grants and RLS.
class FakeAccount {
  String uid = '';
  final tables = <String, List<Map<String, dynamic>>>{
    'cloud_bots': [],
    'cloud_bot_memory': [],
    'cloud_bot_desk': [],
    'cloud_bot_journal': [],
  };
  final refused = <String>[];
  var _tick = 0;

  static const keys = {
    'cloud_bots': ['bot_id'],
    'cloud_bot_memory': ['bot_id', 'item_id'],
    'cloud_bot_desk': ['bot_id', 'item_id'],
    'cloud_bot_journal': ['bot_id', 'item_id'],
  };

  /// Columns `authenticated` may UPDATE (information_schema.column_privileges on production).
  static const updatable = {
    'cloud_bots': {'name', 'setup', 'knowledge', 'knowledge_hash', 'cloud_enabled', 'schedule', 'tz_name', 'tz_offset_min', 'next_run_at', 'deleted', 'device_id', 'origin'},
    'cloud_bot_memory': {'data', 'deleted', 'device_id', 'origin'},
    'cloud_bot_desk': {'data', 'deleted', 'device_id', 'origin'},
    'cloud_bot_journal': <String>{},
  };

  String _now() => DateTime.utc(2026, 10, 26, 8).add(Duration(milliseconds: ++_tick)).toIso8601String();

  List<Map<String, dynamic>> mine(String t) => [for (final r in tables[t]!) if (r['user_id'] == uid) r];

  bool _sameKey(String t, Map a, Map b) => a['user_id'] == b['user_id'] && keys[t]!.every((k) => '${a[k]}' == '${b[k]}');

  http.Response _err(int status, String code, String msg) {
    refused.add('$code $msg');
    return http.Response(jsonEncode({'code': code, 'message': msg, 'details': null, 'hint': null}), status,
        headers: {'content-type': 'application/json'});
  }

  http.Response _json(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

  bool _match(Map<String, dynamic> r, Map<String, String> q) {
    for (final e in q.entries) {
      if (const {'select', 'order', 'offset', 'limit', 'on_conflict', 'columns'}.contains(e.key)) continue;
      final v = e.value;
      if (v.startsWith('eq.')) {
        if ('${r[e.key]}' != v.substring(3)) return false;
      } else if (v.startsWith('gte.')) {
        if ('${r[e.key]}'.compareTo(v.substring(4)) < 0) return false;
      } else if (v.startsWith('in.(')) {
        final set = v.substring(4, v.length - 1).split(',').map((x) => x.replaceAll('"', '')).toSet();
        if (!set.contains('${r[e.key]}')) return false;
      }
    }
    return true;
  }

  http.Client client() => MockClient((req) async {
        final r = await _handle(req);
        return http.Response.bytes(r.bodyBytes, r.statusCode, headers: r.headers, request: req);
      });

  Future<http.Response> _handle(http.Request req) async {
        final path = req.url.path;
        if (path.endsWith('/rpc/bot_cloud_info')) return _json({'runner': false});
        final t = path.split('/').last;
        if (!tables.containsKey(t)) return _err(404, '42P01', 'relation "$t" does not exist');
        final q = req.url.queryParameters;
        final prefer = req.headers['Prefer'] ?? req.headers['prefer'] ?? '';
        final wantRows = prefer.contains('return=representation');
        switch (req.method) {
          case 'GET':
            var rows = [for (final r in mine(t)) if (_match(r, q)) r];
            rows.sort((a, b) => '${a['updated_at']}'.compareTo('${b['updated_at']}'));
            final off = int.tryParse(q['offset'] ?? '') ?? 0;
            final lim = int.tryParse(q['limit'] ?? '') ?? 100000;
            rows = rows.skip(off).take(lim).toList();
            if ((req.headers['Accept'] ?? '').contains('vnd.pgrst.object')) {
              if (rows.isEmpty) return _err(406, 'PGRST116', 'JSON object requested, multiple (or no) rows returned');
              return _json(rows.first);
            }
            return _json(rows);
          case 'POST':
            final body = jsonDecode(req.body);
            final list = [for (final r in (body is List ? body : [body])) Map<String, dynamic>.from(r as Map)];
            final merge = prefer.contains('resolution=merge-duplicates');
            if (merge) {
              // ON CONFLICT DO UPDATE SET <every column sent>: Postgres checks UPDATE rights on all of them up front.
              final cols = {for (final r in list) ...r.keys};
              if (cols.any((c) => !updatable[t]!.contains(c))) return _err(403, '42501', 'permission denied for table $t');
            }
            final out = <Map<String, dynamic>>[];
            for (final r in list) {
              r['user_id'] = uid;
              if (t != 'cloud_bots' && !tables['cloud_bots']!.any((b) => b['user_id'] == uid && b['bot_id'] == r['bot_id'])) {
                return _err(409, '23503', 'insert or update on table "$t" violates foreign key constraint');
              }
              final old = tables[t]!.where((x) => _sameKey(t, x, r)).firstOrNull;
              if (old != null) {
                if (!merge) continue; // ON CONFLICT DO NOTHING
                if (t == 'cloud_bots' && old['deleted'] == true && r['deleted'] == false) return _err(400, '23514', 'bot removed');
                old.addAll(r);
                old['updated_at'] = _now();
                out.add(old);
                continue;
              }
              r['updated_at'] = _now();
              tables[t]!.add(r);
              out.add(r);
            }
            return wantRows ? _json(out, status: 201) : http.Response('', 201);
          case 'PATCH':
            final body = Map<String, dynamic>.from(jsonDecode(req.body) as Map);
            if (body.keys.any((c) => !updatable[t]!.contains(c))) return _err(403, '42501', 'permission denied for table $t');
            final hit = [for (final r in mine(t)) if (_match(r, q)) r];
            for (final r in hit) {
              if (t == 'cloud_bots' && r['deleted'] == true && body['deleted'] == false) return _err(400, '23514', 'bot removed');
              r.addAll(body);
              r['updated_at'] = _now();
            }
            return wantRows ? _json(hit) : http.Response('', 204);
          case 'DELETE':
            tables[t]!.removeWhere((r) => r['user_id'] == uid && _match(r, q));
            return http.Response('', 204);
        }
        return _err(405, 'PGRST', 'method');
  }
}

Future<void> _freshPhone() async {
  SharedPreferences.setMockInitialValues({});
  await Bots.I.init();
  await Offices.I.init();
}

/// The owner's bot as the account's owner set it up: a routine, a memory line, a desk task, a journal entry, its chat.
Future<Bot> _nova() async {
  final b = await Bots.I.create({
    'name': 'Nova',
    'role': 'Researcher',
    'persona': 'Careful and brief.',
    'routines': [
      {'time': '08:30', 'days': 'weekdays', 'kind': 'work', 'do': 'Brief me on Somali tech news'}
    ],
  });
  b.convId = 'conv-nova-1';
  b.memory.add('The owner prefers Somali summaries.');
  b.desk.add(DeskTask('d1', 'Compare three hosting plans', status: 'doing'));
  b.log('work', 'Started on the hosting comparison.');
  b.active = true;
  await Bots.I.save();
  return b;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAccount account;

  setUp(() async {
    BotSync.I.debugReset();
    await _freshPhone();
    account = FakeAccount()..uid = 'acct-A';
    BotSync.debugClient = SupabaseClient('http://fake.local', 'anon-key',
        httpClient: account.client(), authOptions: const AuthClientOptions(autoRefreshToken: false));
    BotSync.debugUid = () => account.uid;
  });
  tearDown(() {
    BotSync.I.stop();
    BotSync.debugClient = null;
    BotSync.debugUid = null;
  });

  void expectNovaBack() {
    final n = Bots.I.bots.where((b) => b.name == 'Nova').firstOrNull;
    expect(n, isNotNull, reason: 'Nova did not come back: ${Bots.I.bots.map((b) => b.name).toList()}');
    expect(n!.role, 'Researcher');
    expect(n.persona, 'Careful and brief.');
    expect(n.routines.map((r) => '${r.time} ${r.days} ${r.instruction}').toList(), ['08:30 weekdays Brief me on Somali tech news']);
    expect(n.memory, contains('The owner prefers Somali summaries.'));
    expect(n.desk.map((t) => t.text).toList(), contains('Compare three hosting plans'));
    expect(n.journal.map((e) => e.text).toList(), contains('Started on the hosting comparison.'));
    expect(n.convId, 'conv-nova-1', reason: 'the bot must find its own chat again');
  }

  test('a sync round writes the bots to the account (production grants: no key column is ever updated)', () async {
    await _nova();
    await BotSync.I.start();
    expect(account.refused, isEmpty, reason: 'the account refused the writes: ${account.refused.toSet()}');
    expect(account.mine('cloud_bots').map((r) => r['name']).toSet(), containsAll(['Nova']));
    expect(account.mine('cloud_bot_memory'), isNotEmpty);
    expect(account.mine('cloud_bot_desk'), isNotEmpty);
    expect(account.mine('cloud_bot_journal'), isNotEmpty);
    // A second round with changes updates rows in place (no 42501 on the update path either).
    final n = Bots.I.bots.firstWhere((b) => b.name == 'Nova');
    n.persona = 'Careful, brief and kind.';
    n.memory.remove('The owner prefers Somali summaries.');
    await Bots.I.save();
    await BotSync.I.syncNow();
    expect(account.refused, isEmpty, reason: '${account.refused.toSet()}');
    final row = account.mine('cloud_bots').firstWhere((r) => r['name'] == 'Nova');
    expect((row['setup'] as Map)['persona'], 'Careful, brief and kind.');
    expect(account.mine('cloud_bot_memory').where((r) => r['deleted'] == true), isNotEmpty, reason: 'a removed memory line is a tombstone');
  });

  test('sign out -> sign in to the same account brings every bot back (settings, routines, memory, desk, journal, chat)', () async {
    await _nova();
    final chief = Bots.I.chiefId;
    expect(chief, isNotEmpty);
    await BotSync.I.start();
    await BotSync.I.leave();
    expect(Bots.I.bots, isEmpty, reason: 'signed out: nothing of the account stays visible');
    await BotSync.I.start();
    expectNovaBack();
    expect(Bots.I.chiefId, chief, reason: 'the Chief is still the Chief');
  });

  test('a second account on the same phone is delivered the built-in Chief with the app', () async {
    // The first account seeds the Chief and sets the device-wide seeded flag.
    await _nova();
    await BotSync.I.start();
    expect(Bots.I.chief, isNotNull, reason: 'the first account has a Chief');
    // Sign out; the account's bots are put away and the device flag stays set.
    await BotSync.I.leave();
    expect(Bots.I.bots, isEmpty, reason: 'signed out: nothing of the account stays visible');
    // A different account signs in on the same phone (no fresh install, so the device flag is still set and
    // Bots.init will not seed a Chief). It must still be delivered the Chief with the app.
    account.uid = 'acct-B';
    await BotSync.I.start();
    expect(Bots.I.chief, isNotNull, reason: 'a new account is delivered the built-in Chief');
    expect(Bots.I.chief!.id, 'chief');
    expect(account.mine('cloud_bots').any((r) => (r['setup'] as Map?)?['chief'] == true), isTrue,
        reason: 'the delivered Chief is synced to the new account');
  });

  test('a Chief the owner removed in this account is not brought back on sign-in', () async {
    await _nova();
    await BotSync.I.start();
    expect(Bots.I.chief, isNotNull);
    // The owner removes the Chief; BotSync records it per account.
    await Bots.I.remove(Bots.I.chief!);
    expect(Bots.I.chief, isNull);
    await Bots.I.save();
    // Sign out and back in to the same account: the removed Chief must not be resurrected here.
    await BotSync.I.leave();
    account.uid = 'acct-A';
    await BotSync.I.start();
    expect(Bots.I.chief, isNull, reason: 'the removed Chief is not resurrected for this account');
  });

  test('a new phone (nothing kept on it) gets the bots back from the account', () async {
    await _nova();
    await BotSync.I.start();
    await BotSync.I.leave();
    // Reinstall / another phone: only the account has them.
    await _freshPhone();
    Bots.I.bots.clear();
    await Bots.I.save();
    await BotSync.I.start();
    expectNovaBack();
  });

  test('bots made while the account could not be written still come back on this phone (kept per account)', () async {
    await _nova();
    // Offline at sign-out time: nothing reached the account.
    final online = account.client();
    BotSync.debugClient = SupabaseClient('http://fake.local', 'anon-key',
        httpClient: MockClient((r) async => throw http.ClientException('offline')), authOptions: const AuthClientOptions(autoRefreshToken: false));
    await BotSync.I.start();
    await BotSync.I.leave();
    expect(Bots.I.bots, isEmpty);
    BotSync.debugClient = SupabaseClient('http://fake.local', 'anon-key', httpClient: online, authOptions: const AuthClientOptions(autoRefreshToken: false));
    await BotSync.I.start();
    expectNovaBack();
    expect(account.mine('cloud_bots').map((r) => r['name']), contains('Nova'), reason: 'and they are sent up once the account can be reached');
  });

  test('another account on the same phone never sees them, and the owner gets them back after it signs out', () async {
    await _nova();
    await BotSync.I.start();
    await BotSync.I.leave();
    account.uid = 'acct-B';
    await BotSync.I.start();
    expect(Bots.I.bots.where((b) => b.name == 'Nova'), isEmpty, reason: 'account B must not see account A\'s bots');
    expect(account.mine('cloud_bots').map((r) => r['name']), isNot(contains('Nova')), reason: 'and never sends them up as its own');
    await BotSync.I.leave();
    account.uid = 'acct-A';
    await BotSync.I.start();
    expectNovaBack();
  });

  test('a session that ended without sign-out: the next account puts the old one\'s bots away, the owner gets them back', () async {
    await _nova();
    await BotSync.I.start();
    // The session expired: no leave(). Account B signs in on this phone.
    BotSync.I.stop();
    account.uid = 'acct-B';
    await BotSync.I.start();
    expect(Bots.I.bots.where((b) => b.name == 'Nova'), isEmpty);
    await BotSync.I.leave();
    account.uid = 'acct-A';
    await BotSync.I.start();
    expectNovaBack();
  });

  test('deleting the account keeps nothing on the phone', () async {
    await _nova();
    await BotSync.I.start();
    await BotSync.I.leave(send: false);
    expect(BotSync.I.hasKeptFor('acct-A'), isFalse);
    expect(Bots.I.bots, isEmpty);
  });

  test('a bot removed before signing out stays removed after signing back in', () async {
    final n = await _nova();
    await BotSync.I.start();
    if (n.convId.isNotEmpty) n.convId = '';
    await Bots.I.remove(n);
    await BotSync.I.leave();
    await BotSync.I.start();
    expect(Bots.I.bots.where((b) => b.name == 'Nova'), isEmpty, reason: 'a removed bot came back');
    expect(account.mine('cloud_bots').firstWhere((r) => r['bot_id'] == n.id)['deleted'], isTrue);
  });
}
