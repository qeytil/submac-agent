import 'dart:io';

import 'package:agent/screens/bot_job_screen.dart';
import 'package:agent/services/bot_package.dart';
import 'package:agent/services/bot_sync.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/byok.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/oc_lanes.dart';
import 'package:agent/services/opencode.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/model_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Each bot's own model (owner 2026-11-05): chosen in the bot's profile, saved on the Bot and synced, never exported,
// and every turn of the bot runs on it (falling back to the default, same as SubMac, when it is not usable here).

const _pid = 'byok-1a2b3c4d';

ByokProvider _prov({bool enabled = true, List<ByokModel>? models}) => ByokProvider(
      id: _pid,
      kind: ByokKind.openaiCompatible,
      preset: 'tokenharbor',
      baseUrl: ByokPresets.byId('tokenharbor')?.baseUrl ?? 'https://example.test/v1',
      enabled: enabled,
      keys: [ByokKey(id: 'k1', name: 'main', hint: 'cdef')],
      activeKey: 'k1',
      models: models ??
          [
            ByokModel(id: 'gpt-x-mini'),
            ByokModel(id: 'gpt-x'),
            ByokModel(id: 'claude-opus-4', name: 'Claude Opus 4'),
            ByokModel(id: 'off-model', enabled: false),
          ],
    );

void _withProvider({String chat = ByokRef.submac, bool enabled = true}) =>
    ByokStore.I.resetForTests(ByokConfig(providers: [_prov(enabled: enabled)], chat: chat), {'k1': 'secret'});

Bot _bot([String model = 'auto']) => Bot(id: 'b1', name: 'Hodan', role: 'Researcher', persona: 'You are Hodan.', model: model);

