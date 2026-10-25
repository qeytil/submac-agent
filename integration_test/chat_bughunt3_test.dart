// Chat bug hunt ROUND 3 on a real emulator (2026-10-25). Investigation only, never part of the normal test run.
// Round 3 fixes: ticks the 18+/Terms gate in the UI, b3 checks the wake AFTER the alarm time, c1 waits for member
// replies (office queue + working bots), ADB:<cmd> lines let the capture script cut the network, and every QAERR fails the job.
// Runs REAL multi-step tasks through the app's own agent loop against production ai-chat v41 with a throwaway account,
// then real bot, routine and team work. Prints:
//   SHOT:<name>            screencap taken by tools/chatbug2_capture.sh
//   T:<task>|<json>        one line per task: seconds, steps, tool calls, errors, cards, reply length, tokens
//   MSGS:<task>|<dump>     the chat as the app holds it
//   CB:<id>|<finding>      a finding line
//   QA:/QAERR:             progress and failures of the harness itself
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent/app_state.dart';
import 'package:agent/main.dart' as app;
import 'package:agent/models.dart';
import 'package:agent/screens/auth_screen.dart';
import 'package:agent/services/context_window.dart';
import 'package:agent/services/telegram_bridge.dart';
import 'package:agent/services/bot_powers.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('QA_EMAIL');
const _pw = String.fromEnvironment('QA_PW');
// Second throwaway account for part 2 (one free day's allowance ran out in run 40182704967 after ~80 agent calls).
const _email2 = String.fromEnvironment('QA_EMAIL2');
// Tasks that already ran end to end in run 40182704967 (results kept in the report).
const _skip = {'t3_code', 't3_fix', 't7_multitool', 't8_steer', 't8_check'};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat bughunt 3: real tasks + bots', (tester) async {
    void log(String s) => print(s);
    var exceptions = 0;

    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 50));
        final e = tester.takeException();
        if (e != null) {
          exceptions++;
          log('QAERR: exception: ${e.toString().split('\n').first}');
        }
      }
    }

    String visible() {
      final out = <String>[];
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText().trim();
        if (s.isNotEmpty && !out.contains(s)) out.add(s);
      }
      return out.join(' ¦ ').replaceAll('\n', ' ');
    }

    Future<void> shot(String name) async {
      await wait(700);
      log('SHOT:$name');
      final v = visible();
      log('SEE:$name|${v.length > 1800 ? v.substring(0, 1800) : v}');
      await wait(1500);
    }

    BuildContext ctx() => app.appNavKey.currentContext!;
    AppState st() => Provider.of<AppState>(ctx(), listen: false);

    Future<void> step(String what, Future<void> Function() f) async {
      if (_skip.contains(what)) {
        log('QA: skip $what (done in run 40182704967)');
        return;
      }
      final t0 = DateTime.now();
      try {
        await f();
        log('QA: ok $what (${DateTime.now().difference(t0).inSeconds}s)');
      } catch (e, s) {
        log('QAERR: $what: ${e.toString().split('\n').take(2).join(' ')} ${s.toString().split('\n').take(2).join(' ')}');
        await shot('err_${what.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}');
      }
    }

    Future<void> backHome() async {
      for (var i = 0; i < 6 && app.appNavKey.currentState!.canPop(); i++) {
        app.appNavKey.currentState!.pop();
        await wait(700);
      }
    }

    Future<Finder> box() async {
      if (find.byType(TextField).evaluate().isEmpty && find.text('Ask SubMac anything').evaluate().isNotEmpty) {
        await tester.tap(find.text('Ask SubMac anything').first, warnIfMissed: false);
        await wait(1200);
      }
      final f = find.byType(TextField);
      if (f.evaluate().isEmpty) throw 'no chat box';
      return f.last;
    }

    Future<void> type(String text) async {
      final b = await box();
      await tester.tap(b, warnIfMissed: false);
      await wait(400);
      await tester.enterText(b, text);
      await wait(600);
      final send = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SendButton');
      if (send.evaluate().isEmpty) throw 'no send button';
      await tester.tap(send.first, warnIfMissed: false);
      await wait(800);
    }

    bool running([String? conv]) => st().runs.any((r) => !r.side && (conv == null || r.convId == conv));
    AgentRun? task() => st().runs.where((r) => !r.side && r.convId == st().currentId).firstOrNull;

    final peak = <String, int>{};
    Future<void> settle(int s, {String key = ''}) async {
      final t0 = DateTime.now();
      await wait(1500);
      bool here() => st().runs.any((r) => r.convId == st().currentId);
      while (DateTime.now().difference(t0).inSeconds < s && here()) {
        final r = task();
        if (r != null && key.isNotEmpty) {
          peak['$key.steps'] = math.max(r.step, peak['$key.steps'] ?? 0);
          peak['$key.tokens'] = math.max(r.tokens, peak['$key.tokens'] ?? 0);
        }
        await wait(1000);
      }
      if (here()) log('QAERR: still running after ${s}s: ${st().runs.map((r) => '${r.title}/${r.status}/step${r.step}').toList()}');
      await wait(2500);
    }

    String dumpList(List<ChatMessage> list) {
      final parts = <String>[];
      for (final m in list) {
        final c = m.content.replaceAll('\n', '⏎');
        parts.add('${m.role}${m.name == null ? '' : '(${m.name})'}${m.toolCalls?.isNotEmpty == true ? '[${m.toolCalls!.map((c) => '${c.name}${c.arguments.length > 80 ? '' : ' ${c.arguments}'}').join(',')}]' : ''}'
            '${m.error != null ? '{ERR:${m.error}}' : ''}:${c.length > 400 ? '${c.substring(0, 400)}…(${c.length})' : c}');
      }
      return parts.join(' ¦ ');
    }

    void dump(String name) => log('MSGS:$name|${dumpList(st().messages)}');

    void record(String name, DateTime t0) {
      final msgs = st().messages;
      final calls = [for (final m in msgs) ...?m.toolCalls?.map((c) => c.name)];
      final errs = [for (final m in msgs) if (m.error != null) m.error!.split('\n').first];
      final last = msgs.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      final j = {
        't0': t0.toUtc().toIso8601String(),
        't1': DateTime.now().toUtc().toIso8601String(),
        'window': ContextWindow.tokens,
        'secs': DateTime.now().difference(t0).inSeconds,
        'steps': peak['$name.steps'] ?? 0,
        'runTokens': peak['$name.tokens'] ?? 0,
        'tools': calls,
        'errors': errs,
        'assistantMsgs': msgs.where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).length,
        'replyChars': last.content.length,
        'tables': find.byType(TableCard).evaluate().length,
        'choices': find.byType(ChoicesCard).evaluate().length,
        'banner': st().banner,
      };
      log('T:$name|${jsonEncode(j)}');
    }

    Future<void> fresh() async {
      await backHome();
      // Each task on its own: a run left over from the previous task is stopped (and logged), so it cannot hold
      // the next task's waits or spend its allowance.
      final left = st().runs.where((r) => !r.side).toList();
      if (left.isNotEmpty) {
        log('QA: stopping leftover runs: ${left.map((r) => '${r.title}/${r.status}').toList()}');
        for (final r in left) {
          r.stop();
        }
        await wait(3000);
      }
      st().newChat();
      await wait(1500);
    }

    Future<void> scrollTop() async {
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.dragFrom(Offset(size.width / 2, size.height * 0.3), const Offset(0, 1600));
      await wait(1200);
    }

    Future<void> real(String name, String prompt, {int secs = 200, Future<void> Function()? during}) async {
      await step(name, () async {
        await fresh();
        final t0 = DateTime.now();
        await type(prompt);
        if (during != null) await during();
        await settle(secs, key: name);
        record(name, t0);
        dump(name);
        await shot('${name}_end');
        await scrollTop();
        await shot('${name}_top');
      });
    }

    Future<void> follow(String name, String prompt, {int secs = 200}) async {
      await step(name, () async {
        final t0 = DateTime.now();
        await type(prompt);
        await settle(secs, key: name);
        record(name, t0);
        dump(name);
        await shot('${name}_end');
      });
    }

    // The capture script runs `adb shell` for these (network on/off) and the harness waits for it to land.
    Future<void> adb(String cmd) async {
      log('ADB:$cmd');
      await wait(9000);
    }

    String boxText() {
      final f = find.byType(TextField);
      if (f.evaluate().isEmpty) return '<no box>';
      return tester.widget<TextField>(f.last).controller?.text ?? '<no controller>';
    }

    Future<List<int>> png() async {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, 256, 256), Paint()..color = const Color(0xFFFFFFFF));
      c.drawCircle(const Offset(128, 128), 90, Paint()..color = const Color(0xFFD32F2F));
      final img = await rec.endRecording().toImage(256, 256);
      final b = await img.toByteData(format: ui.ImageByteFormat.png);
      return b!.buffer.asUint8List();
    }

    // ------------------------------------------------------------ start and sign in
    app.main();
    for (var i = 0; i < 120 && find.text('Create account').evaluate().isEmpty && find.byType(TextField).evaluate().isEmpty; i++) {
      await wait(1000);
    }
    await wait(2000);
    if (Supabase.instance.client.auth.currentSession == null) {
      try {
        await Supabase.instance.client.auth.signInWithPassword(email: _email, password: _pw);
      } catch (e) {
        log('QAERR: sign-in: $e');
        try {
          await Supabase.instance.client.auth.signUp(email: _email, password: _pw);
        } catch (e2) {
          log('QAERR: sign-up: $e2');
        }
      }
      await wait(9000);
    }
    log('QA: signed in = ${Supabase.instance.client.auth.currentSession != null} uid=${Supabase.instance.client.auth.currentUser?.id}');
    // The 18+ / Terms gate: tick it in the UI like a person, then "Agree and continue".
    for (var i = 0; i < 20 && find.text('Agree and continue').evaluate().isEmpty && find.byType(TextField).evaluate().isEmpty; i++) {
      await wait(1000);
    }
    if (find.text('Agree and continue').evaluate().isNotEmpty) {
      await shot('00_consent_gate');
      final tick = find.byType(Checkbox);
      if (tick.evaluate().isNotEmpty) {
        await tester.tap(tick.first, warnIfMissed: false);
      } else {
        await tester.tap(find.textContaining('I am 18 or older').first, warnIfMissed: false);
      }
      await wait(800);
      await tester.tap(find.text('Agree and continue'), warnIfMissed: false);
      for (var i = 0; i < 40 && find.text('Agree and continue').evaluate().isNotEmpty; i++) {
        await wait(1000);
      }
      if (find.text('Agree and continue').evaluate().isNotEmpty) {
        log('QAERR: consent gate still up after the UI tick; saving consent directly');
        try {
          await Supabase.instance.client.auth.updateUser(UserAttributes(data: AuthRules.consentData()));
        } catch (e) {
          log('QAERR: consent save: $e');
        }
        await wait(8000);
      }
    }
    for (var i = 0; i < 30 && find.byType(TextField).evaluate().isEmpty && find.text('Ask SubMac anything').evaluate().isEmpty; i++) {
      await wait(1000);
    }
    log('QA: consent gate gone = ${find.text('Agree and continue').evaluate().isEmpty} chat box = ${find.byType(TextField).evaluate().isNotEmpty}');
    if (find.text('Agree and continue').evaluate().isNotEmpty) {
      log('QAERR: FATAL consent gate blocks the app; stopping');
      return;
    }
    await backHome();
    await shot('00_home');

    // ============================================================ PART 1: real tasks in the main chat
    await real('t1_trip',
        'Plan a 3-day trip to Nairobi for 2 people with a total budget of \$800. Give a day-by-day table (day, morning, afternoon, '
        'evening, cost) and then ask me with choices whether we prefer a hotel or an Airbnb.',
        secs: 240);
    // Answer the choice card by tapping it, like a person does.
    await step('t1_choice_tap', () async {
      final c = find.byType(ChoicesCard);
      log('CB:t1|choice cards on screen=${c.evaluate().length}');
      if (c.evaluate().isEmpty) return;
      final opt = find.descendant(of: c.last, matching: find.textContaining(RegExp('Airbnb|Hotel', caseSensitive: false)));
      if (opt.evaluate().isEmpty) return;
      await tester.tap(opt.first, warnIfMissed: false);
      final t0 = DateTime.now();
      await settle(180, key: 't1_choice_tap');
      record('t1_choice_tap', t0);
      dump('t1_choice_tap');
      await shot('t1_after_choice');
    });

    await real('t2_phones',
        'Research and compare the iPhone 16, Samsung Galaxy S25 and Google Pixel 9: current US price, screen, battery, camera. '
        'Put them in a table and give me links to your sources.',
        secs: 300);

    await real('t3_code',
        'Write a Python function parse_date(s) that turns "DD/MM/YYYY" into "YYYY-MM-DD" and raises ValueError on bad input. '
        'Save it to a file, write 4 tests, run them, and fix anything that fails. Show me the final code.',
        secs: 300);
    await follow('t3_fix',
        'The tests miss two cases: parse_date must also accept "DD-MM-YYYY" and "DD.MM.YYYY", and must reject 31/02/2024. '
        'Fix the function, add tests for these, run all tests again, and show me the final code and the test output.',
        secs: 300);

    await step('t4_email_approval', () async {
      await fresh();
      final t0 = DateTime.now();
      await type('Draft an email to ahmed.test@example.com telling him the meeting moved to Thursday 3 pm, and send it.');
      final until = DateTime.now().add(const Duration(seconds: 150));
      var sawAsk = false;
      while (DateTime.now().isBefore(until) && running()) {
        if (find.text('Allow').evaluate().isNotEmpty || find.text('Not now').evaluate().isNotEmpty || find.text('Send').evaluate().length > 1 ||
            st().asks.isNotEmpty) {
          sawAsk = true;
          break;
        }
        await wait(500);
      }
      await wait(1500);
      log('CB:t4|approval or ask shown=$sawAsk asks=${st().asks.map((a) => '${a.kind}:${a.title}').toList()}');
      await shot('t4_approval');
      for (final t in ['Not now', 'Don\'t send', 'Deny', 'Cancel', 'No']) {
        if (find.text(t).evaluate().isNotEmpty) {
          await tester.tap(find.text(t).last, warnIfMissed: false);
          log('CB:t4|tapped $t');
          break;
        }
      }
      if (running()) {
        await type("No, don't send it. Just show me the final draft here.");
        log('CB:t4|answered the ask in the chat');
      }
      await settle(150, key: 't4_email_approval');
      record('t4_email_approval', t0);
      dump('t4_email_approval');
      await shot('t4_after');
    });

    await real('t5_somali',
        'Igu qor maqaal dheer (ugu yaraan 500 eray) oo Af-Soomaali ah oo ku saabsan taariikhda magaalada Muqdisho. '
        'Isticmaal cinwaanno, liis, iyo shax (table) muujinaysa xilliyada muhiimka ah. Halkan sheekada ku qor, ha samayn fayl.',
        secs: 240);
    await step('t5_check', () async {
      final last = st().messages.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      final words = last.content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      log('CB:t5|replyWords=$words hasTable=${last.content.contains('|---') || last.content.contains('```table')} somali=${RegExp(r'\b(waa|iyo|magaalada)\b').hasMatch(last.content)}');
    });

    await real('t6_arabic',
        'اكتب لي مقالاً طويلاً (حوالي 400 كلمة) عن تاريخ مدينة بربرة مع عناوين وقائمة وجدول للأحداث المهمة. اكتبه هنا في المحادثة، وليس في ملف.',
        secs: 240);

    await step('t6_rtl_check', () async {
      final arabic = RegExp(r'[\u0600-\u06FF]');
      var rtl = 0, ltr = 0, startAligned = 0, total = 0;
      final samples = <String>[];
      for (final e in find.byType(RichText).evaluate()) {
        final w = e.widget as RichText;
        final t = w.text.toPlainText();
        if (!arabic.hasMatch(t) || t.trim().length < 6) continue;
        total++;
        final dir = w.textDirection;
        if (dir == TextDirection.rtl) {
          rtl++;
        } else {
          ltr++;
        }
        if (w.textAlign == TextAlign.start || w.textAlign == TextAlign.right) startAligned++;
        if (dir != TextDirection.rtl && samples.length < 4) samples.add('${t.length > 50 ? t.substring(0, 50) : t}/${w.textAlign}');
      }
      final last = st().messages.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      final words = last.content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      log('CB:t6|arabic text runs=$total rtl=$rtl ltr=$ltr startOrRightAligned=$startAligned replyWords=$words ltrSamples=$samples');
      await shot('t6_rtl');
    });

    await real('t7_multitool',
        'Search the web for: today\'s USD to KES rate, today\'s USD to ETB rate, and the weather today in Mogadishu and Hargeisa. '
        'Then summarise everything in one table with the source for each row.',
        secs: 300);

    // Steer mid-task: a second instruction while tools run.
    await real('t8_steer',
        'Find three good coffee shops in Nairobi with their opening hours and rating, using web search.',
        secs: 300, during: () async {
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 90) {
        final r = task();
        if (r != null && r.step > 0 && !r.inModel) break;
        await wait(300);
      }
      await type('Change of plan: make it Kigali instead of Nairobi.');
      log('CB:t8|steer sent after ${DateTime.now().difference(t0).inSeconds}s step=${task()?.step}');
    });
    await step('t8_check', () async {
      final text = st().messages.where((m) => m.role == 'assistant').map((m) => m.content).join(' ');
      log('CB:t8|final mentions Kigali=${text.contains('Kigali')} mentions Nairobi=${text.contains('Nairobi')}');
    });

    // Stop, then resume with "continue".
    await step('t9_stop_resume', () async {
      await fresh();
      final t0 = DateTime.now();
      await type('Research the 5 biggest companies in Somalia: for each give the sector, founding year, CEO and a source link.');
      final until = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(until)) {
        final r = task();
        if (r != null && r.step >= 2) break;
        await wait(400);
      }
      log('CB:t9|stopping at step=${task()?.step} status=${task()?.status}');
      final stop = find.bySemanticsLabel('Stop');
      if (stop.evaluate().isNotEmpty) {
        await tester.tap(stop.first, warnIfMissed: false);
      } else {
        st().stop();
      }
      await wait(5000);
      dump('t9_after_stop');
      await shot('t9_after_stop');
      await type('continue');
      await settle(300, key: 't9_stop_resume');
      record('t9_stop_resume', t0);
      dump('t9_stop_resume');
      await shot('t9_after_continue');
    });

    // A photo (the vision route), then a follow-up about it without the photo.
    await step('t10_photo', () async {
      await fresh();
      final t0 = DateTime.now();
      final bytes = await png();
      await st().send('What colour is the shape in this picture, and what shape is it? One short sentence.',
          [Attachment(name: 'shape.png', mime: 'image/png', bytes: Uint8List.fromList(bytes))]);
      await settle(120, key: 't10_photo');
      dump('t10_photo');
      await type('Describe the background colour of that same picture in one word.');
      await settle(120, key: 't10_photo2');
      record('t10_photo', t0);
      dump('t10_photo_followup');
      final last = st().messages.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      log('CB:t10|followup says white=${last.content.toLowerCase().contains('white')} cantSee=${RegExp("can't see|cannot see|can not see|unable to see|don't have", caseSensitive: false).hasMatch(last.content)} window=${ContextWindow.tokens} reply=${last.content.length > 160 ? last.content.substring(0, 160) : last.content}');
      await shot('t10_photo');
    });

    // A huge paste (too long for one request).
    await step('t11_too_long', () async {
      await fresh();
      final t0 = DateTime.now();
      final para = 'Mogadishu port records show many ships arriving with goods from Dubai, Mombasa and Mumbai every week. ';
      final huge = 'Summarise this text in 3 bullets:\n${List.filled(5200, para).join()}';
      log('CB:t11|paste chars=${huge.length}');
      await st().send(huge, const []);
      await settle(150, key: 't11_too_long');
      record('t11_too_long', t0);
      final last = st().messages.lastWhere((m) => m.role == 'assistant', orElse: () => ChatMessage(id: '', role: 'assistant'));
      log('CB:t11|last assistant error=${last.error} content=${last.content.length > 200 ? last.content.substring(0, 200) : last.content} banner=${st().banner}');
      await shot('t11_too_long');
    });

    // Try again after a real failure (network cut by adb), then a double tap on Try again (CB-22).
    await step('t12_try_again', () async {
      await fresh();
      final t0 = DateTime.now();
      await adb('net_off');
      await type('What is the capital of Kenya? Answer in one word.');
      final until = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(until) && !st().messages.any((m) => m.error != null)) {
        await wait(1000);
      }
      final errs = st().messages.where((m) => m.error != null).map((m) => m.error!.split('\n').first).toList();
      log('CB:t12|offline: error cards=$errs banner=${st().banner} tryAgainButtons=${find.text('Try again').evaluate().length} secs=${DateTime.now().difference(t0).inSeconds}');
      await shot('t12_offline_error');
      await adb('net_on');
      await wait(12000);
      final users0 = st().messages.where((m) => m.role == 'user').length;
      var maxRuns = 0;
      final btn = find.text('Try again');
      if (btn.evaluate().isNotEmpty) {
        await tester.tap(btn.last, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 120));
        if (btn.evaluate().isNotEmpty) await tester.tap(btn.last, warnIfMissed: false);
        log('CB:t12|tapped Try again twice (button)');
      } else {
        unawaited(st().regenerate());
        unawaited(st().regenerate());
        log('CB:t12|no Try again button: called regenerate() twice');
      }
      final t1 = DateTime.now();
      while (DateTime.now().difference(t1).inSeconds < 120) {
        final n = st().runs.where((r) => !r.side && r.convId == st().currentId).length;
        if (n > maxRuns) maxRuns = n;
        if (DateTime.now().difference(t1).inSeconds > 8 && st().runs.isEmpty) break;
        await wait(250);
      }
      await wait(4000);
      final replies = st().messages.where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).toList();
      log('CB:t12|after double Try again: maxConcurrentRuns=$maxRuns users $users0->${st().messages.where((m) => m.role == 'user').length} '
          'assistantReplies=${replies.length} nairobi=${replies.where((m) => m.content.contains('Nairobi')).length}');
      record('t12_try_again', t0);
      dump('t12_try_again');
      await shot('t12_after_retry');
    });

    // ------------------------------------------------------------ second throwaway account (fresh daily allowance)
    await step('switch_account', () async {
      if (_email2.isEmpty) throw 'no QA_EMAIL2';
      await fresh();
      await Supabase.instance.client.auth.signOut();
      await wait(6000);
      try {
        await Supabase.instance.client.auth.signUp(email: _email2, password: _pw, data: AuthRules.consentData());
      } catch (e) {
        log('QA: sign-up 2: $e');
      }
      if (Supabase.instance.client.auth.currentSession == null) {
        await Supabase.instance.client.auth.signInWithPassword(email: _email2, password: _pw);
      }
      for (var i = 0; i < 40 && find.byType(TextField).evaluate().isEmpty && find.text('Ask SubMac anything').evaluate().isEmpty; i++) {
        if (find.text('Agree and continue').evaluate().isNotEmpty) {
          final tick = find.byType(Checkbox);
          if (tick.evaluate().isNotEmpty) await tester.tap(tick.first, warnIfMissed: false);
          await wait(600);
          await tester.tap(find.text('Agree and continue'), warnIfMissed: false);
        }
        await wait(1000);
      }
      await wait(4000);
      log('QA: account 2 = ${Supabase.instance.client.auth.currentUser?.email} uid=${Supabase.instance.client.auth.currentUser?.id} box=${find.byType(TextField).evaluate().isNotEmpty}');
      await shot('switch_account');
    });

    // A long chat that forces compaction (history over 14k tokens), then recall of an early fact.
    await step('t13_compaction', () async {
      await fresh();
      final t0 = DateTime.now();
      const words = ['amber', 'basalt', 'cobalt', 'dahlia', 'ember'];
      for (var i = 0; i < 5; i++) {
        final filler = List.filled(170, 'Section ${i + 1} covers stock counts, supplier notes and delivery dates for the Hamarweyne shop. ').join();
        await st().send('Part ${i + 1} of my notes. The code word for part ${i + 1} is ${words[i]}. Reply only "Noted ${i + 1}".\n$filler', const []);
        await settle(150, key: 't13_compaction');
        await wait(4000);
      }
      await wait(25000); // the background compaction runs 2 s after a reply
      final marks = st().messages.where((m) => m.role == 'system' && (m.name ?? '').startsWith('compact:')).toList();
      log('CB:t13|messages=${st().messages.length} compactMarks=${marks.length} summaryChars=${marks.isEmpty ? 0 : marks.last.content.length} '
          'summaryHasAmber=${marks.isNotEmpty && marks.last.content.contains('amber')} window=${ContextWindow.tokens}');
      await type('What was the code word for part 1? One word.');
      await settle(150, key: 't13_recall');
      final last = st().messages.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      log('CB:t13|recall says amber=${last.content.toLowerCase().contains('amber')} reply=${last.content.length > 120 ? last.content.substring(0, 120) : last.content}');
      record('t13_compaction', t0);
      await shot('t13_compaction');
    });

    // A very big photo (CB-26): no size limit on the phone.
    await step('t14_big_attachment', () async {
      await fresh();
      final t0 = DateTime.now();
      const side = 1800;
      final rnd = math.Random(7);
      final px = Uint8List(side * side * 4);
      for (var i = 0; i < px.length; i++) {
        px[i] = (i & 3) == 3 ? 255 : rnd.nextInt(256);
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(px, side, side, ui.PixelFormat.rgba8888, done.complete);
      final img = await done.future;
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      final bytes = bd!.buffer.asUint8List();
      log('CB:t14|photo bytes=${bytes.length}');
      await st().send('What do you see in this picture? One sentence.', [Attachment(name: 'noise.png', mime: 'image/png', bytes: bytes)]);
      await settle(180, key: 't14_big_attachment');
      final last = st().messages.lastWhere((m) => m.role == 'assistant', orElse: () => ChatMessage(id: '', role: 'assistant'));
      log('CB:t14|secs=${DateTime.now().difference(t0).inSeconds} error=${last.error} reply=${last.content.length > 160 ? last.content.substring(0, 160) : last.content} banner=${st().banner}');
      record('t14_big_attachment', t0);
      await shot('t14_big_attachment');
    });

    // Drafts between main chats (CB-29).
    await step('t15_drafts_main', () async {
      await backHome();
      final convs = st().conversations.where((c) => Bots.I.byConv(c.id) == null).take(2).toList();
      if (convs.length < 2) throw 'need 2 chats, have ${convs.length}';
      await st().openConversation(convs[0].id);
      await wait(2500);
      final b = await box();
      await tester.enterText(b, 'DRAFT-A-only-for-chat-one');
      await wait(800);
      await st().openConversation(convs[1].id);
      await wait(2500);
      final inB = boxText();
      await shot('t15_draft_in_other_chat');
      await st().openConversation(convs[0].id);
      await wait(2500);
      final backInA = boxText();
      log('CB:t15|main chats: box in chat B="$inB" leak=${inB.contains('DRAFT-A')} back in A="$backInA"');
      await tester.enterText(await box(), '');
      await wait(500);
    });

    // Telegram with a fake token (CB-25): the only part testable without a real bot.
    await step('t16_telegram_fake', () async {
      final r = await TelegramBridge.I.connect('123456789:AAFakeTokenForChatBugHunt3xxxxxxxxxxx');
      log('CB:t16|connect(fake token) -> $r on=${TelegramBridge.I.on} status=${TelegramBridge.I.status}');
    });

    // ============================================================ PART 2: bots
    Bot? ledger;
    await step('b1_create_bot', () async {
      await backHome();
      final t0 = DateTime.now();
      ledger = await st().hireForJob({
        'name': 'Ledger',
        'role': 'Bookkeeper',
        'mission': 'Keeps the owner\'s small-shop books tidy.',
        'instructions': 'Always answer in exactly three bullet points. Never use tables.',
      });
      final err = await st().hireBot(ledger!);
      log('CB:b1|bot=${ledger!.id} conv=${ledger!.convId} hireErr=$err current=${st().currentId}');
      await wait(2000);
      await st().send('What should every invoice I send to customers contain?', const []);
      await settle(180, key: 'b1_create_bot');
      record('b1_create_bot', t0);
      dump('b1_create_bot');
      final last = st().messages.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      final bullets = RegExp(r'^\s*([-*•]|\d+\.)\s', multiLine: true).allMatches(last.content).length;
      log('CB:b1|instruction "exactly three bullets": bullets=$bullets tablesInReply=${last.content.contains('|---') || last.content.contains('```table')}');
      await shot('b1_bot_chat');
    });

    await step('b2_edit_bot', () async {
      final b = ledger;
      if (b == null) throw 'no bot';
      final t0 = DateTime.now();
      b.instructions = 'Always answer in Somali, in one short paragraph. No bullet points.';
      await Bots.I.save();
      await st().send('What should a receipt contain?', const []);
      await settle(180, key: 'b2_edit_bot');
      record('b2_edit_bot', t0);
      dump('b2_edit_bot');
      final last = st().messages.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      final bullets = RegExp(r'^\s*([-*•]|\d+\.)\s', multiLine: true).allMatches(last.content).length;
      log('CB:b2|after edit: bullets=$bullets startsSomali=${RegExp(r'\b(waa|iyo|ka|ku|oo)\b').hasMatch(last.content)} text=${last.content.length > 160 ? last.content.substring(0, 160) : last.content}');
      await shot('b2_after_edit');
    });

    // A real routine through the real Android alarm, 2 minutes from now.
    await step('b3_routine_alarm', () async {
      final b = ledger;
      if (b == null) throw 'no bot';
      final at = DateTime.now().add(const Duration(minutes: 2));
      final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
      b.routines.add(BotRoutine(id: 'rq', time: hm, days: 'daily', kind: 'message', instruction: 'Send me one practical bookkeeping tip.'));
      await Bots.I.save();
      await Bots.I.arm(b);
      final before = (st().messagesOf(b.convId)).length;
      final j0 = b.journal.length;
      final traces0 = BotTraces.I.of(b.id).length;
      final due = DateTime(at.year, at.month, at.day, at.hour, at.minute);
      log('CB:b3|routine armed for $hm (now ${DateTime.now().toIso8601String().substring(11, 19)}) next=${b.routines.last.next(DateTime.now())}');
      await backHome();
      st().newChat();
      final until = DateTime.now().add(const Duration(minutes: 6));
      var fired = false;
      while (DateTime.now().isBefore(until)) {
        // Round 2 counted the hire's own lastWake as "fired". Only a wake at or after the alarm minute counts.
        if (b.lastWake != null && !b.lastWake!.isBefore(due.subtract(const Duration(seconds: 5)))) fired = true;
        if (fired && !running(b.convId)) break;
        await wait(2000);
      }
      await wait(5000);
      final list = st().messagesOf(b.convId);
      log('CB:b3|fired=$fired due=$due traces+=${BotTraces.I.of(b.id).length - traces0} lastWake=${b.lastWake} msgs before=$before after=${list.length} journal+=${b.journal.length - j0} '
          'journal=${b.journal.skip(j0).map((e) => '${e.kind}:${e.text}').toList()} next=${Bots.I.nextWork(b)}');
      log('MSGS:b3_bot|${dumpList(list.length > 8 ? list.sublist(list.length - 8) : list)}');
      await shot('b3_after_routine');
    });

    // The same alarm delivered twice (Android can redeliver after a process restart): how many wakes?
    await step('b4_double_fire', () async {
      final b = ledger;
      if (b == null) throw 'no bot';
      final traces0 = BotTraces.I.of(b.id).length;
      final j0 = b.journal.length;
      final f1 = Bots.I.fire(Bots.alarmId(b, 'rq'));
      final f2 = Bots.I.fire(Bots.alarmId(b, 'rq'));
      final r = await Future.wait([f1, f2]);
      final until = DateTime.now().add(const Duration(minutes: 4));
      await wait(3000);
      while (DateTime.now().isBefore(until) && running(b.convId)) {
        await wait(2000);
      }
      await wait(4000);
      log('CB:b4|fire results=$r traces+=${BotTraces.I.of(b.id).length - traces0} followups=${b.followups.map((f) => '${f.at.toIso8601String().substring(11, 16)} ${f.instruction}').toList()} '
          'journal=${b.journal.skip(j0).map((e) => '${e.kind}:${e.text}').toList()}');
    });

    // The owner writes in the bot's chat while a background routine run is working.
    await step('b5_message_during_wake', () async {
      final b = ledger;
      if (b == null) throw 'no bot';
      b.routines.add(BotRoutine(id: 'rw', time: '23:59', days: 'daily', kind: 'work',
          instruction: 'Check if anything in your memory needs a follow-up. If nothing does, reply with only [no reply].'));
      await Bots.I.save();
      await st().openBot(b);
      await wait(1500);
      unawaited(Bots.I.fire(Bots.alarmId(b, 'rw')));
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 40 && !running(b.convId)) {
        await wait(300);
      }
      log('CB:b5|wake running=${running(b.convId)} after ${DateTime.now().difference(t0).inSeconds}s');
      await type('Quick question while you work: what is 17 times 3?');
      final mine = st().messages.lastWhere((m) => m.role == 'user', orElse: () => ChatMessage(id: '', role: 'user'));
      log('CB:b5|my message id=${mine.id} text=${mine.content}');
      await settle(240, key: 'b5');
      await wait(5000);
      final list = st().messagesOf(b.convId);
      final kept = list.any((m) => m.id == mine.id);
      final answered = list.any((m) => m.role == 'assistant' && m.content.contains('51'));
      log('CB:b5|my message still in chat=$kept answered(51)=$answered journal=${b.journal.reversed.take(3).map((e) => '${e.kind}:${e.text}').toList()}');
      log('MSGS:b5|${dumpList(list.length > 10 ? list.sublist(list.length - 10) : list)}');
      await shot('b5_after');
      b.routines.removeWhere((r) => r.id == 'rw' || r.id == 'rq');
      await Bots.I.save();
      await Bots.I.arm(b);
    });

    // Bot daily budget: how many "tokens" one owner chat costs the bot's background budget.
    await step('b6_budget', () async {
      final b = ledger;
      if (b == null) throw 'no bot';
      log('CB:b6|bot tokensToday=${b.tokensTodayNow} (counted from owner chats + wakes, raw prompt+completion) budgetK=${b.tokenBudgetK} '
          'traces=${BotTraces.I.of(b.id).map((r) => "${r.why.length > 30 ? r.why.substring(0, 30) : r.why}=${r.tokens}").toList()}');
    });

    // ============================================================ PART 3: a team
    bool teamBusy(Office o) =>
        TeamRun.I.busy(o) || TeamRun.I.running.isNotEmpty || Offices.I.queue.any((j) => j.officeId == o.id) ||
        o.members.any((id) => Offices.I.isWorking?.call(id) ?? false);

    Bot? hodan;
    Office? team;
    await step('c1_team_job', () async {
      await backHome();
      final t0 = DateTime.now();
      final lead = await st().hireForJob({'name': 'Hodan', 'role': 'Project lead', 'mission': 'Plans and coordinates events.'});
      final nova = await st().hireForJob({'name': 'Nova', 'role': 'Researcher', 'mission': 'Finds facts, prices and venues.'});
      hodan = lead;
      await st().prepareOfficeBots([lead.id, nova.id]);
      team = await Offices.I.create(name: 'Launch team', members: [lead.id, nova.id], chiefId: lead.id);
      TeamRun.I.send(team!, 'Plan a small product launch for 30 guests in Mogadishu next month: venue ideas with prices, a budget, and a checklist.');
      await wait(2000);
      final until = DateTime.now().add(const Duration(minutes: 7));
      final n0 = team!.posts.length;
      var quiet = 0;
      var sawBusy = false;
      while (DateTime.now().isBefore(until)) {
        final b = teamBusy(team!);
        if (b) sawBusy = true;
        final memberPosted = team!.posts.skip(n0).any((p) => p.from == lead.id || p.from == nova.id || p.from == lead.name || p.from == nova.name);
        quiet = b ? 0 : quiet + 1;
        if (memberPosted && quiet >= 8) break; // members answered and nothing has run for 16 s
        if (!memberPosted && quiet >= 90) break;
        await wait(2000);
      }
      await TeamRun.I.work?.timeout(const Duration(minutes: 2), onTimeout: () {});
      log('CB:c1|teamRun.busy=${TeamRun.I.busy(team!)} sawAnyWork=$sawBusy queue=${Offices.I.queue.where((j) => j.officeId == team!.id).map((j) => '${j.kind}:${j.botId}').toList()}');
      log('CB:c1|secs=${DateTime.now().difference(t0).inSeconds} awaitingGo=${TeamRun.I.awaitingGo(team!)} posts=${team!.posts.length}');
      log('MSGS:c1_team|${team!.posts.map((p) => '${p.from}(${p.kind}): ${p.text.replaceAll('\n', '⏎').substring(0, p.text.length > 300 ? 300 : p.text.length)}${p.parts.isEmpty ? '' : ' [parts:${p.parts.length}]'}').join(' ¦ ')}');
      if (TeamRun.I.awaitingGo(team!)) {
        TeamRun.I.send(team!, 'Go');
        await TeamRun.I.work?.timeout(const Duration(minutes: 6), onTimeout: () {});
        log('MSGS:c1_team_go|${team!.posts.map((p) => '${p.from}(${p.kind}): ${p.text.replaceAll('\n', '⏎').substring(0, p.text.length > 300 ? 300 : p.text.length)}').join(' ¦ ')}');
      }
    });

    await step('c2_team_stop', () async {
      final o = team;
      if (o == null) throw 'no team';
      final n0 = o.posts.length;
      TeamRun.I.send(o, 'Research the five best suppliers of office chairs in Nairobi with prices, then compare them.');
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 60 && !(TeamRun.I.busy(o) && o.posts.length > n0 + 1)) {
        await wait(500);
      }
      await wait(6000);
      final workingAtStop = teamBusy(o);
      TeamRun.I.send(o, 'stop');
      final stopAt = o.posts.length;
      log('CB:c2|stop sent after ${DateTime.now().difference(t0).inSeconds}s teamRun.busy=${TeamRun.I.busy(o)} anyWork=$workingAtStop '
          'queue=${Offices.I.queue.where((j) => j.officeId == o.id).map((j) => '${j.kind}:${j.botId}').toList()}');
      await TeamRun.I.work?.timeout(const Duration(minutes: 3), onTimeout: () {});
      await wait(5000);
      for (var i = 0; i < 45 && teamBusy(o); i++) {
        await wait(2000);
      }
      await wait(5000);
      final after = o.posts.skip(stopAt + 1).where((p) => p.from != 'you' && p.from != 'system').toList();
      log('CB:c2|posts after stop=${after.length} ${after.map((p) => '${p.from}(${p.kind}):${p.text.length > 80 ? p.text.substring(0, 80) : p.text}').toList()} stillWorking=${teamBusy(o)}');
      log('MSGS:c2_team_stop|${o.posts.skip(n0).map((p) => '${p.from}(${p.kind}): ${p.text.replaceAll('\n', '⏎').substring(0, p.text.length > 200 ? 200 : p.text.length)}').join(' ¦ ')}');
    });

    // Two team requests back to back (CB-37): is the second one answered?
    await step('c3_two_requests', () async {
      final o = team;
      if (o == null) throw 'no team';
      for (var i = 0; i < 60 && teamBusy(o); i++) {
        await wait(2000);
      }
      final n0 = o.posts.length;
      TeamRun.I.send(o, 'Give me three name ideas for the launch event. Just the names.');
      await wait(3000);
      TeamRun.I.send(o, 'Separate question: what is 15% of 2400? Reply with the number.');
      final t0 = DateTime.now();
      var quiet = 0;
      while (DateTime.now().difference(t0).inSeconds < 300) {
        quiet = teamBusy(o) ? 0 : quiet + 1;
        if (quiet >= 10 && DateTime.now().difference(t0).inSeconds > 30) break;
        await wait(2000);
      }
      final posts = o.posts.skip(n0).toList();
      final answered360 = posts.any((p) => p.from != 'you' && p.text.contains('360'));
      log('CB:c3|posts=${posts.length} secondAnswered(360)=$answered360 '
          '${posts.map((p) => '${p.from}(${p.kind}):${p.text.replaceAll('\n', ' ').substring(0, p.text.length > 90 ? 90 : p.text.length)}').toList()}');
    });

    // Drafts in the Bots workspace (CB-29): text is per chat, are attachments too?
    await step('c4_drafts_bots', () async {
      final a = ledger, b = hodan;
      if (a == null || b == null) throw 'no bots';
      await backHome();
      await st().openBot(a);
      await wait(3000);
      await tester.enterText(await box(), 'DRAFT-LEDGER-only');
      await wait(800);
      await st().openBot(b);
      await wait(3000);
      final inB = boxText();
      await shot('c4_bot_draft');
      await st().openBot(a);
      await wait(3000);
      log('CB:c4|bots workspace: box in Hodan="$inB" leak=${inB.contains('DRAFT-LEDGER')} back in Ledger="${boxText()}"');
      await tester.enterText(await box(), '');
      await backHome();
    });

    // ============================================================ PART 4: delete all chats while a task runs (last: destructive)
    await step('d1_delete_all_running', () async {
      await fresh();
      await type('Search the web for the history of the Somali shilling and write a detailed 800-word report.');
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 60 && (task()?.step ?? 0) < 1) {
        await wait(300);
      }
      final conv = st().currentId;
      log('CB:d1|deleting all chats while running=${running()} conv=$conv');
      await st().deleteAllConversations();
      await wait(2000);
      log('CB:d1|right after delete: runs=${st().runs.map((r) => r.convId).toList()} chats=${st().conversations.length}');
      final until = DateTime.now().add(const Duration(minutes: 4));
      while (DateTime.now().isBefore(until) && running()) {
        await wait(2000);
      }
      await wait(8000);
      final idx = st().repo.store.index.values.map((m) => '${m['id']}:${m['title']}:${m['_unknown'] == true ? 'ghost' : ''}').toList();
      log('CB:d1|after the task ended: local chat index=$idx conversations=${st().conversations.map((c) => c.title).toList()}');
      await st().refreshConversations();
      await wait(3000);
      log('CB:d1|after reload: conversations=${st().conversations.map((c) => '${c.id}:${c.title}').toList()}');
    });

    log('QA: exceptions caught during the run = $exceptions');
    log('QA: done');
  }, timeout: const Timeout(Duration(minutes: 140)));
}
