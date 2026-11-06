import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/i18n.dart';

/// Where the bridge keeps its secrets (the bot token and the pairing code). Swapped out in tests.
abstract class TelegramSecrets {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _SecureSecrets implements TelegramSecrets {
  const _SecureSecrets();
  // Kept on purpose: flutter_secure_storage 10 reads this to migrate data saved by 9.x. Drop it only after every phone ran a v10 build.
  // ignore: deprecated_member_use
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  @override
  Future<String?> read(String key) => _secure.read(key: key);
  @override
  Future<void> write(String key, String value) => _secure.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _secure.delete(key: key);
}

/// Talk to SubMac from Telegram: the user makes a bot with @BotFather, pastes its token,
/// and sends the pairing code to the bot. Only that chat is answered. The token stays on the phone.
class TelegramBridge extends ChangeNotifier {
  TelegramBridge._({TelegramSecrets? secrets, http.Client Function()? client, Future<void> Function(Duration)? wait})
      : _secure = secrets ?? const _SecureSecrets(),
        _newClient = client ?? http.Client.new,
        _wait = wait ?? ((d) => Future<void>.delayed(d));
  static final I = TelegramBridge._();

  /// A bridge with its own storage, HTTP client and clock, for tests.
  @visibleForTesting
  factory TelegramBridge.forTest({required TelegramSecrets secrets, required http.Client Function() client, Future<void> Function(Duration)? wait}) =>
      TelegramBridge._(secrets: secrets, client: client, wait: wait);

  final TelegramSecrets _secure;
  final http.Client Function() _newClient;
  final Future<void> Function(Duration) _wait;

  /// How long a pairing code stays good. It is kept across restarts (CB-25) and replaced once it runs out.
  static const pairCodeLife = Duration(hours: 24);
  DateTime? pairCodeExpires;

  String _token = '';
  int? chatId;
  String botName = '';
  String pairCode = '';
  bool enabled = false;
  String status = '';
  bool _polling = false;
  int _offset = 0;
  http.Client? _client;

  /// Runs a message through the agent and gives back the reply (set by AppState).
  Future<String> Function(String text, String from)? onMessage;

