/// Building Android apps (APK / AAB) remotely on GitHub Actions: the fact the agent and every bot must know, the built-in
/// skills with the workflow templates, the hint that points a request at them, and the failure-log diagnosis used by
/// code_build. Pure Dart (no Flutter, no state), so it is unit tested and the prompt text never changes between steps.
///
/// Why: asked to "build my app APK on GitHub", the agent sometimes answered that it needs Android Studio or a computer.
/// That is wrong: GitHub's ubuntu-latest runners already carry the Android SDK, and SubMac's own APK is built that way
/// (.github/workflows/dev-check.yml and build-apk.yml in this repo).
class ApkBuild {
  ApkBuild._();

  /// The id of the built-in skill (English) and its Somali counterpart.
  static const skillId = 'build-android-apk';
  static const skillIdSo = 'so-build-android-apk';

  /// The marker tests look for in every prompt (part of [rule]).
  static const marker = 'Android Studio is only an editor';

  /// One line for the shared house rules (every prompt: main agent, quick replies, Live, bots, teams).
  static const rule = '- Android apps (APK or AAB) can be built remotely on GitHub Actions with no computer: GitHub\'s ubuntu-latest '
      'machines already have the Android SDK, build-tools, platform-tools and Java (ANDROID_HOME is set). $marker and is never '
      'needed; Telesia itself is built this way. Never say a remote APK build is impossible or needs Android Studio or a local setup: '
      'offer it (skill $skillId).';

  /// The short version for a team job.
  static const teamRule = 'Android APKs build remotely on GitHub Actions (no Android Studio, no computer needed): never say it is impossible.';

  /// The Coding section of the main prompt (and every bot with the coding tools).
  static const codingLine = '- APKs on GitHub (never "impossible", never "you need Android Studio"): code_build apk builds Flutter, native '
      'Android (Gradle, Kotlin or Java), React Native and Capacitor/Ionic projects; for another setup, release signing or a GitHub '
      'Release, read skill_use $skillId ($skillIdSo in Somali) for ready workflows. Build loop: push, start, wait; on a failure read the '
      'log it returns, fix the cause and start again, at most 3 tries, then tell the user the real error line. On success give the APK '
      'as a ```file card and the run link.';

  // ---------------------------------------------------------------- what the user asked

  static final _apkWord = RegExp(
      r'\b(apk|apks|aab|app ?bundle|gradlew?|assemble(debug|release)|android studio|apk-?(ga|gii|ka|da))\b',
      caseSensitive: false);
  static final _buildWord = RegExp(
      r'\b(build|builds|building|built|compile|compiling|make|generate|export|package|produce|dhis|dhisi|dhiso|dhisto|ka dhis|ii dhis|'
      r'samee|sameey|sameeyso|soo saar|diyaari|diyaarso)\b',
      caseSensitive: false);
  static final _appWord = RegExp(
      r'\b(android|app|apps|app-?ka|appka|abka|barnaamij(ka)?|abliikeeshan(ka)?|application|flutter|react native|capacitor|ionic|kotlin)\b',
      caseSensitive: false);
  static final _remoteWord = RegExp(r'\b(github( actions?)?|actions|ci|workflow|online|remote|remotely|cloud|internet|server)\b',
      caseSensitive: false);

  /// The message is about building an Android app file (or asks whether it can be done without Android Studio).
  static bool wants(String text) {
    if (text.trim().isEmpty) return false;
    if (_apkWord.hasMatch(text)) return true;
    return _buildWord.hasMatch(text) && _appWord.hasMatch(text) && _remoteWord.hasMatch(text);
  }

  /// A one-step hint for a request about an APK build ('' when the message is about something else).
  static String noteFor(String text) {
    if (!wants(text)) return '';
    return '# Android app builds\n'
        'This request is about building an Android app file. It CAN be done remotely on the user\'s GitHub Actions: the runners '
        'already have the Android SDK and Java, no Android Studio or computer is needed. Use code_build (target apk) for a project '
        'folder on GitHub, or read skill_use $skillId (Somali: $skillIdSo) for the workflow templates and the build loop. '
        'Never answer that it is impossible.';
  }

  // ---------------------------------------------------------------- failure diagnosis

