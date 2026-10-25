// SubMac chat regression harness on a real Android emulator (PR-H, branch qa/chat-regress, 2026-10-25).
// Test infrastructure only: never part of the normal unit-test run (integration_test/ is driven by
// tools/chat_regress_capture.sh from .github/workflows/chat-regress-emu.yml).
//
// It consolidates the round-3 (chat_bughunt3/3b) and round-4 (chat_bughunt4_bots / _teams) harnesses into three phases:
//   A  main chat   - stop/steer/fake tool/cut stream/cards/asks/approvals/try again/photos/paste/drafts/delete-all
//   B  bots        - create/edit/render/routines/double fire/wake + owner message/workspace/telegram/deletes/doze
//   C  teams       - plan + go-ahead/second request/stop/delete running/background/Arabic
// and, after the drive, the cold-start phases P2 (force-stop, CB-21) and P3 (process kill, CB-46) run by the script.
//
// Safety and reliability (fix plan section 3):
//   * consent: the 18+/Terms box is ticked in the UI and "Agree and continue" tapped; the composer must exist before
//     any step, or the run stops with a FATAL;
//   * approvals: per-step scripted answers; a watchdog answers any other approval sheet, team approval or ask_user with
//     "Not now" after 20-25 s and logs "QAWARN unanswered-ask <title>"; the CB-41 step holds its ask on purpose;
//   * no other-app tasks: "Let it take action" is off, bots and team members get the phone/apps/browser powers off,
//     team tool calls to app/phone/browser tools are refused, and ADB:front brings SubMac back if it loses the front;
//   * every step has a hard timeout; a stall detector fails a step after 5 min with no log line, no app progress and no
//     new charge (billing_usage moves when ai-chat writes an ai_usage row; ai_usage itself is not readable by a user);
//   * a step that times out or stalls is cut off (its zone generation is retired), its runs are stopped, and the run
//     goes on with the next step; per-phase time budgets skip what does not fit.
//
// Output lines (parsed by tools/chat_regress_capture.sh):
//   CB-<n> PASS|FAIL|SKIP|<detail>   one per assertion; PASS means the fixed behaviour, FAIL means the bug is still there
//   QA: ... / QAWARN ... / QAERR: ...   harness progress / warnings / errors (any QAERR fails the job)
//   QA: STEPFAIL <phase>/<step>      a step threw, timed out or stalled (fails the job)
//   PHASE <X>: ...                   per-phase summary at the end
//   SHOT:<name>  SEE:<name>|...  T:<task>|<json>  MSGS:<task>|...  POSTS:<task>|...  ADB:<cmd>  PHASE2_DUE:<epoch s>
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:agent/agent/core.dart' show Turn;
import 'package:agent/app_state.dart';
import 'package:agent/main.dart' as app;
import 'package:agent/models.dart';
import 'package:agent/screens/auth_screen.dart';
import 'package:agent/screens/bot_activity_screen.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:agent/screens/offices_screen.dart';
import 'package:agent/services/bot_powers.dart';
import 'package:agent/services/bot_status.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/choices.dart';
import 'package:agent/services/context_window.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:agent/services/telegram_bridge.dart';
import 'package:agent/widgets/ask_bar.dart';
import 'package:agent/widgets/chat/message_actions.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('QA_EMAIL');
const _pw = String.fromEnvironment('QA_PW');
/// Phases to run, e.g. "ABC" (default), "A", "BC". K (the force-stop arm for P2/P3) runs when B is on.
const _phases = String.fromEnvironment('QA_PHASES', defaultValue: 'ABC');
/// Per-phase time budgets in minutes; a step that would start after its phase budget is skipped (logged, not a failure).
const _budgetA = int.fromEnvironment('QA_BUDGET_A', defaultValue: 38);
const _budgetB = int.fromEnvironment('QA_BUDGET_B', defaultValue: 28);
const _budgetC = int.fromEnvironment('QA_BUDGET_C', defaultValue: 20);
/// No log line, no app progress and no new charge for this long fails the running step.
const _stallSecs = int.fromEnvironment('QA_STALL_SECS', defaultValue: 300);
const _marker = '/data/user/0/com.submac.agent/files/qa_regress_phase.txt';
final _blocked = RegExp(r'^(open_app|phone_|screen_|whatsapp|sms|call_|app_settings|browser)');

String _hm(DateTime at) => '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

// ================================================================================================ transport seam
/// Wraps the app's one model HTTP client (LlmClient.testClient). No app code changes: it only rewrites what one
/// marked request sends back, and counts request sizes.
class _Seam extends http.BaseClient {
  _Seam(this.inner);
  final http.Client inner;

  /// CB-3: the first model request whose body has this marker gets a tool call to a tool the app does not have.
  String? fakeToolMarker;
  String fakeToolName = 'functions.lookup_shop_hours';
  bool fakeSent = false;

  /// CB-10: the first streamed model request whose body has this marker is cut after [cutAfter] content chars with
  /// finish_reason "length" (what the server's cutTail sends on an upstream hiccup).
  String? cutMarker;
  int cutAfter = 280;
  bool cutDone = false;

  /// CB-30 / CB-26: request counting.
  String? countMarker;
  int countHits = 0;
  int maxBody = 0;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest req) async {
    requests++;
    final body = req is http.Request ? req.body : '';
    if (body.length > maxBody) maxBody = body.length;
    if (countMarker != null && body.length > 100000 && body.contains(countMarker!)) countHits++;
    final fm = fakeToolMarker;
    if (fm != null && body.contains(fm) && !body.contains('"role":"tool"')) {
      fakeToolMarker = null;
      fakeSent = true;
      print('QA: seam sent a fake tool call "$fakeToolName"');
      return _sse(req, [
        {
          'choices': [
            {
              'index': 0,
              'delta': {
                'role': 'assistant',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_cb3',
                    'type': 'function',
                    'function': {'name': fakeToolName, 'arguments': '{"shop":"Hamarweyne"}'},
                  }
                ],
              },
              'finish_reason': null,
            }
          ],
        },
        {
          'choices': [
            {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'}
          ],
          'usage': {'prompt_tokens': 12, 'completion_tokens': 6},
        },
      ]);
    }
    final resp = await inner.send(req);
    final cm = cutMarker;
    if (cm != null && body.contains(cm) && body.contains('"stream":true') && resp.statusCode == 200) {
      cutMarker = null;
      return _cut(req, resp);
    }
    return resp;
  }

  http.StreamedResponse _sse(http.BaseRequest req, List<Map<String, dynamic>> events) {
    final sb = StringBuffer(': ping\n\n');
    for (final e in events) {
      sb.write('data: ${jsonEncode(e)}\n\n');
    }
    sb.write('data: [DONE]\n\n');
    return http.StreamedResponse(Stream<List<int>>.value(utf8.encode(sb.toString())), 200,
        headers: {'content-type': 'text/event-stream'}, request: req);
  }

  http.StreamedResponse _cut(http.BaseRequest req, http.StreamedResponse resp) {
    final out = StreamController<List<int>>();
    var chars = 0;
    late StreamSubscription<String> sub;
    void finish() {
      if (out.isClosed) return;
      cutDone = true;
      print('QA: seam cut the stream after $chars content chars (finish_reason=length)');
      out.add(utf8.encode('data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'length'}
            ]
          })}\n\ndata: [DONE]\n\n'));
      out.close();
      unawaited(sub.cancel());
    }

    sub = resp.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (out.isClosed) return;
      out.add(utf8.encode('$line\n'));
      final t = line.trim();
      if (t.startsWith('data:') && t.length > 6 && !t.endsWith('[DONE]')) {
        try {
          final j = jsonDecode(t.substring(5).trim()) as Map<String, dynamic>;
          final ch = j['choices'] as List?;
          final c = ch == null || ch.isEmpty ? null : ((ch.first as Map)['delta'] as Map?)?['content'];
          if (c is String) chars += c.length;
        } catch (_) {}
      }
      if (t.isEmpty && chars >= cutAfter) finish();
    }, onDone: () {
      if (!out.isClosed) out.close();
    }, onError: (Object e) {
      if (!out.isClosed) {
        out.addError(e);
        out.close();
      }
    });
    return http.StreamedResponse(out.stream, resp.statusCode, headers: resp.headers, request: req);
  }
}