  bool get on => enabled && _token.isNotEmpty;
  bool get paired => chatId != null;
  bool get polling => _polling;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _token = await _secure.read('telegram_token') ?? '';
    chatId = p.getInt('telegram_chat');
    botName = p.getString('telegram_bot') ?? '';
    enabled = p.getBool('telegram_on') ?? false;
    if (on && !paired) {
      // CB-25: the code used to live only in memory, so after a restart nothing could pair. Keep it, or make a new one and show it.
      pairCode = await _secure.read('telegram_pair_code') ?? '';
      final exp = int.tryParse(await _secure.read('telegram_pair_expires') ?? '');
      pairCodeExpires = exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp);
      if (_pairCodeStale) await _newPairCode();
      _showPairCode();
    }
    if (on) unawaited(_loop());
  }

  bool get _pairCodeStale => pairCode.isEmpty || pairCodeExpires == null || DateTime.now().isAfter(pairCodeExpires!);

  Future<void> _newPairCode() async {
    pairCode = (100000 + Random.secure().nextInt(900000)).toString();
    pairCodeExpires = DateTime.now().add(pairCodeLife);
    await _secure.write('telegram_pair_code', pairCode);
    await _secure.write('telegram_pair_expires', '${pairCodeExpires!.millisecondsSinceEpoch}');
  }

  Future<void> _clearPairCode() async {
    pairCode = '';
    pairCodeExpires = null;
    await _secure.delete('telegram_pair_code');
    await _secure.delete('telegram_pair_expires');
  }

  void _showPairCode() {
    status = tr('Send {code} to @{bot} to link your chat.', {'code': pairCode, 'bot': botName});
    notifyListeners();
  }

  /// Telegram turned the token down (401 or 404): stop for good until a new token is pasted.
  Future<void> _tokenRejected() async {
    enabled = false;
    status = tr('The token was rejected. Paste a new one.');
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('telegram_on', false);
    } catch (_) {}
    notifyListeners();
  }

  String _api(String m) => 'https://api.telegram.org/bot$_token/$m';

  /// Saves the token, checks it, and starts listening for the pairing code.
  Future<String?> connect(String token) async {
    token = token.trim();
    try {
      final c = _newClient();
      final http.Response r;
      try {
        r = await c.get(Uri.parse('https://api.telegram.org/bot$token/getMe')).timeout(const Duration(seconds: 20));
      } finally {
        c.close();
      }
      final j = jsonDecode(r.body);
      if (j['ok'] != true) return tr('Telegram did not accept that token. Copy it again from @BotFather.');
      _token = token;
      botName = '${j['result']['username']}';
      await _secure.write('telegram_token', token);
      final p = await SharedPreferences.getInstance();
      await p.setString('telegram_bot', botName);
      chatId = null;
      await p.remove('telegram_chat');
      await _newPairCode();
      enabled = true;
      await p.setBool('telegram_on', true);
      _showPairCode();
      unawaited(_loop());
      return null;
    } catch (e) {
      return tr('Telegram isn\'t answering. Check the bot token and your internet, then try again.');
    }
  }

  Future<void> disconnect() async {
    enabled = false;
    _client?.close();
    _token = '';
    chatId = null;
    botName = '';
    status = '';
    await _secure.delete('telegram_token');
    await _clearPairCode();
    final p = await SharedPreferences.getInstance();
    await p.remove('telegram_chat');
    await p.remove('telegram_bot');
    await p.setBool('telegram_on', false);
    notifyListeners();
  }

  Future<void> _loop() async {
    if (_polling) return;
    _polling = true;
    var fails = 0;
    while (on) {
      try {
        _client = _newClient();
        final r = await _client!
            .get(Uri.parse('${_api('getUpdates')}?timeout=45&offset=$_offset&allowed_updates=["message"]'))
            .timeout(const Duration(seconds: 60));
        // CB-25: a revoked or wrong token is not a network blip. Retrying it forever only showed "Reconnecting…".
        if (r.statusCode == 401 || r.statusCode == 404) {
          await _tokenRejected();
          break;
        }
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (r.statusCode == 429 || j['error_code'] == 429) {
          // Too many requests: wait as long as Telegram asks, then carry on. Not a failure.
          final after = (j['parameters']?['retry_after'] as num?)?.toInt() ?? 5;
          await _wait(Duration(seconds: after.clamp(1, 600)));
          continue;
        }
        if (j['ok'] != true) throw '${j['description']}';
        if (fails > 0) {
          // Back online: drop "Reconnecting…" and show the pairing code again if the chat isn't linked yet.
          if (!paired && pairCode.isNotEmpty) {
            _showPairCode();
          } else {
            status = '';
            notifyListeners();
          }
        }
        fails = 0;
        for (final u in (j['result'] as List)) {
          _offset = (u['update_id'] as num).toInt() + 1;
          final m = u['message'];
          if (m == null) continue;
          unawaited(_handle(Map<String, dynamic>.from(m as Map)));
        }
      } catch (e) {
        if (!on) break;
        fails++;
        status = tr('Reconnecting to Telegram…');
        notifyListeners();
        await _wait(Duration(seconds: min(60, 3 * fails)));
      } finally {
        _client?.close();
      }
    }
    _polling = false;
  }

  Future<void> _handle(Map<String, dynamic> m) async {
    // Only a one-to-one chat with the bot pairs or gets answered. Groups and channels are ignored, so a code
    // pasted in a group can't link the whole group to the phone.
    final type = '${m['chat']?['type'] ?? 'private'}';
    if (type != 'private') return;
    final id = (m['chat']['id'] as num).toInt();
    final text = (m['text'] ?? m['caption'] ?? '').toString().trim();
    final from = '${m['from']?['first_name'] ?? 'You'}';
    if (chatId == null) {
      if (_pairCodeStale) {
        // The code ran out (or was never made): make a new one and show it, and don't take this message.
        await _newPairCode();
        _showPairCode();
        return;
      }
      if (text.contains(pairCode)) {
        chatId = id;
        final p = await SharedPreferences.getInstance();
        await p.setInt('telegram_chat', id);
        await _clearPairCode();
        status = tr('Linked with {name}.', {'name': from});
        notifyListeners();
        await send('Linked. Message me here any time and I will work on it on your phone.');
      }
      return;
    }
    if (id != chatId || text.isEmpty) return;
    if (text == '/start') {
      await send('Hi $from. Ask me anything, or give me a task.');
      return;
    }
    unawaited(_typing());
    try {
      final reply = await (onMessage?.call(text, from) ?? Future.value('Telesia is not ready yet.'));
      await deliver(reply);
    } catch (e) {
      await send('Sorry, that did not work: $e');
    }
  }

  Future<void> _typing() async {
    try {
      await _post(_api('sendChatAction'), {'chat_id': '$chatId', 'action': 'typing'});
    } catch (_) {}
  }

  /// Sends a reply: the words as plain text, and any files from ```file cards as documents.
  Future<void> deliver(String reply) async {
    final files = [
      for (final m in RegExp(r'```file\s*\n([^\n`]+)').allMatches(reply)) m.group(1)!.trim(),
      for (final m in RegExp(r'(?:IMAGE_SAVED|FILE_SAVED|VIDEO_SAVED|AUDIO_SAVED) (\S+)').allMatches(reply)) m.group(1)!.trim(),
    ];
    var t = reply
        .replaceAll(RegExp(r'<think(ing)?>[\s\S]*?(</think(ing)?>|$)', caseSensitive: false), '')
        .replaceAllMapped(RegExp(r'```(summary|template|draft)\s*\n([\s\S]*?)```'), (m) => m.group(2)!.trim())
        .replaceAllMapped(RegExp(r'```(links)\s*\n([\s\S]*?)```'), (m) {
          try {
            final l = jsonDecode(m.group(2)!) as List;
            return l.map((e) => '${e['title'] ?? ''} ${e['url'] ?? ''}'.trim()).join('\n');
          } catch (_) {
            return '';
          }
        })
        .replaceAll(RegExp(r'```(table|grid|images|photos|order|order_summary|plan|choices|receipt|confirm|page|file|video)\s*\n[\s\S]*?```'), '')
        .replaceAll(RegExp(r'^\s*---\s*$', multiLine: true), '')
        .replaceAll('**', '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (t.isEmpty && files.isEmpty) t = 'Done. The details are in the Telesia app.';
    if (t.isNotEmpty) await send(t);
    for (final f in files) {
      await _sendFile(f);
    }
  }

  Future<void> send(String text) async {
    if (chatId == null || _token.isEmpty) return;
    for (var i = 0; i < text.length; i += 3900) {
      final part = text.substring(i, min(text.length, i + 3900));
      try {
        await _post(_api('sendMessage'), {'chat_id': '$chatId', 'text': part});
      } catch (_) {}
    }
  }

  Future<void> _post(String url, Map<String, String> body) async {
    final c = _newClient();
    try {
      await c.post(Uri.parse(url), body: body).timeout(const Duration(seconds: 30));
    } finally {
      c.close();
    }
  }

  Future<void> _sendFile(String path) async {
    final f = File(path);
    if (!await f.exists()) return;
    try {
      final isPhoto = RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(path);
      final req = http.MultipartRequest('POST', Uri.parse(_api(isPhoto ? 'sendPhoto' : 'sendDocument')))
        ..fields['chat_id'] = '$chatId'
        ..files.add(await http.MultipartFile.fromPath(isPhoto ? 'photo' : 'document', path));
      await req.send().timeout(const Duration(minutes: 2));
    } catch (_) {}
  }
}
