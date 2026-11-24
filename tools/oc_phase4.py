#!/usr/bin/env python3
"""Investigation phase 4: ability gating. New files are committed separately; this script only edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# case_abilities.dart: the editable default set
sub('lib/services/case_abilities.dart',
    """  /// Never in the default set; turned on per case.
  static const optIn = {'phone-records'};
""",
    """  /// Never in the default set; turned on per case.
  static const optIn = {'phone-records'};

  /// The editable default set (Settings → Investigation). Seeded from [initialDefaults]; the store keeps changes.
  static Map<String, String> defaults = initialDefaults();

  /// The broad seed the owner asked for: the phone's sensors, location and everything it offers on their behalf.
  static Map<String, String> initialDefaults() => {for (final a in all) a.id: defaultOn.contains(a.id) ? on : off};
""")
sub('lib/services/case_abilities.dart',
    "  static Map<String, String> defaultLevels() => {for (final a in all) a.id: defaultOn.contains(a.id) ? on : off};",
    "  static Map<String, String> defaultLevels() => Map.of(defaults);")
sub('lib/services/case_abilities.dart',
    "    return {for (final a in all) if (!have.contains(a.id)) a.id: defaultOn.contains(a.id) ? on : off};",
    "    return {for (final a in all) if (!have.contains(a.id)) a.id: defaults[a.id] ?? off};")

# app_state.dart: import the abilities + defaults store (parts share these imports)
sub('lib/app_state.dart',
    "import 'services/offices.dart';\nimport 'services/cases.dart';",
    "import 'services/offices.dart';\nimport 'services/cases.dart';\nimport 'services/case_abilities.dart';\nimport 'services/case_ability_defaults.dart';")

# system_phone.dart: initialise the defaults store
sub('lib/state/system_phone.dart',
    "    try {\n      await Cases.I.init();\n    } catch (_) {}\n",
    "    try {\n      await Cases.I.init();\n    } catch (_) {}\n    try {\n      await CaseAbilityDefaults.I.init();\n    } catch (_) {}\n")

# tool_router.dart: the ability gate and the tool → ability map
sub('lib/state/tool_router.dart',
    "  Future<ToolGate> toolGate(String name, Map<String, dynamic> args, String? convId) async {\n    final scoped = Bots.I.byConv(convId);",
    """  Future<ToolGate> toolGate(String name, Map<String, dynamic> args, String? convId) async {
    // The Investigation section's ability gate (docs/investigation.md §10): in a case's chat, a tool whose ability is
    // Off is refused outright, and one set to Ask is shown on the approval card first. Unknown tools are never gated.
    final caseCtx = Cases.I.byConv(convId);
    if (caseCtx != null) {
      final ability = _caseAbilityOf(name);
      if (ability != null) {
        final level = CaseAbilities.levelOf(caseCtx.abilities, ability);
        if (level == CaseAbilities.off) {
          return ToolGate.blocked('Not allowed: "${CaseAbilities.label(ability)}" is off for this case. Do not try another way; '
              'the user can turn it on under the case\\'s Abilities. Say what you would need.');
        }
        if (level == CaseAbilities.ask) {
          final req = ActionRequest(
            title: 'Allow ${CaseAbilities.label(ability)}?',
            body: 'This case asks first before the detective uses "${CaseAbilities.label(ability)}".',
            detail: _toolLabel(name, args),
            confirmLabel: 'Allow',
          )..kind = 'ability';
          return ToolGate(ask: req, kind: 'ability');
        }
      }
    }
    final scoped = Bots.I.byConv(convId);""")
sub('lib/state/tool_router.dart',
    "  /// Shows the approval for [g] where the user can answer it: a bot working in the background asks from a notification;",
    """  /// The investigator ability a tool belongs to, or null when the tool is not gated by abilities (docs §10).
  String? _caseAbilityOf(String name) {
    if (name.startsWith('mcp_') ||
        name == 'apps_run_tool' ||
        name == 'apps_list_tools' ||
        ConnectorCatalog.isConnectorTool(name) ||
        ConnectorTools.names.contains(name) ||
        SetupTools.names.contains(name)) {
      return 'social-check';
    }
    if (DocMaker.names.contains(name)) return 'report-writing';
    if (const {'find_place', 'get_weather'}.contains(name)) return 'sensors-location';
    if (DocTools.names.contains(name) ||
        MediaCoder.names.contains(name) ||
        MediaGen.names.contains(name) ||
        name == 'generate_image' ||
        name == 'generate_video') {
      return 'photos-media';
    }
    if (WebTools.names.contains(name) || BrowserAgent.names.contains(name) || BrowserJobs.names.contains(name)) return 'web-research';
    if (const {'read_sms', 'phone_contacts'}.contains(name)) return 'phone-records';
    if (PhoneTools.names.contains(name) ||
        SystemTools.names.contains(name) ||
        WhatsAppTools.names.contains(name) ||
        LifeTools.names.contains(name)) {
      return 'phone-powers';
    }
    if (const {'read_file', 'write_file', 'append_file', 'edit_file', 'list_files', 'search_files', 'delete_file', 'move_file', 'copy_file', 'make_dir'}.contains(name)) {
      return 'case-files';
    }
    return null;
  }

  /// Shows the approval for [g] where the user can answer it: a bot working in the background asks from a notification;""")

# settings_screen.dart: the Investigation entry
sub('lib/screens/settings_screen.dart',
    "import 'billing/billing_widgets.dart';\nimport 'connectors_screen.dart';",
    "import 'billing/billing_widgets.dart';\nimport 'case_settings_screen.dart';\nimport 'connectors_screen.dart';")
sub('lib/screens/settings_screen.dart',
    """          _Group([
            row('Phone access', const _PhonePage()),
            row('Privacy', const _PrivacyPage()),
            row('Notifications', const _NotificationsPage()),
          ]),""",
    """          _Group([
            row('Phone access', const _PhonePage()),
            row('Investigation', const CaseSettingsScreen()),
            row('Privacy', const _PrivacyPage()),
            row('Notifications', const _NotificationsPage()),
          ]),""")

print('phase 4 applied')
