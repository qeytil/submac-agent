// Chat bug hunt ROUND 4, BOTS part, on a real emulator (2026-10-25). Investigation only, never part of the normal test run.
// Built on the round-3 harness (consent tick, fixed settle(), per-chat run tracking). New in round 4:
//  * no main-chat tasks; bots get the 'phone', 'apps' and 'browser' powers switched off so no task opens another app (CB-42);
//  * a watchdog inside wait(): answers approval sheets ("Not now"), cancels user asks after 25 s, and asks the capture
//    script to bring SubMac back to the front (ADB:front) when it is not resumed;
//  * every step has a hard timeout (step(..., limit:)) so nothing can hang the job;
//  * a cold-start "phase 2/3" (marker file) for the force-stop (CB-21) and process-kill retests: the capture script
//    force-stops / kills the app and relaunches it, and this file's main() then only starts the app and logs P2:/P3: lines.
// Prints: SHOT:<name>, T:<task>|<json>, MSGS:<task>|<dump>, CB:<id>|<finding>, QA:/QAERR:, ADB:<cmd>, PHASE2_DUE:<epoch s>.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent/app_state.dart';
import 'package:agent/main.dart' as app;
import 'package:agent/models.dart';
import 'package:agent/screens/auth_screen.dart';
import 'package:agent/screens/bot_activity_screen.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:agent/services/bot_powers.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/telegram_bridge.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('QA_EMAIL');
const _pw = String.fromEnvironment('QA_PW');
const _marker = '/data/user/0/com.submac.agent/files/cb4_phase.txt';

String _hm(DateTime at) => '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

/// A cold start after the capture script force-stopped (p2) or killed (p3) the app: start the app the normal way and
/// log what the bots do. No test framework: this is how the real app starts from the launcher or from an alarm.
Future<void> _coldStart(String phase, List<String> m) async {
  final botId = m.length > 1 ? m[1] : '';
  final due = m.length > 2 ? DateTime.tryParse(m[2]) : null;
  print('$phase: cold start at ${DateTime.now().toIso8601String()} bot=$botId due=$due');
  app.main();
  var n = 0;
  var armed = false;
  Timer.periodic(const Duration(seconds: 15), (t) async {
    n++;
    final b = Bots.I.byId(botId);
    if (b == null) {
      print('$phase: t=${n * 15}s bot not loaded yet (bots=${Bots.I.bots.length})');
    } else {
      print('$phase: t=${n * 15}s lastWake=${b.lastWake} journal=${b.journal.reversed.take(4).map((e) => '${e.at.toIso8601String().substring(11, 19)} ${e.kind}:${e.text.length > 60 ? e.text.substring(0, 60) : e.text}').toList()} '
          'traces=${BotTraces.I.of(b.id).length} routines=${b.routines.map((r) => '${r.id}@${r.time} next=${r.next(DateTime.now())}').toList()} '
          'followups=${b.followups.map((f) => f.at.toIso8601String().substring(11, 16)).toList()} nextWork=${Bots.I.nextWork(b)}');
      // Phase 2 arms the next test (an alarm that fires while the process is dead) once the app is up.
      if (phase == 'P2' && !armed && n >= 10) {
        armed = true;
        final at = DateTime.now().add(const Duration(minutes: 3));
        b.routines.removeWhere((r) => r.id == 'rk' || r.id == 'rk2');
        b.routines.add(BotRoutine(id: 'rk2', time: _hm(at), days: 'daily', kind: 'message', instruction: 'Send me one short bookkeeping tip (kill test).'));
        await Bots.I.save();
        await Bots.I.arm(b);
        final d = DateTime(at.year, at.month, at.day, at.hour, at.minute);
        File(_marker).writeAsStringSync('p3|${b.id}|${d.toIso8601String()}');
        print('P2: armed rk2 for ${_hm(at)} PHASE3_DUE:${d.millisecondsSinceEpoch ~/ 1000}');
      }
    }
    if (n >= 24) {
      t.cancel();
      print('$phase: end of observation');
    }
  });
}