// ================================================================================================ cold starts (P2/P3)
/// A cold start after the capture script force-stopped (P2) or killed (P3) the app. Starts the app the normal way and
/// checks whether the bot routine that was due while the app was dead ran (CB-21 for P2, CB-46 for P3).
Future<void> _coldStart(String phase, List<String> m) async {
  final botId = m.length > 1 ? m[1] : '';
  final due = m.length > 2 ? DateTime.tryParse(m[2]) : null;
  print('$phase: cold start at ${DateTime.now().toIso8601String()} bot=$botId due=$due');
  app.main();
  final id = phase == 'P2' ? 'CB-21' : 'CB-46';
  var n = 0;
  var said = false;
  var armed = false;
  Timer.periodic(const Duration(seconds: 15), (t) async {
    n++;
    final b = Bots.I.byId(botId);
    if (b == null) {
      print('$phase: t=${n * 15}s bot not loaded yet (bots=${Bots.I.bots.length})');
    } else {
      final woke = due != null && b.lastWake != null && !b.lastWake!.isBefore(due.subtract(const Duration(seconds: 5)));
      print('$phase: t=${n * 15}s lastWake=${b.lastWake} woke=$woke journal=${b.journal.reversed.take(3).map((e) => '${e.at.toIso8601String().substring(11, 19)} ${e.kind}').toList()} '
          'traces=${BotTraces.I.of(b.id).length} nextWork=${Bots.I.nextWork(b)}');
      if (!said && (woke || n >= 9)) {
        said = true;
        print('$id ${woke ? 'PASS' : 'FAIL'}|$phase routine due $due ran after the ${phase == 'P2' ? 'force-stop + relaunch' : 'process kill'}: lastWake=${b.lastWake} (checked ${n * 15}s after start)');
      }
      // P2 arms the P3 test (a routine that falls due while the process is dead) once its own verdict is in.
      if (phase == 'P2' && said && !armed) {
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
    if (n >= 24 || (said && phase == 'P3')) {
      t.cancel();
      if (!said) print('$id SKIP|$phase bot never loaded');
      if (phase == 'P3') {
        try {
          File(_marker).deleteSync();
        } catch (_) {}
      }
      print('$phase: end of observation');
    }
  });
}

// ================================================================================================ the harness
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

  testWidgets('chat regress: A main chat, B bots, C teams', (tester) async {
    final testStart = DateTime.now();
    var lastActivity = DateTime.now();
    void log(String s) {
      lastActivity = DateTime.now();
      print(s);
    }

    // ---------------------------------------------------------------------------------------- state and results
    var phase = '-';
    final phaseStart = <String, DateTime>{};
    final budgets = {'A': _budgetA, 'B': _budgetB, 'C': _budgetC, 'K': 5};
    final stepsOk = <String, int>{}, stepsFailed = <String, int>{}, stepsSkipped = <String, int>{};
    final cbRes = <String, Map<String, int>>{};
    var fatal = false;
    var exceptions = 0;
    var gen = 0; // generation of the step that may run; a cut-off step's leftovers see a different one and stop
    String? scripted; // the current step's answer to an ask_user (approval sheets get "Not now")
    var holdAsks = false; // CB-41 leaves its ask open on purpose
    var lostFront = 0;
    final seam = _Seam(http.Client());
    LlmClient.testClient = seam;

    void cb(String id, bool? pass, String detail) {
      final r = pass == null ? 'SKIP' : (pass ? 'PASS' : 'FAIL');
      (cbRes[phase] ??= {})[r] = ((cbRes[phase] ?? {})[r] ?? 0) + 1;
      log('$id $r|$phase ${detail.replaceAll('\n', ' ')}');
    }

    BuildContext ctx() => app.appNavKey.currentContext!;
    AppState st() => Provider.of<AppState>(ctx(), listen: false);

    String visible() {
      final out = <String>[];
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText().trim();
        if (s.isNotEmpty && !out.contains(s)) out.add(s);
      }
      return out.join(' ¦ ').replaceAll('\n', ' ');
    }

    // ---------------------------------------------------------------------------------------- watchdog
    final askSeen = <Object, DateTime>{};
    DateTime? sheetSince;
    var lastFront = DateTime(2000);
    var guarding = false;
    Future<void> watchdog() async {
      if (guarding) return;
      guarding = true;
      try {
        final now = DateTime.now();
        final life = WidgetsBinding.instance.lifecycleState;
        if (life != null && life != AppLifecycleState.resumed && now.difference(lastFront).inSeconds > 20) {
          lastFront = now;
          lostFront++;
          log('ADB:front');
          log('QAWARN not-in-front SubMac lifecycle=$life: asked the script to bring it back');
        }
        // Approval sheets (ConfirmQueue): a scripted step says no at once; anything else gets "Not now" after 20 s.
        final sheet = find.byType(BottomSheet);
        if (sheet.evaluate().isEmpty) {
          sheetSince = null;
        } else {
          sheetSince ??= now;
          if (scripted != null || now.difference(sheetSince!).inSeconds >= 20) {
            for (final t in ['Not now', "Don't send", 'Deny', "Don't allow", 'Cancel', 'No']) {
              final b = find.descendant(of: sheet, matching: find.text(t));
              if (b.evaluate().isNotEmpty) {
                final title = find.descendant(of: sheet, matching: find.byType(RichText)).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).take(3).join(' / ');
                if (scripted == null) {
                  log('QAWARN unanswered-ask $title (approval sheet, tapped "$t" after 20 s)');
                } else {
                  log('QA: scripted answer "$t" on approval sheet: $title');
                }
                await tester.tap(b.last, warnIfMissed: false);
                sheetSince = null;
                break;
              }
            }
          }
        }
        // ask_user and other asks.
        for (final a in List.of(st().asks)) {
          if (holdAsks) continue;
          final seen = askSeen.putIfAbsent(a, () => now);
          final sc = scripted;
          if (sc != null && a.kind == 'text') {
            log('QA: scripted answer "$sc" to ask "${a.title}"');
            st().answerAsk(a, {'answer': sc});
          } else if (now.difference(seen).inSeconds >= 25) {
            log('QAWARN unanswered-ask ${a.kind}:${a.title} (answered Not now after 25 s)');
            st().answerAsk(a, null);
          }
        }
        // Team approvals.
        for (final a in List.of(Offices.I.pending)) {
          final seen = askSeen.putIfAbsent(a.id, () => now);
          if (now.difference(seen).inSeconds >= 20) {
            log('QAWARN unanswered-ask team:${a.title} (answered Not now after 20 s)');
            askSeen.remove(a.id);
            await Offices.I.answer(a.id, false);
          }
        }
      } catch (_) {
      } finally {
        guarding = false;
      }
    }

    // ---------------------------------------------------------------------------------------- stall detector
    // Activity = a log line, app progress (runs, messages, team posts, bot traces) or a new charge (billing_usage).
    String fingerprint() {
      try {
        final s = st();
        final runs = s.runs.map((r) => '${r.step}/${r.tokens}/${r.status}').join(',');
        final msgs = '${s.messages.length}:${s.messages.isEmpty ? 0 : s.messages.last.content.length}';
        final posts = Offices.I.offices.fold<int>(0, (a, o) => a + o.posts.length);
        final traces = Bots.I.bots.fold<int>(0, (a, b) => a + BotTraces.I.of(b.id).length);
        return '$runs|$msgs|$posts|$traces|${TeamRun.I.running.length}|${Offices.I.queue.length}';
      } catch (_) {
        return '';
      }
    }

    var lastPrint = '';
    var lastUsage = '';
    var usageAt = DateTime(2000);
    Completer<String?>? stepDone;
    Future<String> usage() async {
      try {
        final r = await Supabase.instance.client.rpc('billing_usage').timeout(const Duration(seconds: 15));
        if (r is Map) {
          final m = Map<String, dynamic>.from(r)..remove('plans');
          return jsonEncode(m);
        }
        return '$r';
      } catch (e) {
        return 'err';
      }
    }

    final stallTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      final fp = fingerprint();
      if (fp != lastPrint) {
        lastPrint = fp;
        lastActivity = DateTime.now();
      }
      if (DateTime.now().difference(usageAt).inSeconds >= 60) {
        usageAt = DateTime.now();
        final u = await usage();
        if (u != lastUsage && u != 'err') {
          if (lastUsage.isNotEmpty) lastActivity = DateTime.now();
          lastUsage = u;
        }
      }
      final idle = DateTime.now().difference(lastActivity).inSeconds;
      final d = stepDone;
      if (d != null && !d.isCompleted && idle >= _stallSecs) d.complete('§stall: no log line, no app progress and no new charge for ${idle}s');
    });

    // ---------------------------------------------------------------------------------------- basic helpers
    Future<void> wait(int ms) async {
      final my = Zone.current[#qaGen];
      final end = DateTime.now().add(Duration(milliseconds: ms));
      var tick = 0;
      while (DateTime.now().isBefore(end)) {
        if (my != null && my != gen) throw 'step cut off (timeout or stall)';
        await tester.pump(const Duration(milliseconds: 50));
        final e = tester.takeException();
        if (e != null) {
          exceptions++;
          log('QAERR: uncaught app exception: ${e.toString().split('\n').first}');
        }
        if (++tick % 30 == 0) await watchdog();
      }
    }

    Future<void> shot(String name) async {
      await wait(700);
      log('SHOT:$name');
      final v = visible();
      log('SEE:$name|${v.length > 900 ? v.substring(0, 900) : v}');
      await wait(1500);
    }

    void stopAll(String why) {
      try {
        final left = st().runs.toList();
        if (left.isEmpty) return;
        log('QA: stopping runs ($why): ${left.map((r) => '${r.title}/${r.status}').toList()}');
        for (final r in left) {
          r.stop();
        }
      } catch (_) {}
    }

    Future<void> backHome() async {
      for (var i = 0; i < 6 && (app.appNavKey.currentState?.canPop() ?? false); i++) {
        app.appNavKey.currentState!.pop();
        await wait(700);
      }
    }

    bool composer() => find.byType(TextField).evaluate().isNotEmpty || find.text('Ask SubMac anything').evaluate().isNotEmpty;

    bool phaseOver(String p) {
      final s = phaseStart[p];
      if (s == null) return false;
      if (DateTime.now().difference(testStart).inMinutes >= 88) return true;
      return DateTime.now().difference(s).inMinutes >= (budgets[p] ?? 30);
    }

    Future<void> step(String name, Future<void> Function() f, {int limit = 420}) async {
      if (fatal) return;
      if (phaseOver(phase)) {
        stepsSkipped[phase] = (stepsSkipped[phase] ?? 0) + 1;
        log('QA: SKIP $phase/$name (phase budget ${budgets[phase]} min used)');
        return;
      }
      final my = ++gen;
      final t0 = DateTime.now();
      lastActivity = t0;
      log('QA: start $phase/$name (limit ${limit}s)');
      final done = Completer<String?>();
      stepDone = done;
      final timer = Timer(Duration(seconds: limit), () {
        if (!done.isCompleted) done.complete('§hard timeout after ${limit}s');
      });
      runZoned(() => f(), zoneValues: {#qaGen: my}).then((_) {
        if (!done.isCompleted) done.complete(null);
      }, onError: (Object e, StackTrace s) {
        if (!done.isCompleted) done.complete('${e.toString().split('\n').take(2).join(' ')} @ ${s.toString().split('\n').take(2).join(' ')}');
      });
      final err = await done.future;
      timer.cancel();
      stepDone = null;
      if (err == null) {
        stepsOk[phase] = (stepsOk[phase] ?? 0) + 1;
        log('QA: ok $phase/$name (${DateTime.now().difference(t0).inSeconds}s)');
        return;
      }
      gen++; // retire the step: its leftovers throw at their next wait()
      stepsFailed[phase] = (stepsFailed[phase] ?? 0) + 1;
      log('QAERR: $phase/$name: $err');
      log('QA: STEPFAIL $phase/$name');
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      stopAll('after $name');
      holdAsks = false;
      scripted = null;
      try {
        await shot('err_${name.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}');
        await backHome();
      } catch (_) {}
    }

    void startPhase(String p) {
      phase = p;
      phaseStart[p] = DateTime.now();
      log('QA: phase $p start (budget ${budgets[p]} min, elapsed ${DateTime.now().difference(testStart).inMinutes} min)');
    }

    Future<Finder> box() async {
      if (find.byType(TextField).evaluate().isEmpty && find.text('Ask SubMac anything').evaluate().isNotEmpty) {
        await tester.tap(find.text('Ask SubMac anything').first, warnIfMissed: false);
        await wait(1200);
      }
      final f = find.byType(TextField);
      if (f.evaluate().isEmpty) throw 'no composer on screen';
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
    Future<bool> settle(int s, {String key = '', String? conv}) async {
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
      final still = here();
      if (still) {
        log('QAWARN still-running after ${s}s: ${st().runs.map((r) => '${r.title}/${r.status}/step${r.step}').toList()} (stopped)');
        stopAll('settle limit');
      }
      await wait(2500);
      return !still;
    }

    String dumpList(List<ChatMessage> list) {
      final parts = <String>[];
      for (final m in list) {
        final c = m.content.replaceAll('\n', '⏎');
        parts.add('${m.role}${m.toolCalls?.isNotEmpty == true ? '[${m.toolCalls!.map((c) => c.name).join(',')}]' : ''}'
            '${m.error != null ? '{ERR:${m.error}}' : ''}:${c.length > 300 ? '${c.substring(0, 300)}…(${c.length})' : c}');
      }
      return parts.join(' ¦ ');
    }

    List<ChatMessage> tail(List<ChatMessage> l, int n) => l.length > n ? l.sublist(l.length - n) : l;
    void dump(String name, [String? conv]) => log('MSGS:$name|${dumpList(tail(conv == null ? st().messages : st().messagesOf(conv), 12))}');
    ChatMessage lastReply([String? conv]) => (conv == null ? st().messages : st().messagesOf(conv))
        .lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
    List<String> callsIn(List<ChatMessage> l) => [for (final m in l) ...?m.toolCalls?.map((c) => c.name)];

    void record(String name, DateTime t0, {String? conv}) {
      final msgs = conv == null ? st().messages : st().messagesOf(conv);
      log('T:$name|${jsonEncode({
            't0': t0.toUtc().toIso8601String(),
            't1': DateTime.now().toUtc().toIso8601String(),
            'secs': DateTime.now().difference(t0).inSeconds,
            'steps': peak['$name.steps'] ?? 0,
            'runTokens': peak['$name.tokens'] ?? 0,
            'tools': callsIn(msgs),
            'errors': [for (final m in msgs) if (m.error != null) m.error!.split('\n').first],
            'replyChars': lastReply(conv).content.length,
            'tables': find.byType(TableCard).evaluate().length,
            'choices': find.byType(ChoicesCard).evaluate().length,
            'window': ContextWindow.tokens,
            'banner': st().banner,
          })}');
    }

    Future<void> fresh() async {
      await backHome();
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
      if (!composer()) throw 'no composer after newChat';
    }

    Future<void> scrollTop() async {
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.dragFrom(Offset(size.width / 2, size.height * 0.3), const Offset(0, 1600));
      await wait(1200);
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

    ({int ar, int arRtl, int lat, int latRtl}) dirs() {
      final arabic = RegExp(r'[\u0600-\u06FF]');
      var ar = 0, arRtl = 0, lat = 0, latRtl = 0;
      for (final e in find.byType(RichText).evaluate()) {
        final w = e.widget as RichText;
        final t = w.text.toPlainText();
        if (t.trim().length < 12) continue;
        final dir = w.textDirection ?? Directionality.maybeOf(e);
        final a = arabic.allMatches(t).length, l = RegExp('[A-Za-z]').allMatches(t).length;
        if (a > l) {
          ar++;
          if (dir == TextDirection.rtl) arRtl++;
        } else if (l > 0) {
          lat++;
          if (dir == TextDirection.rtl) latRtl++;
        }
      }
      return (ar: ar, arRtl: arRtl, lat: lat, latRtl: latRtl);
    }

    Future<void> openWorkspace(Bot b) async {
      await backHome();
      unawaited(app.appNavKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => BotsWorkspace(open: 'bot:${b.id}'))));
      await wait(3500);
    }

    String wsActive() {
      final f = find.byType(BotsWorkspace);
      if (f.evaluate().isEmpty) return '<no workspace>';
      return tester.state<BotsWorkspaceState>(f.first).active;
    }

    void botState(String tag, Bot b) => log('QA: $tag bot=${b.name} lastWake=${b.lastWake} tokensToday=${b.tokensTodayNow} '
        'journal=${b.journal.reversed.take(4).map((e) => '${e.at.toIso8601String().substring(11, 19)} ${e.kind}:${e.text.length > 60 ? e.text.substring(0, 60) : e.text}').toList()} '
        'followups=${b.followups.map((f) => f.at.toIso8601String().substring(11, 16)).toList()} traces=${BotTraces.I.of(b.id).length} next=${Bots.I.nextWork(b)}');

    // ======================================================================================== start, sign in, consent
    app.main();
    for (var i = 0; i < 120 && find.text('Create account').evaluate().isEmpty && find.byType(TextField).evaluate().isEmpty; i++) {
      await wait(1000);
    }
    await wait(2000);
    if (_email.isEmpty) {
      log('QAERR: FATAL no QA_EMAIL/QA_PW given to the build');
      fatal = true;
    } else if (Supabase.instance.client.auth.currentSession == null) {
      try {
        await Supabase.instance.client.auth.signInWithPassword(email: _email, password: _pw);
      } catch (e) {
        log('QAERR: sign-in: ${e.toString().split('\n').first}');
      }
      await wait(9000);
    }
    log('QA: signed in = ${Supabase.instance.client.auth.currentSession != null} uid=${Supabase.instance.client.auth.currentUser?.id}');
    if (!fatal && Supabase.instance.client.auth.currentSession == null) {
      log('QAERR: FATAL not signed in');
      fatal = true;
    }
    if (!fatal) {
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
          log('QAWARN consent gate still up after the UI tick; saving consent directly');
          try {
            await Supabase.instance.client.auth.updateUser(UserAttributes(data: AuthRules.consentData()));
          } catch (e) {
            log('QAERR: consent save: $e');
          }
          await wait(8000);
        }
        log('QA: consent ticked in the UI, gate gone = ${find.text('Agree and continue').evaluate().isEmpty}');
      }
      for (var i = 0; i < 30 && !composer(); i++) {
        await wait(1000);
      }
      await backHome();
      if (find.text('Agree and continue').evaluate().isNotEmpty || !composer()) {
        log('QAERR: FATAL composer missing after sign-in (consent gate up = ${find.text('Agree and continue').evaluate().isNotEmpty}); stopping');
        await shot('00_fatal');
        fatal = true;
      }
    }
    if (!fatal) {
      // No app or phone control anywhere in this run (round 3 froze when the agent drove Gmail, CB-42).
      st().setAgentEnabled(false);
      log('QA: "Let it take action" = ${st().agentEnabled}; allowance ${(await usage()).replaceAll('\n', ' ')}');
      await shot('00_home');
    }

    const safeOff = {'phone', 'apps', 'browser'};

    // ======================================================================================== PHASE A: main chat
    if (_phases.contains('A') && !fatal) {
      startPhase('A');

      // CB-2: Stop during a long streamed answer keeps the words already on screen.
      await step('a01_stop_keeps_text', () async {
        await fresh();
        await type('Write a 1200-word story about a camel caravan crossing the Somali desert. No tools.');
        var seen = 0;
        final t0 = DateTime.now();
        while (DateTime.now().difference(t0).inSeconds < 150) {
          final a = st().messages.where((m) => m.role == 'assistant').toList();
          seen = a.isEmpty ? 0 : a.last.content.length;
          if (seen > 600) break;
          await wait(200);
        }
        final run = task();
        await shot('a01_before_stop');
        final stop = find.bySemanticsLabel('Stop');
        if (stop.evaluate().isNotEmpty) {
          await tester.tap(stop.first, warnIfMissed: false);
        } else {
          st().stop();
        }
        await wait(6000);
        if (run != null && st().runs.contains(run)) run.stop();
        final a = st().messages.where((m) => m.role == 'assistant').toList();
        final kept = a.isEmpty ? 0 : a.last.content.length;
        cb('CB-2', seen > 100 ? kept >= seen ~/ 2 : null, 'streamed=$seen chars before Stop, kept=$kept');
        dump('a01');
        await shot('a01_after_stop');
      }, limit: 240);

      // CB-1: a message typed while the FINAL answer streams gets its own answer.
      await step('a02_steer_final_stream', () async {
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
        await settle(180, key: 'a02');
        await wait(10000);
        await settle(60, key: 'a02');
        final list = st().messages;
        final idx = list.indexWhere((m) => m.id == mine.id);
        final after = idx < 0 ? <ChatMessage>[] : list.sublist(idx + 1).where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).toList();
        final kismayo = list.where((m) => m.role == 'assistant').any((m) => m.content.contains('Kismayo'));
        cb('CB-1', at > 0 ? (idx >= 0 && (after.isNotEmpty || kismayo)) : null,
            'steer typed at $at streamed chars; kept=${idx >= 0} replies after it=${after.length} mentionsKismayo=$kismayo');
        dump('a02');
        await shot('a02_after');
      }, limit: 330);

      // CB-3: a tool name the app does not have (transport seam) must not end the task.
      await step('a03_unknown_tool', () async {
        await fresh();
        seam.fakeSent = false;
        seam.fakeToolMarker = 'CB3PROBE';
        await type('CB3PROBE: in one sentence, what is the capital of Somalia?');
        await settle(150, key: 'a03');
        seam.fakeToolMarker = null;
        final last = st().messages.where((m) => m.role == 'assistant').lastOrNull;
        final errs = [for (final m in st().messages) if (m.error != null) m.error!];
        final raw = st().messages.any((m) => '${m.content} ${m.error ?? ''}'.contains(RegExp('NOT_FOUND|GenkitException')));
        final ok = last != null && last.content.trim().isNotEmpty && last.error == null && !raw;
        cb('CB-3', seam.fakeSent ? ok : null, 'fake "${seam.fakeToolName}" sent=${seam.fakeSent} lastReply="${(last?.content ?? '').replaceAll('\n', ' ').substring(0, math.min(120, (last?.content ?? '').length))}" errors=$errs rawGenkitError=$raw');
        record('a03_unknown_tool', DateTime.now());
        dump('a03');
        await shot('a03_unknown_tool');
      }, limit: 220);

      // CB-10: a cut-off answer (finish_reason=length) continues in the SAME bubble.
      await step('a04_cut_stream', () async {
        await fresh();
        seam.cutDone = false;
        seam.cutMarker = 'CB10PROBE';
        await type('CB10PROBE: give me a table of 8 African capitals with their country and population, then two sentences about them. No tools.');
        final mine = st().messages.lastWhere((m) => m.role == 'user');
        await settle(200, key: 'a04');
        seam.cutMarker = null;
        final list = st().messages;
        final idx = list.indexWhere((m) => m.id == mine.id);
        final replies = idx < 0 ? <ChatMessage>[] : list.sublist(idx + 1).where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).toList();
        cb('CB-10', seam.cutDone ? replies.length == 1 : null,
            'cut=${seam.cutDone} assistant bubbles after the prompt=${replies.length} tables=${find.byType(TableCard).evaluate().length}');
        dump('a04');
        await shot('a04_cut_stream');
      }, limit: 260);

      // Cards placed in a real chat screen (no model call): CB-5, 7, 8, 9, 11a, 11b.
      Future<void> inject(List<ChatMessage> ms) async {
        await fresh();
        st().messages.addAll(ms);
        st().notifyListeners();
        await wait(2500);
      }

      await step('a05_cards', () async {
        const card = '```choices\n["Yes, book it", "Not now"]\n```';
        await inject([
          ChatMessage(id: 'a5u0', role: 'user', content: 'Help me book a trip'),
          ChatMessage(id: 'a5a1', role: 'assistant', content: 'Book the 9 am flight?\n$card'),
          ChatMessage(id: 'a5u1', role: 'user', content: 'Yes, book it'),
          ChatMessage(id: 'a5a2', role: 'assistant', content: 'Booked. Also book the hotel?\n$card'),
        ]);
        await scrollTop();
        final cards = find.byType(ChoicesCard);
        final n = cards.evaluate().length;
        final users0 = st().messages.where((m) => m.role == 'user').length;
        if (n >= 2) {
          final opt = find.descendant(of: cards.first, matching: find.text('Not now'));
          if (opt.evaluate().isNotEmpty) {
            await tester.ensureVisible(opt.first);
            await wait(500);
            await tester.tap(opt.first, warnIfMissed: false);
          }
          await wait(2500);
        }
        final users1 = st().messages.where((m) => m.role == 'user').length;
        cb('CB-5', n >= 2 ? users1 == users0 : null, 'choice cards=$n; tap on the answered card sent a message=${users1 > users0}');
        stopAll('a05 stale choice');
        await wait(2000);

        await inject([
          ChatMessage(id: 'a7u', role: 'user', content: 'budget'),
          ChatMessage(id: 'a7a', role: 'assistant', content: 'Your budget:\n```table\n{"columns":["Item","Cost"],"rows":[["Rent","\$300"],["Food","\$120"]\n```'),
        ]);
        cb('CB-7', visible().contains('Rent'), 'broken table JSON: "Rent" visible=${visible().contains('Rent')}');
        await shot('a05_broken_card');

        await inject([
          ChatMessage(id: 'a8u', role: 'user', content: 'packing'),
          ChatMessage(id: 'a8a', role: 'assistant', content: 'Your packing list:\n```list\n{"title":"Packing","items":["Passport","Charger","Sunscreen"]}\n```\n'
              'Useful links:\n```links\n[{"title":"Visa portal","url":"https://evisa.go.ke"}]\n```'),
        ]);
        await Clipboard.setData(const ClipboardData(text: 'EMPTY'));
        final copy = find.descendant(of: find.byType(MessageActionRow), matching: find.byTooltip('Copy'));
        if (copy.evaluate().isEmpty) {
          await tester.tap(find.textContaining('Your packing list').first, warnIfMissed: false);
          await wait(1000);
        }
        if (copy.evaluate().isEmpty) {
          cb('CB-8', null, 'no Copy action on screen');
        } else {
          await tester.tap(copy.first, warnIfMissed: false);
          await wait(1200);
          final got = (await Clipboard.getData('text/plain'))?.text ?? '';
          cb('CB-8', got.contains('Passport') && got.contains('evisa'), 'copied="${got.replaceAll('\n', '⏎')}"');
        }

        await inject([
          ChatMessage(id: 'a9u', role: 'user', content: 'salaan'),
          ChatMessage(id: 'a9a', role: 'assistant', content: 'السلام عليكم! Waan ku faraxsanahay inaan ku caawiyo. Maxaan kuu qabtaa maanta?'),
          ChatMessage(id: 'a9u2', role: 'user', content: 'ما هو أحدث هاتف؟'),
          ChatMessage(id: 'a9a2', role: 'assistant', content: 'iPhone 16 هو أحدث هاتف من شركة آبل، ويأتي بكاميرا محسنة وبطارية أطول.'),
        ]);
        TextDirection? dirOf(String needle) {
          for (final e in find.byType(RichText).evaluate()) {
            final w = e.widget as RichText;
            if (w.text.toPlainText().contains(needle)) return w.textDirection ?? Directionality.maybeOf(e);
          }
          return null;
        }

        final so = dirOf('faraxsanahay'), ar = dirOf('شركة');
        cb('CB-9', so == null || ar == null ? null : so == TextDirection.ltr && ar == TextDirection.rtl,
            'Somali reply opening with an Arabic greeting=$so (want ltr); Arabic reply opening with iPhone=$ar (want rtl)');
        await shot('a05_direction');

        final parts = Choices.parse('Pay \$1,200 now, Pay later');
        cb('CB-11a', parts.length == 2, 'Choices.parse("Pay \$1,200 now, Pay later") -> $parts');
        await inject([
          ChatMessage(id: 'a11u', role: 'user', content: 'shell'),
          ChatMessage(id: 'a11a', role: 'assistant', content: 'Commands:\n\n| Command | Use |\n|---|---|\n| `ls \\| wc -l` | count files |\n| `pwd` | show folder |\n'),
        ]);
        final v = visible();
        cb('CB-11b', v.contains('count files') && v.contains('wc -l'), 'pipe inside code in a table: "wc -l" visible=${v.contains('wc -l')} "count files" visible=${v.contains('count files')}');
        await shot('a05_pipe_table');
      }, limit: 180);

      // CB-41: an ask left open in chat A must not show its answer buttons in chat B.
      await step('a06_ask_scope', () async {
        await fresh();
        holdAsks = true;
        final convA = st().currentId;
        await type('CB41PROBE: before anything else, use the ask_user tool to ask me whether I prefer tea or coffee, with the options Tea and Coffee. Then wait for my answer.');
        UserAsk? ask;
        final t0 = DateTime.now();
        while (DateTime.now().difference(t0).inSeconds < 100 && ask == null) {
          ask = st().asks.where((a) => a.convId == convA).firstOrNull;
          if (ask == null && !running(convA) && DateTime.now().difference(t0).inSeconds > 20) break;
          await wait(500);
        }
        if (ask == null) {
          holdAsks = false;
          cb('CB-41', null, 'the model never called ask_user (asks=${st().asks.length})');
          dump('a06');
          return;
        }
        await shot('a06_ask_in_A');
        st().newChat();
        await wait(3000);
        final title = ask.title.length > 24 ? ask.title.substring(0, 24) : ask.title;
        final inB = find.descendant(of: find.byType(AskBar), matching: find.textContaining(title)).evaluate().isNotEmpty;
        final buttonsInB = find.descendant(of: find.byType(AskBar), matching: find.text('Coffee')).evaluate().isNotEmpty;
        cb('CB-41', !buttonsInB, 'ask "${ask.title}" from chat A visible in chat B=$inB answerButtonsInB=$buttonsInB');
        await shot('a06_chat_B');
        await st().openConversation(convA!);
        await wait(2000);
        st().answerAsk(ask, {'answer': 'Tea'});
        holdAsks = false;
        await settle(90, conv: convA);
        dump('a06', convA);
      }, limit: 240);

      // CB-42 (guarded): an email "send" must not drive another app; answer scripted "No, just draft".
      await step('a07_email_guarded', () async {
        await fresh();
        scripted = 'No, just draft';
        final front0 = lostFront;
        final t0 = DateTime.now();
        await type('Draft an email to ahmed.test@example.com telling him the meeting moved to Thursday 3 pm, and send it.');
        await settle(180, key: 'a07');
        scripted = null;
        final calls = callsIn(st().messages);
        final other = calls.where((c) => _blocked.hasMatch(c)).toList();
        final draft = st().messages.any((m) => m.role == 'assistant' && m.content.contains('Thursday'));
        cb('CB-42', other.isEmpty && lostFront == front0 && draft,
            'other-app calls=$other lostFront=${lostFront - front0} draftShown=$draft tools=$calls');
        record('a07_email_guarded', t0);
        dump('a07');
        await shot('a07_after');
      }, limit: 260);

      // CB-22: Try again tapped twice after a real (network) failure starts one run.
      await step('a08_try_again_twice', () async {
        await fresh();
        await adb('net_off');
        await type('What is the capital of Kenya? Answer in one word.');
        final t0 = DateTime.now();
        while (DateTime.now().difference(t0).inSeconds < 120 && !st().messages.any((m) => m.error != null)) {
          await wait(1000);
        }
        final hadError = st().messages.any((m) => m.error != null);
        await shot('a08_offline_error');
        await adb('net_on');
        await wait(12000);
        var maxRuns = 0;
        final btn = find.text('Try again');
        if (btn.evaluate().isNotEmpty) {
          await tester.tap(btn.last, warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 120));
          if (btn.evaluate().isNotEmpty) await tester.tap(btn.last, warnIfMissed: false);
        } else {
          unawaited(st().regenerate());
          unawaited(st().regenerate());
        }
        final t1 = DateTime.now();
        while (DateTime.now().difference(t1).inSeconds < 120) {
          final n = st().runs.where((r) => !r.side && r.convId == st().currentId).length;
          if (n > maxRuns) maxRuns = n;
          if (DateTime.now().difference(t1).inSeconds > 8 && st().runs.isEmpty) break;
          await wait(250);
        }
        await wait(4000);
        final replies = st().messages.where((m) => m.role == 'assistant' && m.content.trim().isNotEmpty).length;
        cb('CB-22', hadError ? maxRuns <= 1 && replies <= 1 : null, 'offline error shown=$hadError; after two Try again taps: maxConcurrentRuns=$maxRuns replies=$replies');
        dump('a08');
        await shot('a08_after_retry');
      }, limit: 300);

      // CB-23: a follow-up about a photo, without the photo.
      await step('a09_photo_followup', () async {
        await fresh();
        await st().send('What colour is the shape in this picture, and what shape is it? One short sentence.',
            [Attachment(name: 'shape.png', mime: 'image/png', bytes: await png())]);
        await settle(120, key: 'a09');
        await type('Describe the background colour of that same picture in one word.');
        await settle(120, key: 'a09b');
        final last = lastReply();
        final white = last.content.toLowerCase().contains('white');
        final cant = RegExp("can't see|cannot see|can not see|unable to see|don't have", caseSensitive: false).hasMatch(last.content);
        cb('CB-23', white && !cant, 'follow-up says white=$white cantSee=$cant window=${ContextWindow.tokens} reply="${last.content.length > 120 ? last.content.substring(0, 120) : last.content}"');
        dump('a09');
      }, limit: 300);

      // CB-30: a too-long paste is uploaded at most once.
      await step('a10_too_long_paste', () async {
        await fresh();
        const para = 'Mogadishu port records show many ships arriving with goods from Dubai, Mombasa and Mumbai every week. ';
        final huge = 'Summarise this text in 3 bullets:\n${List.filled(5200, para).join()}';
        seam.countMarker = 'Mogadishu port records show';
        seam.countHits = 0;
        await st().send(huge, const []);
        await settle(150, key: 'a10');
        seam.countMarker = null;
        final last = st().messages.where((m) => m.role == 'assistant').lastOrNull;
        cb('CB-30', seam.countHits <= 1, 'paste chars=${huge.length} uploads=${seam.countHits} lastError=${last?.error} banner=${st().banner}');
        await shot('a10_too_long');
        st().newChat(); // keep the 530 KB chat out of later steps
      }, limit: 240);

      // CB-26: a very big photo is not uploaded as-is.
      await step('a11_big_attachment', () async {
        await fresh();
        const side = 1800;
        final rnd = math.Random(7);
        final px = Uint8List(side * side * 4);
        for (var i = 0; i < px.length; i++) {
          px[i] = (i & 3) == 3 ? 255 : rnd.nextInt(256);
        }
        final got = Completer<ui.Image>();
        ui.decodeImageFromPixels(px, side, side, ui.PixelFormat.rgba8888, got.complete);
        final bd = await (await got.future).toByteData(format: ui.ImageByteFormat.png);
        final bytes = bd!.buffer.asUint8List();
        seam.maxBody = 0;
        await st().send('What do you see in this picture? One sentence.', [Attachment(name: 'noise.png', mime: 'image/png', bytes: bytes)]);
        await settle(180, key: 'a11');
        cb('CB-26', seam.maxBody < 8000000, 'photo bytes=${bytes.length} largest model request body=${seam.maxBody}');
        dump('a11');
        st().newChat();
      }, limit: 260);

      // CB-29 (text half): a draft typed in one main chat must not show up in another.
      await step('a12_drafts_main', () async {
        await backHome();
        final convs = st().conversations.where((c) => Bots.I.byConv(c.id) == null).take(2).toList();
        if (convs.length < 2) {
          cb('CB-29', null, 'need 2 main chats, have ${convs.length}');
          return;
        }
        await st().openConversation(convs[0].id);
        await wait(2500);
        await tester.enterText(await box(), 'DRAFT-A-only-for-chat-one');
        await wait(800);
        await st().openConversation(convs[1].id);
        await wait(2500);
        final inB = boxText();
        await st().openConversation(convs[0].id);
        await wait(2500);
        final backInA = boxText();
        cb('CB-29', !inB.contains('DRAFT-A') && backInA.contains('DRAFT-A'), 'main chats: box in chat B="$inB" back in A="$backInA"');
        await tester.enterText(await box(), '');
        await wait(500);
      }, limit: 120);

      // CB-18: delete all chats while a task runs leaves no ghost chat.
      await step('a13_delete_all_running', () async {
        await fresh();
        await type('Write a detailed 800-word report on the history of the Somali shilling. No tools.');
        final t0 = DateTime.now();
        while (DateTime.now().difference(t0).inSeconds < 60 && (task()?.step ?? 0) < 1 && !(st().messages.lastOrNull?.streaming ?? false)) {
          await wait(300);
        }
        final conv = st().currentId;
        final run = task();
        await st().deleteAllConversations();
        await wait(2000);
        final until = DateTime.now().add(const Duration(minutes: 3));
        while (DateTime.now().isBefore(until) && running()) {
          await wait(2000);
        }
        if (run != null && st().runs.contains(run)) run.stop();
        await wait(6000);
        await st().refreshConversations();
        await wait(3000);
        final left = st().conversations.where((c) => Bots.I.byConv(c.id) == null).map((c) => '${c.id}:${c.title}').toList();
        cb('CB-18', left.isEmpty, 'delete-all while conv $conv was running: main chats after reload=$left');
      }, limit: 300);

      // Real tasks (round 3 t1/t5/t6/t9): choice card scrolled into view, inline long answers (CB-39), live RTL (CB-9).
      await step('a14_trip_choice', () async {
        await fresh();
        final t0 = DateTime.now();
        await type('Plan a 3-day trip to Nairobi for 2 people with a total budget of \$800. Give a day-by-day table (day, morning, afternoon, '
            'evening, cost) and then ask me with choices whether we prefer a hotel or an Airbnb.');
        await settle(240, key: 'a14');
        record('a14_trip', t0);
        final c = find.byType(ChoicesCard);
        if (c.evaluate().isEmpty) {
          log('QA: a14 no choice card on screen');
          return;
        }
        final opt = find.descendant(of: c.last, matching: find.textContaining(RegExp('Airbnb|Hotel', caseSensitive: false)));
        if (opt.evaluate().isEmpty) return;
        await tester.ensureVisible(opt.first); // round 3: the card was below the fold and the tap missed
        await wait(800);
        final users0 = st().messages.where((m) => m.role == 'user').length;
        await tester.tap(opt.first, warnIfMissed: false);
        await wait(2000);
        log('QA: a14 choice tap sent a message=${st().messages.where((m) => m.role == 'user').length > users0}');
        await settle(180, key: 'a14b');
        dump('a14');
        await shot('a14_after_choice');
      }, limit: 480);

      await step('a15_somali_inline', () async {
        await fresh();
        final t0 = DateTime.now();
        await type('Igu qor maqaal dheer (ugu yaraan 500 eray) oo Af-Soomaali ah oo ku saabsan taariikhda magaalada Muqdisho. '
            'Isticmaal cinwaanno, liis, iyo shax (table). Halkan sheekada ku qor, ha samayn fayl.');
        await settle(240, key: 'a15');
        record('a15_somali', t0);
        final last = lastReply();
        final words = last.content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        final files = callsIn(st().messages).where((c) => c.contains('document') || c.contains('file')).toList();
        cb('CB-39', words >= 200, 'Somali long answer inline: replyWords=$words fileTools=$files');
      }, limit: 300);

      await step('a16_arabic_inline_rtl', () async {
        await fresh();
        final t0 = DateTime.now();
        await type('اكتب لي مقالاً طويلاً (حوالي 400 كلمة) عن تاريخ مدينة بربرة مع عناوين وقائمة وجدول للأحداث المهمة. اكتبه هنا في المحادثة، وليس في ملف.');
        await settle(240, key: 'a16');
        record('a16_arabic', t0);
        final d = dirs();
        final words = lastReply().content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        cb('CB-9', d.ar > 0 ? d.arRtl == d.ar : null, 'live Arabic reply: arabic runs=${d.ar} rtl=${d.arRtl}');
        cb('CB-39', words >= 150, 'Arabic long answer inline: replyWords=$words');
        await shot('a16_arabic');
      }, limit: 300);

      // Stop, then "continue"; the step stops whatever it started.
      await step('a17_stop_resume', () async {
        await fresh();
        final t0 = DateTime.now();
        await type('List the 5 biggest companies in Somalia: for each give the sector, founding year and CEO. Use web search.');
        final until = DateTime.now().add(const Duration(seconds: 120));
        while (DateTime.now().isBefore(until)) {
          final r = task();
          if (r != null && r.step >= 2) break;
          await wait(400);
        }
        final run = task();
        final stop = find.bySemanticsLabel('Stop');
        if (stop.evaluate().isNotEmpty) {
          await tester.tap(stop.first, warnIfMissed: false);
        } else {
          st().stop();
        }
        await wait(5000);
        final stopped = run == null || !st().runs.contains(run);
        if (!stopped) run.stop();
        log('QA: a17 run stopped by Stop=$stopped');
        await type('continue');
        final run2 = task();
        await settle(240, key: 'a17');
        if (run2 != null && st().runs.contains(run2)) run2.stop();
        record('a17_stop_resume', t0);
        dump('a17');
      }, limit: 360);
    }

    // ======================================================================================== PHASE B: bots
    Bot? ledger, nova;
    if (_phases.contains('B') && !fatal) {
      startPhase('B');
      await step('b01_create_bot', () async {
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
        log('QA: b01 bot=${ledger!.id} conv=${ledger!.convId} hireErr=$err powersOff=${ledger!.powersOff}');
        await openWorkspace(ledger!);
        await type('What should every invoice I send to customers contain?');
        await settle(180, key: 'b01', conv: ledger!.convId);
        record('b01_create_bot', t0, conv: ledger!.convId);
        final last = lastReply(ledger!.convId);
        final bullets = RegExp(r'^\s*([-*•]|\d+\.)\s', multiLine: true).allMatches(last.content).length;
        log('QA: b01 instruction "exactly three bullets, no tables": bullets=$bullets');
        dump('b01', ledger!.convId);
        await shot('b01_bot_chat');
      }, limit: 300);

      await step('b02_edit_bot', () async {
        final b = ledger!;
        b.instructions = 'Always answer in Somali, in one short paragraph. No bullet points.';
        b.powersOff
          ..clear()
          ..addAll({...safeOff, 'web'});
        await Bots.I.save();
        final n0 = st().messagesOf(b.convId).length;
        await type('Search the web for today\'s US dollar to Kenyan shilling exchange rate and tell me the number.');
        await settle(180, key: 'b02', conv: b.convId);
        final added = st().messagesOf(b.convId).skip(n0).toList();
        final calls = callsIn(added);
        log('QA: b02 web off: toolCalls=$calls webUsed=${calls.any((c) => c.contains('web') || c.contains('search') || c.contains('fetch'))}');
        dump('b02', b.convId);
        b.instructions = 'Follow the owner\'s formatting requests exactly.';
        b.powersOff
          ..clear()
          ..addAll(safeOff);
        await Bots.I.save();
      }, limit: 240);

      Future<void> render(String name, String prompt, {int secs = 150}) async {
        await step(name, () async {
          final b = ledger!;
          if (wsActive() != 'b:${b.id}') await openWorkspace(b);
          await type(prompt);
          await settle(secs, key: name, conv: b.convId);
          final d = dirs();
          log('QA: $name tables=${find.byType(TableCard).evaluate().length} choices=${find.byType(ChoicesCard).evaluate().length} arabicRuns=${d.ar}/${d.arRtl}rtl');
          if (name == 'b03_arabic') cb('CB-9', d.ar > 0 ? d.arRtl == d.ar : null, 'bot chat Arabic: arabic runs=${d.ar} rtl=${d.arRtl}');
          await shot(name);
        }, limit: secs + 60);
      }

      await render('b03_table', 'Make me a table of 3 shop expenses this week: item, cost in USD, date. Use a real table.');
      await render('b03_choices', 'Ask me, with tappable choices, whether I want daily or weekly reports. Give exactly two choices.');
      await step('b03_choice_tap', () async {
        final c = find.byType(ChoicesCard);
        if (c.evaluate().isEmpty) {
          log('QA: b03 no choice card on screen');
          return;
        }
        final opt = find.descendant(of: c.last, matching: find.textContaining(RegExp('Weekly', caseSensitive: false)));
        if (opt.evaluate().isEmpty) return;
        await tester.ensureVisible(opt.first);
        await wait(800);
        final n0 = st().messagesOf(ledger!.convId).length;
        await tester.tap(opt.first, warnIfMissed: false);
        await settle(120, conv: ledger!.convId);
        log('QA: b03 choice tap added ${st().messagesOf(ledger!.convId).length - n0} messages');
      }, limit: 180);
      await render('b03_arabic', 'اكتب لي جملتين باللغة العربية عن أهمية حفظ الفواتير في المتجر. بالعربية فقط.');

      // CB-20: owner chats are not bot background work; the bot budget is still at 0 before any wake.
      await step('b04_budget_owner_chats', () async {
        final b = ledger!;
        cb('CB-20', b.tokensTodayNow == 0, 'after owner chats only: bot tokensToday=${b.tokensTodayNow} traces=${BotTraces.I.of(b.id).length} line="${BotActivityScreen.usageLine(b)}"');
        await backHome();
        unawaited(app.appNavKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => BotActivityScreen(bot: b))));
        await wait(2500);
        await shot('b04_bot_activity');
        await backHome();
      }, limit: 60);

      // Routines through the real Android alarm: a wake counts only at or after the minute it was armed for.
      await step('b05_routines_on_time', () async {
        final b = ledger!;
        final now = DateTime.now();
        final atF = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(minutes: 2));
        final atR = atF.add(const Duration(minutes: 1));
        b.followups.add(BotFollowup('f1shot', atF, 'Send me a one-line reminder to count the cash drawer (one-off test).', 'message'));
        b.routines.add(BotRoutine(id: 'rq', time: _hm(atR), days: 'daily', kind: 'message', instruction: 'Send me one practical bookkeeping tip.'));
        await Bots.I.save();
        await Bots.I.arm(b);
        final armedAt = DateTime.now();
        log('QA: b05 one-off due ${_hm(atF)}, routine due ${_hm(atR)}, armed at ${armedAt.toIso8601String().substring(11, 19)}');
        await adb('alarms', ms: 4000);
        await backHome();
        st().newChat();
        final wakes = <DateTime>[];
        DateTime? seen = b.lastWake;
        var minute = 0;
        while (DateTime.now().isBefore(atR.add(const Duration(minutes: 4)))) {
          final w = b.lastWake;
          if (w != null && w != seen && !w.isBefore(atF.subtract(const Duration(seconds: 5)))) {
            seen = w;
            wakes.add(w);
            log('QA: b05 wake at ${w.toIso8601String().substring(11, 19)} (one-off +${w.difference(atF).inSeconds}s, routine +${w.difference(atR).inSeconds}s)');
          }
          if (wakes.length >= 2 && !running(b.convId) && DateTime.now().isAfter(atR.add(const Duration(seconds: 90)))) break;
          if (DateTime.now().difference(armedAt).inMinutes > minute) {
            minute = DateTime.now().difference(armedAt).inMinutes;
            log('QA: b05 waiting for the alarms (+${minute}min, wakes=${wakes.length})');
          }
          await wait(2000);
        }
        log('QA: b05 wakes=${wakes.length} oneOffStillQueued=${b.followups.any((f) => f.id == 'f1shot')}');
        botState('b05', b);
        await adb('notif', ms: 4000);
      }, limit: 480);

      // CB-35: the same alarm delivered twice (concurrently, then late) runs the routine once.
      await step('b06_double_fire', () async {
        final b = ledger!;
        final traces0 = BotTraces.I.of(b.id).length;
        final f0 = b.followups.length;
        final r = await Future.wait([Bots.I.fire(Bots.alarmId(b, 'rq')), Bots.I.fire(Bots.alarmId(b, 'rq'))]);
        await wait(3000);
        final until = DateTime.now().add(const Duration(minutes: 3));
        while (DateTime.now().isBefore(until) && running(b.convId)) {
          await wait(2000);
        }
        await wait(3000);
        final t1 = BotTraces.I.of(b.id).length;
        final concurrent = t1 - traces0, added = b.followups.length - f0;
        final again = await Bots.I.fire(Bots.alarmId(b, 'rq'));
        await wait(3000);
        final until2 = DateTime.now().add(const Duration(minutes: 2));
        while (DateTime.now().isBefore(until2) && running(b.convId)) {
          await wait(2000);
        }
        final late = BotTraces.I.of(b.id).length - t1;
        cb('CB-35', concurrent <= 1 && added == 0 && late == 0, 'double fire results=$r wakes=$concurrent followupsAdded=$added; late redelivery fire=$again wakes=$late');
        b.followups.clear();
        await Bots.I.save();
        await Bots.I.arm(b);
      }, limit: 360);

      // CB-17: the owner's message typed during a silent wake survives.
      await step('b07_message_during_wake', () async {
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
        final wakeRunning = running(b.convId);
        await type('Quick question while you work: what is 17 times 3?');
        final mine = st().messagesOf(b.convId).lastWhere((m) => m.role == 'user', orElse: () => ChatMessage(id: '', role: 'user'));
        await settle(240, key: 'b07', conv: b.convId);
        await wait(5000);
        final list = st().messagesOf(b.convId);
        final kept = list.any((m) => m.id == mine.id);
        final answered = list.any((m) => m.role == 'assistant' && m.content.contains('51'));
        cb('CB-17', wakeRunning ? kept && answered : null, 'wake running when I typed=$wakeRunning; my message kept=$kept answered(51)=$answered');
        dump('b07', b.convId);
        b.routines.removeWhere((r) => r.id == 'rw');
        await Bots.I.save();
        await Bots.I.arm(b);
      }, limit: 330);

      await step('b08_second_bot', () async {
        nova = await st().hireForJob({'name': 'Nova', 'role': 'Researcher', 'mission': 'Finds facts and prices.', 'instructions': 'Answer in one short sentence.'});
        nova!.powersOff
          ..clear()
          ..addAll({...safeOff, 'web'});
        await Bots.I.save();
        final err = await st().hireBot(nova!);
        log('QA: b08 nova=${nova!.id} conv=${nova!.convId} err=$err');
      }, limit: 120);

      // CB-16: after a notification-style openConversation, the workspace shows and sends to that bot.
      await step('b09_wrong_chat_send', () async {
        final a = ledger!, b = nova!;
        await openWorkspace(a);
        await st().openConversation(b.convId);
        await wait(3000);
        final shown = wsActive();
        final la = st().messagesOf(a.convId).length, lb = st().messagesOf(b.convId).length;
        await type('CB16 probe: which bot are you? Reply with your name only.');
        await settle(90, conv: st().currentId);
        final toA = st().messagesOf(a.convId).skip(la).where((m) => m.role == 'user' && m.content.contains('CB16')).length;
        final toB = st().messagesOf(b.convId).skip(lb).where((m) => m.role == 'user' && m.content.contains('CB16')).length;
        cb('CB-16', shown == 'b:${b.id}' && toB == 1 && toA == 0, 'workspace shows $shown after opening Nova\'s chat; message landed in ledger=$toA nova=$toB');
        await shot('b09_after_send');
      }, limit: 180);

      // CB-29 (attachment half): a picture picked in one bot chat does not travel to another.
      await step('b10_attachments_per_chat', () async {
        final a = ledger!, b = nova!;
        await openWorkspace(a);
        final dir = await Directory.systemTemp.createTemp('qa');
        final p = '${dir.path}/receipt.png';
        await File(p).writeAsBytes(await png());
        st().shareInbox.value = {'files': [p]};
        await wait(2500);
        int chips() => find.byWidgetPredicate((w) => w.runtimeType.toString() == 'AttachmentChip').evaluate().length;
        final inA = chips();
        await tester.enterText(await box(), 'DRAFT-LEDGER-only');
        await wait(800);
        await st().openBot(b);
        await wait(3000);
        final inB = chips();
        final textB = boxText();
        cb('CB-29', inA > 0 ? inB == 0 && !textB.contains('DRAFT-LEDGER') : null, 'bots workspace: chips in Ledger=$inA, in Nova=$inB text in Nova="$textB"');
        await shot('b10_nova');
        await st().openBot(a);
        await wait(2500);
        await tester.enterText(await box(), '');
        await backHome();
      }, limit: 180);

      // CB-25: a dead Telegram token does not poll forever.
      await step('b11_telegram_dead_token', () async {
        final r = await TelegramBridge.I.connect('123456789:AAFakeTokenForChatRegressxxxxxxxxxxxxx');
        log('QA: b11 connect(fake token) -> $r on=${TelegramBridge.I.on} status="${TelegramBridge.I.status}"');
        var calls = 0;
        HttpOverrides.global = _Count(() => calls++);
        try {
          const sec = FlutterSecureStorage(aOptions: AndroidOptions());
          await sec.write(key: 'telegram_token', value: '123456789:AADeadTokenForChatRegressxxxxxxxxxxxxx');
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('telegram_on', true);
          await prefs.setString('telegram_bot', 'qa_dead_bot');
          await TelegramBridge.I.init();
          final t0 = DateTime.now();
          while (DateTime.now().difference(t0).inSeconds < 120) {
            await wait(3000);
          }
          cb('CB-25', calls <= 6, 'dead token after 120 s: telegram HTTP clients=$calls on=${TelegramBridge.I.on} status="${TelegramBridge.I.status}"');
          await TelegramBridge.I.disconnect();
        } finally {
          HttpOverrides.global = null;
        }
      }, limit: 200);

      // CB-18 for bots: removing a bot mid-wake, and delete-all while a bot runs.
      await step('b12_delete_bot_while_waking', () async {
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
        final wasRunning = running(conv);
        await st().deleteConversation(conv);
        await Bots.I.remove(b);
        for (var i = 0; i < 6; i++) {
          await wait(10000);
          log('QA: b12 +${(i + 1) * 10}s runs=${st().runs.map((r) => r.convId).toList()}');
        }
        final back = Bots.I.byId(b.id) != null;
        final ghost = st().conversations.any((c) => c.id == conv) || st().repo.store.index.values.any((m) => m['id'] == conv);
        cb('CB-18', wasRunning ? !back && !ghost : null, 'removed Nova mid-wake (running=$wasRunning): bot back=$back ghost chat=$ghost');
      }, limit: 180);

      await step('b13_delete_all_while_bot_runs', () async {
        final b = ledger!;
        b.routines.add(BotRoutine(id: 'rd', time: '23:57', days: 'daily', kind: 'message', instruction: 'Write me a 250-word note on keeping a shop cash book, then send it.'));
        await Bots.I.save();
        await backHome();
        st().newChat();
        unawaited(Bots.I.fire(Bots.alarmId(b, 'rd')));
        final t0 = DateTime.now();
        while (DateTime.now().difference(t0).inSeconds < 40 && !running(b.convId)) {
          await wait(300);
        }
        final conv = b.convId;
        final wasRunning = running(conv);
        await st().deleteAllConversations();
        await wait(2000);
        while (DateTime.now().difference(t0).inSeconds < 200 && running(conv)) {
          await wait(2000);
        }
        await wait(6000);
        await st().refreshConversations();
        await wait(3000);
        final ghost = st().conversations.any((c) => c.id == conv);
        cb('CB-18', wasRunning ? !ghost : null, 'delete-all while Ledger woke (running=$wasRunning): its old chat back after reload=$ghost conversations=${st().conversations.length}');
        botState('b13', b);
        b.routines.removeWhere((r) => r.id == 'rd');
        await Bots.I.save();
      }, limit: 300);

      await step('b14_doze', () async {
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
        await adb('doze_on', ms: 8000);
        try {
          var minute = 0;
          while (DateTime.now().isBefore(at.add(const Duration(minutes: 3)))) {
            if (b.lastWake != w0 && !running(b.convId)) break;
            if (DateTime.now().difference(now).inMinutes > minute) {
              minute = DateTime.now().difference(now).inMinutes;
              log('QA: b14 waiting under forced idle (+${minute}min)');
            }
            await wait(2000);
          }
          log('QA: b14 routine due ${_hm(at)} under forced idle: woke=${b.lastWake != w0} at=${b.lastWake}');
        } finally {
          log('ADB:doze_off');
        }
        await wait(8000);
        b.routines.removeWhere((r) => r.id == 'rz');
        b.followups.clear();
        await Bots.I.save();
        await Bots.I.arm(b);
      }, limit: 360);
    }

    // ======================================================================================== PHASE C: teams
    if (_phases.contains('C') && !fatal) {
      startPhase('C');
      final calls = <String, int>{};
      final callTimes = <DateTime>[];
      final toolsBy = <String, List<String>>{};
      String? failBot;
      final origLlm = TeamRun.I.llm;
      final origTool = TeamRun.I.runTool;
      final origAsk = TeamRun.I.approvalFor;
      if (origLlm == null || origTool == null) {
        log('QAERR: TeamRun is not wired (llm=${origLlm != null} runTool=${origTool != null})');
      } else {
        TeamRun.I.llm = (Bot b, Turn t, {int maxTokens = 1500}) async {
          calls[b.name] = (calls[b.name] ?? 0) + 1;
          callTimes.add(DateTime.now());
          final r = await origLlm(b, t, maxTokens: maxTokens);
          log('LLM:${b.name}|step=${t.step} in=${r.tokensIn} out=${r.tokensOut} calls=${r.toolCalls.map((c) => c.name).join(',')} fin=${r.finishReason}');
          return r;
        };
        TeamRun.I.approvalFor = (Bot b, ToolCall c, Map<String, dynamic> args) async {
          if (_blocked.hasMatch(c.name)) return null;
          return origAsk == null ? null : origAsk(b, c, args);
        };
        TeamRun.I.runTool = (Bot b, ToolCall c, Map<String, dynamic> args, {Object? approved}) async {
          (toolsBy[b.name] ??= []).add(c.name);
          if (_blocked.hasMatch(c.name)) {
            log('TOOL:${b.name}|${c.name} BLOCKED by harness (no other-app tasks)');
            return 'Error: ${c.name} is not available in this test run.';
          }
          if (failBot == b.id) {
            log('TOOL:${b.name}|${c.name} INJECTED FAILURE');
            return 'Error in ${c.name}: the service is unavailable right now (HTTP 503).';
          }
          return origTool(b, c, args, approved: approved);
        };
      }
      bool teamBusy(Office o) =>
          TeamRun.I.busy(o) || Offices.I.queue.any((j) => j.officeId == o.id) || o.members.any((id) => Offices.I.isWorking?.call(id) ?? false);
      String who(String id) => id == 'you' ? 'You' : (id == 'system' ? 'System' : (Bots.I.byId(id)?.name ?? id));
      String postsOf(Office o, [int from = 0]) => o.posts.skip(from).map((p) {
            final t = p.text.replaceAll('\n', '⏎');
            return '${who(p.from)}(${p.kind}): ${t.length > 240 ? '${t.substring(0, 240)}…' : t}';
          }).join(' ¦ ');
      int callsSince(DateTime t) => callTimes.where((c) => c.isAfter(t)).length;

      Future<void> openTeam(Office o) async {
        await backHome();
        unawaited(app.appNavKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => TeamChat(office: o))));
        await wait(2500);
      }

      Future<void> say(Office o, String text) async {
        final b = find.byType(TextField);
        final send = find.byIcon(Icons.arrow_upward_rounded);
        if (b.evaluate().isNotEmpty && send.evaluate().isNotEmpty) {
          await tester.enterText(b.last, text);
          await wait(500);
          await tester.tap(send.last, warnIfMissed: false);
          await wait(800);
          if (!o.posts.any((p) => p.from == 'you' && p.text == text.trim())) TeamRun.I.send(o, text);
        } else {
          TeamRun.I.send(o, text);
        }
        log('QA: owner said "${text.length > 70 ? text.substring(0, 70) : text}" busy=${TeamRun.I.busy(o)} awaitingGo=${TeamRun.I.awaitingGo(o)}');
      }

      /// Waits until the team (TeamRun, the office queue and its members) is quiet for [quietS] seconds.
      Future<void> settleTeam(Office o, {int maxS = 360, int quietS = 25, bool answerGo = true}) async {
        final t0 = DateTime.now();
        var quiet = 0;
        var minute = 0;
        await wait(2000);
        while (DateTime.now().difference(t0).inSeconds < maxS) {
          if (answerGo && TeamRun.I.awaitingGo(o)) await say(o, 'Go');
          quiet = teamBusy(o) ? 0 : quiet + 1;
          if (quiet >= quietS) break;
          if (DateTime.now().difference(t0).inMinutes > minute) {
            minute = DateTime.now().difference(t0).inMinutes;
            log('QA: team ${o.name} busy +${minute}min posts=${o.posts.length} queue=${Offices.I.queue.where((j) => j.officeId == o.id).length}');
          }
          await wait(1000);
        }
        if (teamBusy(o)) log('QAWARN team ${o.name} still busy after ${maxS}s');
      }

      Office? team;
      Bot? lead, tnova, amina;
      await step('c01_create_team', () async {
        lead = await st().hireForJob({'name': 'Hodan', 'role': 'Project lead', 'mission': 'Plans the work, hands out parts and writes the final answer.'});
        tnova = await st().hireForJob({'name': 'Nuur', 'role': 'Researcher', 'mission': 'Finds facts, prices and specs on the web, with sources.'});
        amina = await st().hireForJob({'name': 'Amina', 'role': 'Analyst', 'mission': 'Compares options and builds clear tables.'});
        final ids = [lead!.id, tnova!.id, amina!.id];
        for (final id in ids) {
          Bots.I.byId(id)?.powersOff
            ?..clear()
            ..addAll(safeOff);
        }
        await Bots.I.save();
        final err = await st().prepareOfficeBots(ids);
        team = await Offices.I.create(name: 'Laptop team', members: ids, chiefId: lead!.id);
        await openTeam(team!);
        log('QA: c01 prepare=$err intro: ${postsOf(team!)}');
        await shot('c01_team');
      }, limit: 120);

      // CB-36: the intro's promise matches what the lead does; CB-37: a second request while the team works is answered.
      await step('c02_job_and_second_request', () async {
        final o = team!;
        final n0 = o.posts.length;
        final intro = o.posts.take(n0).map((p) => p.text).join(' ');
        final promisesGo = RegExp('go-ahead|go ahead|wait for your', caseSensitive: false).hasMatch(intro);
        await say(o,
            'Team, I need three things: 1) research 3 laptops under \$1000 for a university student (price, CPU, RAM, battery) with sources, '
            '2) compare them in a table, 3) write a short summary recommending one. Only show me the result here.');
        var sawGo = false, secondSent = false;
        var n2 = 0;
        final t1 = DateTime.now();
        var quiet = 0;
        var minute = 0;
        while (DateTime.now().difference(t1).inSeconds < 480) {
          final s = DateTime.now().difference(t1).inSeconds;
          if (TeamRun.I.awaitingGo(o)) {
            sawGo = true;
            await say(o, 'Go');
          }
          if (!secondSent && s > 40 && teamBusy(o)) {
            secondSent = true;
            n2 = o.posts.length;
            await say(o, 'Separate question for anyone: what is 15% of 2,400? Just the number.');
          }
          quiet = teamBusy(o) ? 0 : quiet + 1;
          if (quiet >= 30 && s > 45) break;
          if (s ~/ 60 > minute) {
            minute = s ~/ 60;
            log('QA: c02 +${minute}min posts=${o.posts.length} busy=${teamBusy(o)}');
          }
          await wait(1000);
        }
        cb('CB-36', promisesGo ? sawGo : true, 'intro promises a go-ahead wait=$promisesGo; the lead waited for Go=$sawGo');
        if (secondSent) {
          final hit = o.posts.skip(n2).where((p) => p.from != 'you' && RegExp(r'\b360\b').hasMatch(p.text)).toList();
          cb('CB-37', hit.isNotEmpty, 'second request while the team worked answered (360)=${hit.isNotEmpty} by ${hit.map((p) => who(p.from)).toList()}');
        } else {
          cb('CB-37', null, 'team was not busy 40 s in; second request not sent');
        }
        log('POSTS:c02|${postsOf(o, n0)}');
        await shot('c02_end');
      }, limit: 600);

      // CB-19 / CB-34: Stop stops the lead, the members and their reply jobs.
      await step('c03_stop', () async {
        final o = team!;
        await settleTeam(o, maxS: 90, quietS: 10);
        final n0 = o.posts.length;
        await say(o, 'Team, research the 4 best co-working spaces in Nairobi with monthly prices, compare them in a table and recommend one.');
        final t1 = DateTime.now();
        while (DateTime.now().difference(t1).inSeconds < 75) {
          if (TeamRun.I.awaitingGo(o)) await say(o, 'Go');
          if (o.posts.skip(n0).where((p) => p.from == lead!.id).length >= 2 && teamBusy(o)) break;
          await wait(1000);
        }
        final wasBusy = teamBusy(o);
        await say(o, 'stop');
        final stopAt = DateTime.now();
        final nStop = o.posts.length;
        for (var i = 0; i < 9; i++) {
          await wait(10000);
          log('QA: c03 +${(i + 1) * 10}s after stop busy=${teamBusy(o)} posts=${o.posts.length - nStop}');
        }
        final grace = stopAt.add(const Duration(seconds: 10));
        final late = o.posts.skip(nStop).where((p) => p.from != 'you' && p.from != 'system' && p.at.isAfter(grace)).toList();
        final lateCalls = callsSince(grace);
        cb('CB-19', wasBusy ? late.isEmpty : null, 'member posts more than 10 s after Stop=${late.length} ${late.map((p) => who(p.from)).toList()}');
        cb('CB-34', wasBusy ? lateCalls == 0 && !teamBusy(o) : null, 'model calls more than 10 s after Stop=$lateCalls stillBusy=${teamBusy(o)}');
        log('POSTS:c03|${postsOf(o, n0)}');
      }, limit: 240);

      // CB-60: deleting a running team stops it.
      await step('c04_delete_running_team', () async {
        final l = lead!, n = tnova!;
        final o = await Offices.I.create(name: 'Temp team', members: [l.id, n.id], chiefId: l.id);
        await openTeam(o);
        await say(o, 'Team, research 3 budget hotels in Hargeisa with prices and compare them in a table.');
        final t1 = DateTime.now();
        while (DateTime.now().difference(t1).inSeconds < 60) {
          if (TeamRun.I.awaitingGo(o)) await say(o, 'Go');
          if (o.posts.where((p) => p.from == l.id).length >= 2 && TeamRun.I.busy(o)) break;
          await wait(1000);
        }
        final wasBusy = teamBusy(o);
        await backHome();
        await Offices.I.remove(o);
        final del = DateTime.now();
        for (var i = 0; i < 6; i++) {
          await wait(10000);
          log('QA: c04 +${(i + 1) * 10}s after delete running=${TeamRun.I.running.contains(o.id)}');
        }
        final lateCalls = callsSince(del.add(const Duration(seconds: 10)));
        cb('CB-60', wasBusy ? lateCalls == 0 && !TeamRun.I.running.contains(o.id) : null,
            'deleted while busy=$wasBusy: model calls more than 10 s later=$lateCalls stillRunning=${TeamRun.I.running.contains(o.id)} cores=${TeamRun.I.coresFor(o.id)}');
      }, limit: 150);

      // CB-63: an Arabic team job gets no English fixed phrases.
      await step('c05_arabic', () async {
        final o = team!;
        await openTeam(o);
        await settleTeam(o, maxS: 60, quietS: 8);
        final n0 = o.posts.length;
        await say(o, 'يا فريق، قارنوا بين ثلاث سماعات لاسلكية بسعر أقل من 100 دولار في جدول، ثم أوصوني بواحدة.');
        await settleTeam(o, maxS: 300, quietS: 25);
        final arabic = RegExp(r'[\u0600-\u06FF]');
        final fixed = o.posts.skip(n0).where((p) => p.from != 'you' && (p.from == lead!.id || p.from == 'system')).where((p) {
          final t = p.text.trim();
          return t.isNotEmpty && !arabic.hasMatch(t) && RegExp('[A-Za-z]{3,}').hasMatch(t);
        }).toList();
        final plan = o.posts.skip(n0).any((p) => p.text.contains('The plan:'));
        cb('CB-63', fixed.isEmpty && !plan, 'English-only lead/system posts in an Arabic job=${fixed.map((p) => p.text.length > 50 ? p.text.substring(0, 50) : p.text).toList()} "The plan:"=$plan');
        log('POSTS:c05|${postsOf(o, n0)}');
        await shot('c05_arabic');
      }, limit: 420);

      // CB-62: the team keeps working while SubMac is in the background for 60 s.
      await step('c06_background', () async {
        final o = team!;
        await settleTeam(o, maxS: 60, quietS: 8);
        final n0 = o.posts.length;
        await say(o, 'Team, compare the 3 cheapest ways to send \$200 from the US to Somalia (fees and speed) in a table, and recommend one.');
        final t1 = DateTime.now();
        while (DateTime.now().difference(t1).inSeconds < 60) {
          if (TeamRun.I.awaitingGo(o)) await say(o, 'Go');
          if (o.posts.skip(n0).where((p) => p.from == lead!.id).length >= 2) break;
          await wait(1000);
        }
        final busy = teamBusy(o);
        final pre = o.posts.length;
        await adb('bg_60', ms: 75000);
        final grew = o.posts.length - pre;
        cb('CB-62', busy ? grew > 0 : null, 'team busy when sent to background=$busy; posts added during 60 s in background=$grew');
        await settleTeam(o, maxS: 240, quietS: 20);
        log('POSTS:c06|${postsOf(o, n0)}');
        await adb('notif', ms: 4000);
      }, limit: 480);

      await step('c07_tool_failure', () async {
        final o = team!;
        await openTeam(o);
        await settleTeam(o, maxS: 60, quietS: 8);
        final n0 = o.posts.length;
        failBot = tnova!.id;
        await say(o, 'Team, find the current price of a Dell XPS 13 and a MacBook Air M3 in the US and tell me which is cheaper.');
        await settleTeam(o, maxS: 240, quietS: 20);
        failBot = null;
        final answer = o.posts.skip(n0).where((p) => p.kind == 'answer').lastOrNull;
        log('QA: c07 member tool failure injected for Nuur: final answer posted=${answer != null} tools=${toolsBy[tnova!.name]}');
        log('POSTS:c07|${postsOf(o, n0)}');
      }, limit: 300);

      await step('c08_usage', () async {
        for (final b in [lead, tnova, amina].whereType<Bot>()) {
          log('QA: c08 bot ${b.name}: tokensToday=${b.tokensTodayNow} calls=${calls[b.name] ?? 0} line="${BotActivityScreen.usageLine(b)}" ring=${BotStatus.I.of(BotStatus.teamKey(team?.id ?? '')).toString()}');
        }
      }, limit: 30);
      if (origLlm != null) TeamRun.I.llm = origLlm;
      if (origTool != null) TeamRun.I.runTool = origTool;
      TeamRun.I.approvalFor = origAsk;
    }

    // ======================================================================================== K: arm the cold-start phases
    if (_phases.contains('B') && !fatal && ledger != null) {
      startPhase('K');
      await step('k01_arm_for_force_stop', () async {
        final b = ledger!;
        await backHome();
        final now = DateTime.now();
        final at = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(minutes: 3));
        b.routines.removeWhere((r) => r.id == 'rq' || r.id == 'rk');
        b.routines.add(BotRoutine(id: 'rk', time: _hm(at), days: 'daily', kind: 'message', instruction: 'Send me one short bookkeeping tip (force-stop test).'));
        await Bots.I.save();
        await Bots.I.arm(b);
        await Directory('/data/user/0/com.submac.agent/files').create(recursive: true);
        File(_marker).writeAsStringSync('p2|${b.id}|${at.toIso8601String()}');
        botState('k01', b);
        log('PHASE2_DUE:${at.millisecondsSinceEpoch ~/ 1000}');
      }, limit: 60);
    }

    // ======================================================================================== summary
    stallTimer.cancel();
    LlmClient.testClient = http.Client();
    for (final p in ['A', 'B', 'C', 'K']) {
      if (!phaseStart.containsKey(p)) continue;
      final r = cbRes[p] ?? {};
      log('PHASE $p: steps ok=${stepsOk[p] ?? 0} failed=${stepsFailed[p] ?? 0} skipped=${stepsSkipped[p] ?? 0} '
          'CB pass=${r['PASS'] ?? 0} fail=${r['FAIL'] ?? 0} skip=${r['SKIP'] ?? 0}');
    }
    log('QA: uncaught app exceptions=$exceptions lostFront=$lostFront seamRequests=${seam.requests} elapsed=${DateTime.now().difference(testStart).inMinutes}min fatal=$fatal');
    log('QA: done');
  }, timeout: const Timeout(Duration(minutes: 95)));
}

/// Counts the HTTP clients the Telegram bridge opens (one per getUpdates attempt); everything else passes through.
class _Count extends HttpOverrides {
  _Count(this.hit);
  final void Function() hit;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    if (StackTrace.current.toString().contains('telegram_bridge')) hit();
    return super.createHttpClient(context);
  }
}
