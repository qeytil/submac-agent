// The Chief (fix/chief-bots): every account always has exactly one Chief, and whichever bot is the Chief gets the
// bot-making tool (bot_make: draft, create, list, edit, save) and its built-in skill; no other bot does.
//
// Root causes on dev 769887c:
// - The default Chief was seeded once per PHONE (`bot_chief_seeded_v1`), before the account was known, under the fixed
//   id 'chief'. Signing out takes every bot off the phone (BotSync._takeOff), so the next account that signed in on
//   that phone (and every app start after) had no Chief at all; an account whose Chief is another bot got a second
//   Chief on a new phone (the phone's seed stayed the Chief and was sent up with `chief: true`); a Chief made on one
//   phone never moved on the others; a removed default Chief was never replaced (its id can never be reused: SYNC-5).
// - bot_make was not one of BotPowers' always-on tools, so it counted as the "apps" power: switching that off for the
//   Chief (or any power filter) silently took bot creation away.
// - The account's "too many bots" refusal shares SQLSTATE 23514 with "bot removed", so a bot past the account's cap
//   was deleted from the phone as if it had been removed elsewhere.
// Run: flutter test test/chief_bots_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:convert';

import 'package:agent/services/bot_powers.dart';
import 'package:agent/services/bot_sync.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/chief_craft.dart';
import 'package:agent/services/offices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'bots_restore_test.dart' as rt;

Future<void> _freshPhone() async {
  BotSync.I.debugReset();
  SharedPreferences.setMockInitialValues({});
  Bots.I.chiefId = '';
  await Bots.I.init();
  await Offices.I.init();
}

bool _hasMake(Bot b) => Bots.I.definitionsFor(b).any((d) => (d['function'] as Map)['name'] == 'bot_make');

int _localChiefs() => Bots.I.bots.where((b) => Bots.I.isChief(b)).length;

List<Map<String, dynamic>> _accountChiefs(rt.FakeAccount a) =>
    [for (final r in a.mine('cloud_bots')) if (r['deleted'] != true && (r['setup'] as Map?)?['chief'] == true) r];

Future<Bot> _nova() async {
  final b = await Bots.I.create({'name': 'Nova', 'role': 'Researcher', 'persona': 'Careful and brief.'});
  b.convId = 'conv-nova';
  b.active = true;
  await Bots.I.save();
  return b;
}