void main() {
  tearDown(() => ByokStore.I.resetForTests());

  group('saved on the bot', () {
    test('the model survives save and load (toJson/fromJson)', () {
      final b = _bot('$_pid|gpt-x');
      expect(Bot.fromJson(b.toJson()).model, '$_pid|gpt-x');
      expect(Bot.fromJson(_bot('submac').toJson()).model, 'submac');
      expect(Bot.fromJson({'id': 'x', 'name': 'Old'}).model, 'auto', reason: 'older bots start on the default');
    });

    test('synced like the bot\'s other settings', () {
      final b = _bot('$_pid|gpt-x');
      expect(BotSync.setupOf(b)['model'], '$_pid|gpt-x');
      final other = _bot()..applySetup(BotSync.setupOf(b));
      expect(other.model, '$_pid|gpt-x');
    });

    test('setModel stores the choice; empty means default', () async {
      final b = _bot();
      await Bots.I.setModel(b, '$_pid|gpt-x');
      expect(b.model, '$_pid|gpt-x');
      await Bots.I.setModel(b, 'submac');
      expect(b.model, 'submac');
      await Bots.I.setModel(b, '');
      expect(b.model, 'auto');
    });
  });

  group('shared and store bots', () {
    test('the model choice is never exported', () {
      final pkg = _bot('$_pid|gpt-x').export();
      expect(pkg['model'], 'auto');
      expect('$pkg'.contains(_pid), isFalse);
      expect('$pkg'.contains('gpt-x'), isFalse);
    });

    test('an incoming package\'s model hint is dropped: the copy starts on its default', () {
      final j = BotPackage.sanitize({'submac': BotPackage.format, 'name': 'Nova', 'persona': 'You are Nova.', 'model': 'byok-ffff|gpt-9'});
      expect(j, isNotNull);
      expect(j!['model'], 'auto');
    });
  });

  group('fallback', () {
    test('default follows SubMac\'s model (the owner\'s chats)', () {
      ByokStore.I.resetForTests();
      expect(OcLane.botSetting('auto'), ByokRef.submac);
      expect(OcLane.pick(background: true, botModel: 'auto'), {'providerID': OcLane.bot, 'modelID': Cloud.submac});
      _withProvider(chat: '$_pid|gpt-x');
      expect(OcLane.botSetting('auto'), '$_pid|gpt-x');
      expect(OcLane.botSetting(''), '$_pid|gpt-x');
      expect(OcLane.pick(background: true, botModel: 'auto'), {'providerID': _pid, 'modelID': 'gpt-x'});
    });

    test('an own model that is not usable here falls back to the default', () {
      _withProvider();
      for (final s in ['$_pid|off-model', '$_pid|missing', 'byok-ffffffff|gpt-x']) {
        expect(OcLane.botModelUnavailable(s), isTrue, reason: s);
        expect(OcLane.botSetting(s), ByokRef.submac, reason: s);
        expect(OcLane.pick(background: true, botModel: s), {'providerID': OcLane.bot, 'modelID': Cloud.submac}, reason: s);
      }
      // The owner's chats on an own model: the unusable bot model falls back to that one.
      _withProvider(chat: '$_pid|claude-opus-4');
      expect(OcLane.pick(background: true, botModel: 'byok-ffffffff|gpt-x'), {'providerID': _pid, 'modelID': 'claude-opus-4'});
      // Provider switched off: the bot's own model is unusable, and so is the chat model: SubMac.
      _withProvider(chat: '$_pid|claude-opus-4', enabled: false);
      expect(OcLane.pick(background: true, botModel: '$_pid|gpt-x'), {'providerID': OcLane.bot, 'modelID': Cloud.submac});
    });

    test('SubMac chosen for the bot stays SubMac even when the owner\'s chats use an own model', () {
      _withProvider(chat: '$_pid|gpt-x');
      expect(OcLane.botModelUnavailable('submac'), isFalse);
      expect(OcLane.pick(background: true, botModel: 'submac'), {'providerID': OcLane.bot, 'modelID': Cloud.submac});
      expect(OcLane.pick(background: true, officeWork: true, botModel: 'submac'), {'providerID': OcLane.office, 'modelID': Cloud.submac});
    });

    test('a usable own model is used whatever the lane', () {
      _withProvider();
      for (final bg in [false, true]) {
        expect(OcLane.pick(background: bg, botModel: '$_pid|gpt-x'), {'providerID': _pid, 'modelID': 'gpt-x'});
      }
      expect(OcLane.pick(background: true, officeWork: true, botModel: '$_pid|gpt-x'), {'providerID': _pid, 'modelID': 'gpt-x'});
    });

    test('profile words', () {
      _withProvider();
      expect(botModelLabel('auto'), BotModelWords.defaultLabel);
      expect(botModelLabel('submac'), 'SubMac');
      expect(botModelLabel('$_pid|claude-opus-4'), contains('Claude Opus 4'));
      expect(botModelLabel('$_pid|missing'), startsWith(BotModelWords.defaultLabel));
      expect(botModelLabel('$_pid|missing'), contains('not available'));
    });
  });

  group('the turn uses the bot\'s model', () {
    test('the prompt names the bot\'s provider and model', () {
      _withProvider();
      final body = OpenCodeEngine.promptBody([], system: 'You are Hodan', model: OcLane.pick(background: true, botModel: '$_pid|gpt-x'));
      expect(body['model'], {'providerID': _pid, 'modelID': 'gpt-x'});
    });

    test('private chat, team parts and background wakes all pass the bot\'s model', () {
      final runner = File('lib/state/agent_runner.dart').readAsStringSync();
      final ctl = File('lib/state/bots_controller.dart').readAsStringSync();
      // A bot's chat turn (owner typing, wakes, routines, follow-ups run in the bot's chat).
      expect(runner, contains('botModel: laneBot?.model'));
      // Team members' and leads' parts.
      expect(runner, contains('OcLane.pick(background: background, officeWork: true, botModel: b.model)'));
      // Owner 2026-11-07: bot work is governed by the bot's own allowance in its profile, never by the account-wide
      // gate that used to pre-pause non-BYOK bots.
      expect(ctl, contains('b.overBudget'));
      expect(ctl, isNot(contains('OcLane.isByok(OcLane.pick(background: true, botModel: b.model))')));
    });
  });

  group('picker', () {
    test('strong models are pinned first; the rest keep their order', () {
      _withProvider();
      expect(ByokStore.I.choices.map((c) => c.model.id), ['claude-opus-4', 'gpt-x', 'gpt-x-mini']);
      expect(ByokModel(id: 'gemini-2.5-pro').strength, 2);
      expect(ByokModel(id: 'gemini-2.5-flash-lite').strength, 0);
      expect(ByokModel(id: 'llama-3.1-8b').strength, 0);
      expect(ByokModel(id: 'some-model', reasoning: true).strength, 2);
    });

    Future<void> pumpRow(WidgetTester t, Bot b) async {
      t.view.physicalSize = const Size(420, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(420, 1000), disableAnimations: true),
          child: Scaffold(body: ListView(children: [BotModelRow(bot: b)])),
        ),
      ));
      await t.pump();
    }

    testWidgets('the profile row is always there, shows the choice and saves a new one', (t) async {
      SharedPreferences.setMockInitialValues({});
      ByokStore.I.resetForTests();
      final b = _bot();
      await pumpRow(t, b);
      expect(find.byKey(const ValueKey('bot-model')), findsOneWidget, reason: 'shown even without own providers');
      expect(find.text(BotModelWords.defaultLabel), findsOneWidget);

      _withProvider();
      await t.pump();
      await t.tap(find.byKey(const ValueKey('bot-model')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-default')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-submac')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-$_pid|claude-opus-4')), findsOneWidget);
      // Strong first in the sheet too.
      final opus = t.getTopLeft(find.byKey(const ValueKey('model-$_pid|claude-opus-4'))).dy;
      final mini = t.getTopLeft(find.byKey(const ValueKey('model-$_pid|gpt-x-mini'))).dy;
      expect(opus, lessThan(mini));
      await t.tap(find.byKey(const ValueKey('model-$_pid|claude-opus-4')));
      await t.pumpAndSettle();
      expect(b.model, '$_pid|claude-opus-4');
      expect(find.textContaining('Claude Opus 4'), findsOneWidget);

      // Back to the default.
      await t.tap(find.byKey(const ValueKey('bot-model')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('model-default')));
      await t.pumpAndSettle();
      expect(b.model, 'auto');
      expect(find.text(BotModelWords.defaultLabel), findsOneWidget);
    });
  });

  group('not in Settings', () {
    test('the per-bot model control left the powers list; Settings → Models only points to the profile', () {
      final powers = File('lib/screens/bot_activity_screen.dart').readAsStringSync();
      expect(powers.contains('showModelPicker'), isFalse);
      final models = File('lib/screens/models_screen.dart').readAsStringSync();
      expect(models, contains('bots-model-note'));
      expect(models.contains('Bots.I'), isFalse);
    });
  });
}
