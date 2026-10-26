import 'dart:async';
import 'dart:convert';

import 'package:agent/services/telegram_bridge.dart';
import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// CB-25: Telegram pairing must survive a restart, and a dead token must stop the loop instead of retrying forever.

class _MemSecrets implements TelegramSecrets {
  final Map<String, String> m = {};
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
  @override
  Future<void> delete(String key) async => m.remove(key);
}

/// A fake Telegram: answers getMe, hands out queued getUpdates replies, and then holds the long poll open.
class _FakeTelegram {
  final List<http.Response> updates = [];
  final List<String> calls = [];
  final List<Map<String, String>> sent = [];
  final Completer<void> idle = Completer<void>();

  http.Client client() => MockClient((req) async {
        final method = req.url.pathSegments.last;
        calls.add(method);
        if (method == 'getMe') return http.Response(jsonEncode({'ok': true, 'result': {'username': 'my_bot'}}), 200);
        if (method == 'sendMessage' || method == 'sendChatAction') {
          sent.add(Map<String, String>.from(req.bodyFields));
          return http.Response('{"ok":true,"result":{}}', 200);
        }
        if (method == 'getUpdates') {
          if (updates.isNotEmpty) return updates.removeAt(0);
          if (!idle.isCompleted) idle.complete();
          // Hold the long poll open, the way Telegram does when nothing is new.
          return Completer<http.Response>().future;
        }
        return http.Response('{"ok":false}', 400);
      });

  static http.Response ok(List<Map<String, dynamic>> result) => http.Response(jsonEncode({'ok': true, 'result': result}), 200);

  static Map<String, dynamic> msg(int updateId, String text, {int chat = 42, String type = 'private'}) => {
        'update_id': updateId,
        'message': {
          'chat': {'id': chat, 'type': type},
          'from': {'first_name': 'Amina'},
          'text': text,
        },
      };
}

