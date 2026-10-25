// Chat bug hunt on a real emulator (2026-10-25, report: docs/chat-bughunt-102.md). Drives the debug app the way a
// person does (types, taps Send / Stop, taps cards) against production ai-chat with a throwaway account, and also
// shows exact reply texts in the real chat screen to photograph rendering bugs. Never part of the normal test run.
// Prints SHOT:<name> (screencap), SEE:<name>|<text on screen>, CB:<id>|<finding>, QA:/QAERR: lines.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
import 'package:agent/app_state.dart';
import 'package:agent/main.dart' as app;
import 'package:agent/models.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('QA_EMAIL');
const _pw = String.fromEnvironment('QA_PW');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat bughunt', (tester) async {
    // ignore: avoid_print
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
      log('SEE:$name|${v.length > 2500 ? v.substring(0, 2500) : v}');
      await wait(1500);
    }

    BuildContext ctx() => app.appNavKey.currentContext!;
    AppState st() => Provider.of<AppState>(ctx(), listen: false);

    Future<void> step(String what, Future<void> Function() f) async {
      try {
        await f();
        log('QA: ok $what');
      } catch (e) {
        log('QAERR: $what: ${e.toString().split('\n').take(2).join(' ')}');
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
      await wait(700);
      final send = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SendButton');
      if (send.evaluate().isEmpty) throw 'no send button';
      await tester.tap(send.first, warnIfMissed: false);
      await wait(800);
    }

    bool running() => st().runs.any((r) => !r.side);
    Future<void> settle(int s) async {
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < s && st().runs.isNotEmpty) {
        await wait(1000);
      }
      await wait(2500);
    }

    ChatMessage? streamingReply() {
      for (final m in st().messages.reversed) {
        if (m.role == 'assistant' && m.streaming) return m;
      }
      return null;
    }

    Future<bool> waitStreaming(int minChars, int s) async {
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < s) {
        final m = streamingReply();
        if (m != null && m.content.length >= minChars && (m.toolCalls?.isEmpty ?? true)) return true;
        if (!running() && DateTime.now().difference(t0).inSeconds > 8) return false;
        await wait(250);
      }
      return false;
    }

    void dump(String name) {
      final parts = <String>[];
      for (final m in st().messages) {
        final c = m.content.replaceAll('\n', '⏎');
        parts.add('${m.role}${m.toolCalls?.isNotEmpty == true ? '[${m.toolCalls!.map((c) => c.name).join(',')}]' : ''}'
            '${m.error != null ? '{ERR:${m.error}}' : ''}:${c.length > 300 ? '${c.substring(0, 300)}…(${c.length})' : c}');
      }
      log('MSGS:$name|${parts.join(' ¦ ')}');
    }

    Future<void> fresh() async {
      await backHome();
      st().newChat();
      await wait(1500);
    }

    /// Puts an exact exchange on the real chat screen (no model call) to photograph how a reply renders.
    Future<void> show(String name, List<ChatMessage> msgs) async {
      await fresh();
      st().messages.addAll(msgs);
      st().notifyListeners();
      await wait(2500);
      await shot(name);
    }

    Future<void> scrollTop() async {
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.dragFrom(Offset(size.width / 2, size.height * 0.3), const Offset(0, 1400));
      await wait(1200);
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
    log('QA: signed in = ${Supabase.instance.client.auth.currentSession != null}');
    // The 18+ / Terms gate (ConsentScreen) blocks the whole app for an account that has not agreed yet.
    final meta = Supabase.instance.client.auth.currentUser?.userMetadata;
    if (meta?['age_18'] != true) {
      try {
        await Supabase.instance.client.auth.updateUser(UserAttributes(data: {
          'consent_v': 2,
          'age_18': true,
          'consent_at': DateTime.now().toUtc().toIso8601String(),
        }));
        log('QA: consent saved');
      } catch (e) {
        log('QAERR: consent: $e');
      }
      await wait(6000);
    }
    for (var i = 0; i < 20 && find.text('Agree and continue').evaluate().isNotEmpty; i++) {
      await wait(1000);
    }
    log('QA: consent gate gone = ${find.text('Agree and continue').evaluate().isEmpty}');
    await backHome();
    await shot('00_home');

    // ------------------------------------------------------------ real model: send + stream
    await step('stream', () async {
      await fresh();
      await type('Write a 6 paragraph story about a fisherman in Kismayo.');
      await waitStreaming(120, 60);
      await shot('01_streaming');
      await settle(120);
      dump('stream');
      await shot('02_stream_done');
    });

    // ------------------------------------------------------------ CB-2 Stop mid-answer
    await step('cb2 stop', () async {
      await fresh();
      await type('Write a very long, detailed 2000-word guide to opening a small shop in Mogadishu, with many sections.');
      final got = await waitStreaming(400, 90);
      final before = streamingReply()?.content ?? '';
      log('CB:2|streaming before stop=$got chars=${before.length}');
      await shot('cb2_before_stop');
      final stop = find.bySemanticsLabel('Stop');
      if (stop.evaluate().isEmpty) throw 'no Stop button';
      await tester.tap(stop.first, warnIfMissed: false);
      await wait(4000);
      final kept = st().messages.where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).toList();
      log('CB:2|after stop: assistant messages with text=${kept.length} '
          '${kept.isEmpty ? '(the ${before.length} streamed chars are gone)' : 'kept ${kept.last.content.length} chars'}');
      dump('cb2');
      await shot('cb2_after_stop');
    });

    // ------------------------------------------------------------ CB-1 steer while the final answer streams
    await step('cb1 steer final', () async {
      await fresh();
      await type('Write a detailed 1500-word essay on the history of Somali poetry.');
      final got = await waitStreaming(250, 90);
      log('CB:1|answer streaming when steering=$got');
      await type('Stop the essay. Instead reply with only the single word BANANA.');
      await shot('cb1_steer_sent');
      await settle(240);
      await wait(20000);
      final msgs = st().messages;
      final iSteer = msgs.lastIndexWhere((m) => m.role == 'user' && m.content.contains('BANANA'));
      final after = iSteer < 0 ? const <ChatMessage>[] : msgs.sublist(iSteer + 1).where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).toList();
      final banana = msgs.any((m) => m.role == 'assistant' && m.content.toUpperCase().contains('BANANA'));
      log('CB:1|replies after the steer message=${after.length} anyBanana=$banana stillRunning=${running()} inbox=${st().runs.map((r) => r.inbox.length).toList()}');
      dump('cb1');
      await shot('cb1_after');
      await scrollTop();
      await shot('cb1_after_top');
    });

    // ------------------------------------------------------------ steer mid-task (a tool is running): expected OK
    await step('steer mid-task', () async {
      await fresh();
      await type('Search the web for the current weather in Mogadishu and in Nairobi and compare them.');
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 60) {
        final r = st().runs.where((r) => !r.side).firstOrNull;
        if (r != null && !r.inModel && r.step > 0) break;
        await wait(200);
      }
      await type('Also add Cairo to the comparison.');
      await shot('steer_tool_sent');
      await settle(240);
      final all = st().messages.where((m) => m.role == 'assistant').map((m) => m.content).join(' ');
      log('CB:steer|answer mentions Cairo=${all.contains('Cairo')}');
      dump('steer');
      await shot('steer_tool_after');
    });

    // ------------------------------------------------------------ CB-3 a tool name the app does not have
    await step('cb3 unknown tool', () async {
      await fresh();
      await type('Call the tool named exactly "python" with the code print(2**100). If it does not exist, call "browser.search" with query Somalia.');
      await settle(150);
      final last = st().messages.lastWhere((m) => m.role == 'assistant', orElse: () => ChatMessage(id: '', role: 'assistant'));
      final calls = [for (final m in st().messages) ...?m.toolCalls?.map((c) => c.name)];
      log('CB:3|calls=$calls lastError=${last.error}');
      dump('cb3');
      await shot('cb3_after');
    });

    // ------------------------------------------------------------ real rich reply: table, code, choices, maths
    await step('rich', () async {
      await fresh();
      await type('Compare EVC Plus, Zaad and Sahal in a table, then show a short Python code block that converts USD to SOS, '
          'then ask me which one I use and give me choices.');
      await settle(200);
      dump('rich');
      await shot('rich_answer');
      await scrollTop();
      await shot('rich_answer_top');
      log('CB:rich|tables=${find.byType(TableCard).evaluate().length} choices=${find.byType(ChoicesCard).evaluate().length}');
    });
    await step('long markdown', () async {
      await fresh();
      await type('Give me a long markdown cheat sheet with headings, nested lists, a table, a blockquote, inline math \$E=mc^2\$ '
          'and one display equation in LaTeX.');
      await settle(200);
      dump('md');
      await shot('md_answer');
      await scrollTop();
      await shot('md_answer_top');
    });

    // ------------------------------------------------------------ approval card
    await step('approval', () async {
      await fresh();
      await type('Send an SMS to +252610000000 saying: hello test.');
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0).inSeconds < 90 && st().asks.isEmpty && find.text('Allow').evaluate().isEmpty &&
          find.text('Send').evaluate().length < 2 && running()) {
        await wait(500);
      }
      await wait(1500);
      await shot('approval_card');
      for (final t in ['Not now', 'Don\'t send', 'Deny', 'Cancel', 'No']) {
        if (find.text(t).evaluate().isNotEmpty) {
          await tester.tap(find.text(t).last, warnIfMissed: false);
          break;
        }
      }
      await settle(90);
      dump('approval');
      await shot('approval_after');
    });

    // ------------------------------------------------------------ real Somali / Arabic
    await step('somali rtl', () async {
      await fresh();
      await type('Fadlan Af-Soomaali igu jawaab: sharax waxa uu yahay Zaad. Jawaabtaada ku bilow "السلام عليكم".');
      await settle(150);
      dump('so');
      await shot('cb9_somali_real');
    });
    await step('arabic rtl', () async {
      await fresh();
      await type('اشرح لي باختصار ما هو iPhone 16، وابدأ الإجابة بكلمة iPhone.');
      await settle(150);
      dump('ar');
      await shot('cb9_arabic_real');
    });

    // ------------------------------------------------------------ exact replies on the real screen (rendering bugs)
    const ask = '```choices\n["Yes, book it", "Not now"]\n```';
    await step('cb5 stale choices', () async {
      await show('cb5_stale_choices', [
        ChatMessage(id: 'u0', role: 'user', content: 'Find me a flight to Nairobi on Friday'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'The 9 am Jubba flight is \$180. Book it?\n$ask'),
        ChatMessage(id: 'u1', role: 'user', content: 'Yes, book it'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'Booked. Also book the hotel near the airport?\n$ask'),
      ]);
      await scrollTop();
      await shot('cb5_stale_choices_top');
      log('CB:5|choice cards=${find.byType(ChoicesCard).evaluate().length} '
          'status=${ChoicesCard.statusIn(st().messages, const ['Yes, book it', 'Not now'], busy: false)}');
    });
    await step('cb6 fence', () async {
      await show('cb6_csharp_fence', [
        ChatMessage(id: 'u', role: 'user', content: 'Show me C# hello world and the tea prices'),
        ChatMessage(id: 'a', role: 'assistant', content: 'Here is the code:\n```c#\nConsole.WriteLine("hi");\n```\n\nPrices:\n```table\n'
            '{"columns":["Item","Price"],"rows":[["Tea","\$1"],["Coffee","\$2"]]}\n```'),
      ]);
    });
    await step('cb7 broken card', () async {
      await show('cb7_broken_table', [
        ChatMessage(id: 'u', role: 'user', content: 'My monthly budget?'),
        ChatMessage(id: 'a', role: 'assistant', content: 'Your budget:\n```table\n{"columns":["Item","Cost"],"rows":[["Rent","\$300"],["Food","\$120"]\n```\nTotal \$420.'),
      ]);
    });
    await step('cb8 copy', () async {
      await show('cb8_list_links', [
        ChatMessage(id: 'u', role: 'user', content: 'Packing list for Nairobi?'),
        ChatMessage(id: 'a', role: 'assistant', content: 'Your packing list:\n```list\n{"title":"Packing","items":["Passport","Charger","Sunscreen"]}\n```\n'
            'Useful links:\n```links\n[{"title":"Visa portal","url":"https://evisa.go.ke"}]\n```'),
      ]);
      await tester.tap(find.textContaining('Your packing list').first, warnIfMissed: false);
      await wait(1200);
      final copy = find.byTooltip('Copy');
      if (copy.evaluate().isNotEmpty) {
        await tester.tap(copy.last, warnIfMissed: false);
        await wait(1000);
      }
      final clip = await Clipboard.getData('text/plain');
      log('CB:8|copied=${(clip?.text ?? '<none>').replaceAll('\n', '⏎')}');
      await shot('cb8_after_copy');
    });
    await step('cb9 direction', () async {
      await show('cb9_direction', [
        ChatMessage(id: 'u', role: 'user', content: 'Salaan'),
        ChatMessage(id: 'a', role: 'assistant', content: 'السلام عليكم! Waan ku faraxsanahay inaan ku caawiyo.\n\n1. Zaad waa adeeg lacag-dirid.\n2. Waxaa leh Telesom.'),
        ChatMessage(id: 'u2', role: 'user', content: 'ما هو iPhone 16؟'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'iPhone 16 هو أحدث هاتف من شركة آبل.\n\n1. كاميرا محسنة.\n2. بطارية أطول.'),
      ]);
    });
    await step('cb10 cut', () async {
      await show('cb10_cut_table', [
        ChatMessage(id: 'u', role: 'user', content: 'Plan my week in Mombasa as a table'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'Here is your week:\n\n| Day | Plan |\n|---|---|\n| Mon | Beach |'),
        ChatMessage(id: 'a2', role: 'assistant', content: '| Tue | Old town |\n| Wed | Museum |\n\nEnjoy the trip!'),
      ]);
    });
    log('QA: exceptions caught during the run = $exceptions');
    log('QA: done');
  }, timeout: const Timeout(Duration(minutes: 80)));
}
