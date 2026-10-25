// Chat bug hunt ROUND 4, TEAMS part, on a real emulator (2026-10-25). Investigation only, never part of the normal run.
// Runs real team jobs through the app's own TeamRun / Offices code against production ai-chat v41 with a throwaway
// account (chatbugs4t-*), then stop, a second request, a tool failure, a network cut, background/reopen, delete while
// running, Somali/Arabic, usage counters and notifications.
// Safety: "Let it take action" is turned off (no app/phone tools), member calls to app/phone tools are refused by the
// harness, every approval sheet or waiting approval is answered "Not now" after 20 s, and every wait is bounded.
// Prints:
//   SHOT:<name>   screencap (tools/chatbug4t_capture.sh)        ADB:<cmd>  network / background commands
//   T:<task>|<json>  one line per task                          CB:<id>|<finding>
//   LLM:<bot>|...    one line per team model call (harness wrap) TOOL:<bot>|...  one line per member tool call
//   POSTS:<task>|... the team chat                              QA:/QAERR: harness progress and failures
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, avoid_print
import 'dart:async';
import 'dart:convert';

import 'package:agent/agent/core.dart' show Turn;
import 'package:agent/app_state.dart';
import 'package:agent/main.dart' as app;
import 'package:agent/models.dart';
import 'package:agent/screens/auth_screen.dart';
import 'package:agent/screens/bot_activity_screen.dart';
import 'package:agent/screens/offices_screen.dart';
import 'package:agent/services/bot_status.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('QA_EMAIL');
const _pw = String.fromEnvironment('QA_PW');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat bughunt 4: teams', (tester) async {
    void log(String s) => print(s);
    final testStart = DateTime.now();
    // Hard budget for the whole harness: after this every remaining step is skipped (the job also has a timeout).
    const budget = Duration(minutes: 80);
    bool overBudget() => DateTime.now().difference(testStart) > budget;

    String visible() {
      final out = <String>[];
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText().trim();
        if (s.isNotEmpty && !out.contains(s)) out.add(s);
      }
      return out.join(' ¦ ').replaceAll('\n', ' ');
    }

    // ---------------------------------------------------------------- guard: never hang on a question
    final seenAsk = <String, DateTime>{};
    var lastGuard = DateTime.fromMillisecondsSinceEpoch(0);
    var guarding = false;
    Future<void> guard() async {
      if (guarding || DateTime.now().difference(lastGuard).inMilliseconds < 1500) return;
      guarding = true;
      lastGuard = DateTime.now();
      try {
        for (final a in List.of(Offices.I.pending)) {
          final seen = seenAsk.putIfAbsent(a.id, () {
            log('CB:approval|waiting: "${a.title}" kind=${a.kind} bot=${Bots.I.byId(a.botId)?.name} office=${a.officeId}');
            return DateTime.now();
          });
          if (DateTime.now().difference(seen).inSeconds >= 20) {
            log('CB:approval|harness answered Not now after 20 s: "${a.title}"');
            seenAsk.remove(a.id);
            await Offices.I.answer(a.id, false);
          }
        }
        final nn = find.text('Not now');
        if (nn.evaluate().isNotEmpty) {
          final v = visible();
          log('CB:sheet|harness tapped Not now on screen: ${v.length > 300 ? v.substring(0, 300) : v}');
          await tester.tap(nn.last, warnIfMissed: false);
        }
      } catch (e) {
        log('QA: guard: $e');
      } finally {
        guarding = false;
      }
    }

    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 50));
        final e = tester.takeException();
        if (e != null) log('QAERR: exception: ${e.toString().split('\n').first}');
        await guard();
      }
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
      if (overBudget()) {
        log('QA: skip $what (harness budget of ${budget.inMinutes} min used)');
        return;
      }
      final t0 = DateTime.now();
      log('QA: start $what');
      try {
        await f();
        log('QA: ok $what (${DateTime.now().difference(t0).inSeconds}s)');
      } catch (e, s) {
        log('QAERR: $what: ${e.toString().split('\n').take(2).join(' ')} ${s.toString().split('\n').take(2).join(' ')}');
        try {
          await shot('err_${what.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}');
        } catch (_) {}
      }
    }

    Future<void> backHome() async {
      for (var i = 0; i < 6 && app.appNavKey.currentState!.canPop(); i++) {
        app.appNavKey.currentState!.pop();
        await wait(700);
      }
    }

    Future<void> adb(String cmd, {int ms = 9000}) async {
      log('ADB:$cmd');
      await wait(ms);
    }

    // ---------------------------------------------------------------- start and sign in (round-3 harness)
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
    if (find.text('Agree and continue').evaluate().isNotEmpty) {
      log('QAERR: FATAL consent gate blocks the app; stopping');
      return;
    }
    await backHome();
    // No app or phone control in this run (CB-42 froze round 3 by driving Gmail).
    st().setAgentEnabled(false);
    for (var i = 0; i < 30 && TeamRun.I.llm == null; i++) {
      await wait(1000);
    }
    await shot('00_home');

    // ---------------------------------------------------------------- wrap the team wire (counts, tool log, failure switch)
    final calls = <String, int>{};
    final raw = <String, int>{};
    final toolsBy = <String, List<String>>{};
    String? failBot; // tool failure injection for one member (c4)
    final origLlm = TeamRun.I.llm;
    final origTool = TeamRun.I.runTool;
    final origAsk = TeamRun.I.approvalFor;
    final blocked = RegExp(r'^(open_app|phone_|screen_|whatsapp|sms|call_|app_settings|browser)');
    if (origLlm == null || origTool == null) {
      log('QAERR: TeamRun is not wired (llm=${origLlm != null} runTool=${origTool != null})');
    } else {
      TeamRun.I.llm = (Bot b, Turn t, {int maxTokens = 1500}) async {
        calls[b.name] = (calls[b.name] ?? 0) + 1;
        final t0 = DateTime.now();
        try {
          final r = await origLlm(b, t, maxTokens: maxTokens);
          raw[b.name] = (raw[b.name] ?? 0) + r.tokens;
          log('LLM:${b.name}|step=${t.step} ms=${DateTime.now().difference(t0).inMilliseconds} in=${r.tokensIn} out=${r.tokensOut} '
              'tools=${t.tools?.length ?? 0} calls=${r.toolCalls.map((c) => c.name).join(',')} fin=${r.finishReason} chars=${r.content.length}');
          return r;
        } catch (e) {
          log('LLM:${b.name}|step=${t.step} ERROR ${e.toString().split('\n').first}');
          rethrow;
        }
      };
      TeamRun.I.approvalFor = (Bot b, ToolCall c, Map<String, dynamic> args) async {
        if (blocked.hasMatch(c.name)) return null;
        return origAsk == null ? null : origAsk(b, c, args);
      };
      TeamRun.I.runTool = (Bot b, ToolCall c, Map<String, dynamic> args, {Object? approved}) async {
        (toolsBy[b.name] ??= []).add(c.name);
        if (blocked.hasMatch(c.name)) {
          log('TOOL:${b.name}|${c.name} BLOCKED by harness');
          return 'Error: ${c.name} is not available in this test run.';
        }
        if (failBot == b.id) {
          log('TOOL:${b.name}|${c.name} INJECTED FAILURE');
          return 'Error in ${c.name}: the service is unavailable right now (HTTP 503).';
        }
        final a = jsonEncode(args);
        final out = await origTool(b, c, args, approved: approved);
        log('TOOL:${b.name}|${c.name} ${a.length > 140 ? a.substring(0, 140) : a} -> ${out.length} chars${out.startsWith('Error') ? ' ERR ${out.substring(0, out.length > 120 ? 120 : out.length)}' : ''}');
        return out;
      };
    }

    // ---------------------------------------------------------------- team helpers
    bool teamBusy(Office o) =>
        TeamRun.I.busy(o) || Offices.I.queue.any((j) => j.officeId == o.id) || o.members.any((id) => Offices.I.isWorking?.call(id) ?? false);
    String ring(Office o) => BotStatus.I.of(BotStatus.teamKey(o.id)).toString();
    String who(String id) => id == 'you' ? 'You' : (id == 'system' ? 'System' : (Bots.I.byId(id)?.name ?? id));
    String postsOf(Office o, [int from = 0, int cut = 500]) => o.posts.skip(from).map((p) {
          final t = p.text.replaceAll('\n', '⏎');
          return '${who(p.from)}(${p.kind})@${p.at.toUtc().toIso8601String().substring(11, 19)}: ${t.length > cut ? '${t.substring(0, cut)}…(${t.length})' : t}'
              '${p.parts.isEmpty ? '' : ' [parts:${p.parts.length}]'}';
        }).join(' ¦ ');
    Map<String, int> snap() => {...calls};
    Map<String, int> diff(Map<String, int> a) => {for (final k in calls.keys) if ((calls[k] ?? 0) - (a[k] ?? 0) > 0) k: (calls[k] ?? 0) - (a[k] ?? 0)};

    Future<void> openTeam(Office o) async {
      await backHome();
      unawaited(app.appNavKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => TeamChat(office: o))));
      await wait(2500);
    }

    Future<void> say(Office o, String text) async {
      final box = find.byType(TextField);
      final send = find.byIcon(Icons.arrow_upward_rounded);
      if (box.evaluate().isNotEmpty && send.evaluate().isNotEmpty) {
        await tester.tap(box.last, warnIfMissed: false);
        await wait(300);
        await tester.enterText(box.last, text);
        await wait(500);
        await tester.tap(send.last, warnIfMissed: false);
        await wait(800);
        if (!o.posts.any((p) => p.from == 'you' && p.text == text.trim())) {
          log('QA: UI send did not post; sending through TeamRun.send');
          TeamRun.I.send(o, text);
        }
      } else {
        log('QA: no team composer on screen; sending through TeamRun.send');
        TeamRun.I.send(o, text);
      }
      log('QA: owner said "${text.length > 80 ? text.substring(0, 80) : text}" busy=${TeamRun.I.busy(o)} awaitingGo=${TeamRun.I.awaitingGo(o)}');
    }

    /// Waits until the team is quiet for [quietS] seconds (or [maxS] passes). Logs busy/ring transitions.
    Future<int> settleTeam(Office o, {int maxS = 420, int quietS = 25, bool Function()? until}) async {
      final t0 = DateTime.now();
      var quiet = 0;
      var last = '';
      await wait(2000);
      while (DateTime.now().difference(t0).inSeconds < maxS) {
        final b = teamBusy(o);
        final s = 'run=${TeamRun.I.busy(o)} queue=${Offices.I.queue.where((j) => j.officeId == o.id).length} ring=${ring(o)} go=${TeamRun.I.awaitingGo(o)}';
        if (s != last) {
          log('QA: team state +${DateTime.now().difference(t0).inSeconds}s $s posts=${o.posts.length}');
          last = s;
        }
        if (until != null && until()) break;
        if (TeamRun.I.awaitingGo(o)) break;
        quiet = b ? 0 : quiet + 1;
        if (quiet >= quietS) break;
        await wait(1000);
      }
      final secs = DateTime.now().difference(t0).inSeconds;
      if (secs >= maxS) log('QAERR: team still busy after ${maxS}s: ${TeamRun.I.running} queue=${Offices.I.queue.length}');
      return secs;
    }

    void record(String name, Office o, DateTime t0, int n0, Map<String, int> c0, [Map<String, Object?> extra = const {}]) {
      final posts = o.posts.skip(n0).toList();
      final answer = posts.where((p) => p.kind == 'answer').lastOrNull;
      final j = <String, Object?>{
        't0': t0.toUtc().toIso8601String(),
        't1': DateTime.now().toUtc().toIso8601String(),
        'secs': DateTime.now().difference(t0).inSeconds,
        'calls': diff(c0),
        'posts': posts.length,
        'byKind': {for (final k in posts.map((p) => p.kind).toSet()) k: posts.where((p) => p.kind == k).length},
        'answerChars': answer?.text.length ?? 0,
        'answerParts': answer?.parts.length ?? 0,
        'answerHasTable': answer != null && RegExp(r'^\s*\|.*\|', multiLine: true).hasMatch(answer.text),
        ...extra,
      };
      log('T:$name|${jsonEncode(j)}');
      log('POSTS:$name|${postsOf(o, n0)}');
    }

    // ================================================================ c0: create a team with a lead and 3 members
    Office? team;
    Bot? lead, nova, amina, faisal;
    await step('c0_create', () async {
      lead = await st().hireForJob({'name': 'Hodan', 'role': 'Project lead', 'mission': 'Plans the work, hands out parts and writes the final answer.'});
      nova = await st().hireForJob({'name': 'Nova', 'role': 'Researcher', 'mission': 'Finds facts, prices and specs on the web, with sources.'});
      amina = await st().hireForJob({'name': 'Amina', 'role': 'Analyst', 'mission': 'Compares options and builds clear tables.'});
      faisal = await st().hireForJob({'name': 'Faisal', 'role': 'Writer', 'mission': 'Writes clear emails and summaries.'});
      final ids = [lead!.id, nova!.id, amina!.id, faisal!.id];
      final err = await st().prepareOfficeBots(ids);
      log('CB:c0|prepare=$err convs=${[for (final id in ids) Bots.I.byId(id)?.convId.isNotEmpty].toList()}');
      team = await Offices.I.create(name: 'Laptop team', members: ids, chiefId: lead!.id);
      await openTeam(team!);
      log('CB:c0|intro posts: ${postsOf(team!)}');
      log('CB:c0|member tools: ${[for (final id in ids) '${Bots.I.byId(id)?.name}=${TeamRun.I.toolsFor?.call(Bots.I.byId(id)!).length ?? -1}'].join(' ')}');
      await shot('c0_team_created');
    });

    // ================================================================ c1 + c2: a real three-part job, plus a second request while it works
    await step('c1_job', () async {
      final o = team;
      if (o == null) throw 'no team';
      final t0 = DateTime.now();
      final n0 = o.posts.length;
      final c0 = snap();
      await say(o,
          'Team, I need three things: 1) research 3 laptops under \$1000 for a university student (current US price, CPU, RAM, battery life, weight) '
          'with sources, 2) compare them in a table, 3) write a short summary email to my brother recommending one. '
          'Only show me the email draft here, do not send it.');
      // CB-36: does the lead post a plan, and does it wait for a go-ahead as the intro promised?
      var planAt = -1;
      var secondSent = false;
      var n2 = 0;
      final t1 = DateTime.now();
      var quiet = 0;
      var sawRun = false;
      while (DateTime.now().difference(t1).inSeconds < 600) {
        final s = DateTime.now().difference(t1).inSeconds;
        final plan = o.posts.skip(n0).where((p) => p.from == lead!.id && RegExp(r'The plan:|Qorshaha:').hasMatch(p.text)).firstOrNull;
        if (plan != null && planAt < 0) {
          planAt = s;
          log('CB:c1|plan posted after ${s}s awaitingGo=${TeamRun.I.awaitingGo(o)} busy=${TeamRun.I.busy(o)}');
          await shot('c1_plan');
        }
        if (TeamRun.I.awaitingGo(o)) {
          log('CB:c1|lead waits for a go-ahead after ${s}s; answering Go');
          await shot('c1_waiting_go');
          await say(o, 'Go');
        }
        if (TeamRun.I.busy(o)) sawRun = true;
        // CB-37: a second, unrelated request once the team is working (a member hand-off is in the chat or 40 s passed).
        final handOff = o.posts.skip(n0).any((p) => p.from == lead!.id && p.text.contains(':') && p.text != plan?.text && p.kind != 'answer');
        if (!secondSent && (handOff || s > 40) && teamBusy(o)) {
          secondSent = true;
          n2 = o.posts.length;
          log('CB:c2|second request sent at ${s}s run=${TeamRun.I.busy(o)} ring=${ring(o)}');
          await say(o, 'Separate question for anyone: what is 15% of 2,400? Just the number.');
          await shot('c2_second_request');
        }
        final b = teamBusy(o);
        quiet = b ? 0 : quiet + 1;
        if (quiet >= 30 && s > 30) break;
        await wait(1000);
      }
      log('CB:c1|planAt=$planAt sawTeamRun=$sawRun answer=${o.posts.skip(n0).any((p) => p.kind == 'answer')} busyNow=${teamBusy(o)}');
      if (secondSent) {
        final after = o.posts.skip(n2).where((p) => p.from != 'you').toList();
        final hit = after.where((p) => RegExp(r'\b360\b').hasMatch(p.text)).toList();
        log('CB:c2|second answered (360) = ${hit.isNotEmpty} by ${hit.map((p) => '${who(p.from)}/${p.kind}').toList()} posts after it=${after.length}');
      } else {
        log('CB:c2|second request never sent (team was not busy)');
      }
      record('c1_job', o, t0, n0, c0, {'planAt': planAt, 'tools': toolsBy});
      final ans = o.posts.skip(n0).where((p) => p.kind == 'answer').lastOrNull;
      if (ans != null) {
        log('ANSWER:c1|${ans.text.replaceAll('\n', '⏎')}');
        for (final p in ans.parts) {
          log('PART:c1|${who(p.from)}|${p.text.replaceAll('\n', '⏎').substring(0, p.text.length > 1500 ? 1500 : p.text.length)}');
        }
      }
      await shot('c1_end');
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.dragFrom(Offset(size.width / 2, size.height * 0.3), const Offset(0, 900));
      await wait(1200);
      await shot('c1_end_up');
    });

    // If c2's second request is answered only later, give it one more look.
    await step('c2_check', () async {
      final o = team;
      if (o == null) throw 'no team';
      await settleTeam(o, maxS: 90, quietS: 15);
      final mine = o.posts.lastIndexWhere((p) => p.from == 'you' && p.text.startsWith('Separate question'));
      if (mine < 0) return;
      final after = o.posts.skip(mine + 1).toList();
      log('CB:c2|final look: answered(360)=${after.any((p) => p.from != 'you' && RegExp(r'\b360\b').hasMatch(p.text))} '
          'system="${after.where((p) => p.kind == 'system').map((p) => p.text).join(' / ')}"');
    });

    // ================================================================ c3: owner Stop mid-job (CB-34, CB-19)
    await step('c3_stop', () async {
      final o = team;
      if (o == null) throw 'no team';
      await settleTeam(o, maxS: 120, quietS: 10);
      final t0 = DateTime.now();
      final n0 = o.posts.length;
      final c0 = snap();
      await say(o, 'Team, research the 4 best co-working spaces in Nairobi with monthly prices, compare them in a table and recommend one.');
      // Stop once a member is working on its part (a hand-off is posted) or after 75 s.
      final t1 = DateTime.now();
      while (DateTime.now().difference(t1).inSeconds < 75) {
        if (TeamRun.I.awaitingGo(o)) await say(o, 'Go');
        final handed = o.posts.skip(n0).where((p) => p.from == lead!.id).length >= 2;
        if (handed && TeamRun.I.busy(o)) break;
        await wait(1000);
      }
      final before = {'run': TeamRun.I.busy(o), 'any': teamBusy(o), 'ring': ring(o), 'cores': TeamRun.I.coresFor(o.id)};
      await say(o, 'stop');
      final nStop = o.posts.length;
      final stopAt = DateTime.now();
      log('CB:c3|stop sent after ${stopAt.difference(t1).inSeconds}s state before=$before');
      await wait(3000);
      log('CB:c3|3 s after stop: run=${TeamRun.I.busy(o)} any=${teamBusy(o)} ring=${ring(o)} cores=${TeamRun.I.coresFor(o.id)}');
      await shot('c3_after_stop');
      final c1 = snap();
      var lastBusy = 0;
      for (var i = 0; i < 90; i++) {
        if (teamBusy(o) || ring(o).contains('working')) lastBusy = i;
        await wait(1000);
      }
      final after = o.posts.skip(nStop).toList();
      log('CB:c3|posts after stop=${after.length}: ${after.map((p) => '${who(p.from)}(${p.kind})@+${p.at.difference(stopAt).inSeconds}s:${p.text.length > 100 ? p.text.substring(0, 100) : p.text}').toList()}');
      log('CB:c3|model calls after stop=${diff(c1)} busy last seen at +${lastBusy}s ring now=${ring(o)} run=${TeamRun.I.busy(o)}');
      record('c3_stop', o, t0, n0, c0);
      await shot('c3_end');
    });

    // ================================================================ c4: a member tool failure (injected) and a network cut
    await step('c4_member_error', () async {
      final o = team;
      if (o == null) throw 'no team';
      await settleTeam(o, maxS: 90, quietS: 10);
      final t0 = DateTime.now();
      final n0 = o.posts.length;
      final c0 = snap();
      failBot = nova!.id;
      await say(o, 'Team, find the current price of a Dell XPS 13 and a MacBook Air M3 in the US and tell me which is cheaper.');
      await settleTeam(o, maxS: 300, quietS: 25);
      failBot = null;
      record('c4_tool_fail', o, t0, n0, c0, {'tools': toolsBy[nova!.name]});
      await shot('c4_tool_fail_end');
      // A network cut while a member works.
      final t1 = DateTime.now();
      final n1 = o.posts.length;
      final c1 = snap();
      await say(o, 'Team, give me a 5-item packing list for a 2-day work trip to Mogadishu, and a one-line weather note.');
      final t2 = DateTime.now();
      while (DateTime.now().difference(t2).inSeconds < 60) {
        if (TeamRun.I.awaitingGo(o)) await say(o, 'Go');
        if (o.posts.skip(n1).where((p) => p.from == lead!.id).length >= 2) break;
        await wait(1000);
      }
      await adb('net_off');
      log('CB:c4|net off at +${DateTime.now().difference(t1).inSeconds}s run=${TeamRun.I.busy(o)}');
      await wait(40000);
      await shot('c4_offline');
      await adb('net_on');
      await settleTeam(o, maxS: 240, quietS: 25);
      record('c4_net_cut', o, t1, n1, c1);
      await shot('c4_net_end');
    });

    // ================================================================ c5: app to the background mid-job, then reopened; notifications
    await step('c5_background', () async {
      final o = team;
      if (o == null) throw 'no team';
      await settleTeam(o, maxS: 90, quietS: 10);
      final t0 = DateTime.now();
      final n0 = o.posts.length;
      final c0 = snap();
      await say(o, 'Team, compare the 3 cheapest ways to send \$200 from the US to Somalia (fees and speed) in a table, and recommend one.');
      final t1 = DateTime.now();
      while (DateTime.now().difference(t1).inSeconds < 60) {
        if (TeamRun.I.awaitingGo(o)) await say(o, 'Go');
        if (o.posts.skip(n0).where((p) => p.from == lead!.id).length >= 2) break;
        await wait(1000);
      }
      final pre = o.posts.length;
      // The capture script presses HOME, waits 60 s, saves the notification list, then starts SubMac again.
      log('CB:c5|to background at +${DateTime.now().difference(t0).inSeconds}s run=${TeamRun.I.busy(o)} posts=$pre');
      await adb('bg_60', ms: 75000);
      log('CB:c5|back after +${DateTime.now().difference(t0).inSeconds}s posts=${o.posts.length} (+${o.posts.length - pre} while away) run=${TeamRun.I.busy(o)} '
          'viewingOffice=${st().viewingOffice} appVisible=${st().appVisible}');
      await shot('c5_reopened');
      await settleTeam(o, maxS: 300, quietS: 25);
      record('c5_background', o, t0, n0, c0);
      await shot('c5_end');
      // Notifications when the team answers while the owner is elsewhere: leave the team chat, then ask.
      await backHome();
      final n1 = o.posts.length;
      TeamRun.I.send(o, '@Faisal write one sentence thanking the team.');
      await settleTeam(o, maxS: 150, quietS: 20);
      await adb('notif_dump', ms: 4000);
      log('CB:c11|reply while away posted=${o.posts.length - n1} unread=${o.unread} ring=${ring(o)}');
    });

    // ================================================================ c6: step caps and usage counters (CB-20)
    await step('c6_usage', () async {
      for (final b in [lead, nova, amina, faisal].whereType<Bot>()) {
        log('CB:c6|bot ${b.name}: tokensToday(raw, shown in Bot Activity)=${b.tokensTodayNow} budgetK=${b.tokenBudgetK} harnessRaw=${raw[b.name] ?? 0} calls=${calls[b.name] ?? 0} '
            'line="${BotActivityScreen.usageLine(b)}"');
      }
      log('CB:c6|memberSteps cap=${TeamRun.memberSteps} maxParts=${TeamRun.maxParts}');
      final b = nova;
      if (b != null) {
        await backHome();
        unawaited(app.appNavKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => BotActivityScreen(bot: b))));
        await wait(2500);
        await shot('c6_bot_activity_nova');
        await backHome();
      }
    });

    // ================================================================ c7: delete the team while it runs
    await step('c7_delete_running', () async {
      final l = lead, n = nova;
      if (l == null || n == null) throw 'no bots';
      final o = await Offices.I.create(name: 'Temp team', members: [l.id, n.id], chiefId: l.id);
      await openTeam(o);
      final t0 = DateTime.now();
      final c0 = snap();
      await say(o, 'Team, research 3 budget hotels in Hargeisa with prices and compare them in a table.');
      final t1 = DateTime.now();
      while (DateTime.now().difference(t1).inSeconds < 60) {
        if (TeamRun.I.awaitingGo(o)) await say(o, 'Go');
        if (o.posts.where((p) => p.from == l.id).length >= 2 && TeamRun.I.busy(o)) break;
        await wait(1000);
      }
      final pre = o.posts.length;
      log('CB:c7|deleting at +${DateTime.now().difference(t0).inSeconds}s run=${TeamRun.I.busy(o)} cores=${TeamRun.I.coresFor(o.id)}');
      await backHome();
      await Offices.I.remove(o);
      final c1 = snap();
      final del = DateTime.now();
      for (var i = 0; i < 120; i++) {
        await wait(1000);
      }
      log('CB:c7|after delete: running=${TeamRun.I.running.contains(o.id)} cores=${TeamRun.I.coresFor(o.id)} byId=${Offices.I.byId(o.id) != null} '
          'posts on the deleted team=${o.posts.length - pre} calls after delete=${diff(c1)} queue=${Offices.I.queue.where((j) => j.officeId == o.id).length} '
          'pending approvals=${Offices.I.pending.where((a) => a.officeId == o.id).length} secs=${DateTime.now().difference(del).inSeconds}');
      log('POSTS:c7|${postsOf(o, pre)}');
      log('T:c7_delete|${jsonEncode({'t0': t0.toUtc().toIso8601String(), 't1': DateTime.now().toUtc().toIso8601String(), 'calls': diff(c0)})}');
      await shot('c7_after_delete');
    });

    // ================================================================ c8: Somali and Arabic
    await step('c8_somali', () async {
      final o = team;
      if (o == null) throw 'no team';
      await openTeam(o);
      await settleTeam(o, maxS: 60, quietS: 8);
      final t0 = DateTime.now();
      final n0 = o.posts.length;
      final c0 = snap();
      await say(o, 'Kooxda, fadlan soo baadha 3 telefoon oo qiimahoodu ka hooseeyo \$300, isku barbar dhiga shax, kadibna ii sheega midka ugu fiican.');
      await settleTeam(o, maxS: 360, quietS: 25);
      record('c8_somali', o, t0, n0, c0);
      await shot('c8_somali_end');
    });
    await step('c9_arabic', () async {
      final o = team;
      if (o == null) throw 'no team';
      final t0 = DateTime.now();
      final n0 = o.posts.length;
      final c0 = snap();
      await say(o, 'يا فريق، قارنوا بين ثلاث سماعات لاسلكية بسعر أقل من 100 دولار في جدول، ثم أوصوني بواحدة.');
      await settleTeam(o, maxS: 360, quietS: 25);
      record('c9_arabic', o, t0, n0, c0);
      await shot('c9_arabic_end');
    });

    // ================================================================ end
    await step('z_totals', () async {
      log('CB:z|harness calls=$calls raw=$raw tools=${toolsBy.map((k, v) => MapEntry(k, v.length))}');
      log('CB:z|offices=${Offices.I.offices.map((o) => '${o.name}:${o.posts.length}').toList()} pending=${Offices.I.pending.length} '
          'elapsed=${DateTime.now().difference(testStart).inMinutes}min');
    });
    await backHome();
    await shot('zz_end');
  }, timeout: const Timeout(Duration(minutes: 95)));
}
