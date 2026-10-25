import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Talk to SubMac from Telegram: the user makes a bot with @BotFather, pastes its token,
/// and sends the pairing code to the bot. Only that chat is answered. The token stays on the phone.
class TelegramBridge extends ChangeNotifier {
  TelegramBridge._();
  static final I = TelegramBridge._();

  // Kept on purpose: flutter_secure_storage 10 reads this to migrate data saved by 9.x. Drop it only after every phone ran a v10 build.
  // ignore: deprecated_member_use
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

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

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _token = await _secure.read(key: 'telegram_token') ?? '';
    chatId = p.getInt('telegram_chat');
    botName = p.getString('telegram_bot') ?? '';
    enabled = p.getBool('telegram_on') ?? false;
    if (on) unawaited(_loop());
  }

  String _api(String m) => 'https://api.telegram.org/bot$_token/$m';

  /// Saves the token, checks it, and starts listening for the pairing code.
  Future<String?> connect(String token) async {
    token = token.trim();
    try {
      final r = await http.get(Uri.parse('https://api.telegram.org/bot$token/getMe')).timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body);
      if (j['ok'] != true) return 'Telegram did not accept that token. Copy it again from @BotFather.';
      _token = token;
      botName = '${j['result']['username']}';
      await _secure.write(key: 'telegram_token', value: token);
      final p = await SharedPreferences.getInstance();
      await p.setString('telegram_bot', botName);
      chatId = null;
      await p.remove('telegram_chat');
      pairCode = (100000 + Random.secure().nextInt(900000)).toString();
      enabled = true;
      await p.setBool('telegram_on', true);
      status = 'Send $pairCode to @$botName to link your chat.';
      notifyListeners();
      unawaited(_loop());
      return null;
    } catch (e) {
      return 'Telegram isn\'t answering. Check the bot token and your internet, then try again.';
    }
  }

  Future<void> disconnect() async {
    enabled = false;
    _client?.close();
    _token = '';
    chatId = null;
    botName = '';
    status = '';
    await _secure.delete(key: 'telegram_token');
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
        _client = http.Client();
        final r = await _client!
            .get(Uri.parse('${_api('getUpdates')}?timeout=45&offset=$_offset&allowed_updates=["message"]'))
            .timeout(const Duration(seconds: 60));
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j['ok'] != true) throw '${j['description']}';
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
        status = 'Reconnecting to Telegram…';
        notifyListeners();
        await Future<void>.delayed(Duration(seconds: min(60, 3 * fails)));
      } finally {
        _client?.close();
      }
    }
    _polling = false;
  }

  Future<void> _handle(Map<String, dynamic> m) async {
    final id = (m['chat']['id'] as num).toInt();
    final text = (m['text'] ?? m['caption'] ?? '').toString().trim();
    final from = '${m['from']?['first_name'] ?? 'You'}';
    if (chatId == null) {
      if (pairCode.isNotEmpty && text.contains(pairCode)) {
        chatId = id;
        final p = await SharedPreferences.getInstance();
        await p.setInt('telegram_chat', id);
        pairCode = '';
        status = 'Linked with $from.';
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
      final reply = await (onMessage?.call(text, from) ?? Future.value('SubMac is not ready yet.'));
      await deliver(reply);
    } catch (e) {
      await send('Sorry, that did not work: $e');
    }
  }

  Future<void> _typing() async {
    try {
      await http.post(Uri.parse(_api('sendChatAction')), body: {'chat_id': '$chatId', 'action': 'typing'});
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
    if (t.isEmpty && files.isEmpty) t = 'Done. The details are in the SubMac app.';
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
        await http.post(Uri.parse(_api('sendMessage')), body: {'chat_id': '$chatId', 'text': part});
      } catch (_) {}
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