void main() {
  final f = File(_marker);
  if (f.existsSync()) {
    final m = f.readAsStringSync().trim().split('|');
    if (m.first == 'p2' || m.first == 'p3') {
      unawaited(_coldStart(m.first.toUpperCase(), m));
      return;
    }
  }
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat bughunt 4: bots', (tester) async {
    void log(String s) => print(s);
    var exceptions = 0;
    var aborted = false;
    var tick = 0;
    var lastFront = DateTime(2000);
    final askSeen = <Object, DateTime>{};

    BuildContext ctx() => app.appNavKey.currentContext!;
    AppState st() => Provider.of<AppState>(ctx(), listen: false);

    // Watchdog: approvals, asks and a lost foreground never hold the run.
    void watchdog() {
      final now = DateTime.now();
      final life = WidgetsBinding.instance.lifecycleState;
      if (life != null && life != AppLifecycleState.resumed && now.difference(lastFront).inSeconds > 20) {
        lastFront = now;
        log('ADB:front');
        log('CB:watchdog|SubMac not resumed ($life): asked the script to bring it back');
      }
      final sheet = find.byType(BottomSheet);
      if (sheet.evaluate().isNotEmpty) {
        for (final t in ['Not now', 'Deny', "Don't allow", 'Cancel', 'No']) {
          final b = find.descendant(of: sheet, matching: find.text(t));
          if (b.evaluate().isNotEmpty) {
            log('CB:watchdog|approval sheet answered "$t": ${find.descendant(of: sheet, matching: find.byType(RichText)).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).take(4).join(' / ')}');
            tester.tap(b.last, warnIfMissed: false);
            break;
          }
        }
      }
      try {
        for (final a in List.of(st().asks)) {
          final seen = askSeen.putIfAbsent(a, () => now);
          if (now.difference(seen).inSeconds > 25) {
            log('CB:watchdog|ask cancelled after 25 s: ${a.kind}:${a.title}');
            st().answerAsk(a, null);
          }
        }
      } catch (_) {}
    }

    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        if (aborted) throw 'step aborted by its hard timeout';
        await tester.pump(const Duration(milliseconds: 50));
        final e = tester.takeException();
        if (e != null) {
          exceptions++;
          log('QAERR: exception: ${e.toString().split('\n').first}');
        }
        if (++tick % 40 == 0) watchdog();
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

    void stopAll(String why) {
      final left = st().runs.toList();
      if (left.isEmpty) return;
      log('QA: stopping runs ($why): ${left.map((r) => '${r.title}/${r.status}').toList()}');
      for (final r in left) {
        r.stop();
      }
    }

    Future<void> step(String what, Future<void> Function() f, {int limit = 420}) async {
      final t0 = DateTime.now();
      var failed = false;
      final fut = f().catchError((Object e, StackTrace s) {
        failed = true;
        if (!aborted) log('QAERR: $what: ${e.toString().split('\n').take(2).join(' ')} ${s.toString().split('\n').take(2).join(' ')}');
      });
      try {
        await fut.timeout(Duration(seconds: limit));
        if (!failed) log('QA: ok $what (${DateTime.now().difference(t0).inSeconds}s)');
        if (failed) await shot('err_${what.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}');
      } on TimeoutException {
        log('QAERR: $what: hard timeout after ${limit}s');
        aborted = true;
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        aborted = false;
        stopAll('timeout in $what');
        await shot('timeout_${what.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}');
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

    final peak = <String, int>{};
    Future<void> settle(int s, {String key = '', String? conv}) async {
      final t0 = DateTime.now();
      await wait(1500);
      final c = conv ?? st().currentId;
      bool here() => st().runs.any((r) => r.convId == c);
      while (DateTime.now().difference(t0).inSeconds < s && here()) {
        final r = st().runs.where((r) => !r.side && r.convId == c).firstOrNull;
        if (r != null && key.isNotEmpty) {
          peak['$key.steps'] = math.max(r.step, peak['$key.steps'] ?? 0);
          peak['$key.tokens'] = math.max(r.tokens, peak['$key.tokens'] ?? 0);
        }
        await wait(1000);
      }
      if (here()) {
        log('QAERR: still running after ${s}s: ${st().runs.map((r) => '${r.title}/${r.status}/step${r.step}').toList()}');
        stopAll('settle limit');
      }
      await wait(2500);
    }

    String dumpList(List<ChatMessage> list) {
      final parts = <String>[];
      for (final m in list) {
        final c = m.content.replaceAll('\n', '⏎');
        parts.add('${m.role}${m.toolCalls?.isNotEmpty == true ? '[${m.toolCalls!.map((c) => c.name).join(',')}]' : ''}'
            '${m.error != null ? '{ERR:${m.error}}' : ''}:${c.length > 400 ? '${c.substring(0, 400)}…(${c.length})' : c}');
      }
      return parts.join(' ¦ ');
    }

    List<ChatMessage> tail(List<ChatMessage> l, int n) => l.length > n ? l.sublist(l.length - n) : l;

    void record(String name, DateTime t0, {String? conv}) {
      final msgs = conv == null ? st().messages : st().messagesOf(conv);
      final calls = [for (final m in msgs) ...?m.toolCalls?.map((c) => c.name)];
      final last = msgs.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      log('T:$name|${jsonEncode({
            't0': t0.toUtc().toIso8601String(),
            't1': DateTime.now().toUtc().toIso8601String(),
            'secs': DateTime.now().difference(t0).inSeconds,
            'steps': peak['$name.steps'] ?? 0,
            'runTokens': peak['$name.tokens'] ?? 0,
            'tools': calls,
            'replyChars': last.content.length,
            'tables': find.byType(TableCard).evaluate().length,
            'choices': find.byType(ChoicesCard).evaluate().length,
            'banner': st().banner,
          })}');
    }

    Future<void> adb(String cmd, {int ms = 9000}) async {
      log('ADB:$cmd');
      await wait(ms);
    }

    String boxText() {
      final f = find.byType(TextField);
      if (f.evaluate().isEmpty) return '<no box>';
      return tester.widget<TextField>(f.last).controller?.text ?? '<no controller>';
    }

    Future<Uint8List> png() async {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, 256, 256), Paint()..color = const Color(0xFFFFFFFF));
      c.drawCircle(const Offset(128, 128), 90, Paint()..color = const Color(0xFFD32F2F));
      final img = await rec.endRecording().toImage(256, 256);
      final b = await img.toByteData(format: ui.ImageByteFormat.png);
      return b!.buffer.asUint8List();
    }

    String rtlReport() {
      final script = RegExp(r'[\u0600-\u06FF]');
      var ar = 0, arRtl = 0, so = 0, soRtl = 0;
      for (final e in find.byType(RichText).evaluate()) {
        final w = e.widget as RichText;
        final t = w.text.toPlainText();
        if (t.trim().length < 12) continue;
        if (script.hasMatch(t)) {
          ar++;
          if (w.textDirection == TextDirection.rtl) arRtl++;
        } else if (RegExp(r'\b(waa|iyo|ayaa|oo|ka|ku)\b').allMatches(t).length >= 2) {
          so++;
          if (w.textDirection == TextDirection.rtl) soRtl++;
        }
      }
      return 'arabicRuns=$ar arabicRtl=$arRtl somaliRuns=$so somaliRtl=$soRtl';
    }

    Future<void> openWorkspace(Bot b) async {
      await backHome();
      unawaited(app.appNavKey.currentState!.push(MaterialPageRoute(builder: (_) => BotsWorkspace(open: 'bot:${b.id}'))));
      await wait(3500);
    }

    String wsActive() {
      final f = find.byType(BotsWorkspace);
      if (f.evaluate().isEmpty) return '<no workspace>';
      return tester.state<BotsWorkspaceState>(f.first).active;
    }

    void botState(String tag, Bot b) => log('CB:$tag|bot=${b.name} lastWake=${b.lastWake} tokensToday=${b.tokensTodayNow} '
        'journal=${b.journal.reversed.take(4).map((e) => '${e.at.toIso8601String().substring(11, 19)} ${e.kind}:${e.text.length > 70 ? e.text.substring(0, 70) : e.text}').toList()} '
        'followups=${b.followups.map((f) => '${f.at.toIso8601String().substring(11, 16)} ${f.kind}:${f.instruction.length > 40 ? f.instruction.substring(0, 40) : f.instruction}').toList()} '
        'traces=${BotTraces.I.of(b.id).length} next=${Bots.I.nextWork(b)}');

    // ------------------------------------------------------------ start and sign in (round-3 code)
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
      }
      await wait(9000);
    }
    log('QA: signed in = ${Supabase.instance.client.auth.currentSession != null} uid=${Supabase.instance.client.auth.currentUser?.id}');
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

    const safeOff = {'phone', 'apps', 'browser'};
    Bot? ledger, nova;

    // ============================================================ 1. create a bot, does it follow its instructions?
    await step('b1_create_bot', () async {
      final t0 = DateTime.now();
      ledger = await st().hireForJob({
        'name': 'Ledger',
        'role': 'Bookkeeper',
        'mission': 'Keeps the owner\'s small-shop books tidy.',
        'instructions': 'Always answer in exactly three bullet points. Never use tables.',
      });
      ledger!.powersOff
        ..clear()
        ..addAll(safeOff);
      await Bots.I.save();
      final err = await st().hireBot(ledger!);
      log('CB:b1|bot=${ledger!.id} conv=${ledger!.convId} hireErr=$err current=${st().currentId} powersOff=${ledger!.powersOff}');
      await openWorkspace(ledger!);
      await type('What should every invoice I send to customers contain?');
      await settle(180, key: 'b1_create_bot', conv: ledger!.convId);
      record('b1_create_bot', t0, conv: ledger!.convId);
      final list = st().messagesOf(ledger!.convId);
      log('MSGS:b1|${dumpList(tail(list, 6))}');
      final last = list.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      final bullets = RegExp(r'^\s*([-*•]|\d+\.)\s', multiLine: true).allMatches(last.content).length;
      log('CB:b1|instruction "exactly three bullets, no tables": bullets=$bullets table=${last.content.contains('|---') || last.content.contains('```table')}');
      await shot('b1_bot_chat');
    }, limit: 300);

    // ============================================================ 2. edit the bot: instructions and tools
    await step('b2_edit_bot', () async {
      final b = ledger!;
      final t0 = DateTime.now();
      b.instructions = 'Always answer in Somali, in one short paragraph. No bullet points.';
      b.powersOff
        ..clear()
        ..addAll({...safeOff, 'web'});
      await Bots.I.save();
      log('CB:b2|edited: instructions=Somali paragraph powersOff=${b.powersOff} effectiveOff=${b.effectiveOff}');
      final n0 = st().messagesOf(b.convId).length;
      await type('Search the web for today\'s US dollar to Kenyan shilling exchange rate and tell me the number.');
      await settle(180, key: 'b2_edit_bot', conv: b.convId);
      record('b2_edit_bot', t0, conv: b.convId);
      final list = st().messagesOf(b.convId);
      final added = list.skip(n0).toList();
      final calls = [for (final m in added) ...?m.toolCalls?.map((c) => c.name)];
      final last = list.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      final bullets = RegExp(r'^\s*([-*•]|\d+\.)\s', multiLine: true).allMatches(last.content).length;
      log('CB:b2|after edit: toolCalls=$calls webUsed=${calls.any((c) => c.contains('web') || c.contains('fetch') || c.contains('search'))} bullets=$bullets '
          'somali=${RegExp(r'\b(waa|iyo|ka|ku|oo)\b').hasMatch(last.content)} text=${last.content.length > 200 ? last.content.substring(0, 200) : last.content}');
      log('MSGS:b2|${dumpList(added)}');
      await shot('b2_after_edit');
      // Back to neutral for the rendering checks.
      b.instructions = 'Follow the owner\'s formatting requests exactly.';
      b.powersOff
        ..clear()
        ..addAll(safeOff);
      await Bots.I.save();
    }, limit: 300);

    // ============================================================ 3. bot chat rendering: table, choices, Somali, Arabic
    Future<void> render(String name, String prompt, {int secs = 150}) async {
      await step(name, () async {
        final b = ledger!;
        if (wsActive() != 'b:${b.id}') await openWorkspace(b);
        final t0 = DateTime.now();
        await type(prompt);
        await settle(secs, key: name, conv: b.convId);
        record(name, t0, conv: b.convId);
        final last = st().messagesOf(b.convId).lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
        log('CB:$name|tables=${find.byType(TableCard).evaluate().length} choices=${find.byType(ChoicesCard).evaluate().length} ${rtlReport()} '
            'raw=${last.content.replaceAll('\n', '⏎').substring(0, math.min(300, last.content.length))}');
        await shot(name);
      }, limit: secs + 60);
    }

    await render('b3_table', 'Make me a table of 3 shop expenses this week: item, cost in USD, date. Use a real table.');
    await render('b3_choices', 'Ask me, with tappable choices, whether I want daily or weekly reports. Give exactly two choices.');
    await step('b3_choice_tap', () async {
      final c = find.byType(ChoicesCard);
      if (c.evaluate().isEmpty) {
        log('CB:b3_choice_tap|no choice card on screen');
        return;
      }
      await tester.ensureVisible(c.last);
      await wait(800);
      final opt = find.descendant(of: c.last, matching: find.textContaining(RegExp('Weekly', caseSensitive: false)));
      if (opt.evaluate().isEmpty) {
        log('CB:b3_choice_tap|no Weekly option');
        return;
      }
      final n0 = st().messagesOf(ledger!.convId).length;
      await tester.tap(opt.first, warnIfMissed: false);
      await settle(120, conv: ledger!.convId);
      final added = st().messagesOf(ledger!.convId).skip(n0).toList();
      log('CB:b3_choice_tap|after tap: ${dumpList(added)}');
      await shot('b3_choice_tap');
    }, limit: 180);
    await render('b3_somali', 'Igu qor hal sadar oo Af-Soomaali ah oo ku saabsan sida loo xafido rasiidhada dukaanka. Two sentences, in Somali only.');
    await render('b3_arabic', 'اكتب لي جملتين باللغة العربية عن أهمية حفظ الفواتير في المتجر. بالعربية فقط.');

    // ============================================================ 4. routines: one-off and repeating, on time
    await step('r1_routines_on_time', () async {
      final b = ledger!;
      final now = DateTime.now();
      final atF = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(minutes: 2));
      final atR = atF.add(const Duration(minutes: 1));
      b.followups.add(BotFollowup('f1shot', atF, 'Send me a one-line reminder to count the cash drawer (one-off test).', 'message'));
      b.routines.add(BotRoutine(id: 'rq', time: _hm(atR), days: 'daily', kind: 'message', instruction: 'Send me one practical bookkeeping tip.'));
      await Bots.I.save();
      await Bots.I.arm(b);
      final traces0 = BotTraces.I.of(b.id).length;
      final j0 = b.journal.length;
      log('CB:r1|one-off follow-up due ${_hm(atF)}, daily routine due ${_hm(atR)} (now ${now.toIso8601String().substring(11, 19)})');
      await adb('alarms', ms: 4000);
      await backHome();
      st().newChat();
      final wakes = <DateTime>[];
      DateTime? seen = b.lastWake;
      final until = atR.add(const Duration(minutes: 5));
      while (DateTime.now().isBefore(until)) {
        if (b.lastWake != null && b.lastWake != seen) {
          seen = b.lastWake;
          wakes.add(b.lastWake!);
          log('CB:r1|wake at ${b.lastWake!.toIso8601String().substring(11, 19)} (followup due +${b.lastWake!.difference(atF).inSeconds}s, routine due +${b.lastWake!.difference(atR).inSeconds}s)');
        }
        if (wakes.length >= 2 && !running(b.convId) && DateTime.now().isAfter(atR.add(const Duration(seconds: 90)))) break;
        await wait(2000);
      }
      await wait(5000);
      final rq = b.routines.firstWhere((r) => r.id == 'rq');
      log('CB:r1|wakes=${wakes.length} traces+=${BotTraces.I.of(b.id).length - traces0} journal+=${b.journal.skip(j0).map((e) => '${e.at.toIso8601String().substring(11, 19)} ${e.kind}:${e.text}').toList()} '
          'oneOffStillQueued=${b.followups.any((f) => f.id == 'f1shot')} routineNext=${rq.next(DateTime.now())}');
      log('MSGS:r1|${dumpList(tail(st().messagesOf(b.convId), 8))}');
      await adb('notif', ms: 4000);
      await adb('alarms', ms: 4000);
      await shot('r1_home_after_routines');
    }, limit: 600);

    // ============================================================ CB-35: the same alarm delivered twice
    await step('r2_double_fire', () async {
      final b = ledger!;
      final traces0 = BotTraces.I.of(b.id).length;
      final f0 = b.followups.length;
      final j0 = b.journal.length;
      final r = await Future.wait([Bots.I.fire(Bots.alarmId(b, 'rq')), Bots.I.fire(Bots.alarmId(b, 'rq'))]);
      await wait(3000);
      final until = DateTime.now().add(const Duration(minutes: 4));
      while (DateTime.now().isBefore(until) && running(b.convId)) {
        await wait(2000);
      }
      await wait(4000);
      log('CB:r2|concurrent double fire results=$r traces+=${BotTraces.I.of(b.id).length - traces0} followupsAdded=${b.followups.length - f0} '
          'followups=${b.followups.map((f) => '${f.at.toIso8601String().substring(11, 16)} ${f.instruction}').toList()} journal+=${b.journal.skip(j0).map((e) => '${e.kind}:${e.text}').toList()}');
      // A redelivery after the first wake already finished (Android redelivers after a process restart).
      final t1 = BotTraces.I.of(b.id).length;
      final again = await Bots.I.fire(Bots.alarmId(b, 'rq'));
      await wait(3000);
      final until2 = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(until2) && running(b.convId)) {
        await wait(2000);
      }
      log('CB:r2|late redelivery fire=$again traces+=${BotTraces.I.of(b.id).length - t1} messagesToday=${b.journal.where((e) => e.kind == 'message').length}');
      botState('r2', b);
      // Do not let the 15-minute follow-ups fire into later steps.
      b.followups.clear();
      await Bots.I.save();
      await Bots.I.arm(b);
    }, limit: 540);

    // ============================================================ 5. CB-17: owner message during a silent wake
    await step('b5_message_during_wake', () async {
      final b = ledger!;
      b.routines.add(BotRoutine(id: 'rw', time: '23:59', days: 'daily', kind: 'work',
          instruction: 'Check if anything in your memory needs a follow-up. If nothing does, reply with only [no reply].'));
      await Bots.I.save();
      await openWorkspace(b);
      unawaited(Bots.I.fire(Bots.alarmId(b, 'rw')));
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 40 && !running(b.convId)) {
        await wait(300);
      }
      log('CB:b5|wake running=${running(b.convId)} after ${DateTime.now().difference(t0).inSeconds}s');
      await type('Quick question while you work: what is 17 times 3?');
      final mine = st().messagesOf(b.convId).lastWhere((m) => m.role == 'user', orElse: () => ChatMessage(id: '', role: 'user'));
      log('CB:b5|my message id=${mine.id} text=${mine.content}');
      await settle(240, key: 'b5', conv: b.convId);
      await wait(5000);
      final list = st().messagesOf(b.convId);
      final kept = list.any((m) => m.id == mine.id);
      final answered = list.any((m) => m.role == 'assistant' && m.content.contains('51'));
      log('CB:b5|my message still in chat=$kept answered(51)=$answered journal=${b.journal.reversed.take(3).map((e) => '${e.kind}:${e.text}').toList()}');
      log('MSGS:b5|${dumpList(tail(list, 10))}');
      record('b5_message_during_wake', t0, conv: b.convId);
      await shot('b5_after');
      b.routines.removeWhere((r) => r.id == 'rw');
      await Bots.I.save();
      await Bots.I.arm(b);
    }, limit: 360);

    // ============================================================ 6. CB-20: bot budget and Bot Activity
    await step('b6_budget_activity', () async {
      final b = ledger!;
      final traces = BotTraces.I.of(b.id);
      final sum = traces.fold<int>(0, (a, r) => a + r.tokens);
      log('CB:b6|tokensToday=${b.tokensTodayNow} traceSum=$sum budgetK=${b.tokenBudgetK} usageLine="${BotActivityScreen.usageLine(b)}" '
          'traces=${traces.map((r) => '${r.why.length > 30 ? r.why.substring(0, 30) : r.why}=${r.tokens}').toList()} '
          'uid=${Supabase.instance.client.auth.currentUser?.id} at=${DateTime.now().toUtc().toIso8601String()}');
      b.tokenBudgetK = 50;
      await Bots.I.save();
      log('CB:b6|with a 50k (Light) limit: overBudget=${b.overBudget} usageLine="${BotActivityScreen.usageLine(b)}"');
      await backHome();
      unawaited(app.appNavKey.currentState!.push(MaterialPageRoute(builder: (_) => BotActivityScreen(bot: b))));
      await wait(2500);
      await shot('b6_bot_activity');
      // Over budget: does a routine still run?
      final t0 = BotTraces.I.of(b.id).length;
      final fired = await Bots.I.fire(Bots.alarmId(b, 'rq'));
      await wait(8000);
      log('CB:b6|over-budget fire=$fired traces+=${BotTraces.I.of(b.id).length - t0} journal=${b.journal.reversed.take(2).map((e) => '${e.kind}:${e.text}').toList()}');
      b.tokenBudgetK = 0;
      await Bots.I.save();
      await backHome();
    }, limit: 180);

    // ============================================================ second bot for the workspace tests
    await step('w0_second_bot', () async {
      nova = await st().hireForJob({'name': 'Nova', 'role': 'Researcher', 'mission': 'Finds facts and prices.', 'instructions': 'Answer in one short sentence.'});
      nova!.powersOff
        ..clear()
        ..addAll({...safeOff, 'web'});
      await Bots.I.save();
      final err = await st().hireBot(nova!);
      log('CB:w0|nova=${nova!.id} conv=${nova!.convId} err=$err');
    }, limit: 120);

    // ============================================================ 7. CB-16: wrong-chat send after a notification-style openConversation
    await step('w1_wrong_chat_send', () async {
      final a = ledger!, b = nova!;
      await openWorkspace(a);
      log('CB:w1|workspace active=${wsActive()} currentId=${st().currentId} (ledger=${a.convId})');
      // What a tap on Nova's notification does (payload conv/<id> -> openConversation), with Ledger's workspace on screen.
      await st().openConversation(b.convId);
      await wait(3000);
      final header = find.text('Nova').evaluate().length;
      log('CB:w1|after openConversation(nova): workspace active=${wsActive()} currentId=${st().currentId} novaTextOnScreen=$header');
      await shot('w1_after_notification_open');
      final la = st().messagesOf(a.convId).length, lb = st().messagesOf(b.convId).length;
      await type('CB16 probe: which bot are you? Reply with your name only.');
      await settle(90, conv: st().currentId);
      final toA = st().messagesOf(a.convId).skip(la).where((m) => m.role == 'user' && m.content.contains('CB16')).length;
      final toB = st().messagesOf(b.convId).skip(lb).where((m) => m.role == 'user' && m.content.contains('CB16')).length;
      log('CB:w1|typed in the workspace showing ${wsActive()}: landed in ledger=$toA nova=$toB reply=${dumpList(st().messagesOf(b.convId).skip(lb).toList())}');
      await shot('w1_after_send');
    }, limit: 180);

    // ============================================================ 8. CB-29: attachments per chat in the Bots workspace
    await step('w2_attachments_per_chat', () async {
      final a = ledger!, b = nova!;
      await openWorkspace(a);
      final dir = await Directory.systemTemp.createTemp('cb4');
      final p = '${dir.path}/receipt.png';
      await File(p).writeAsBytes(await png());
      st().shareInbox.value = {'files': [p]};
      await wait(2500);
      int chips() => find.byWidgetPredicate((w) => w.runtimeType.toString() == 'AttachmentChip').evaluate().length;
      final inA = chips();
      await tester.enterText(await box(), 'DRAFT-LEDGER-only');
      await wait(800);
      await shot('w2_attachment_in_ledger');
      // Switch the workspace to Nova by its rail, the way a person does (fall back to openBot).
      await st().openBot(b);
      await wait(3000);
      final inB = chips();
      final textB = boxText();
      log('CB:w2|ledger chips=$inA; after switching to Nova (active=${wsActive()}): chips=$inB text="$textB"');
      await shot('w2_attachment_in_nova');
      if (inB > 0) {
        final lb = st().messagesOf(b.convId).length;
        await type('CB29 probe: describe the picture I sent, if any, in five words.');
        await settle(90, conv: b.convId);
        final sent = st().messagesOf(b.convId).skip(lb).where((m) => m.role == 'user').map((m) => 'atts=${m.attachments.length}').toList();
        log('CB:w2|sent in Nova with the leaked chip: $sent');
      }
      await st().openBot(a);
      await wait(3000);
      log('CB:w2|back in Ledger: chips=${chips()} text="${boxText()}"');
      await tester.enterText(await box(), '');
      await backHome();
    }, limit: 240);

    // ============================================================ 10. Telegram without a real token (CB-25)
    await step('t1_telegram', () async {
      final r = await TelegramBridge.I.connect('123456789:AAFakeTokenForChatBugHunt4xxxxxxxxxxx');
      log('CB:t1|connect(fake token) -> $r on=${TelegramBridge.I.on} status="${TelegramBridge.I.status}"');
      // A token that worked once and then died (revoked in @BotFather): what init() finds on the next start.
      var calls = 0;
      HttpOverrides.global = _Count(() => calls++);
      const sec = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
      await sec.write(key: 'telegram_token', value: '123456789:AADeadTokenForChatBugHunt4xxxxxxxxxxx');
      final p = await SharedPreferences.getInstance();
      await p.setBool('telegram_on', true);
      await p.setString('telegram_bot', 'cb4_dead_bot');
      await TelegramBridge.I.init();
      final t0 = DateTime.now();
      final seen = <String>{};
      while (DateTime.now().difference(t0).inSeconds < 150) {
        seen.add(TelegramBridge.I.status);
        await wait(3000);
      }
      log('CB:t1|dead token after 150 s: telegram HTTP clients=$calls on=${TelegramBridge.I.on} paired=${TelegramBridge.I.paired} statuses=$seen');
      log('CB:t1|pairing state kept on disk: ${p.getKeys().where((k) => k.contains('telegram')).map((k) => '$k=${p.get(k)}').toList()} pairCode(in memory)="${TelegramBridge.I.pairCode}"');
      await TelegramBridge.I.disconnect();
      HttpOverrides.global = null;
    }, limit: 220);

    // ============================================================ 9. CB-18: a bot acting on a deleted bot / chat; delete-all while a bot runs
    await step('d2_delete_bot_while_waking', () async {
      final b = nova!;
      b.routines.add(BotRoutine(id: 'rn', time: '23:58', days: 'daily', kind: 'message', instruction: 'Write me a 150-word note on why prices matter, then send it.'));
      await Bots.I.save();
      await backHome();
      st().newChat();
      unawaited(Bots.I.fire(Bots.alarmId(b, 'rn')));
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 40 && !running(b.convId)) {
        await wait(300);
      }
      final conv = b.convId;
      log('CB:d2|nova wake running=${running(conv)}; removing Nova the way the Remove button does');
      await st().deleteConversation(conv);
      await Bots.I.remove(b);
      await wait(2000);
      log('CB:d2|right after remove: runs=${st().runs.map((r) => r.convId).toList()} byId=${Bots.I.byId(b.id) != null}');
      await wait(60000);
      final idx = st().repo.store.index.values.where((m) => m['id'] == conv).map((m) => '${m['id']}:${m['title']}:${m['_unknown'] == true ? 'ghost' : ''}').toList();
      log('CB:d2|60 s later: bot back=${Bots.I.byId(b.id) != null} chat index for its conv=$idx inConversations=${st().conversations.any((c) => c.id == conv)} msgs=${st().messagesOf(conv).length}');
      await adb('notif', ms: 4000);
      await adb('alarms', ms: 4000);
    }, limit: 200);

    await step('d3_wake_after_chat_deleted', () async {
      final b = ledger!;
      final old = b.convId;
      await backHome();
      st().newChat();
      await st().deleteConversation(old);
      await wait(2000);
      final t0 = DateTime.now();
      final fired = await Bots.I.fire(Bots.alarmId(b, 'rq'));
      await wait(3000);
      while (DateTime.now().difference(t0).inSeconds < 180 && running(b.convId)) {
        await wait(2000);
      }
      await wait(4000);
      log('CB:d3|chat $old deleted, then routine fire=$fired: bot conv now=${b.convId} sameId=${b.convId == old} msgs=${st().messagesOf(b.convId).length} '
          'inConversations=${st().conversations.any((c) => c.id == b.convId)}');
      log('MSGS:d3|${dumpList(tail(st().messagesOf(b.convId), 6))}');
      botState('d3', b);
    }, limit: 240);

    await step('d1_delete_all_while_bot_runs', () async {
      final b = ledger!;
      b.routines.add(BotRoutine(id: 'rd', time: '23:57', days: 'daily', kind: 'message',
          instruction: 'Write me a 250-word note on keeping a shop cash book, then send it.'));
      await Bots.I.save();
      await backHome();
      st().newChat();
      unawaited(Bots.I.fire(Bots.alarmId(b, 'rd')));
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 40 && !running(b.convId)) {
        await wait(300);
      }
      final conv = b.convId;
      log('CB:d1|bot wake running=${running(conv)} conv=$conv chats=${st().conversations.length}; delete all chats now');
      await st().deleteAllConversations();
      await wait(2000);
      log('CB:d1|right after delete-all: runs=${st().runs.map((r) => '${r.convId}/${r.status}').toList()} chats=${st().conversations.length}');
      while (DateTime.now().difference(t0).inSeconds < 200 && running(conv)) {
        await wait(2000);
      }
      await wait(8000);
      final idx = st().repo.store.index.values.map((m) => '${m['id']}:${m['title']}:${m['_unknown'] == true ? 'ghost' : ''}').toList();
      log('CB:d1|after the wake ended: local chat index=$idx conversations=${st().conversations.map((c) => c.title).toList()} botConv=${b.convId}');
      await st().refreshConversations();
      await wait(3000);
      log('CB:d1|after reload: conversations=${st().conversations.map((c) => '${c.id}:${c.title}').toList()}');
      botState('d1', b);
      await adb('notif', ms: 4000);
      b.routines.removeWhere((r) => r.id == 'rd');
      await Bots.I.save();
    }, limit: 300);

    // ============================================================ doze: a routine due while the device is forced idle
    await step('z1_doze', () async {
      final b = ledger!;
      await backHome();
      st().newChat();
      final now = DateTime.now();
      final at = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(minutes: 2));
      b.routines.removeWhere((r) => r.id == 'rz');
      b.routines.add(BotRoutine(id: 'rz', time: _hm(at), days: 'daily', kind: 'message', instruction: 'Send me a one-line doze test tip.'));
      await Bots.I.save();
      await Bots.I.arm(b);
      final w0 = b.lastWake;
      final tr0 = BotTraces.I.of(b.id).length;
      await adb('doze_on', ms: 8000);
      while (DateTime.now().isBefore(at.add(const Duration(minutes: 3)))) {
        if (b.lastWake != w0 && !running(b.convId)) break;
        await wait(2000);
      }
      log('CB:z1|routine due ${_hm(at)} under forced idle: woke=${b.lastWake != w0} at=${b.lastWake} traces+=${BotTraces.I.of(b.id).length - tr0} '
          'journal=${b.journal.reversed.take(2).map((e) => '${e.kind}:${e.text}').toList()} followups=${b.followups.map((f) => f.at.toIso8601String().substring(11, 16)).toList()}');
      await adb('doze_off', ms: 8000);
      log('MSGS:z1|${dumpList(tail(st().messagesOf(b.convId), 4))}');
      b.routines.removeWhere((r) => r.id == 'rz');
      b.followups.clear();
      await Bots.I.save();
      await Bots.I.arm(b);
    }, limit: 360);

    // ============================================================ CB-21 setup: a routine due after the script force-stops the app
    await step('k0_arm_for_force_stop', () async {
      final b = ledger!;
      final now = DateTime.now();
      final at = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(minutes: 3));
      b.routines.removeWhere((r) => r.id == 'rq' || r.id == 'rk');
      b.routines.add(BotRoutine(id: 'rk', time: _hm(at), days: 'daily', kind: 'message', instruction: 'Send me one short bookkeeping tip (force-stop test).'));
      await Bots.I.save();
      await Bots.I.arm(b);
      await Directory('/data/user/0/com.submac.agent/files').create(recursive: true);
      File(_marker).writeAsStringSync('p2|${b.id}|${at.toIso8601String()}');
      botState('k0', b);
      log('PHASE2_DUE:${at.millisecondsSinceEpoch ~/ 1000}');
    }, limit: 60);

    log('QA: exceptions caught during the run = $exceptions');
    log('QA: done');
  }, timeout: const Timeout(Duration(minutes: 100)));
}

/// Counts the HTTP clients the Telegram bridge opens (one per getUpdates attempt), everything else passes through.
class _Count extends HttpOverrides {
  _Count(this.hit);
  final void Function() hit;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    if (StackTrace.current.toString().contains('telegram_bridge')) hit();
    return super.createHttpClient(context);
  }
}
