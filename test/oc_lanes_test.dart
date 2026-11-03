// Bot work on opencode bills to the bots' share (owner 2026-11-03): every model call of a bot's wake or a team
// member's part carries the background lane, the owner's own chats stay foreground, bots run on their own model
// setting, and a background turn stops when the bots' share is refused or the bot's budget runs out.
import 'dart:io';

import 'package:agent/services/oc_lanes.dart';
import 'package:agent/services/opencode.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> ev(String type, Map<String, dynamic> props) => {'type': type, 'properties': props};

void main() {
  group('lanes', () {
    test('the owner\'s chat is foreground; a bot\'s wake and team work are background, each with its own source', () {
      expect(OcLane.pick(background: false), {'providerID': 'submac', 'modelID': 'submac'});
      expect(OcLane.pick(background: true, botModel: 'auto'), {'providerID': 'submac-bg', 'modelID': 'submac'});
      expect(OcLane.pick(background: true, officeWork: true, botModel: 'auto'), {'providerID': 'submac-office', 'modelID': 'submac'});
      // The owner typing in a bot's chat (or an office reply the owner watches) stays on the owner's lane.
      expect(OcLane.pick(background: false, officeWork: true, botModel: 'auto')['providerID'], 'submac');
      expect(OcLane.isBackground(OcLane.pick(background: true)), isTrue);
      expect(OcLane.isBackground(OcLane.pick(background: true, officeWork: true)), isTrue);
      expect(OcLane.isBackground(OcLane.pick(background: false)), isFalse);
      expect(OcLane.bgSources.values.toSet(), {'bot', 'office'}, reason: 'both bill to the bots\' share (ai-chat BOT_SOURCES)');
    });

    test('each provider has its own proxy path: only background providers use the lane path', () {
      final ps = {for (final p in OcLane.providers()) p['id']: p};
      expect(ps.keys.toSet(), {'submac', 'submac-bg', 'submac-office'});
      expect(ps['submac']!['path'], '');
      expect(ps['submac-bg']!['path'], '/lane/bot');
      expect(ps['submac-office']!['path'], '/lane/office');
      for (final p in ps.values) {
        expect(RegExp(r'^[a-z0-9-]{1,32}$').hasMatch(p['id']!), isTrue, reason: 'OpenCode.kt keeps ids of this shape');
        if (p['path']!.isNotEmpty) expect(RegExp(r'^/lane/[a-z-]{1,20}$').hasMatch(p['path']!), isTrue);
      }
    });

    test('a bot runs on its own model setting; unset, unknown or another provider falls back to submac', () {
      expect(OcLane.modelFor(null), 'submac');
      expect(OcLane.modelFor('auto'), 'submac');
      expect(OcLane.modelFor(''), 'submac');
      expect(OcLane.modelFor('submac|submac-think'), 'submac-think');
      expect(OcLane.modelFor('submac-fast'), 'submac-fast');
      expect(OcLane.modelFor('submac|submac-image'), 'submac', reason: 'not a chat model');
      expect(OcLane.modelFor('openai|gpt-4o'), 'submac', reason: 'SubMac Cloud is the only provider');
      expect(OcLane.modelFor('submac|nonsense'), 'submac');
      expect(OcLane.pick(background: true, botModel: 'submac|submac-smart')['modelID'], 'submac-smart');
      expect(OcLane.pick(background: false, botModel: 'submac|submac-smart'),
          {'providerID': 'submac', 'modelID': 'submac-smart'}, reason: 'the owner in a bot\'s chat: the bot\'s model, owner\'s lane');
    });

    test('every prompt names its model, so a bot\'s chat never stays on the lane of an earlier wake', () {
      final parts = [
        {'type': 'text', 'text': 'hi'}
      ];
      expect(OpenCodeEngine.promptBody(parts)['model'], {'providerID': 'submac', 'modelID': 'submac'});
      final bg = OpenCodeEngine.promptBody(parts, system: 'You are Hodan', model: OcLane.pick(background: true));
      expect(bg['model'], {'providerID': 'submac-bg', 'modelID': 'submac'});
      expect(bg['system'], 'You are Hodan');
      expect(OpenCodeEngine.promptBody(parts, system: '').containsKey('system'), isFalse);
    });
  });

  group('background guard', () {
    test('ai-chat\'s background_paused (retried by opencode, or an error) stops a background turn only', () {
      for (final msg in [
        'Paused until tomorrow to save your daily allowance.',
        'Background tasks are paused until midnight (00:00 EAT) to save your allowance. Your own chats still work.',
        '{"error":{"code":"background_paused"}}',
      ]) {
        final t = OpenCodeTurn('s1')..apply(ev('session.status', {'sessionID': 's1', 'status': {'type': 'retry', 'message': msg}}));
        expect(OcBgGuard(background: true).check(t), OcBgGuard.paused, reason: msg);
        expect(OcBgGuard(background: false).check(t), isNull, reason: 'the owner\'s chat is never stopped by the bots\' share');
      }
      final err = OpenCodeTurn('s1')..error = 'Paused until tomorrow to save your daily allowance.';
      expect(OcBgGuard(background: true).check(err), OcBgGuard.paused);
      final busy = OpenCodeTurn('s1')..apply(ev('session.status', {'sessionID': 's1', 'status': {'type': 'retry', 'message': 'Provider is overloaded'}}));
      expect(OcBgGuard(background: true).check(busy), isNull);
      final limit = OpenCodeTurn('s1')..error = 'You\'ve used today\'s allowance. It refreshes tomorrow.';
      expect(OcBgGuard(background: true).check(limit), isNull, reason: 'the whole allowance is not the bots\' share');
    });

    test('a bot\'s own daily budget stops its background turn once the turn has used what was left', () {
      expect(OcBgGuard.leftOf(0, 999999), isNull);
      expect(OcBgGuard.leftOf(10, 4000), 6000);
      expect(OcBgGuard.leftOf(10, 12000), 0);
      final g = OcBgGuard(background: true, budgetLeft: 6000);
      final t = OpenCodeTurn('s1');
      expect(g.check(t), isNull);
      t.apply(ev('message.updated', {'info': {'id': 'a1', 'sessionID': 's1', 'role': 'assistant', 'tokens': {'input': 3000, 'output': 500}}}));
      expect(g.check(t), isNull);
      t.apply(ev('message.updated', {'info': {'id': 'a2', 'sessionID': 's1', 'role': 'assistant', 'tokens': {'input': 2400, 'output': 200}}}));
      expect(g.check(t), OcBgGuard.budget);
      expect(OcBgGuard(background: false, budgetLeft: 10).check(t), isNull, reason: 'chats with the owner still answer');
      expect(OcBgGuard(background: true).check(t), isNull, reason: 'no budget set');
    });
  });

  group('wiring', () {
    final runner = File('lib/state/agent_runner.dart').readAsStringSync();
    final proxy = File('android_native/LocalProxy.kt').readAsStringSync();
    final oc = File('android_native/OpenCode.kt').readAsStringSync();
    final engine = File('lib/services/opencode.dart').readAsStringSync();

    test('chat turns pick their lane from the bot-wake rules; team turns are always background office work', () {
      expect(runner, contains('final bg = _backgroundLane(convId);'));
      expect(runner, contains('model: laneModel'));
      expect(RegExp(r'oc\.prompt\(').allMatches(runner).length, 2);
      expect(RegExp(r'oc\.prompt\([^;]*model: laneModel').allMatches(runner).length, 2, reason: 'every prompt names its lane');
      expect(runner, contains('OcLane.pick(background: true, officeWork: true, botModel: b.model)'));
      expect(runner, contains('Cloud.background.value.pausedNow'));
      expect(runner, contains('Cloud.markBackgroundPaused()'));
    });

    test('the engine writes one provider per lane; the proxy turns the lane path into the background header', () {
      expect(engine, contains("'providers': OcLane.providers()"));
      expect(oc, contains('baseUrl + path'));
      expect(oc, isNot(contains('.put("small_model"')), reason: 'small jobs run on the turn\'s own provider, so on its lane');
      expect(proxy, contains(r'sb.append("$LANE_HEADER: background\r\n")'));
      // A foreground call never carries the lane header, whatever the client sent.
      expect(proxy, contains('if (k.equals(LANE_HEADER, true)) continue'));
      expect(proxy, contains('val (rest, laneSource) = laneOf(rest0)'));
    });
  });
}
