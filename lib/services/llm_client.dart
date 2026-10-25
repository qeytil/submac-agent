import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../models.dart';
import 'cloud.dart';
import 'house_rules.dart';
import 'stream_policy.dart';
import 'usage_accounting.dart';

class LlmException implements Exception {
  final String message;
  final int status;
  final Duration? retryAfter;

  /// The cloud's reason code ('daily_limit', 'busy', 'paused', 'blocked', 'auth'...), '' otherwise.
  final String code;
  /// Vendor and model names are scrubbed here, so no error text or detail ever names a provider.
  LlmException(String message, {this.status = 0, this.retryAfter, this.code = ''}) : message = HouseRules.scrub(message);

  /// Today's allowance is used up (or the account is paused): waiting a minute won't help.
  /// Includes the Contract A codes limit_daily / limit_total / no_plan / blocked.
  bool get isFinal =>
      // too_long (CB-30): the same request is just as long the second time, so it is never re-sent as it is.
      const {'daily_limit', 'background_paused', 'blocked', 'paused', 'auth', 'too_large', 'too_long', 'payments_pending'}.contains(code) ||
      StreamPolicy.finalCodes.contains(code);
  /// The message is too long for the model: compact the chat instead of retrying the same thing.
  bool get isTooLong => code == 'too_long' || code == 'too_large';
  bool get isRateLimit =>
      !isFinal && (status == 429 || message.contains('RESOURCE_EXHAUSTED') || message.toLowerCase().contains('rate limit'));
  bool get isRetryable => !isFinal && !isTooLong && (isRateLimit || status >= 500 || status == 0 || (status >= 300 && status < 400));
  bool get isAuth => status == 401 || status == 403;
  @override
  String toString() => message;
}

class LlmResult {
  final String content;
  final List<ToolCall> toolCalls;
  final String? finishReason;
  /// Tokens this call used (the provider's count, or an estimate).
  final int tokens;
  /// The prompt and output parts of [tokens] (0 when unknown).
  final int tokensIn, tokensOut;
  /// CB-20: the part of [tokensIn] the provider read from its prompt cache (billed at the cached weight).
  final int tokensCached;
  LlmResult(this.content, this.toolCalls, this.finishReason, [this.tokens = 0, this.tokensIn = 0, this.tokensOut = 0, this.tokensCached = 0]);
  /// The model ran out of room for its answer (it was cut off mid-way).
  bool get cutOff => finishReason == 'length' || finishReason == 'max_tokens';
}

/// Minimal OpenAI-compatible client (chat completions with streaming + tools).
class LlmClient {
  /// One HTTP client for every model call, so steps reuse the open connection (no new TLS handshake each step).
  /// Cancel and steer abort only their own request through [_abort]; the shared client is never closed.
  static http.Client _shared = http.Client();

  /// Tests: a fake HTTP client and fixed headers, so no network and no signed-in session are needed.
  @visibleForTesting
  static set testClient(http.Client c) => _shared = c;
  @visibleForTesting
  static Future<Map<String, String>> Function(String source)? testHeaders;
  Completer<void>? _abort;
  bool _cancelled = false;

  void _abortNow() {
    final a = _abort;
    if (a != null && !a.isCompleted) a.complete();
  }

  /// Conversation id sent as `x-submac-chat`, so the cloud keeps one chat on the same model and key
  /// and the provider's prompt cache is reused between steps. Never contains message content.
  String? chatId;

  /// Work nobody is watching (bot wakes, office work): sent as `x-submac-lane: background`, so it uses the bots'
  /// share of the daily allowance and pauses (429 background_paused) instead of blocking the user's own chats.
  bool background = false;

  void cancel() {
    _cancelled = true;
    _abortNow();
  }

  /// The user spoke mid-task: drop this request only if nothing has streamed yet, so the step restarts and hears them.
  bool steered = false;
  bool _gotData = false;
  void cancelForSteer() {
    if (_gotData || _abort == null || _cancelled) return;
    steered = true;
    _cancelled = true;
    _abortNow();
  }