  static final _causes = <(RegExp, String)>[
    (
      RegExp(r'gradlew: Permission denied|Permission denied.*gradlew|gradlew.*Permission denied', caseSensitive: false),
      'gradlew is not executable: run "chmod +x gradlew" before it in the workflow (and commit it as executable).'
    ),
    (
      RegExp(r'gradlew: No such file|gradlew: not found|No such file or directory.*gradlew|GradleWrapperMain|gradle-wrapper\.jar',
          caseSensitive: false),
      'The Gradle wrapper is missing: commit gradlew, gradlew.bat and gradle/wrapper/ (gradle-wrapper.jar and .properties), or '
          'generate it in the workflow with "gradle wrapper" after gradle/actions/setup-gradle.'
    ),
    (
      RegExp(r"Directory '?[^ ]*android'? does not exist|No such file or directory.*\bandroid\b|android platform has not been added|"
          r'Unable to find android project|could not find the android folder|No Android SDK project', caseSensitive: false),
      'The android/ folder is missing: Flutter = "flutter create . --platforms=android", Capacitor = "npx cap add android", '
          'React Native = commit the android/ folder the template made.'
    ),
    (
      RegExp(r'Unsupported class file major version|requires Java 1[17]|requires Java 21|invalid source release|release version \d+ not '
          r'supported|Android Gradle plugin requires Java|Could not determine java version|JAVA_HOME is set to an invalid', caseSensitive: false),
      'Wrong Java version: use actions/setup-java with java-version "17" (Android Gradle Plugin 8.x; Capacitor 7 and newer need "21").'
    ),
    (
      RegExp(r'not accepted the license|license agreements? .* not accepted|Failed to install the following Android SDK|'
          r'SDK location not found|sdk\.dir', caseSensitive: false),
      'Android SDK setup: delete a committed local.properties (its sdk.dir points at someone\'s computer), and accept the licences with '
          '"yes | \$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses" before the build.'
    ),
    (
      RegExp(r'compileSdk(Version)? is not specified|to compile against version \d+ or later|requires compileSdk|'
          r'Failed to find target with hash string|minCompileSdk', caseSensitive: false),
      'compileSdk is too old or missing: raise compileSdk (and targetSdk) in android/app/build.gradle to what the message asks for.'
    ),
    (
      RegExp(r'flutter: command not found|flutter: not found', caseSensitive: false),
      'Flutter is not set up in the workflow: add subosito/flutter-action@v2 (channel stable) before flutter commands.'
    ),
    (
      RegExp(r'npm: command not found|npx: command not found|node: command not found|npm ERR!|Cannot find module', caseSensitive: false),
      'Node step: add actions/setup-node@v4 (node-version 20 or 22) and "npm ci || npm install" before the Android build; a missing '
          'module means a dependency is not in package.json.'
    ),
    (
      RegExp(r'Keystore was tampered|keystore password was incorrect|Failed to read key|Cannot recover key|signingConfig|'
          r'KeytoolException|apksigner', caseSensitive: false),
      'Signing: check the repo secrets (ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD); '
          'without a keystore build the debug APK instead.'
    ),
    (
      RegExp(r'Could not resolve|Could not find [\w.\-]+:[\w.\-]+:|Could not GET', caseSensitive: false),
      'A dependency could not be downloaded: check the version exists (code_docs) and that google() and mavenCentral() are in the '
          'repositories.'
    ),
    (
      RegExp(r'Java heap space|OutOfMemoryError|Gradle build daemon disappeared|Metaspace', caseSensitive: false),
      'Out of memory: set org.gradle.jvmargs=-Xmx4g in gradle.properties.'
    ),
    (
      RegExp(r'^e: .*\.kt|\.kt:\d+|\.java:\d+: error|\.dart:\d+:\d+: Error|Error: .*\.dart', caseSensitive: false, multiLine: true),
      'A compile error in the code: fix the file and line the log names, then build again.'
    ),
  ];

  /// The likely causes found in a failed build log, most specific first (at most 3).
  static List<String> diagnose(String log) {
    final out = <String>[];
    for (final (re, hint) in _causes) {
      if (re.hasMatch(log) && !out.contains(hint)) out.add(hint);
      if (out.length == 3) break;
    }
    return out;
  }

  /// The diagnosis as a block for the tool result ('' when nothing known matched).
  static String diagnosis(String log) {
    final d = diagnose(log);
    if (d.isEmpty) return '';
    return 'Likely cause:\n${d.map((e) => '- $e').join('\n')}';
  }

  // ---------------------------------------------------------------- the built-in skills

