// Marketing reel (owner request 2026-10-20): drives the real app on an emulator, signed in to a demo
// account, through every main screen in Ink (dark) and Paper (light), plus real chats with the cloud
// model. It prints "SHOT:<name>"; tools/reel_capture.sh takes a clean screencap on each, while
// adb screenrecord films the whole run. Never part of the normal test run.
import 'package:agent/app_state.dart';
import 'package:agent/main.dart' as app;
import 'package:agent/screens/approvals_screen.dart';
import 'package:agent/screens/bot_store_screen.dart';
import 'package:agent/screens/bots_screen.dart';
import 'package:agent/screens/connectors_screen.dart';
import 'package:agent/screens/files_screen.dart';
import 'package:agent/screens/hire_screen.dart';
import 'package:agent/screens/inbox_screen.dart';
import 'package:agent/screens/library_screen.dart';
import 'package:agent/screens/live_screen.dart';
import 'package:agent/screens/logins_screen.dart';
import 'package:agent/screens/memory_screen.dart';
import 'package:agent/screens/settings_screen.dart';
import 'package:agent/screens/skill_library_screen.dart';
import 'package:agent/screens/skills_screen.dart';
import 'package:agent/screens/system_screens.dart';
import 'package:agent/screens/today_screen.dart';
import 'package:agent/screens/whatsapp_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('DEMO_EMAIL');
const _pw = String.fromEnvironment('DEMO_PW');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reel', (tester) async {
    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> shot(String name) async {
      await wait(700);
      // ignore: avoid_print
      print('SHOT:$name');
      await wait(1600);
    }

    Future<void> safe(String what, Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        // ignore: avoid_print
        print('REEL skip $what: $e');
      }
    }

    BuildContext ctx() => app.appNavKey.currentContext!;
    AppState st() => Provider.of<AppState>(ctx(), listen: false);

    Future<void> scrollDown([double by = 700]) async {
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.dragFrom(Offset(size.width / 2, size.height * 0.72), Offset(0, -by));
      await wait(900);
    }

    Future<void> screen(String name, Widget w, {int scrolls = 1}) async {
      await safe(name, () async {
        app.appNavKey.currentState!.push(MaterialPageRoute(builder: (_) => w));
        await wait(2600);
        await shot(name);
        for (var i = 0; i < scrolls; i++) {
          await scrollDown();
          await shot('${name}_${i + 2}');
        }
        app.appNavKey.currentState!.pop();
        await wait(1200);
      });
    }

    // 1) Welcome, before sign-in.
    app.main();
    await wait(9000);
    await shot('00_welcome');
    await safe('login form', () async {
      final login = find.text('Log in');
      if (login.evaluate().isNotEmpty) {
        await tester.tap(login.first);
        await wait(1500);
        final fields = find.byType(TextField);
        if (fields.evaluate().isNotEmpty) {
          await tester.enterText(fields.first, _email);
          await wait(600);
        }
        await shot('01_login');
      }
    });
    await Supabase.instance.client.auth.signInWithPassword(email: _email, password: _pw);
    await wait(9000);
    // Close anything that opened on first start (a sheet or dialog).
    for (var i = 0; i < 2; i++) {
      await safe('close first-run', () async {
        if (app.appNavKey.currentState!.canPop()) {
          app.appNavKey.currentState!.pop();
          await wait(1000);
        }
      });
    }

    // 2) Every main screen, in Ink and Paper.
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      final t = mode == ThemeMode.dark ? 'ink' : 'paper';
      st().setThemeMode(mode);
      st().newChat();
      await wait(2500);
      await shot('10_${t}_home');
      await safe('drawer', () async {
        await tester.dragFrom(const Offset(3, 420), const Offset(320, 0));
        await wait(1600);
        await shot('11_${t}_sidebar');
        await tester.tapAt(const Offset(390, 420));
        await wait(1200);
      });
      await screen('20_${t}_apps', const ConnectorsScreen(), scrolls: 3);
      await screen('21_${t}_team', const BotsScreen());
      await screen('22_${t}_botstore', const BotStoreScreen(), scrolls: 2);
      await screen('23_${t}_hire', const HireScreen());
      await screen('24_${t}_skills', const SkillsScreen());
      await screen('25_${t}_skilllibrary', const SkillLibraryScreen(), scrolls: 2);
      await screen('26_${t}_scheduled', const ScheduledScreen(), scrolls: 0);
      await screen('27_${t}_today', const TodayScreen());
      await screen('28_${t}_settings', const SettingsScreen(), scrolls: 3);
      await screen('29_${t}_memory', const MemoryScreen(), scrolls: 0);
      await screen('30_${t}_library', const LibraryScreen(), scrolls: 0);
      await screen('31_${t}_files', const FilesScreen(), scrolls: 0);
      await screen('32_${t}_whatsapp', const WhatsAppScreen());
      await screen('34_${t}_phone', const SystemPermissionsScreen());
      await screen('36_${t}_inbox', const InboxScreen(), scrolls: 0);
      await screen('37_${t}_approvals', const ApprovalsScreen(), scrolls: 0);
      await screen('38_${t}_logins', const LoginsScreen(), scrolls: 0);
      await screen('39_${t}_privacy', const PrivacyScreen(), scrolls: 0);
      await screen('40_${t}_instructions', const CustomInstructionsScreen(), scrolls: 0);
    }

    // 3) Real chats with the cloud model: typed in the composer, then sent, then the answer as it lands.
    const prompts = [
      ['50_trip', 'Plan a relaxed 3-day trip to Zanzibar for two, day by day, with rough costs.'],
      ['51_compare', 'Compare the Pixel 9, iPhone 16 and Galaxy S25 in a table: price, camera, battery.'],
      ['52_weather', 'What is the weather in Nairobi this week, and what should I pack?'],
      ['53_email', 'Write a short, polite email to my landlord asking to fix the kitchen sink this week.'],
      ['54_coffee', 'Find 3 highly rated coffee shops in Dubai Marina with what each is known for.'],
      ['55_explain', 'Explain how solar panels work in simple words, with a short summary at the end.'],
    ];
    var i = 0;
    for (final p in prompts) {
      final t = i.isEven ? 'paper' : 'ink';
      i++;
      await safe(p[0], () async {
        st().setThemeMode(t == 'ink' ? ThemeMode.dark : ThemeMode.light);
        st().newChat();
        await wait(1800);
        final hint = find.text('Ask Telesia anything');
        if (hint.evaluate().isNotEmpty) {
          await tester.tap(hint.first);
          await wait(900);
        }
        final fields = find.byType(TextField);
        if (fields.evaluate().isNotEmpty) {
          // Type it out a few words at a time so the recording shows real typing.
          final words = p[1].split(' ');
          for (var w = 1; w <= words.length; w++) {
            await tester.enterText(fields.last, words.take(w).join(' '));
            await wait(110);
          }
          await shot('${p[0]}_${t}_typed');
          await tester.enterText(fields.last, '');
        }
        await tester.testTextInput.receiveAction(TextInputAction.done);
        FocusManager.instance.primaryFocus?.unfocus();
        final run = st().send(p[1], const []);
        await wait(5000);
        await shot('${p[0]}_${t}_working');
        final end = DateTime.now().add(const Duration(seconds: 120));
        await Future.any([run, Future<void>.delayed(const Duration(seconds: 120))]);
        while (DateTime.now().isBefore(end) && st().runs.any((r) => !r.side)) {
          await wait(500);
        }
        await wait(2500);
        await shot('${p[0]}_${t}_answer');
        // The top of the answer, then the other theme on the same chat.
        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        await tester.dragFrom(Offset(size.width / 2, size.height * 0.3), const Offset(0, 900));
        await wait(1200);
        await shot('${p[0]}_${t}_answer_top');
        st().setThemeMode(t == 'ink' ? ThemeMode.light : ThemeMode.dark);
        await wait(1500);
        await shot('${p[0]}_${t == 'ink' ? 'paper' : 'ink'}_answer_top');
      });
    }

    // 4) The sidebar full of real chats, then Live voice.
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      final t = mode == ThemeMode.dark ? 'ink' : 'paper';
      st().setThemeMode(mode);
      await safe('sidebar chats', () async {
        await wait(1200);
        await tester.dragFrom(const Offset(3, 420), const Offset(320, 0));
        await wait(1600);
        await shot('60_${t}_sidebar_chats');
        await tester.tapAt(const Offset(390, 420));
        await wait(1200);
      });
    }
    await safe('live', () async {
      st().setThemeMode(ThemeMode.dark);
      app.appNavKey.currentState!.push(liveRoute());
      await wait(9000);
      await shot('70_live');
      await wait(6000);
      await shot('71_live_2');
      app.appNavKey.currentState!.pop();
      await wait(2000);
    });
    // ignore: avoid_print
    print('REEL DONE');
  }, timeout: const Timeout(Duration(minutes: 50)));
}
