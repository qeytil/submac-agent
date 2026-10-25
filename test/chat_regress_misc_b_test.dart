// Chat regressions, PR-11b fix/chat-misc-b: CB-13 (edit and resend drops the reply quote; does nothing while busy) and
// the editAndResend double-send PR-1 found next to CB-22 (an edit racing another edit, "Try again" or a send).
//
// Run: flutter test test/chat_regress_misc_b_test.dart
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/widgets/chat/reply_quote.dart';
import 'package:agent/widgets/message_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Docs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Docs(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

const _busyNote = 'SubMac is still answering. Stop it first, then edit your message.';

/// A chat on screen with two turns: W ("first question") -> its answer, then X -> its answer.
class _Chat {
  _Chat(this.s, this.convId, this.w, this.wAnswer, this.x, this.xAnswer);
  final AppState s;
  final String convId;
  final ChatMessage w, wAnswer, x, xAnswer;

  List<ChatMessage> get users => [for (final m in s.messages) if (m.role == 'user') m];
  Future<List<ChatMessage>> saved() => s.repo.listMessages(convId);
}

Future<_Chat> _chat(String uid, {String? xContent}) async {
  final s = AppState();
  s.repo.testUserId = uid;
  final c = await s.repo.createConversation(title: 'Chat');
  final w = ChatMessage(id: 'w', role: 'user', content: 'first question');
  final wa = ChatMessage(id: 'wa', role: 'assistant', content: 'The first answer');
  final x = ChatMessage(id: 'x', role: 'user', content: xContent ?? 'second question');
  final xa = ChatMessage(id: 'xa', role: 'assistant', content: 'The second answer');
  for (final m in [w, wa, x, xa]) {
    await s.repo.insertMessage(c.id, m);
  }
  s.conversations = [c];
  s.currentId = c.id;
  s.messages = [w, wa, x, xa];
  s.listsForTest[c.id] = s.messages;
  return _Chat(s, c.id, w, wa, x, xa);
}

