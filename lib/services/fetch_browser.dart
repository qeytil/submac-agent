import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'readable.dart';
import 'tools.dart' show AgentTools;

/// One page as the read-only browser sees it.
class FetchPage {
  FetchPage({required this.url, required this.status, this.title = '', this.text = '', this.links = const [], this.note = ''});
  final String url;
  final int status;
  final String title;
  final String text;
  final List<({String text, String url})> links;

  /// Why the page may be incomplete (blocked, needs scripts), '' when it read fine.
  final String note;
}

/// The browser agent's read-only mode for runs with no screen (owner 2026-11-07: "browser use with the app closed").
///
/// Why it exists: the browser agent drives `InAppWebView` widgets that live in the app's widget tree
/// (lib/widgets/browser_layer.dart). With Telesia closed (an alarm started the engine headless) no frame is ever drawn,
/// so the platform view is never created, `BrowserTab.ready` never completes and every browser tool failed after
/// `loadLimit` ("the browser view is not ready"). BrowserAgent first tries an off-screen `HeadlessInAppWebView`
/// (BrowserAgent.headless); when that cannot start either, the task carries on here: plain HTTP GETs, the page's
/// readable text (Readable) and numbered links. It can open pages, follow links, search within a page and read on,
/// which covers research, checking prices, news and status pages. It cannot type, sign in, submit forms, run a page's
/// scripts or pay: those calls answer what is needed instead, and the task finishes with what needs the app open.
class FetchBrowser {
  FetchBrowser._();
  static final FetchBrowser I = FetchBrowser._();

  /// Tests: the network.
  static Future<({int status, String ct, String body, String url})> Function(String url)? getOverride;

  static const pageChars = 6000;
  static const maxLinks = 60;

  final Map<String, FetchPage> _page = {};
  final Map<String, List<String>> _history = {};
  final Map<String, int> _offset = {};

  /// The tools this mode answers, and what each needs instead when it cannot.
  static const readTools = {'browser_open', 'browser_click', 'browser_read', 'browser_find', 'browser_back', 'browser_scroll', 'browser_view', 'browser_act', 'browser_wait', 'browser_tabs'};

  void forget(String job) {
    _page.remove(job);
    _history.remove(job);
    _offset.remove(job);
  }

  FetchPage? pageOf(String job) => _page[job];