  /// Library index lines (same shape as the shared library's index.json entries).
  static const skills = <Map<String, Object>>[
    {
      'id': skillId,
      'name': 'Build an Android APK on GitHub Actions',
      'cat': 'developer',
      'sub': 'Android',
      'desc': 'Build an installable APK (or Play Store AAB) remotely on the user\'s GitHub Actions for Flutter, native Android '
          '(Gradle/Kotlin), React Native or Capacitor/Ionic: no Android Studio or computer needed. Workflows, signing, release link, '
          'fix-and-retry loop.',
      'tags': ['apk', 'android', 'android app', 'aab', 'github', 'github actions', 'actions', 'workflow', 'ci', 'gradle',
        'flutter', 'react native', 'capacitor', 'ionic', 'kotlin', 'android studio', 'keystore'],
      'powers': <String>[],
      'level': 'pro',
      'v': 1,
    },
    {
      'id': skillIdSo,
      'name': 'APK ka dhis GitHub Actions',
      'cat': 'somalia',
      'sub': 'Developer',
      'desc': 'Ka dhis APK Android ah GitHub Actions (Flutter, Android Gradle/Kotlin, React Native, Capacitor): looma baahna Android '
          'Studio ama kombiyuutar. Build an APK on GitHub Actions, explained in Somali.',
      'tags': ['apk', 'apk-ga', 'ka dhis', 'android', 'app-ka', 'appka', 'abka', 'barnaamij', 'github',
        'github actions', 'actions', 'flutter', 'gradle', 'android studio'],
      'powers': <String>[],
      'level': 'pro',
      'v': 1,
    },
  ];

  /// The full instructions of a built-in skill, or null when [id] is not one.
  static String? bodyOf(String id) => switch (id) {
        skillId => _bodyEn,
        skillIdSo => _bodySo,
        _ => null,
      };

  // ---- workflow templates (shared by both bodies). Our own text; the actions they use are listed in docs/third-party.md.

  static const flutterYaml = r'''
name: Android APK
on:
  workflow_dispatch:
  push:
    branches: [main]
permissions:
  contents: write
jobs:
  apk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - name: Platform folder (made when the repo has none)
        run: |
          N=$(grep -m1 "^name:" pubspec.yaml | awk '{print $2}')
          [ -d android ] || flutter create . --project-name "$N" --platforms=android
      - run: flutter pub get
      - run: flutter build apk --release   # or --debug; release is signed with the debug key unless you sign below
      - run: cp build/app/outputs/flutter-apk/app-release.apk app.apk
      # SIGN (optional) goes here
      - uses: actions/upload-artifact@v4
        with:
          name: app-apk
          path: app.apk
      # RELEASE (optional) goes here
''';

  static const androidYaml = r'''
name: Android APK
on:
  workflow_dispatch:
  push:
    branches: [main]
permissions:
  contents: write
jobs:
  apk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - uses: gradle/actions/setup-gradle@v4
      - name: Build
        run: |
          rm -f local.properties          # a committed sdk.dir from someone's computer breaks the build
          chmod +x gradlew
          ./gradlew assembleDebug --stacktrace
          cp $(ls app/build/outputs/apk/debug/*.apk | head -1) app.apk
      # SIGN (optional): build assembleRelease instead, then sign app/build/outputs/apk/release/*-unsigned.apk
      - uses: actions/upload-artifact@v4
        with:
          name: app-apk
          path: app.apk
      # RELEASE (optional) goes here
''';

  static const reactNativeYaml = r'''
name: Android APK
on:
  workflow_dispatch:
permissions:
  contents: write
jobs:
  apk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - uses: gradle/actions/setup-gradle@v4
      - run: npm ci || npm install
      - name: Build (release bundles the JavaScript; a debug APK needs a running Metro server)
        working-directory: android
        run: |
          rm -f local.properties
          chmod +x gradlew
          ./gradlew assembleRelease --stacktrace
          cp $(ls app/build/outputs/apk/release/*.apk | head -1) ../app.apk
      # SIGN (optional) goes here (the template signs release with the debug key)
      - uses: actions/upload-artifact@v4
        with:
          name: app-apk
          path: app.apk
''';

  static const capacitorYaml = r'''
name: Android APK
on:
  workflow_dispatch:
permissions:
  contents: write
jobs:
  apk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Java for this Capacitor version (7 and newer need 21)
        id: jv
        run: |
          V=$(grep -o '"@capacitor/android": *"[^0-9]*[0-9]*' package.json | grep -o '[0-9]*$' || true)
          if [ "${V:-6}" -ge 7 ]; then echo "java=21" >> $GITHUB_OUTPUT; else echo "java=17" >> $GITHUB_OUTPUT; fi
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: ${{ steps.jv.outputs.java }}
      - uses: gradle/actions/setup-gradle@v4
      - run: npm ci || npm install
      - run: npm run build
      - run: |
          [ -d android ] || npx cap add android
          npx cap sync android
      - name: Build
        working-directory: android
        run: |
          rm -f local.properties
          chmod +x gradlew
          ./gradlew assembleDebug --stacktrace
          cp $(ls app/build/outputs/apk/debug/*.apk | head -1) ../app.apk
      - uses: actions/upload-artifact@v4
        with:
          name: app-apk
          path: app.apk
''';