Future<void> _frames([int n = 25]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  var started = 0;
  late Completer<void> hold;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('cb13');
    PathProviderPlatform.instance = _Docs(tmp.path);
    started = 0;
    hold = Completer<void>();
    AppState.debugRunAgent = (app, run) async {
      if (!run.side) started++;
      await hold.future;
    };
  });
  tearDown(() async {
    if (!hold.isCompleted) hold.complete();
    AppState.debugRunAgent = null;
    selectedReply.value = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ---------------------------------------------------------------- CB-13 the reply quote
  group('CB-13 edit and resend keeps the reply quote', () {
    test('an edited reply still quotes the message it replied to', () async {
      const ref = ReplyRef(id: 'wa', author: 'SubMac', quote: 'The first answer');
      final t = await _chat('u13a', xContent: ReplyCodec.encode(ref, 'why is that?'));
      // The edit box shows only the user's own words (bodyOf); the user changes them.
      expect(ReplyCodec.bodyOf(t.x.content), 'why is that?');
      final going = t.s.editAndResend(t.x, 'why is that, exactly?');
      await _frames();
      hold.complete();
      await going;
      final edited = t.users.last;
      final d = ReplyCodec.decode(edited.content);
      expect(d.ref, isNotNull, reason: 'the edit dropped the reply quote: "${edited.content}"');
      expect(d.ref!.id, 'wa');
      expect(d.ref!.author, 'SubMac');
      expect(d.ref!.quote, 'The first answer');
      expect(d.body, 'why is that, exactly?');
      // Saved the same way (it syncs and comes back after a restart).
      final saved = (await t.saved()).where((m) => m.role == 'user').last;
      expect(ReplyCodec.decode(saved.content).ref?.id, 'wa');
      expect(started, 1);
    });

    test('an edited plain message stays plain', () async {
      final t = await _chat('u13b');
      final going = t.s.editAndResend(t.x, 'second question, reworded');
      await _frames();
      hold.complete();
      await going;
      expect(t.users.last.content, 'second question, reworded');
      expect(ReplyCodec.decode(t.users.last.content).ref, isNull);
    });
  });

  // ---------------------------------------------------------------- CB-13 does nothing while busy
  group('CB-13 edit while SubMac is answering says so', () {
    test('editAndResend during a run sends nothing, changes nothing and tells the caller', () async {
      final t = await _chat('u13c');
      final running = t.s.regenerate();
      await _frames();
      expect(t.s.runs, isNotEmpty);
      expect(t.s.canEditHere, isFalse);
      final before = [...t.s.messages];
      final sent = await t.s.editAndResend(t.w, 'an edit while busy');
      expect(sent, isFalse, reason: 'the screen cannot tell the edit was refused');
      expect(t.s.messages, before);
      hold.complete();
      await running;
      expect(t.s.canEditHere, isTrue);
    });

    testWidgets('tapping Edit while a run is going shows a note instead of an edit box', (tester) async {
      late _Chat t;
      late Future<void> running;
      await tester.runAsync(() async {
        t = await _chat('u13d');
        running = t.s.regenerate();
        await _frames();
      });
      expect(t.s.runs, isNotEmpty);
      selectedReply.value = t.w.id;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<AppState>.value(value: t.s, child: UserMessageView(message: t.w)),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.byTooltip('Edit and resend'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsNothing, reason: 'an edit box that silently does nothing on Send');
      expect(find.text(_busyNote), findsOneWidget);
      await tester.runAsync(() async {
        hold.complete();
        await running;
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  // ---------------------------------------------------------------- double send (as CB-22)
  group('editAndResend double send', () {
    test('two edits in one frame: one message goes out, one run', () async {
      final t = await _chat('u13e');
      // Two quick taps: Send on the edit box of X, then (before it saved) Send on an edit of W.
      final a = t.s.editAndResend(t.x, 'edit one');
      final b = t.s.editAndResend(t.w, 'edit two');
      await _frames();
      expect(started, 1);
      hold.complete();
      await a;
      await b;
      final users = [for (final m in t.users) m.content];
      expect(users, ['first question', 'edit one'], reason: 'both edits went out: $users');
      final saved = [for (final m in await t.saved()) if (m.role == 'user') m.content];
      expect(saved, ['first question', 'edit one'], reason: 'both edits were saved: $saved');
      expect(t.s.messages.any((m) => m.id == 'wa'), isTrue, reason: 'the second edit removed the first answer');
    });

    test('an edit and "Try again" in one frame: the edit goes out, no other answer is removed', () async {
      final t = await _chat('u13f');
      final a = t.s.editAndResend(t.x, 'edit one');
      final b = t.s.regenerate();
      await _frames();
      expect(started, 1);
      hold.complete();
      await a;
      await b;
      expect([for (final m in t.s.messages) m.id].take(2), ['w', 'wa'], reason: '"Try again" removed the first answer');
      expect([for (final m in t.users) m.content], ['first question', 'edit one']);
      final savedIds = [for (final m in await t.saved()) m.id];
      expect(savedIds, contains('wa'));
    });

    test('an edit while a message is still saving is refused; the message stays', () async {
      final t = await _chat('u13g');
      final sending = t.s.send('a third question', const []);
      final sent = t.s.editAndResend(t.w, 'an edit racing the send');
      await _frames();
      hold.complete();
      await sending;
      expect(await sent, isFalse);
      expect([for (final m in t.users) m.content], ['first question', 'second question', 'a third question']);
      expect(started, 1);
    });

    test('a message sent while an edit saves lands after the edit and joins its run', () async {
      final t = await _chat('u13h');
      final a = t.s.editAndResend(t.x, 'edit one');
      final b = t.s.send('and one more thing', const []);
      await _frames();
      expect(started, 1);
      hold.complete();
      await a;
      await b;
      expect([for (final m in t.users) m.content], ['first question', 'edit one', 'and one more thing']);
      final saved = [for (final m in await t.saved()) if (m.role == 'user') m.content];
      expect(saved, ['first question', 'edit one', 'and one more thing']);
    });
  });
}