  static Future<({int status, String ct, String body, String url})> _get(String url) async {
    final o = getOverride;
    if (o != null) return o(url);
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..headers.addAll({
          'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en,*;q=0.5',
        });
      final res = await client.send(req).timeout(const Duration(seconds: 25));
      final bytes = await AgentTools.readCapped(res.stream, maxBytes: 4 * 1024 * 1024, total: const Duration(seconds: 40));
      return (status: res.statusCode, ct: res.headers['content-type'] ?? '', body: utf8.decode(bytes, allowMalformed: true), url: url);
    } finally {
      client.close();
    }
  }

  /// The readable page of [html] at [url]: title, main text, and the links a person would follow (absolute, deduped).
  static FetchPage parse(String html, String url, {int status = 200}) {
    final doc = html_parser.parse(html);
    final title = (doc.querySelector('title')?.text ?? doc.querySelector('h1')?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    var text = '';
    try {
      text = Readable.text(html);
    } catch (_) {}
    if (text.trim().length < 80) text = AgentTools.htmlText(html);
    final base = Uri.tryParse(url);
    final seen = <String>{};
    final links = <({String text, String url})>[];
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = (a.attributes['href'] ?? '').trim();
      if (href.isEmpty || href.startsWith('#') || href.startsWith('javascript:') || href.startsWith('mailto:') || href.startsWith('tel:')) continue;
      final abs = base?.resolve(href).toString() ?? href;
      if (!abs.startsWith('http')) continue;
      final label = _label(a);
      if (label.isEmpty) continue;
      final k = abs.split('#').first;
      if (!seen.add(k)) continue;
      links.add((text: label, url: k));
      if (links.length >= maxLinks) break;
    }
    final blocked = status == 401 || status == 403 || status == 429 ||
        RegExp(r'just a moment|checking your browser|cf-chl|captcha|access denied|are you a robot', caseSensitive: false)
            .hasMatch(text.length > 3000 ? text.substring(0, 3000) : text);
    final note = blocked
        ? 'This site blocks plain page reads or needs a sign-in: it needs the real browser (the app open).'
        : AgentTools.needsJs(html, text)
            ? 'This page builds itself with scripts, so little of it can be read here: try the site\'s search URL, another page, or another site.'
            : '';
    return FetchPage(url: url, status: status, title: title, text: text.trim(), links: links, note: note);
  }

  static String _label(dom.Element a) {
    var t = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) t = (a.attributes['aria-label'] ?? a.attributes['title'] ?? '').trim();
    if (t.isEmpty) t = (a.querySelector('img')?.attributes['alt'] ?? '').trim();
    return t.length > 90 ? '${t.substring(0, 89)}…' : t;
  }

  /// The view the agent reads: title, URL, a slice of the text from [offset], and the numbered links.
  static String view(FetchPage p, {int offset = 0, String head = 'Read-only page (no screen: fetched, not rendered)'}) {
    final off = offset.clamp(0, p.text.length).toInt();
    final end = (off + pageChars).clamp(0, p.text.length).toInt();
    final more = end < p.text.length ? '\n…(more text: browser_scroll or browser_read with offset $end of ${p.text.length})' : '';
    final sb = StringBuffer()
      ..writeln('$head — ${p.title.isEmpty ? Uri.tryParse(p.url)?.host ?? p.url : p.title}')
      ..writeln('${p.url} (HTTP ${p.status})');
    if (p.note.isNotEmpty) sb.writeln('Note: ${p.note}');
    sb
      ..writeln()
      ..writeln(p.text.substring(off, end) + more);
    if (p.links.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('Links (browser_click with the number follows one):');
      for (var i = 0; i < p.links.length; i++) {
        sb.writeln('[${i + 1}] ${p.links[i].text} → ${p.links[i].url}');
      }
    }
    return sb.toString().trim();
  }

  Future<String> open(String job, String url) async {
    var u = url.trim();
    if (u.isEmpty) return 'Error: give the url.';
    if (!u.startsWith('http')) u = 'https://$u';
    final ({int status, String ct, String body, String url}) r;
    try {
      r = await _get(u);
    } on TimeoutException {
      return 'Error: $u took too long to answer. Try another page or site.';
    } catch (e) {
      return 'Error: could not open $u ($e).';
    }
    final FetchPage p;
    if (r.ct.contains('json')) {
      var body = r.body;
      try {
        body = const JsonEncoder.withIndent('  ').convert(jsonDecode(r.body));
      } catch (_) {}
      p = FetchPage(url: u, status: r.status, title: '${Uri.tryParse(u)?.host ?? u} (JSON)', text: body);
    } else if (r.ct.contains('html') || r.body.trimLeft().startsWith('<')) {
      p = parse(r.body, u, status: r.status);
    } else {
      p = FetchPage(url: u, status: r.status, title: Uri.tryParse(u)?.host ?? u, text: r.body);
    }
    final cur = _page[job];
    if (cur != null) (_history[job] ??= []).add(cur.url);
    _page[job] = p;
    _offset[job] = 0;
    return view(p);
  }

  Future<String> click(String job, int n) async {
    final p = _page[job];
    if (p == null) return 'Error: no page open yet. browser_open a url first.';
    if (n < 1 || n > p.links.length) return 'Error: no link [$n] on this page (links 1-${p.links.length}).';
    return open(job, p.links[n - 1].url);
  }

  String read(String job, {int? offset}) {
    final p = _page[job];
    if (p == null) return 'Error: no page open yet. browser_open a url first.';
    final off = offset ?? 0;
    _offset[job] = off;
    return view(p, offset: off);
  }

  String scroll(String job, {bool up = false}) {
    final p = _page[job];
    if (p == null) return 'Error: no page open yet. browser_open a url first.';
    final now = _offset[job] ?? 0;
    final next = up ? (now - pageChars).clamp(0, p.text.length).toInt() : (now + pageChars).clamp(0, p.text.length).toInt();
    if (!up && next >= p.text.length) return 'End of the page. ${p.links.length} links are listed with the page.';
    _offset[job] = next;
    return view(p, offset: next);
  }

  String find(String job, String q) {
    final p = _page[job];
    if (p == null) return 'Error: no page open yet. browser_open a url first.';
    final k = q.trim().toLowerCase();
    if (k.isEmpty) return 'Error: give the text to find.';
    final hits = <String>[];
    var i = p.text.toLowerCase().indexOf(k);
    while (i >= 0 && hits.length < 8) {
      final s = (i - 200).clamp(0, p.text.length).toInt();
      final e = (i + k.length + 300).clamp(0, p.text.length).toInt();
      hits.add('@$i: …${p.text.substring(s, e).replaceAll(RegExp(r'\s+'), ' ')}…');
      i = p.text.toLowerCase().indexOf(k, i + k.length);
    }
    final links = [
      for (var j = 0; j < p.links.length; j++)
        if (p.links[j].text.toLowerCase().contains(k) || p.links[j].url.toLowerCase().contains(k)) '[${j + 1}] ${p.links[j].text} → ${p.links[j].url}'
    ];
    if (hits.isEmpty && links.isEmpty) return '"$q" is not on this page.';
    return [if (hits.isNotEmpty) 'In the text:\n${hits.join('\n')}', if (links.isNotEmpty) 'Links:\n${links.take(10).join('\n')}'].join('\n\n');
  }

  Future<String> back(String job) async {
    final h = _history[job];
    if (h == null || h.isEmpty) return 'Error: no earlier page.';
    final u = h.removeLast();
    _page.remove(job);
    // open() pushes nothing here (no current page), so the history stays one shorter.
    return open(job, u);
  }

  /// What a call that needs the real browser answers in this mode.
  static String needsScreen(String tool) => 'Not available now: $tool needs the real browser, which cannot run with Telesia closed '
      '(read-only mode: open pages, follow links by number, find text, read on). If the task needs it (typing, signing in, a form, '
      'a payment), finish with success:false and say in one line that it needs Telesia open. For a search, open the site\'s search '
      'URL directly (e.g. https://duckduckgo.com/html/?q=...).';

  /// One browser tool call of job [job] in read-only mode.
  Future<String> execute(String job, String tool, Map<String, dynamic> a) async {
    int? n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    switch (tool) {
      case 'browser_open':
        return open(job, '${a['url'] ?? ''}');
      case 'browser_click':
        final id = n(a['id']) ?? n(a['index']) ?? n(a['element']);
        if (id == null) return 'Error: give the link number (id).';
        return click(job, id);
      case 'browser_read':
      case 'browser_view':
      case 'browser_wait':
        return read(job, offset: n(a['offset']) ?? _offset[job] ?? 0);
      case 'browser_scroll':
        return scroll(job, up: '${a['direction'] ?? ''}'.toLowerCase() == 'up');
      case 'browser_find':
        return find(job, '${a['text'] ?? a['query'] ?? ''}');
      case 'browser_back':
        return back(job);
      case 'browser_tabs':
        final p = _page[job];
        return p == null ? 'No page open.' : 'One page (read-only mode): ${p.url}';
      case 'browser_act':
        // Only link-following steps can run here; the first that needs the real browser stops the batch.
        final acts = a['actions'] is List ? a['actions'] as List : const [];
        final out = <String>[];
        for (final x in acts) {
          if (x is! Map) continue;
          final kind = '${x['action'] ?? x['type'] ?? x['kind'] ?? ''}'.toLowerCase();
          if (kind == 'click' || kind == 'tap') {
            final id = n(x['id']) ?? n(x['index']);
            if (id == null) return [...out, 'Error: a click needs the link number.'].join('\n\n');
            out.add(await click(job, id));
          } else if (kind == 'open' || kind == 'goto' || kind == 'navigate') {
            out.add(await open(job, '${x['url'] ?? ''}'));
          } else if (kind == 'scroll') {
            out.add(scroll(job));
          } else {
            out.add(needsScreen('"$kind"'));
            break;
          }
        }
        return out.isEmpty ? 'Error: no actions.' : out.join('\n\n');
    }
    return needsScreen(tool);
  }
}
