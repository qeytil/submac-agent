import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/apk_build.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/code_git.dart';
import 'package:agent/services/house_rules.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/skill_library.dart';
import 'package:agent/services/tool_scope.dart';

/// Remote APK builds: the agent and every bot must know they work on GitHub Actions (no Android Studio, no computer), get
/// the built-in skill for an APK request in English or Somali, and never say it is impossible.
/// Eval in the prompt-eval style: each message runs through the pure parts of the request builder.
class ApkCase {
  const ApkCase(this.text, {required this.apk, this.code = true});
  final String text;

  /// The APK note and the built-in skill must reach this request.
  final bool apk;

  /// The coding tools must open for it.
  final bool code;
}

const apkCases = <ApkCase>[
  // English
  ApkCase('build my app apk on github', apk: true),
  ApkCase('Can you make an APK of my Flutter app without Android Studio?', apk: true),
  ApkCase('I don\'t have a computer, can you build my android app online?', apk: true, code: false),
  ApkCase('compile my react native project into an apk', apk: true),
  ApkCase('my capacitor app needs an apk for my phone', apk: true),
  ApkCase('set up github actions to build my kotlin app', apk: true),
  ApkCase('the gradle build fails with gradlew permission denied', apk: true),
  ApkCase('I need an aab for the Play Store', apk: true),
  // Somali
  ApkCase('ka dhis apk github actions', apk: true),
  ApkCase('app-kayga APK ii samee', apk: true),
  ApkCase('Barnaamijkayga Flutter-ka apk-ga ka dhis GitHub', apk: true),
  ApkCase('ma suurtagal baa in apk la dhiso iyada oo aan Android Studio la haysan?', apk: true),
  ApkCase('app-ka ii dhis github-ka', apk: true),
  // Not about APKs
  ApkCase('hi', apk: false, code: false),
  ApkCase('Iska warran', apk: false, code: false),
  ApkCase('build a house plan for my land in Hargeisa', apk: false, code: false),
  ApkCase('Make a CV for me', apk: false, code: false),
  ApkCase('sawir gaari ah ii samee', apk: false, code: false),
];

