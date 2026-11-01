// The data ear (P1, browser-godmode): the page's own API calls become readable tools.
import 'dart:convert';

import 'package:agent/services/browser/net_calls.dart';
import 'package:agent/services/browser/page_model.dart';
import 'package:agent/services/browser/page_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatNetList numbers the calls, human sizes, and says when the ear is empty', () {
    expect(formatNetList(const []), contains('No data calls recorded'));
    final out = formatNetList([
      NetCall(id: 3, method: 'GET', url: 'https://fly.test/api/search?q=nairobi', status: 200, ct: 'application/json', ms: 340, size: 4300, body: '{"x":1}'),
      NetCall(id: 4, method: 'GET', url: 'https://fly.test/api/list', status: 204, ct: 'application/json', ms: 88, size: 90),
    ]);
    expect(out, contains('[3] GET https://fly.test/api/search?q=nairobi → 200 json 4.2KB (body ready)'));
    expect(out, contains('[4] GET https://fly.test/api/list → 204 json 90B'));
    expect(out, contains('browser_net with an id reads its body'));
  });

  test('formatNetBody pretty-prints JSON and truncates long bodies', () {
    final one = formatNetBody(NetCall(id: 3, method: 'GET', url: 'https://x.test/api', status: 200, ct: 'application/json', size: 9, body: '{"a":[1,2]}'));
    expect(one, startsWith('GET https://x.test/api → 200 (json, 9B'));
    expect(one, contains('"a": [\n    1,\n    2\n  ]'));
    expect(formatNetBody(NetCall(id: 1, url: 'u', method: 'GET', status: 200, body: '')), contains('No body was kept'));
    final long = formatNetBody(NetCall(id: 2, url: 'u', method: 'GET', status: 200, ct: 'text/plain', size: 20000, body: 'x' * 20000));
    expect(long, contains('truncated at 14000 of 20000'));
  });

  test('formatFetch: binary answers point at browser_download, json answers carry the body', () {
    final bin = formatFetch(method: 'GET', url: 'https://x.test/f.pdf', status: 200, ct: 'application/pdf', body: '\x25PDF');
    expect(bin, contains('binary response'));
    expect(bin, contains('browser_download'));
    final ok = formatFetch(method: 'GET', url: 'https://x.test/api', status: 200, ct: 'application/json', body: '{"ok":true}');
    expect(ok, startsWith('GET https://x.test/api → 200 (json, 11B)'));
    expect(ok, contains('{"ok":true}'));
    final dead = formatFetch(method: 'GET', url: 'https://x.test/api', status: 0, ct: '', body: '');
    expect(dead, contains('no answer'));
  });

  test('dataLine: one quiet line the observe payload gains', () {
    expect(dataLine(12), startsWith('12 data calls on this page'));
    expect(dataLine(12), contains('browser_net'));
    expect(dataLine(12), contains('browser_fetch'));
  });

  test('the page script ships the ear: v12 with netList/netBody/netClear and a calls count in the snapshot', () {
    final src = PageScript.source;
    expect(src, contains('var VERSION = 12;'));
    expect(src, contains('S.netList'), reason: 'the list API the browser_net tool calls');
    expect(src, contains('S.netBody'), reason: 'the one-body API');
    expect(src, contains('S.netClear'), reason: 'the forget API');
    expect(src, contains('calls: S.calls.length'), reason: 'the snapshot count the Data line reads');
    expect(src, contains('20000'), reason: 'bodies are capped');
  });

  test('the ear hears XHR too: exactly one send wrapper, and it records (browser_eval 2026-11-01)', () {
    final src = PageScript.source;
    // A second plain `var ns = function` used to replace the recording one, so jQuery/XHR sites were invisible.
    expect(RegExp(r'var ns = function').allMatches(src).length, 1);
    final send = src.substring(src.indexOf('var ns = function'), src.indexOf('XMLHttpRequest.prototype.send = ns'));
    expect(send, contains('record({'), reason: 'the XHR wrapper must record the call');
  });

  test('a pop-up with no ARIA still counts as a modal (browser_eval: the-internet entry_ad)', () {
    final src = PageScript.source;
    expect(src, contains("[class*=modal i]"));
    expect(src, contains('W * H * 0.3'));
  });

  test('PageSnapshot carries the ear count from the snapshot JSON', () {
    final snap = PageSnapshot.parse(jsonEncode({
      'url': 'https://fly.test/search',
      'title': 'Flights',
      'els': [],
      'text': 'hello',
      'calls': 14,
    }));
    expect(snap.calls, 14);
    expect(PageSnapshot.parse(jsonEncode({'url': 'u', 'els': []})).calls, 0, reason: 'older pages without the ear parse fine');
  });
}
