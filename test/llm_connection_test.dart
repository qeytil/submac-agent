import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// LlmClient shares one HTTP client and stops a request with an abort trigger instead of closing the client.
/// These check that this really works with the http package: an abort ends only its own stream, fast, and the
/// shared client keeps working (and reuses its connection) for the next call.
void main() {
  late HttpServer server;
  final ports = <int>[];
  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      ports.add(req.connectionInfo!.remotePort);
      req.response.headers.contentType = ContentType('text', 'event-stream');
      if (req.uri.path == '/slow') {
        for (var i = 0; i < 50; i++) {
          req.response.write('data: {"n":$i}\n\n');
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      } else {
        req.response.write('data: {"n":1}\n\ndata: [DONE]\n\n');
      }
      await req.response.close();
    });
  });
  tearDownAll(() => server.close(force: true));

  Uri u(String p) => Uri.parse('http://127.0.0.1:${server.port}$p');

  Future<List<String>> read(http.Client c, String path, {Completer<void>? abort}) async {
    final req = http.AbortableRequest('POST', u(path), abortTrigger: abort?.future)..body = '{}';
    final resp = await c.send(req);
    return resp.stream.transform(utf8.decoder).transform(const LineSplitter()).where((l) => l.startsWith('data:')).toList();
  }

  test('an abort mid-stream ends that request quickly; the shared client still works', () async {
    final c = http.Client();
    final abort = Completer<void>();
    final sw = Stopwatch()..start();
    final f = read(c, '/slow', abort: abort);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    abort.complete();
    await expectLater(f, throwsA(isA<http.RequestAbortedException>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(await read(c, '/fast'), ['data: {"n":1}', 'data: [DONE]']);
    c.close();
  });

  test('an abort before the answer arrives stops the request', () async {
    final c = http.Client();
    final abort = Completer<void>()..complete();
    await expectLater(read(c, '/slow', abort: abort), throwsA(isA<http.ClientException>()));
    expect(await read(c, '/fast'), hasLength(2));
    c.close();
  });

  test('two calls in a row reuse one connection', () async {
    final c = http.Client();
    ports.clear();
    final done = Completer<void>();
    await read(c, '/fast', abort: done);
    done.complete(); // finishing a request that already ended changes nothing
    await read(c, '/fast');
    expect(ports, hasLength(2));
    expect(ports[0], ports[1]);
    c.close();
  });
}