  /// Steps that sign app.apk with a keystore from the repo secrets; skipped (the APK stays debug-signed) when there is none.
  static const signYaml = r'''
      - name: Sign with the release key (skipped when the secret is not set)
        env:
          KS_B64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          KS_PASS: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          KEY_PASS: ${{ secrets.ANDROID_KEY_PASSWORD }}
        run: |
          if [ -z "$KS_B64" ]; then echo "No keystore secret: keeping the debug-signed APK"; exit 0; fi
          echo "$KS_B64" | base64 -d > release.jks
          BT=$(ls -d $ANDROID_HOME/build-tools/* | sort -V | tail -1)
          $BT/zipalign -p -f 4 app.apk aligned.apk
          $BT/apksigner sign --ks release.jks --ks-pass env:KS_PASS --ks-key-alias "$KEY_ALIAS" --key-pass env:KEY_PASS \
            --out app.apk aligned.apk
          $BT/apksigner verify --print-certs app.apk
          rm -f release.jks aligned.apk
''';

  /// A GitHub Release with the APK attached (the gh tool is already on the runner; needs permissions: contents: write).
  static const releaseYaml = r'''
      - name: GitHub Release with the APK
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh release create "build-${{ github.run_number }}" app.apk --title "Build ${{ github.run_number }}" --notes "APK from ${{ github.sha }}"
''';

  static const _templates = '## Workflow templates (save as .github/workflows/android-apk.yml)\n'
      'Pick the one for the project: pubspec.yaml = Flutter; gradlew or settings.gradle(.kts) at the root = native Android; '
      'package.json with "react-native" = React Native; capacitor.config.* or "@capacitor/android" = Capacitor/Ionic.\n\n'
      '### Flutter\n```yaml\n$flutterYaml```\n\n'
      '### Native Android (Gradle, Kotlin or Java)\n```yaml\n$androidYaml```\n\n'
      '### React Native\n```yaml\n$reactNativeYaml```\n\n'
      '### Capacitor / Ionic\n```yaml\n$capacitorYaml```\n\n'
      '### Signing with the user\'s own key (optional; insert where "SIGN" is)\n'
      'Default is the debug key: fine to install and share, not for Google Play. With a key, the user adds four repo secrets '
      '(Settings > Secrets and variables > Actions): ANDROID_KEYSTORE_BASE64 (the .jks file as base64: "base64 -w0 upload.jks"), '
      'ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD. Never put a keystore or password in the repo or the chat.\n'
      '```yaml\n$signYaml```\n'
      'Keep the same key for every update: a new key means phones refuse to update the app.\n\n'
      '### Download link as a GitHub Release (optional; insert where "RELEASE" is)\n```yaml\n$releaseYaml```\n'
      'The run page always has the artifact (app-apk, a zip with the APK; signed-in GitHub users only, kept 90 days). A Release gives a '
      'plain download link (public on a public repo).\n\n'
      '### Play Store bundle\nFlutter: "flutter build appbundle --release" (build/app/outputs/bundle/release/app-release.aab); Gradle: '
      '"./gradlew bundleRelease". Play needs the upload key: sign the .aab with jarsigner (apksigner is for APKs).\n';

  static const _loop = '## The build loop\n'
      '1. Make sure the code is on the user\'s GitHub (code_git clone or publish; GitHub must be connected).\n'
      '2. If code_build apk fits the project (Flutter, native Android, React Native, Capacitor) use it: code_build start target apk, '
      'then code_build wait until it finishes. Otherwise write the template above to .github/workflows/android-apk.yml, push it '
      '(code_git push), and start it (it has workflow_dispatch; pushing to main also starts the Flutter and native ones).\n'
      '3. Poll until the run completes (code_build wait, or the run page). A first build takes about 5-10 minutes.\n'
      '4. Failure: read the job log (code_build returns the failed step, the first error and a "Likely cause"). Usual causes: no '
      'android/ folder or Gradle wrapper, gradlew not executable (chmod +x), wrong Java (17; 21 for Capacitor 7+), compileSdk too '
      'old or SDK licence, a committed local.properties, a missing Flutter or Node step, signing secrets. Fix the real cause, push, '
      'build again.\n'
      '5. At most 3 tries on failures. Then stop and tell the user the exact error line from the log and what it needs from them.\n'
      '6. Success: give the APK (code_build downloads it to builds/<repo>/: show it with a ```file card), the run link, and the '
      'Release link when you made one. Say once how to install: open it and allow "install unknown apps" for Telesia.\n'
      'Private repos use the free 2,000 Actions minutes a month; public repos are free without a limit.\n';