/// Another phone of the same account changes a bot row (as its push would).
void _otherPhoneWrites(rt.FakeAccount a, String botId, Map<String, dynamic> Function(Map<String, dynamic> setup) change, {bool deleted = false}) {
  final r = a.mine('cloud_bots').firstWhere((x) => x['bot_id'] == botId);
  r['setup'] = deleted ? <String, dynamic>{} : change(Map<String, dynamic>.from(r['setup'] as Map));
  r['deleted'] = deleted;
  r['device_id'] = 'other-phone';
  r['updated_at'] = DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('one Chief per account (sync)', () {
    late rt.FakeAccount account;

    void useClient(http.Client c) {
      BotSync.debugClient = SupabaseClient('http://fake.local', 'anon-key', httpClient: c, authOptions: const AuthClientOptions(autoRefreshToken: false));
    }

    setUp(() async {
      await _freshPhone();
      account = rt.FakeAccount()..uid = 'acct-A';
      useClient(account.client());
      BotSync.debugUid = () => account.uid;
    });
    tearDown(() {
      BotSync.I.stop();
      BotSync.debugClient = null;
      BotSync.debugUid = null;
    });

    test('a new account on a phone another account used gets its own Chief, also after the app restarts', () async {
      await _nova();
      await BotSync.I.start();
      await BotSync.I.leave();
      account.uid = 'acct-B';
      await BotSync.I.start();
      expect(Bots.I.chief, isNotNull, reason: 'account B has no Chief: ${Bots.I.bots.map((b) => b.id).toList()}');
      expect(_localChiefs(), 1);
      expect(Bots.I.bots.where((b) => b.name == 'Nova'), isEmpty);
      expect(_accountChiefs(account).length, 1, reason: 'B\'s Chief is in B\'s account');
      expect(_hasMake(Bots.I.chief!), isTrue);
      // The app starts again: still exactly that Chief.
      final id = Bots.I.chiefId;
      await Bots.I.init();
      expect(Bots.I.chiefId, id);
      expect(_localChiefs(), 1);
      expect(Bots.I.bots.where((b) => b.origin == ChiefCraft.origin).length, 1);
    });

    test('signing out and in again, and a new phone, never make a second Chief', () async {
      await _nova();
      await BotSync.I.start();
      final id = Bots.I.chiefId;
      for (var i = 0; i < 3; i++) {
        await BotSync.I.leave();
        await BotSync.I.start();
        await BotSync.I.syncNow();
      }
      // A new phone (nothing kept on it): it seeds its own default Chief first, then the account's comes.
      await _freshPhone();
      await BotSync.I.start();
      await BotSync.I.syncNow();
      expect(Bots.I.chiefId, id);
      expect(Bots.I.bots.where((b) => b.origin == ChiefCraft.origin).length, 1);
      expect(_accountChiefs(account).length, 1);
      expect(account.mine('cloud_bots').where((r) => r['deleted'] != true && ChiefCraft.isChiefId('${r['bot_id']}')).length, 1);
    });

    test('a new phone takes the account\'s Chief when the owner made another bot the Chief', () async {
      final nova = await _nova();
      await BotSync.I.start();
      await Bots.I.setChief(nova);
      await BotSync.I.syncNow();
      expect(_accountChiefs(account).map((r) => r['bot_id']).toList(), [nova.id]);
      await _freshPhone();
      expect(Bots.I.chiefId, 'chief', reason: 'a fresh install starts with its own default Chief');
      await BotSync.I.start();
      await BotSync.I.syncNow();
      expect(Bots.I.chiefId, nova.id, reason: 'the account\'s Chief, not the phone\'s seed');
      expect(_localChiefs(), 1);
      expect(_accountChiefs(account).map((r) => r['bot_id']).toList(), [nova.id], reason: 'never two Chiefs in the account');
    });

    test('the Chief changed on another phone moves here; a change made here wins over an older one', () async {
      final nova = await _nova();
      await BotSync.I.start();
      expect(Bots.I.chiefId, 'chief');
      _otherPhoneWrites(account, 'chief', (s) => s..remove('chief'));
      _otherPhoneWrites(account, nova.id, (s) => s..['chief'] = true);
      await BotSync.I.syncNow();
      expect(Bots.I.chiefId, nova.id);
      expect(_hasMake(nova), isTrue);
      expect(_hasMake(Bots.I.byId('chief')!), isFalse);
      // Here the owner makes the default Chief the Chief again: that is sent, not undone by the account.
      await Bots.I.setChief(Bots.I.byId('chief')!);
      await BotSync.I.syncNow();
      expect(Bots.I.chiefId, 'chief');
      expect(_accountChiefs(account).map((r) => r['bot_id']).toList(), ['chief']);
    });

    test('the account removed the default Chief: one new Chief under the next id, never more', () async {
      await _nova();
      await BotSync.I.start();
      _otherPhoneWrites(account, 'chief', (s) => s, deleted: true);
      await BotSync.I.syncNow();
      expect(Bots.I.chiefId, 'chief-2');
      expect(_localChiefs(), 1);
      await BotSync.I.syncNow();
      await BotSync.I.syncNow();
      expect(Bots.I.chiefId, 'chief-2');
      expect(Bots.I.bots.where((b) => ChiefCraft.isChiefId(b.id)).length, 1);
      expect(_accountChiefs(account).map((r) => r['bot_id']).toList(), ['chief-2']);
      expect(account.refused, isEmpty, reason: '${account.refused}');
    });

    test('a phone that does not know the old Chief was removed recovers with one new Chief', () async {
      await _nova();
      await BotSync.I.start();
      await BotSync.I.leave(send: false);
      // The account removed 'chief' while this phone was away; this phone seeds 'chief' again before it pulls.
      _otherPhoneWrites(account, 'chief', (s) => s, deleted: true);
      await _freshPhone();
      await BotSync.I.start();
      await BotSync.I.syncNow();
      expect(Bots.I.chiefId, 'chief-2');
      expect(_localChiefs(), 1);
      expect(_accountChiefs(account).length, 1);
    });

    test('the account\'s "too many bots" never deletes the bot on this phone', () async {
      final inner = account.client();
      useClient(MockClient((req) async {
        if (req.method == 'POST' && req.url.path.endsWith('/cloud_bots') && account.mine('cloud_bots').length >= 2) {
          final list = jsonDecode(req.body);
          final ids = [for (final r in (list is List ? list : [list])) '${(r as Map)['bot_id']}'];
          if (ids.any((id) => !account.mine('cloud_bots').any((r) => r['bot_id'] == id))) {
            return http.Response(jsonEncode({'code': '23514', 'message': 'too many bots', 'details': null, 'hint': null}), 400,
                headers: {'content-type': 'application/json'}, request: req);
          }
        }
        final copy = http.Request(req.method, req.url)
          ..headers.addAll(req.headers)
          ..bodyBytes = req.bodyBytes;
        return inner.send(copy).then(http.Response.fromStream);
      }));
      await _nova();
      await BotSync.I.start();
      final extra = await Bots.I.create({'name': 'Idil', 'role': 'Sales lead', 'persona': 'Warm.'});
      await BotSync.I.syncNow();
      expect(account.refused, isEmpty);
      expect(account.mine('cloud_bots').map((r) => r['bot_id']), isNot(contains(extra.id)), reason: 'the account is full');
      expect(BotSync.I.status.value, BotSyncState.ok, reason: BotSync.I.lastError.value);
      expect(Bots.I.byId(extra.id), isNotNull, reason: 'a bot past the account cap was deleted from the phone');
    });
  });

  group('bot_make belongs to the Chief', () {
    setUp(_freshPhone);
    tearDown(() {
      Bots.I.lastOwnerMessage = null;
      Bots.I.bots.clear();
      Bots.I.chiefId = '';
    });

    test('the Chief keeps bot_make whatever powers are off; other bots never get it', () {
      final c = Bots.I.chief!;
      final other = Bot(id: 'n1', name: 'Nova', role: 'Researcher', persona: '');
      Bots.I.bots.add(other);
      for (final off in [<String>{}, {'apps'}, {...BotPowers.all}]) {
        final tools = BotPowers.filter(Bots.I.definitionsFor(c), off);
        expect(tools.any((d) => (d['function'] as Map)['name'] == 'bot_make'), isTrue, reason: 'powers off: $off');
      }
      expect(BotPowers.allowed({'apps'}, 'bot_make'), isTrue);
      expect(_hasMake(other), isFalse);
    });

    test('making another bot the Chief moves the tool and the skill with it', () async {
      final first = Bots.I.chief!..convId = 'conv-first';
      final other = Bot(id: 'n1', name: 'Nova', role: 'Researcher', persona: '');
      Bots.I.bots.add(other);
      expect(Bots.I.stablePromptOf(first), contains('Making bots (your skill)'));
      expect(Bots.I.stablePromptOf(other), isNot(contains('bot_make')));
      await Bots.I.setChief(other);
      expect(_hasMake(other), isTrue);
      expect(_hasMake(first), isFalse);
      expect(Bots.I.stablePromptOf(other), contains('Making bots (your skill)'));
      expect(Bots.I.stablePromptOf(first), isNot(contains('Making bots')));
      expect(await Bots.I.execute('bot_make', {'action': 'list'}, first.convId), startsWith('Error: only the Chief'));
    });

    test('the Chief cannot be removed by the owner while it is the Chief', () async {
      final c = Bots.I.chief!;
      final other = Bot(id: 'n1', name: 'Nova', role: 'Researcher', persona: '');
      Bots.I.bots.add(other);
      expect(Bots.I.canRemove(c), isFalse);
      expect(Bots.I.canRemove(other), isTrue);
      await Bots.I.setChief(other);
      expect(Bots.I.canRemove(c), isTrue);
    });

    test('draft -> the owner\'s yes -> create; then list, edit -> yes -> save', () async {
      final c = Bots.I.chief!..convId = 'conv-chief';
      var last = 'm1';
      Bots.I.lastOwnerMessage = (_) => last;
      Future<String> make(Map<String, dynamic> a) => Bots.I.execute('bot_make', a, 'conv-chief');

      final d = await make({
        'action': 'draft', 'name': 'Idil', 'role': 'Sales lead', 'mission': 'Win more customers.',
        'instructions': 'Follow up every lead within a day.', 'powers': ['web', 'apps'], 'skills': ['follow-up emails'],
      });
      expect(d, startsWith('Draft ready'));
      expect(d, contains('May use: search the web, connected apps and email'));
      // No yes from the owner yet: nothing is made.
      expect(await make({'action': 'create'}), contains('has not answered'));
      expect(Bots.I.bots.where((b) => b.name == 'Idil'), isEmpty);
      last = 'm2';
      expect(await make({'action': 'create'}), startsWith('Created Idil'));
      final idil = Bots.I.bots.firstWhere((b) => b.name == 'Idil');
      expect(idil.origin, ChiefCraft.madeOrigin);
      expect(idil.powersOff, {'browser', 'phone', 'files'});
      expect(_hasMake(idil), isFalse);
      expect(c.journal.last.text, contains('Made a new bot: Idil'));
      // A second create without a new draft makes nothing.
      expect(await make({'action': 'create'}), startsWith('Error: no draft'));

      final l = await make({'action': 'list'});
      expect(l, contains('Idil, Sales lead'));
      expect(l, contains('made by the Chief'));

      final e = await make({'action': 'edit', 'bot': 'Idil', 'role': 'Head of sales'});
      expect(e, contains('Role: Sales lead → Head of sales'));
      expect(await make({'action': 'save'}), contains('has not answered'));
      expect(idil.role, 'Sales lead');
      last = 'm3';
      expect(await make({'action': 'save'}), startsWith('Saved.'));
      expect(idil.role, 'Head of sales');

      // Bots the Chief did not make are changed by the owner in their settings.
      Bots.I.bots.add(BotTemplates.researcher);
      expect(await make({'action': 'edit', 'bot': 'Nova', 'role': 'X'}), contains('was not made by the Chief'));
    });

    test('the Chief never makes a bot past the account\'s limit', () async {
      Bots.I.chief!.convId = 'conv-chief';
      for (var i = Bots.I.bots.length; i < Bots.accountBotCap; i++) {
        Bots.I.bots.add(Bot(id: 'b$i', name: 'Bot $i', role: 'Helper', persona: ''));
      }
      final r = await Bots.I.execute('bot_make', {'action': 'draft', 'name': 'One', 'role': 'More', 'instructions': 'x'}, 'conv-chief');
      expect(r, contains('the most one account can keep'));
      expect(Bots.I.bots.length, Bots.accountBotCap);
    });
  });

  group('ChiefCraft', () {
    test('next default Chief id skips every id in use or removed', () {
      expect(ChiefCraft.nextId([]), 'chief');
      expect(ChiefCraft.nextId(['chief']), 'chief-2');
      expect(ChiefCraft.nextId(['chief', 'chief-2', 'u1']), 'chief-3');
      expect(ChiefCraft.isChiefId('chief-12'), isTrue);
      expect(ChiefCraft.isChiefId('chiefly'), isFalse);
    });

    test('which bot is the Chief after a pull', () {
      String pick({String local = 'a', String last = 'a', String? account = 'b', bool here = true}) =>
          ChiefCraft.afterPull(local: local, lastSynced: last, account: account, accountHere: here);
      expect(pick(), 'b', reason: 'changed on another phone');
      expect(pick(last: 'c'), 'a', reason: 'changed here since the last round: sent next');
      expect(pick(last: ''), 'b', reason: 'never synced here (a fresh seed): the account decides');
      expect(pick(local: ''), 'b');
      expect(pick(account: null), 'a');
      expect(pick(here: false), 'a', reason: 'the account\'s Chief has not reached this phone yet');
    });
  });
}
