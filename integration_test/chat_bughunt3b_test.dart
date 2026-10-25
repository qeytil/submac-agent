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
import 'package:agent/widgets/chat/message_actions.dart';
import 'package:flutter/services.dart';
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

// ignore_for_file: unused_element, unused_import, unnecessary_import
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat bughunt 3b: round-1 UI bugs on a device', (tester) async {
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
      while (DateTime.now().difference(t0).inSeconds < s && st().runs.isNotEmpty) {
        final r = task();
        if (r != null && key.isNotEmpty) {
          peak['$key.steps'] = math.max(r.step, peak['$key.steps'] ?? 0);
          peak['$key.tokens'] = math.max(r.tokens, peak['$key.tokens'] ?? 0);
        }
        await wait(1000);
      }
      if (st().runs.isNotEmpty) log('QAERR: still running after ${s}s: ${st().runs.map((r) => '${r.title}/${r.status}/step${r.step}').toList()}');
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
      for (final r in st().runs.where((r) => !r.side).toList()) {
        r.stop();
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


    // ============================================================ Round-1 UI bugs on a real device (3b)
    // CB-2: Stop during a long streamed answer.
    await step('r2_stop_keeps_text', () async {
      await fresh();
      await type('Write a 1200-word story about a camel caravan crossing the Somali desert. No tools.');
      var seen = 0;
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 120) {
        final a = st().messages.where((m) => m.role == 'assistant').toList();
        seen = a.isEmpty ? 0 : a.last.content.length;
        if (seen > 600) break;
        await wait(200);
      }
      await shot('r2_before_stop');
      final stop = find.bySemanticsLabel('Stop');
      if (stop.evaluate().isNotEmpty) {
        await tester.tap(stop.first, warnIfMissed: false);
      } else {
        st().stop();
      }
      await wait(6000);
      final a = st().messages.where((m) => m.role == 'assistant').toList();
      log('CB:r2|streamed chars before Stop=$seen assistant msgs after=${a.length} kept chars=${a.isEmpty ? 0 : a.last.content.length} '
          'visibleHasCamel=${visible().toLowerCase().contains('camel')}');
      dump('r2');
      await shot('r2_after_stop');
    });

    // CB-1: a message typed while the FINAL answer streams (no tools).
    await step('r1_steer_final_stream', () async {
      await fresh();
      await type('Write three short paragraphs about the history of Mogadishu. No tools, no questions.');
      final t0 = DateTime.now();
      var at = 0;
      while (DateTime.now().difference(t0).inSeconds < 120) {
        final a = st().messages.where((m) => m.role == 'assistant' && m.streaming).toList();
        if (a.isNotEmpty && a.last.content.length > 150 && (a.last.toolCalls?.isEmpty ?? true)) {
          at = a.last.content.length;
          break;
        }
        await wait(150);
      }
      await type('Also add one final sentence about Kismayo.');
      final mine = st().messages.lastWhere((m) => m.role == 'user');
      log('CB:r1|steer typed while streaming at $at chars, running=${running()}');
      await settle(180, key: 'r1');
      await wait(15000);
      final list = st().messages;
      final idx = list.indexWhere((m) => m.id == mine.id);
      final after = idx < 0 ? <ChatMessage>[] : list.sublist(idx + 1).where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).toList();
      final kismayo = list.where((m) => m.role == 'assistant').any((m) => m.content.contains('Kismayo'));
      log('CB:r1|my message kept=${idx >= 0} assistant replies after it=${after.length} anyMentionsKismayo=$kismayo');
      dump('r1');
      await shot('r1_after');
    });

    // Rendered cards: real chat screen with messages placed in it (no model call).
    Future<void> inject(List<ChatMessage> ms) async {
      await fresh();
      st().messages.addAll(ms);
      st().notifyListeners();
      await wait(2500);
    }

    await step('r5_stale_choices', () async {
      const card = '```choices\n["Yes, book it", "Not now"]\n```';
      await inject([
        ChatMessage(id: 'r5u0', role: 'user', content: 'Help me book a trip'),
        ChatMessage(id: 'r5a1', role: 'assistant', content: 'Book the 9 am flight?\n$card'),
        ChatMessage(id: 'r5u1', role: 'user', content: 'Yes, book it'),
        ChatMessage(id: 'r5a2', role: 'assistant', content: 'Booked. Also book the hotel?\n$card'),
      ]);
      await scrollTop();
      final cards = find.byType(ChoicesCard);
      final n = cards.evaluate().length;
      final users0 = st().messages.where((m) => m.role == 'user').length;
      await shot('r5_cards');
      if (n >= 2) {
        final opt = find.descendant(of: cards.first, matching: find.text('Not now'));
        if (opt.evaluate().isNotEmpty) await tester.tap(opt.first, warnIfMissed: false);
        await wait(2500);
      }
      final users1 = st().messages.where((m) => m.role == 'user').length;
      log('CB:r5|choice cards=$n tap on the FIRST (answered) card sent a message=${users1 > users0} last user=${st().messages.lastWhere((m) => m.role == 'user').content}');
      st().stop();
      await wait(2000);
    });

    await step('r6_fence', () async {
      await inject([
        ChatMessage(id: 'r6u', role: 'user', content: 'code and prices'),
        ChatMessage(id: 'r6a', role: 'assistant', content: 'Here is the code:\n```c#\nConsole.WriteLine("hi");\n```\n\nPrices:\n```table\n{"columns":["Item","Price"],"rows":[["Tea","\$1"]]}\n```'),
      ]);
      final v = visible();
      log('CB:r6|table cards=${find.byType(TableCard).evaluate().length} rawTableJsonVisible=${v.contains('"columns"')}');
      await shot('r6_fence');
    });

    await step('r7_broken_card', () async {
      await inject([
        ChatMessage(id: 'r7u', role: 'user', content: 'budget'),
        ChatMessage(id: 'r7a', role: 'assistant', content: 'Your budget:\n```table\n{"columns":["Item","Cost"],"rows":[["Rent","\$300"],["Food","\$120"]\n```'),
      ]);
      log('CB:r7|"Rent" visible=${visible().contains('Rent')}');
      await shot('r7_broken_card');
    });

    await step('r8_copy_cards', () async {
      await inject([
        ChatMessage(id: 'r8u', role: 'user', content: 'packing'),
        ChatMessage(id: 'r8a', role: 'assistant', content: 'Your packing list:\n```list\n{"title":"Packing","items":["Passport","Charger","Sunscreen"]}\n```\n'
            'Useful links:\n```links\n[{"title":"Visa portal","url":"https://evisa.go.ke"}]\n```'),
      ]);
      await Clipboard.setData(const ClipboardData(text: 'EMPTY'));
      final copy = find.descendant(of: find.byType(MessageActionRow), matching: find.byTooltip('Copy'));
      if (copy.evaluate().isEmpty) {
        await tester.tap(find.textContaining('Your packing list').first, warnIfMissed: false);
        await wait(1000);
      }
      if (copy.evaluate().isEmpty) throw 'no Copy action';
      await tester.tap(copy.first, warnIfMissed: false);
      await wait(1200);
      final got = (await Clipboard.getData('text/plain'))?.text ?? '';
      log('CB:r8|copied="${got.replaceAll('\n', '⏎')}" hasPassport=${got.contains('Passport')} hasLink=${got.contains('evisa')}');
    });

    await step('r9_direction', () async {
      await inject([
        ChatMessage(id: 'r9u', role: 'user', content: 'salaan'),
        ChatMessage(id: 'r9a', role: 'assistant', content: 'السلام عليكم! Waan ku faraxsanahay inaan ku caawiyo. Maxaan kuu qabtaa maanta?'),
        ChatMessage(id: 'r9u2', role: 'user', content: 'ما هو أحدث هاتف؟'),
        ChatMessage(id: 'r9a2', role: 'assistant', content: 'iPhone 16 هو أحدث هاتف من شركة آبل، ويأتي بكاميرا محسنة وبطارية أطول.'),
      ]);
      String dirOf(String needle) {
        for (final e in find.byType(RichText).evaluate()) {
          final w = e.widget as RichText;
          if (w.text.toPlainText().contains(needle)) return '${w.textDirection ?? Directionality.of(e)}';
        }
        return 'not found';
      }
      log('CB:r9|Somali reply opening with an Arabic greeting: ${dirOf('faraxsanahay')} ; Arabic reply opening with iPhone: ${dirOf('شركة')}');
      await shot('r9_direction');
    });

    log('QA: exceptions caught during the run = $exceptions');
    log('QA: done');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