  static const _facts = '## Facts (never get these wrong)\n'
      '- GitHub\'s ubuntu-latest runners already have the Android SDK (ANDROID_HOME and ANDROID_SDK_ROOT set), build-tools, '
      'platform-tools, cmdline-tools and several Java versions. Nothing has to be installed by hand.\n'
      '- Android Studio is only an editor: it is never needed to build an APK. No computer is needed either; Telesia itself is built '
      'this way.\n'
      '- Never tell the user a remote APK build is impossible. If something blocks it (GitHub not connected, the token lacks the '
      '"workflow" permission, the code has errors), say exactly that and how to clear it.\n';

  static const _bodyEn = '## When to use\nThe user wants an installable Android app file (APK), a Play Store bundle (AAB), or asks if '
      'their app can be built without Android Studio or a computer.\n\n$_facts\n$_loop\n$_templates';

  static const _bodySo = '## Goorta\nIsticmaalaha wuxuu rabaa fayl Android ah oo la rakibo (APK) ama AAB, ama wuxuu weydiinayaa in '
      'app-kiisa la dhisi karo iyada oo aan Android Studio ama kombiyuutar loo baahnayn. Ugu jawaab af Soomaali; magacyada '
      'faylasha iyo koodhka ku daa Ingiriisi.\n\n'
      '## Xaqiiqooyin\n'
      '- Mashiinnada GitHub Actions (ubuntu-latest) waxaa horey ugu jira Android SDK, build-tools, platform-tools iyo Java '
      '(ANDROID_HOME waa la dejiyay). Waxba gacanta laguma rakibo.\n'
      '- Android Studio waa tafatire kaliya: weligeed looma baahna si APK loo dhiso. Kombiyuutarna looma baahna; Telesia laftiisa '
      'sidaas ayaa loo dhisaa.\n'
      '- Weligaa ha oran "ma suurtowdo". Haddii wax xannibayaan (GitHub lama xirin, token-ku ma laha ogolaanshaha "workflow", '
      'koodhka khalad ayaa ku jira), sheeg kaas iyo sida loo xalliyo.\n\n'
      '## Tallaabooyinka\n'
      '1. Koodhku ha joogo GitHub-ka isticmaalaha (code_git clone ama publish).\n'
      '2. Flutter, Android (Gradle/Kotlin), React Native ama Capacitor: code_build start target apk, kadibna code_build wait. '
      'Haddii kale qor template-ka hoose .github/workflows/android-apk.yml, push garee, oo bilow.\n'
      '3. Sug ilaa uu dhammaado (5-10 daqiiqo markii ugu horreysay).\n'
      '4. Haddii uu fashilmo: akhri log-ga (code_build wuxuu soo celiyaa tallaabada fashilantay, khaladka koowaad iyo "Likely cause"). '
      'Sababaha caadiga ah: galka android/ ama Gradle wrapper ma jiro, gradlew ma fulin karo (chmod +x), Java khaldan (17; 21 '
      'Capacitor 7+), compileSdk duug ah ama ruqsadda SDK, local.properties la soo galiyay, tallaabada Flutter ama Node oo maqan, '
      'saxiixa (signing). Sababta dhabta ah xalli, push garee, mar kale dhis.\n'
      '5. Ugu badnaan 3 jeer. Kadib u sheeg isticmaalaha sadarka khaladka ee log-ga iyo waxa looga baahan yahay.\n'
      '6. Guul: sii APK-ga (```file card), link-ga run-ka, iyo link-ga Release haddii aad samaysay. Sida loo rakibo: fur faylka, '
      'oggolow "install unknown apps" Telesia.\n\n'
      '## Saxiixa (ikhtiyaari)\nCaadi ahaan waa furaha debug: waa la rakibi karaa lana wadaagi karaa, laakiin Google Play ma aha. '
      'Furaha isticmaalaha: afar secrets oo repo-ga ah (ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, '
      'ANDROID_KEY_PASSWORD). Weligaa keystore ama password ha gelin repo-ga ama chat-ka. Isla furaha ku hay update kasta.\n\n'
      '$_templates';
}