  /// What a stream that closed without its end mark says (CB-24). Status 0: retryable, so the runner re-sends the step.
  static const droppedText = 'The connection dropped. Please try again.';

  /// Longest silence allowed inside a stream before it counts as dropped. The server pings every 10 s (`: ping`),
  /// so 30 s of nothing is a dead line (PLAN 1.3).
  static Duration get idleTimeout => StreamPolicy.silence;

  /// Every request goes to SubMac Cloud, signed with the user's session.
  Future<Map<String, String>> _headers(String source) async {
    final th = testHeaders;
    if (th != null) return th(source);
    try {
      final h = await Cloud.headers(source: source, background: background);
      final c = chatId;
      if (c != null && c.isNotEmpty) h['x-submac-chat'] = c.length > 64 ? c.substring(0, 64) : c;
      return h;
    } on CloudException catch (e) {
      throw LlmException(e.message, status: e.status, code: e.code);
    }
  }

  static LlmException _cloudError(int status, String body) {
    final e = Cloud.errorFrom(status, body);
    return LlmException(e.message, status: status, code: e.code);
  }

  Future<LlmResult> streamChat({
    required ProviderConfig provider,
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required void Function(String delta) onDelta,
    int? maxTokens,
    String source = 'agent',
    void Function(int chars)? onReasoning,
    void Function(String name)? onToolStart,
    /// The server's heartbeat (`: ping`): the line is alive while the model works.
    void Function()? onPing,
    /// `x-submac-effort`: 'low' (greetings, short questions, step 1), 'high' ("think harder"), null = normal.
    String? effort,
  }) async {
    final abort = Completer<void>();
    _abort = abort;
    if (_cancelled) abort.complete();
    // The server picks the model and its reasoning level; the app only sends the job and a length cap.
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      if (maxTokens != null) 'max_tokens': maxTokens,
      // Steadier, more literal answers: less drifting and fewer made-up details on agent steps.
      'temperature': (tools != null && tools.isNotEmpty) ? 0.3 : 0.5,
    };
    final req = http.AbortableRequest('POST', Uri.parse(provider.normalizedBaseUrl), abortTrigger: abort.future);
    req.headers.addAll(await _headers(source));
    req.headers['Accept'] = 'text/event-stream';
    if (effort != null) req.headers['x-submac-effort'] = effort;
    req.body = jsonEncode(body);