/// Sentences in [text] that call a remote APK build impossible or say Android Studio / a computer is required, unless
/// they forbid saying so ("Never say ...").
List<String> denials(String text) {
  final bad = RegExp(
      r"(impossible|not possible|can(no|')t (be )?buil[dt]|unable to build|requires? android studio|needs? android studio|"
      r'need(s)? a (computer|pc|laptop)|only (on|with) a computer|ma suurtowdo|lama dhisi karo)',
      caseSensitive: false);
  final out = <String>[];
  for (final s in text.split(RegExp(r'(?<=[.!?:])\s+|\n'))) {
    final low = s.toLowerCase();
    if (!bad.hasMatch(s)) continue;
    if (!(low.contains('apk') || low.contains('android'))) continue;
    if (low.contains('never') || low.contains('weligaa') || low.contains('ha oran')) continue;
    out.add(s.trim());
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  final bot = Bot(id: 'apk1', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await app.local.init();
    Bots.I.bots.add(bot);
  });
  tearDownAll(() => Bots.I.bots.removeWhere((b) => b.id == 'apk1'));

  group('the fact is in every prompt (agent and bots)', () {
    test('house rules carry it, and the red-team markers check it', () {
      expect(HouseRules.core, contains(ApkBuild.rule));
      expect(HouseRules.markers, contains(ApkBuild.marker));
      expect(HouseRules.teamLine, contains(ApkBuild.teamRule));
      expect(HouseRules.vendorWords.hasMatch(ApkBuild.rule), isFalse);
    });

    test('main agent: whole toolbox has the coding line, scoped still has the rule', () {
      final all = app.systemPromptForTest();
      expect(all, contains(ApkBuild.marker));
      expect(all, contains(ApkBuild.codingLine));
      expect(app.systemPromptForTest(allOpen: false), contains(ApkBuild.marker));
    });

    test('quick replies and Live calls', () {
      final list = [ChatMessage(id: 'u', role: 'user', content: 'can you build an apk?')];
      expect('${app.quickPayloadForTest('none', list).first['content']}', contains(ApkBuild.marker));
      expect(app.livePromptForTest(), contains(ApkBuild.marker));
    });

    test('bots: stable and quick prompts, the Coder and teams', () {
      expect(Bots.I.stablePromptOf(bot), contains(ApkBuild.marker));
      expect(Bots.I.quickPromptOf(bot), contains(ApkBuild.marker));
      final coder = BotTemplates.coder;
      expect(Bots.I.stablePromptOf(coder), contains(ApkBuild.marker));
      expect(coder.instructions, contains('never say it needs Android Studio'));
      final o = Office(id: 'apko', name: 'Dev', goal: 'Ship', members: ['apk1'], chiefId: 'apk1');
      expect(Offices.I.teamStablePromptOf(o, bot), contains(ApkBuild.teamRule));
    });

    test('the Coder knowledge pack says it too', () {
      final pack = File('assets/bots/coder.json').readAsStringSync();
      expect(pack, contains('Android Studio is only an editor'));
      expect(pack, contains('build-android-apk'));
      expect(denials(pack), isEmpty);
    });

    test('nothing the app sends says a remote APK build is impossible', () {
      for (final t in [
        app.systemPromptForTest(),
        Bots.I.stablePromptOf(BotTemplates.coder),
        ApkBuild.bodyOf(ApkBuild.skillId)!,
        ApkBuild.bodyOf(ApkBuild.skillIdSo)!,
        for (final c in apkCases) ApkBuild.noteFor(c.text),
      ]) {
        expect(denials(t), isEmpty, reason: denials(t).join('\n'));
      }
      // The checker itself catches a denial.
      expect(denials('Sorry, building an APK is impossible without Android Studio.'), isNotEmpty);
      expect(denials('You need Android Studio to make an APK.'), isNotEmpty);
    });
  });

  group('eval: English and Somali APK requests', () {
    for (final c in apkCases) {
      test('"${c.text}"', () {
        expect(ApkBuild.wants(c.text), c.apk);
        final note = ApkBuild.noteFor(c.text);
        if (c.apk) {
          expect(note, contains(ApkBuild.skillId));
          expect(note, contains('CAN be done remotely'));
          expect(note, contains('Never answer that it is impossible'));
          final fits = SkillLibrary.I.suggestFor(c.text).map((s) => s.id);
          final sk = SkillLibrary.I.search(c.text).map((s) => s.id);
          expect([...fits, ...sk].any((id) => id == ApkBuild.skillId || id == ApkBuild.skillIdSo), isTrue,
              reason: 'the built-in skill is found for "${c.text}"');
        } else {
          expect(note, isEmpty);
          expect(SkillLibrary.I.suggestFor(c.text).map((s) => s.id), isNot(contains(ApkBuild.skillId)));
        }
        if (c.code) expect(ToolScope.hinted(c.text), contains(ToolScope.code));
      });
    }

    test('at least 12 cases, Somali included', () {
      expect(apkCases.where((c) => c.apk).length, greaterThanOrEqualTo(12));
      expect(apkCases.where((c) => c.apk && RegExp(r'\b(dhis|samee|ii)\b').hasMatch(c.text)).length, greaterThanOrEqualTo(4));
    });
  });

  group('the built-in skill', () {
    test('listed even without the online library, and readable offline', () async {
      expect(SkillLibrary.I.byId(ApkBuild.skillId), isNotNull);
      expect(SkillLibrary.I.byId(ApkBuild.skillIdSo), isNotNull);
      final r = await SkillLibrary.I.execute('skill_use', {'id': ApkBuild.skillId}, SkillLibrary.agent);
      expect(r, contains('# Skill: Build an Android APK on GitHub Actions'));
      final so = await SkillLibrary.I.execute('skill_use', {'id': ApkBuild.skillIdSo}, SkillLibrary.agent);
      expect(so, contains('Android Studio waa tafatire kaliya'));
      expect(SkillLibrary.I.promptFor(SkillLibrary.agent), contains(ApkBuild.skillId));
    });

    test('templates for Flutter, native Android, React Native and Capacitor, with signing and a release', () {
      final b = ApkBuild.bodyOf(ApkBuild.skillId)!;
      for (final s in [
        'subosito/flutter-action@v2',
        'flutter build apk --release',
        'java-version: "17"',
        'chmod +x gradlew',
        './gradlew assembleDebug',
        './gradlew assembleRelease',
        'npx cap sync android',
        'npm ci || npm install',
        'actions/upload-artifact@v4',
        'ANDROID_KEYSTORE_BASE64',
        'apksigner sign',
        'gh release create',
        'At most 3 tries',
        'ANDROID_HOME',
      ]) {
        expect(b, contains(s));
      }
      // The Somali one carries the same templates.
      expect(ApkBuild.bodyOf(ApkBuild.skillIdSo), contains('npx cap sync android'));
      expect(ApkBuild.bodyOf('nope'), isNull);
    });

    test('templates are well formed (no tabs, workflow_dispatch, no secrets in them)', () {
      for (final y in [ApkBuild.flutterYaml, ApkBuild.androidYaml, ApkBuild.reactNativeYaml, ApkBuild.capacitorYaml]) {
        expect(y, contains('workflow_dispatch'));
        expect(y, contains('runs-on: ubuntu-latest'));
        expect(y, isNot(contains('\t')));
        expect(RegExp(r'password:\s*\S').hasMatch(y), isFalse);
      }
      expect(ApkBuild.signYaml, contains(r'${{ secrets.ANDROID_KEYSTORE_BASE64 }}'));
      expect(ApkBuild.signYaml, contains('exit 0'));
    });
  });

  group('code_build', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('apk'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('React Native and Capacitor are recognised', () async {
      File('${tmp.path}/package.json').writeAsStringSync('{"dependencies":{"react-native":"0.76.0"}}');
      expect(await CodeGit.kindOf(tmp), 'react-native');
      File('${tmp.path}/package.json').writeAsStringSync('{"dependencies":{"@capacitor/android":"^7.0.0"}}');
      expect(await CodeGit.kindOf(tmp), 'capacitor');
      File('${tmp.path}/package.json').writeAsStringSync('{"dependencies":{"vite":"5"}}');
      expect(await CodeGit.kindOf(tmp), 'node');
    });

    test('APK workflows for every kind', () {
      final rn = CodeGit.workflowFor('react-native', 'apk')!;
      expect(rn, contains('assembleRelease'));
      expect(rn, contains('working-directory: android'));
      final cap = CodeGit.workflowFor('capacitor', 'apk')!;
      expect(cap, contains('npx cap sync android'));
      expect(cap, contains(r'${{ steps.jv.outputs.java }}'));
      expect(CodeGit.workflowFor('android', 'apk'), contains('rm -f local.properties'));
      expect(CodeGit.workflowFor('react-native', 'test'), CodeGit.workflowFor('node', 'test'));
      expect(CodeGit.workflowFor('capacitor', 'web'), CodeGit.workflowFor('node', 'web'));
    });
  });

  group('failure diagnosis', () {
    const logs = {
      '/home/runner/work/x/x/gradlew: Permission denied': 'chmod +x gradlew',
      'Error: Could not find or load main class org.gradle.wrapper.GradleWrapperMain': 'Gradle wrapper is missing',
      'Capacitor: android platform has not been added yet': 'android/ folder is missing',
      'Android Gradle plugin requires Java 17 to run. You are currently using Java 11.': 'Wrong Java version',
      'You have not accepted the license agreements of the following SDK components': 'accept the licences',
      'SDK location not found. Define a valid SDK location with an ANDROID_HOME': 'local.properties',
      'Dependency requires libraries and applications that depend on it to compile against version 34 or later': 'compileSdk',
      'flutter: command not found': 'subosito/flutter-action',
      'npm ERR! missing script: build': 'actions/setup-node',
      'Keystore was tampered with, or password was incorrect': 'repo secrets',
      'Could not resolve com.example:lib:9.9.9.': 'dependency could not be downloaded',
      'Execution failed: Java heap space': 'Xmx4g',
      'e: file:///home/runner/app/src/main/java/Main.kt:12:5 Unresolved reference: foo': 'compile error',
    };
    for (final e in logs.entries) {
      test(e.value, () => expect(ApkBuild.diagnosis(e.key), contains(e.value)));
    }
    test('nothing known: no guess', () {
      expect(ApkBuild.diagnose('all good'), isEmpty);
      expect(ApkBuild.diagnosis(''), '');
    });
    test('at most three causes', () => expect(ApkBuild.diagnose(logs.keys.join('\n')).length, 3));
  });
}
