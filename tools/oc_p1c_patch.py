import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

L = "lib/services/oc_lanes.dart"
patch(L,
"""  static String modelFor(String? setting) {
    final s = (setting ?? '').trim();
    if (s.isEmpty || s == 'auto') return Cloud.submac;
    final i = s.indexOf('|');
    final provider = i >= 0 ? s.substring(0, i).trim() : '';
    final model = (i >= 0 ? s.substring(i + 1) : s).trim().toLowerCase();
    if (provider.isNotEmpty && provider != Cloud.providerId) return Cloud.submac;
    return models.contains(model) ? model : Cloud.submac;
  }""",
"""  /// BYOK only: nothing resolves to a SubMac model any more.
  static String modelFor(String? setting) => '';""")

patch(L,
"""  static Map<String, String> pick({required bool background, bool officeWork = false, String? botModel, String? userModel}) {
    final setting = botModel == null ? (userModel ?? ByokStore.I.chatModel) : botSetting(botModel, userModel: userModel);
    final own = byokFor(setting);
    if (own != null) return own;
    return {
      'providerID': background ? (officeWork ? office : bot) : fg,
      'modelID': botModel == null ? Cloud.submac : modelFor(setting),
    };
  }""",
"""  static Map<String, String> pick({required bool background, bool officeWork = false, String? botModel, String? userModel}) {
    final setting = botModel == null ? (userModel ?? ByokStore.I.chatModel) : botSetting(botModel, userModel: userModel);
    final own = byokFor(setting);
    if (own != null) return own;
    // BYOK only: no SubMac fallback. Use the owner's first usable model when the setting is not a BYOK ref.
    final choices = ByokStore.I.choices;
    if (choices.isNotEmpty) return {'providerID': choices.first.provider.id, 'modelID': choices.first.model.id};
    return const <String, String>{};
  }""")

T = "test/oc_lanes_test.dart"
patch(T,
"""    test('the owner\\'s chat is foreground; a bot\\'s wake and team work are background, each with its own source', () {
      expect(OcLane.pick(background: false), {'providerID': 'submac', 'modelID': 'submac'});
      expect(OcLane.pick(background: true, botModel: 'auto'), {'providerID': 'submac-bg', 'modelID': 'submac'});
      expect(OcLane.pick(background: true, officeWork: true, botModel: 'auto'), {'providerID': 'submac-office', 'modelID': 'submac'});
      // The owner typing in a bot's chat (or an office reply the owner watches) stays on the owner's lane.
      expect(OcLane.pick(background: false, officeWork: true, botModel: 'auto')['providerID'], 'submac');
      expect(OcLane.isBackground(OcLane.pick(background: true)), isTrue);
      expect(OcLane.isBackground(OcLane.pick(background: true, officeWork: true)), isTrue);
      expect(OcLane.isBackground(OcLane.pick(background: false)), isFalse);
      expect(OcLane.bgSources.values.toSet(), {'bot', 'office'}, reason: 'both bill to the bots\\' share (ai-chat BOT_SOURCES)');
    });""",
"""    test('BYOK only: with no model set there is no model to name', () {
      expect(OcLane.pick(background: false), isEmpty);
      expect(OcLane.pick(background: true, botModel: 'auto'), isEmpty);
      expect(OcLane.pick(background: true, officeWork: true, botModel: 'auto'), isEmpty);
      expect(OcLane.isBackground(const {}), isFalse);
      expect(OcLane.bgSources.values.toSet(), {'bot', 'office'}, reason: 'legacy source labels kept for the proxy');
    });""")

patch(T,
"""    test('a bot runs on its own model setting; unset, unknown or another provider falls back to submac', () {
      expect(OcLane.modelFor(null), 'submac');
      expect(OcLane.modelFor('auto'), 'submac');
      expect(OcLane.modelFor(''), 'submac');
      expect(OcLane.modelFor('submac|submac-think'), 'submac');
      expect(OcLane.modelFor('submac-fast'), 'submac');
      expect(OcLane.modelFor('submac|submac-image'), 'submac', reason: 'not a chat model');
      expect(OcLane.modelFor('openai|gpt-4o'), 'submac', reason: 'SubMac Cloud is the only provider');
      expect(OcLane.modelFor('submac|nonsense'), 'submac');
      expect(OcLane.pick(background: true, botModel: 'submac|submac-smart')['modelID'], 'submac');
      expect(OcLane.pick(background: false, botModel: 'submac|submac-smart'),
          {'providerID': 'submac', 'modelID': 'submac'}, reason: 'the owner in a bot\\'s chat: owner\\'s lane');
    });""",
"""    test('BYOK only: no SubMac model alias is ever resolved', () {
      expect(OcLane.modelFor(null), '');
      expect(OcLane.modelFor('auto'), '');
      expect(OcLane.modelFor(''), '');
      expect(OcLane.modelFor('submac|submac-think'), '');
      expect(OcLane.modelFor('submac-fast'), '');
      expect(OcLane.modelFor('submac|submac-image'), '');
      expect(OcLane.modelFor('openai|gpt-4o'), '');
      expect(OcLane.modelFor('submac|nonsense'), '');
      expect(OcLane.pick(background: true, botModel: 'submac|submac-smart'), isEmpty);
      expect(OcLane.pick(background: false, botModel: 'submac|submac-smart'), isEmpty);
    });""")

patch(T,
"""    test('every prompt names its model, so a bot\\'s chat never stays on the lane of an earlier wake', () {
      final parts = [
        {'type': 'text', 'text': 'hi'}
      ];
      expect(OpenCodeEngine.promptBody(parts)['model'], {'providerID': 'submac', 'modelID': 'submac'});
      final bg = OpenCodeEngine.promptBody(parts, system: 'You are Hodan', model: OcLane.pick(background: true));
      expect(bg['model'], {'providerID': 'submac-bg', 'modelID': 'submac'});
      expect(bg['system'], 'You are Hodan');
      expect(OpenCodeEngine.promptBody(parts, system: '').containsKey('system'), isFalse);
    });""",
"""    test('every prompt names its model; with no BYOK model it names none', () {
      final parts = [
        {'type': 'text', 'text': 'hi'}
      ];
      expect(OpenCodeEngine.promptBody(parts)['model'], isEmpty);
      final bg = OpenCodeEngine.promptBody(parts, system: 'You are Hodan', model: OcLane.pick(background: true));
      expect(bg['model'], isEmpty);
      expect(bg['system'], 'You are Hodan');
      expect(OpenCodeEngine.promptBody(parts, system: '').containsKey('system'), isFalse);
    });""")
