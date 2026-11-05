// A measuring test: it prints the tool-definition sizes on purpose.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/web_tools.dart';
import 'package:agent/services/skill_library.dart';
import 'package:agent/services/life_tools.dart';
import 'package:agent/services/media_coder.dart';
import 'package:agent/services/memory_store.dart';
import 'package:agent/services/system_tools.dart';
import 'package:agent/services/browser_jobs.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/services/phone_tools.dart';
import 'package:agent/services/doc_tools.dart';
import 'package:agent/services/doc_maker.dart';
import 'package:agent/services/connector_catalog.dart';
import 'package:agent/services/setup_tools.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/whatsapp.dart';

/// Guards the token cost of the toolbox: every agent step sends these schemas, so growth here
/// spends every user's daily allowance. Raise the limit only on purpose.
void main() {
  test('tool schemas stay lean', () {
    final groups = <String, List<Map<String, dynamic>>>{
      'web': WebTools.definitions, 'skills': SkillLibrary.definitions, 'life': LifeTools.definitions, 'media': MediaCoder.definitions,
      'memory': MemoryStore.definitions, 'system': SystemTools.definitions(), 'settings': [SystemTools.settingsTool],
      'browserJobs': BrowserJobs.definitions, 'agent': AgentTools.definitions, 'phone': PhoneTools.definitions,
      'docTools': DocTools.definitions, 'docMaker': DocMaker.definitions, 'connectors': ConnectorCatalog.definitions(),
      'apiCall': [ConnectorCatalog.apiCallTool], 'setup': SetupTools.definitions, 'bots': Bots.definitions, 'offices': Offices.definitions,
      'whatsapp': [WhatsAppTools.definition],
    };
    var total = 0, n = 0;
    final per = <String, int>{};
    for (final e in groups.entries) {
      final c = jsonEncode(e.value).length;
      total += c; n += e.value.length;
      print('${e.key}: ${e.value.length} tools, ${c ~/ 4} tok');
      for (final t in e.value) { per['${(t['function'] as Map)['name']}'] = jsonEncode(t).length ~/ 4; }
    }
    print('TOTAL $n tools ~${total ~/ 4} tokens');
    final top = per.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    print(top.take(10).map((e) => '${e.key}=${e.value}').join(', '));
    // 11000 -> 11400 (core loop v3, 2026-11-01): web_research and the shell/run_shell honesty lines are worth ~160 tokens;
    // the cap still catches a schema that balloons.
    // 11400 -> 11500 (bots background, 2026-11-05): bot_telegram (~60 tokens) lets a bot's scheduled task message the
    // owner in Telegram with SubMac closed. Bot tools reach opencode through find_tools, not with every step.
    expect(total ~/ 4, lessThan(11500));
  });
}