    final buf = StringBuffer();
    final calls = <int, ToolCall>{};
    String? finish;
    int? usedIn, usedOut;
    var usedCached = 0;
    // CB-24: the server always ends a reply with a finish_reason and `data: [DONE]`. A stream that just stops (a proxy or
    // gateway cut, a radio switch) is a dropped line, never the whole answer.
    var ended = false;
    try {
      final http.StreamedResponse resp;
      try {
        resp = await _shared.send(req).timeout(StreamPolicy.headers);
      } on TimeoutException {
        throw LlmException(StreamPolicy.textFor('busy'), status: 503, code: 'busy');
      }
      Cloud.readHeaders(resp.headers);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final text = await resp.stream.bytesToString();
        final e = _cloudError(resp.statusCode, text);
        throw LlmException(e.message, status: e.status, code: e.code, retryAfter: parseRetryAfter(resp.headers['retry-after']));
      }
      // A stream that stalls (no byte for [idleTimeout]) is treated as dropped instead of hanging the task forever.
      final lines = resp.stream
          .timeout(idleTimeout, onTimeout: (sink) => sink.addError(TimeoutException('stream idle')))
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      var event = '';
      await for (final raw in lines) {
        if (_cancelled) break;
        final line = raw.trim();
        if (line.isEmpty) {
          event = ''; // an SSE event ends at a blank line
          continue;
        }
        // Heartbeat (Contract A): `: ping` at once, then every 10 s while the model works.
        if (line.startsWith(':')) {
          onPing?.call();
          continue;
        }
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
          continue;
        }
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        // Read on to the end instead of breaking, so the connection goes back to the pool for the next step.
        if (data == '[DONE]') {
          ended = true;
          continue;
        }
        Map<String, dynamic> j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (j['error'] != null || event == 'error') throw sseError(j);
        final u = j['usage'];
        if (u is Map) {
          usedIn = (u['prompt_tokens'] as num?)?.toInt() ?? usedIn;
          usedOut = (u['completion_tokens'] as num?)?.toInt() ?? usedOut;
          final hit = UsageUnits.cachedOf(u);
          if (hit > 0) usedCached = hit;
        }
        final choices = j['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;
        final delta = (choice['delta'] as Map?) ?? const {};
        // Thinking models stream their reasoning first: never shown, but it tells the app the model is alive.
        final rc = delta['reasoning_content'] ?? delta['reasoning'];
        if (rc is String && rc.isNotEmpty) onReasoning?.call(rc.length);
        final c = delta['content'];
        if (c is String && c.isNotEmpty) {
          _gotData = true;
          buf.write(c);
          onDelta(c);
        }
        final tcs = delta['tool_calls'] as List?;
        if (tcs != null) {
          _gotData = true;
          for (final t in tcs) {
            final tc = Map<String, dynamic>.from(t as Map);
            final idx = (tc['index'] as num?)?.toInt() ?? calls.length;
            final fn = (tc['function'] as Map?) ?? const {};
            final existing = calls[idx];
            if (existing == null) {
              final nm = (fn['name'] ?? '') as String;
              if (nm.isNotEmpty) onToolStart?.call(nm);
              calls[idx] = ToolCall(
                id: (tc['id'] ?? 'call_$idx') as String,
                name: (fn['name'] ?? '') as String,
                arguments: (fn['arguments'] ?? '') as String,
                extra: mergeExtra(null, tc['extra_content']),
              );
            } else {
              existing.extra = mergeExtra(existing.extra, tc['extra_content']);
              if (tc['id'] is String && (tc['id'] as String).isNotEmpty) existing.id = tc['id'] as String;
              if (fn['name'] is String && (fn['name'] as String).isNotEmpty) {
                final first = existing.name.isEmpty;
                existing.name += fn['name'] as String;
                if (first) onToolStart?.call(existing.name);
              }
              if (fn['arguments'] is String) existing.arguments += fn['arguments'] as String;
            }
          }
        }
        final fr = choice['finish_reason'];
        if (fr is String) {
          finish = fr;
          ended = true;
        }
      }
      if (!ended && !_cancelled) {
        throw LlmException(droppedText, code: 'dropped');
      }
    } on LlmException {
      rethrow;
    } catch (e) {
      if (!_cancelled) {
        final offline = e is SocketException || '$e'.contains('SocketException') || '$e'.contains('Failed host lookup');
        throw LlmException(offline ? 'You\'re offline. Check your connection and try again.' : 'The connection dropped. Please try again.');
      }
    } finally {
      // Ends this request only (a timed-out or broken one must not linger); a finished one is unaffected.
      if (!abort.isCompleted) abort.complete();
    }
    if (steered) throw LlmException('steered');
    final keys = calls.keys.toList()..sort();
    final toolText = calls.values.fold<int>(0, (a, c) => a + c.arguments.length + c.name.length);
    final tin = usedIn ?? (req.body.replaceAll(RegExp(r'data:[^"]{200,}'), '').length ~/ 4 + 0);
    final tout = usedOut ?? ((buf.length + toolText) ~/ 4);
    return LlmResult(buf.toString(), [for (final k in keys) calls[k]!], finish, tin + tout, tin, tout, usedIn == null ? 0 : usedCached);
  }

  Future<String> complete({
    required ProviderConfig provider,
    required String model,
    required List<Map<String, dynamic>> messages,
    int? maxTokens,
    String source = 'agent',
  }) async {
    final http.Response resp;
    try {
      resp = await _shared
          .post(
            Uri.parse(provider.normalizedBaseUrl),
            headers: await _headers(source),
            body: jsonEncode({'model': model, 'messages': messages, 'stream': false, if (maxTokens != null) 'max_tokens': maxTokens}),
          )
          // The server stops non-streamed calls at 45 s and always answers; a little more for the trip.
          .timeout(const Duration(seconds: 50));
    } on TimeoutException {
      throw LlmException('That took too long. Please try again.');
    } on SocketException {
      throw LlmException('You\'re offline. Check your connection and try again.');
    }
    Cloud.readHeaders(resp.headers);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final e = _cloudError(resp.statusCode, resp.body);
      throw LlmException(e.message, status: e.status, code: e.code, retryAfter: parseRetryAfter(resp.headers['retry-after']));
    }
    final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = j['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = (choices.first as Map)['message'] as Map?;
    return (msg?['content'] ?? '').toString();
  }

  /// An SSE `error` event (Contract A: busy, too_long, limit_daily, limit_total, no_plan, blocked, server) as an
  /// exception the agent loop understands. The server's text is fixed and friendly; anything else gets ours.
  static LlmException sseError(Map<String, dynamic> j) {
    final err = j['error'];
    final raw = err is Map ? err['code'] : null;
    // Older servers put a number (the upstream status) in `code`: that is a dropped model, not a Contract A code.
    if (raw is num || raw == null) {
      return LlmException('SubMac lost the connection for a moment. Please try again.', status: raw is num ? raw.toInt() : 502);
    }
    final code = '$raw';
    final known = StreamPolicy.finalCodes.contains(code) || StreamPolicy.retryCodes.contains(code) || code == 'too_long';
    final c = known ? code : 'server';
    final msg = err is Map && err['message'] is String && '${err['message']}'.trim().isNotEmpty ? '${err['message']}'.trim() : StreamPolicy.textFor(c);
    final ra = err is Map ? err['retry_after'] : null;
    return LlmException(msg,
        status: StreamPolicy.statusFor(c),
        code: c,
        retryAfter: ra is num ? Duration(milliseconds: (ra * 1000).round()) : null);
  }

  /// Gemini sends `extra_content.google.thought_signature` on a tool call (usually on its first delta). Kept whole and
  /// merged across deltas, so it goes back exactly as it came.
  @visibleForTesting
  static Map<String, dynamic>? mergeExtra(Map<String, dynamic>? had, Object? more) {
    if (more is! Map || more.isEmpty) return had;
    final out = <String, dynamic>{...?had};
    more.forEach((k, v) {
      final key = '$k';
      final old = out[key];
      out[key] = (old is Map && v is Map) ? {...Map<String, dynamic>.from(old), ...Map<String, dynamic>.from(v)} : v;
    });
    return out;
  }

  static Duration? parseRetryAfter(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final n = double.tryParse(v.trim());
    if (n != null) return Duration(milliseconds: (n * 1000).round());
    final d = HttpDateParser.tryParse(v.trim());
    if (d == null) return null;
    final diff = d.difference(DateTime.now().toUtc());
    return diff.isNegative ? Duration.zero : diff;
  }

}

/// Tiny HTTP-date parser (RFC 1123) so we can honour Retry-After dates.
class HttpDateParser {
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static DateTime? tryParse(String s) {
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(s);
    if (m == null) return null;
    final mon = _months.indexOf(m.group(2)!);
    if (mon < 0) return null;
    return DateTime.utc(int.parse(m.group(3)!), mon + 1, int.parse(m.group(1)!), int.parse(m.group(4)!),
        int.parse(m.group(5)!), int.parse(m.group(6)!));
  }
}