Future<void> _until(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLang.I.choice = 'en';
  });

  test('a 401 from getUpdates stops the loop and turns the bridge off', () async {
    final tg = _FakeTelegram();
    final waits = <Duration>[];
    final b = TelegramBridge.forTest(secrets: _MemSecrets(), client: tg.client, wait: (d) async => waits.add(d));
    tg.updates.add(http.Response('{"ok":false,"error_code":401,"description":"Unauthorized"}', 401));
    expect(await b.connect('123:abc'), isNull);
    await _until(() => !b.polling);
    expect(b.polling, isFalse);
    expect(b.enabled, isFalse);
    expect(b.on, isFalse);
    expect(b.status, 'The token was rejected. Paste a new one.');
    expect(tg.calls.where((c) => c == 'getUpdates').length, 1, reason: 'no retry after a 401');
    expect(waits, isEmpty, reason: 'no back-off after a 401');
    final p = await SharedPreferences.getInstance();
    expect(p.getBool('telegram_on'), isFalse);
  });

  test('a 404 (deleted bot) also stops the loop', () async {
    final tg = _FakeTelegram();
    final b = TelegramBridge.forTest(secrets: _MemSecrets(), client: tg.client, wait: (d) async {});
    tg.updates.add(http.Response('{"ok":false,"error_code":404,"description":"Not Found"}', 404));
    await b.connect('123:abc');
    await _until(() => !b.polling);
    expect(b.enabled, isFalse);
    expect(tg.calls.where((c) => c == 'getUpdates').length, 1);
  });

  test('a 429 waits retry_after and carries on without "Reconnecting"', () async {
    final tg = _FakeTelegram();
    final waits = <Duration>[];
    final b = TelegramBridge.forTest(secrets: _MemSecrets(), client: tg.client, wait: (d) async => waits.add(d));
    tg.updates.add(http.Response(
        jsonEncode({'ok': false, 'error_code': 429, 'description': 'Too Many Requests', 'parameters': {'retry_after': 7}}), 429));
    await b.connect('123:abc');
    await tg.idle.future;
    expect(waits, [const Duration(seconds: 7)]);
    expect(b.enabled, isTrue);
    expect(b.polling, isTrue);
    expect(b.status, contains(b.pairCode));
  });

  test('a restart keeps the pair code, and the kept code still pairs', () async {
    final secrets = _MemSecrets();
    final tg1 = _FakeTelegram();
    final first = TelegramBridge.forTest(secrets: secrets, client: tg1.client, wait: (d) async {});
    expect(await first.connect('123:abc'), isNull);
    final code = first.pairCode;
    expect(code, matches(RegExp(r'^\d{6}$')));
    await tg1.idle.future;

    // The app restarts: a fresh bridge over the same storage.
    final tg2 = _FakeTelegram();
    tg2.updates.add(_FakeTelegram.ok([_FakeTelegram.msg(1, code)]));
    final second = TelegramBridge.forTest(secrets: secrets, client: tg2.client, wait: (d) async {});
    await second.init();
    expect(second.pairCode, code, reason: 'the code shown before the restart still works');
    expect(second.status, contains(code));
    await _until(() => second.paired);
    expect(second.chatId, 42);
    expect(second.status, 'Linked with Amina.');
    expect(second.pairCode, isEmpty);
    expect(secrets.m.containsKey('telegram_pair_code'), isFalse, reason: 'a used code is forgotten');
    expect(tg2.sent.any((s) => s['chat_id'] == '42'), isTrue);
  });

  test('a restart with no saved code makes a new one and shows it', () async {
    final secrets = _MemSecrets()..m['telegram_token'] = '123:abc';
    SharedPreferences.setMockInitialValues({'telegram_on': true, 'telegram_bot': 'my_bot'});
    final tg = _FakeTelegram();
    final b = TelegramBridge.forTest(secrets: secrets, client: tg.client, wait: (d) async {});
    await b.init();
    expect(b.pairCode, matches(RegExp(r'^\d{6}$')));
    expect(b.status, 'Send ${b.pairCode} to @my_bot to link your chat.');
    expect(secrets.m['telegram_pair_code'], b.pairCode);
  });

  test('an expired code is replaced, not accepted', () async {
    final old = DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
    final secrets = _MemSecrets()
      ..m['telegram_token'] = '123:abc'
      ..m['telegram_pair_code'] = '111111'
      ..m['telegram_pair_expires'] = '$old';
    SharedPreferences.setMockInitialValues({'telegram_on': true, 'telegram_bot': 'my_bot'});
    final tg = _FakeTelegram();
    tg.updates.add(_FakeTelegram.ok([_FakeTelegram.msg(1, '111111')]));
    final b = TelegramBridge.forTest(secrets: secrets, client: tg.client, wait: (d) async {});
    await b.init();
    await tg.idle.future;
    expect(b.paired, isFalse);
    expect(b.pairCode, isNot('111111'));
  });

  test('a group chat cannot pair, even with the right code', () async {
    const code = '222333';
    final secrets = _MemSecrets()
      ..m['telegram_token'] = '123:abc'
      ..m['telegram_pair_code'] = code
      ..m['telegram_pair_expires'] = '${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}';
    final tg2 = _FakeTelegram();
    tg2.updates.add(_FakeTelegram.ok([_FakeTelegram.msg(1, code, chat: -100, type: 'group')]));
    final g = TelegramBridge.forTest(secrets: secrets, client: tg2.client, wait: (d) async {});
    SharedPreferences.setMockInitialValues({'telegram_on': true, 'telegram_bot': 'my_bot'});
    await g.init();
    await tg2.idle.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(g.paired, isFalse);
    expect(g.pairCode, code);
  });

  test('a network error still backs off and retries', () async {
    final tg = _FakeTelegram();
    final waits = <Duration>[];
    final b = TelegramBridge.forTest(secrets: _MemSecrets(), client: tg.client, wait: (d) async => waits.add(d));
    tg.updates.add(http.Response('<html>bad gateway</html>', 502));
    tg.updates.add(_FakeTelegram.ok([]));
    await b.connect('123:abc');
    await tg.idle.future;
    expect(waits, [const Duration(seconds: 3)]);
    expect(b.enabled, isTrue);
    expect(b.status, contains(b.pairCode), reason: 'the pairing hint comes back once Telegram answers again');
  });
}
