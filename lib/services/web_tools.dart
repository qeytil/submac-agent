import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tools.dart' show AgentTools;

/// Tools that work without any login: web search, weather, Wikipedia,
/// currency rates, places, RSS feeds and YouTube transcripts.
class WebTools {
  static const userAgent = 'SubMacAgent/1.4 (+https://submac.site; Android app)';
  static const _browserUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

  /// Optional keys for better search (set in Settings > Connectors).
  static String braveKey = '';
  static String tavilyKey = '';

  static const names = {
    'web_search',
    'web_research',
    'get_weather',
    'wikipedia',
    'currency_convert',
    'find_place',
    'read_rss',
    'youtube_transcript',
  };

  static final List<Map<String, dynamic>> definitions = [
    _fn('web_search',
        'Search the web for current information. Returns titles, links and snippets. '
            'Use it for news, prices, opening hours, facts that may have changed, or anything you are unsure of. '
            'Then read the best pages with fetch_url when you need detail.',
        {
          'query': {'type': 'string', 'description': 'What to search for.'},
          'max_results': {'type': 'integer', 'description': 'How many results (default 6, max 10).'},
        },
        ['query']),
    _fn('web_research',
        'Research a question in one call: searches the web, reads the best pages at the same time, and returns the passages '
            'that answer it, with their links. Use it for anything you do not know well (a topic, a product, a person, how to do '
            'something, current facts); then fetch_url a source for more.',
        {
          'question': {'type': 'string'},
          'queries': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Extra searches, other wordings or languages.'},
          'sources': {'type': 'integer', 'description': 'Pages to read (default 5, max 8).'},
        },
        ['question']),
    _fn('get_weather', 'Current weather and a 5-day forecast for a place (Open-Meteo).', {
      'place': {'type': 'string', 'description': 'City or place name, e.g. "Mogadishu" or "Paris, France".'},
    }, ['place']),
    _fn('wikipedia', 'Look something up on Wikipedia and return a short summary with the link.', {
      'query': {'type': 'string'},
      'lang': {'type': 'string', 'description': 'Language code, default "en" (e.g. "so" for Somali).'},
    }, ['query']),
    _fn('currency_convert', 'Convert money between currencies with today\'s exchange rates.', {
      'amount': {'type': 'number'},
      'from': {'type': 'string', 'description': 'Currency code, e.g. USD'},
      'to': {'type': 'string', 'description': 'Currency code, e.g. EUR. Comma-separate several.'},
    }, ['amount', 'from', 'to']),
    _fn('find_place', 'Find places, addresses or businesses on the map (OpenStreetMap). Returns names, addresses and map links.', {
      'query': {'type': 'string', 'description': 'e.g. "pharmacy near Hodan, Mogadishu" or a full address.'},
      'limit': {'type': 'integer', 'description': 'Default 5.'},
    }, ['query']),
    _fn('read_rss', 'Read the latest items of an RSS or Atom news feed.', {
      'url': {'type': 'string'},
      'limit': {'type': 'integer', 'description': 'Default 10.'},
    }, ['url']),
    _fn('youtube_transcript', 'Get the spoken transcript of a YouTube video (when the video has captions), to summarise it.', {
      'url': {'type': 'string', 'description': 'YouTube link or video id.'},
      'lang': {'type': 'string', 'description': 'Preferred caption language, default "en".'},
    }, ['url']),
  ];

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> required) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      switch (name) {
        case 'web_search':
          final n = (AgentTools.intArg(a['max_results']) ?? 6).clamp(1, 10);
          return await webSearch((a['query'] ?? '').toString(), n);
        case 'web_research':
          return await research((a['question'] ?? '').toString(),
              extra: [if (a['queries'] is List) for (final q in a['queries'] as List) '$q' else if (a['queries'] is String) '${a['queries']}'],
              sources: (AgentTools.intArg(a['sources']) ?? 5).clamp(1, 8));
        case 'get_weather':
          return await weather((a['place'] ?? '').toString());
        case 'wikipedia':
          return await wikipedia((a['query'] ?? '').toString(), (a['lang'] ?? 'en').toString());
        case 'currency_convert':
          return await currency(AgentTools.numArg(a['amount']) ?? 1, (a['from'] ?? 'USD').toString(),
              (a['to'] ?? 'EUR').toString());
        case 'find_place':
          return await places((a['query'] ?? '').toString(), (AgentTools.intArg(a['limit']) ?? 5).clamp(1, 10));
        case 'read_rss':
          return await rss((a['url'] ?? '').toString(), (AgentTools.intArg(a['limit']) ?? 10).clamp(1, 30));
        case 'youtube_transcript':
          return await youtube((a['url'] ?? '').toString(), (a['lang'] ?? 'en').toString());
      }
      return 'Error: unknown tool "$name"';
    } on TimeoutException {
      return 'Error: the website took too long to answer.';
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<dynamic> _json(Uri u, {Map<String, String>? headers}) async {
    final r = await http
        .get(u, headers: {'User-Agent': userAgent, 'Accept': 'application/json', ...?headers})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode >= 400) throw Exception('HTTP ${r.statusCode} from ${u.host}');
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  // ---------------- search ----------------
  static Future<String> webSearch(String q, int n) async {
    if (q.trim().isEmpty) return 'Error: empty query';
    List<Map<String, String>> results = [];
    String engine = '';
    final attempts = <(String, Future<List<Map<String, String>>> Function())>[
      if (tavilyKey.isNotEmpty) ('Tavily', () => _tavily(q, n)),
      if (braveKey.isNotEmpty) ('Brave', () => _brave(q, n)),
      // No key: three independent engines at once, first good answer in priority order wins (one engine blocking
      // a phone or a network no longer leaves the agent with encyclopedia titles only).
      ('web', () => _keyless(q, n)),
      ('DuckDuckGo', () => _ddgLite(q, n)),
      ('Wikipedia', () => _wikiSearch(q, n)),
    ];
    final errors = <String>[];
    for (final a in attempts) {
      try {
        results = await a.$2();
        if (results.isNotEmpty) {
          engine = a.$1 == 'web' ? _lastKeyless : a.$1;
          break;
        }
      } catch (e) {
        errors.add('${a.$1}: $e');
      }
    }
    if (results.isEmpty) {
      return 'Error: web search found nothing${errors.isEmpty ? '' : ' (${errors.join('; ')})'}. '
          'Try different words, or read a known site with fetch_url.';
    }
    // CB-38: with no search key and DuckDuckGo failing, only Wikipedia answered. Said plainly, so the model never takes
    // encyclopedia titles for web results (it looped through searches and costly browser tasks).
    if (engine == 'Wikipedia') {
      return jsonEncode({
        'query': q,
        'engine': engine,
        'warning': wikiOnlyWarning,
        'results': results.take(n).toList(),
      });
    }
    return jsonEncode({
      'query': q,
      'engine': engine,
      'results': results.take(n).toList(),
      'note': 'Show the sources you used to the user as a links card.',
    });
  }

  /// CB-38: the label on results that came only from Wikipedia because web search failed.
  static const wikiOnlyWarning = 'Web search unavailable; these are encyclopedia results only (Wikipedia), not web results. '
      'They will not have prices, news, opening hours or shop pages. Read a known site with fetch_url instead, '
      'or answer with what you already have.';

  static String _strip(String html) => _decode(html.replaceAll(RegExp(r'<[^>]+>'), '')).replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _decode(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      // A code point out of range (or too many digits) is left as written: it threw, and the whole engine's results
      // were dropped for one odd title.
      .replaceAllMapped(RegExp(r'&#(\d{1,7});'), (m) {
        final c = int.parse(m[1]!);
        return c > 0 && c <= 0x10FFFF && (c < 0xD800 || c > 0xDFFF) ? String.fromCharCode(c) : m[0]!;
      });

  static Future<List<Map<String, String>>> _ddgHtml(String q, int n) async {
    final r = await http.post(Uri.parse('https://html.duckduckgo.com/html/'),
        headers: {'User-Agent': _browserUa, 'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'q=${Uri.encodeQueryComponent(q)}&kl=wt-wt').timeout(const Duration(seconds: 20));
    final s = utf8.decode(r.bodyBytes, allowMalformed: true);
    final out = <Map<String, String>>[];
    final links = RegExp(r'''<a[^>]*class=["']result__a["'][^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>''').allMatches(s).toList();
    final snippets = RegExp(r'''class=["']result__snippet["'][^>]*>([\s\S]*?)</(?:a|div|td)>''').allMatches(s).toList();
    for (var i = 0; i < links.length && out.length < n; i++) {
      var href = _decode(links[i].group(1)!);
      final m = RegExp(r'uddg=([^&]+)').firstMatch(href);
      if (m != null) href = Uri.decodeComponent(m.group(1)!);
      if (href.startsWith('//')) href = 'https:$href';
      if (href.contains('duckduckgo.com/y.js')) continue; // ads
      out.add({
        'title': _strip(links[i].group(2)!),
        'url': href,
        'snippet': i < snippets.length ? _strip(snippets[i].group(1)!) : '',
      });
    }
    return out;
  }

  static String _lastKeyless = 'web';

  /// DuckDuckGo, Bing and Brave (their plain HTML pages) at the same time. Waits for the first engine in priority
  /// order that answers with results; an engine that fails or finds nothing hands over to the next.
  static Future<List<Map<String, String>>> _keyless(String q, int n) async {
    final engines = <(String, Future<List<Map<String, String>>>)>[
      ('DuckDuckGo', _ddgHtml(q, n).catchError((_) => <Map<String, String>>[])),
      ('Bing', _bing(q, n).catchError((_) => <Map<String, String>>[])),
      ('Brave', _braveHtml(q, n).catchError((_) => <Map<String, String>>[])),
    ];
    for (final e in engines) {
      final r = await e.$2.timeout(const Duration(seconds: 22), onTimeout: () => <Map<String, String>>[]);
      if (r.isNotEmpty) {
        _lastKeyless = e.$1;
        return r;
      }
    }
    return [];
  }

  static Future<List<Map<String, String>>> _bing(String q, int n) async {
    final r = await http
        .get(Uri.parse('https://www.bing.com/search?q=${Uri.encodeQueryComponent(q)}&setlang=en&count=${n + 4}'),
            headers: {'User-Agent': _browserUa, 'Accept-Language': 'en,*;q=0.5'})
        .timeout(const Duration(seconds: 20));
    return parseBing(utf8.decode(r.bodyBytes, allowMalformed: true), n);
  }

  /// Bing's result page: each `li.b_algo` has the link around an h2 (or an h2 around the link) and a caption.
  /// Links may be Bing click-through URLs carrying the real one base64url-encoded in `u=a1...`.
  static List<Map<String, String>> parseBing(String s, int n) {
    final out = <Map<String, String>>[];
    for (final blk in s.split('<li class="b_algo"').skip(1)) {
      if (out.length >= n) break;
      final m = RegExp(r'<a[^>]*href="([^"]+)"[^>]*>(?:(?!</a>)[\s\S])*?<h2[^>]*>([\s\S]*?)</h2>').firstMatch(blk) ??
          RegExp(r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>').firstMatch(blk);
      if (m == null) continue;
      var url = _decode(m.group(1)!);
      final ck = RegExp(r'[?&]u=a1([^&]+)').firstMatch(url);
      if (url.contains('/ck/a?') && ck != null) {
        try {
          url = utf8.decode(base64Url.decode(base64Url.normalize(ck.group(1)!)));
        } catch (_) {}
      }
      if (!url.startsWith('http') || url.contains('bing.com/')) continue;
      final sn = RegExp(r'<p[^>]*>([\s\S]*?)</p>').firstMatch(blk);
      out.add({'title': _strip(m.group(2)!), 'url': url, 'snippet': sn == null ? '' : _strip(sn.group(1)!)});
    }
    return out;
  }

  static Future<List<Map<String, String>>> _braveHtml(String q, int n) async {
    final r = await http
        .get(Uri.parse('https://search.brave.com/search?q=${Uri.encodeQueryComponent(q)}&source=web'),
            headers: {'User-Agent': _browserUa, 'Accept-Language': 'en,*;q=0.5'})
        .timeout(const Duration(seconds: 20));
    return parseBraveHtml(utf8.decode(r.bodyBytes, allowMalformed: true), n);
  }

  /// Brave Search's page: each web result is a block marked data-type="web" with the link, a title and a snippet.
  static List<Map<String, String>> parseBraveHtml(String s, int n) {
    final out = <Map<String, String>>[];
    for (final raw in s.split('data-type="web"').skip(1)) {
      if (out.length >= n) break;
      final blk = raw.length > 8000 ? raw.substring(0, 8000) : raw;
      final a = RegExp(r'<a[^>]*href="(https?://[^"]+)"').firstMatch(blk);
      if (a == null || a.group(1)!.contains('brave.com')) continue;
      final t = RegExp(r'class="title[^"]*"[^>]*>([\s\S]*?)</div>').firstMatch(blk);
      final d = RegExp(r'class="(?:snippet-description|content)[^"]*"[^>]*>([\s\S]*?)</div>').firstMatch(blk);
      out.add({
        'title': t == null ? a.group(1)! : _strip(t.group(1)!),
        'url': _decode(a.group(1)!),
        'snippet': d == null ? '' : _strip(d.group(1)!),
      });
    }
    return out;
  }

  // ---------------- research: search + read the best pages at once ----------------
  /// One call that does what a person does with a search: run it (plus [extra] wordings), open the best [sources]
  /// pages in parallel, and keep the passages that speak to the question. Each source carries its link.
  static Future<String> research(String question, {List<String> extra = const [], int sources = 5}) async {
    final q = question.trim();
    if (q.isEmpty) return 'Error: empty question';
    final queries = [q, ...extra.map((e) => e.trim()).where((e) => e.isNotEmpty && e != q)].take(4).toList();
    final found = <Map<String, String>>[];
    final seen = <String>{};
    String engine = '';
    final lists = await Future.wait(queries.map((x) => webSearch(x, 8).catchError((_) => '')));
    for (final l in lists) {
      try {
        final j = jsonDecode(l) as Map<String, dynamic>;
        engine = engine.isEmpty ? '${j['engine'] ?? ''}' : engine;
        for (final r in (j['results'] as List? ?? const [])) {
          final m = Map<String, String>.from((r as Map).map((k, v) => MapEntry('$k', '$v')));
          final host = Uri.tryParse(m['url'] ?? '')?.host ?? '';
          if (host.isEmpty || !seen.add(m['url']!)) continue;
          found.add(m);
        }
      } catch (_) {}
    }
    if (found.isEmpty) {
      return 'Error: the web search found nothing for this question. Try other words (queries), or read a site you know with fetch_url.';
    }
    // Prefer different sites: one page per host first, then the rest.
    final hosts = <String>{};
    final pick = <Map<String, String>>[
      ...found.where((m) => hosts.add(Uri.parse(m['url']!).host)),
      ...found,
    ].toSet().take(sources).toList();
    final terms = keyTerms([q, ...extra].join(' '));
    final read = await Future.wait(pick.map((m) async {
      try {
        final page = await AgentTools.fetchUrl(m['url']!, 0).timeout(const Duration(seconds: 18));
        final body = page.startsWith('HTTP ') ? page.substring(page.indexOf('\n') + 1) : page;
        return {...m, 'excerpt': bestPassages(body, terms, 2200)};
      } catch (_) {
        return {...m, 'excerpt': '', 'error': 'could not read this page'};
      }
    }));
    return jsonEncode({
      'question': q,
      'engine': engine,
      'sources': [for (final r in read) {'title': r['title'], 'url': r['url'], 'snippet': r['snippet'], 'excerpt': r['excerpt'], if (r['error'] != null) 'error': r['error']}],
      'more': [for (final m in found.skip(pick.length).take(6)) {'title': m['title'], 'url': m['url']}],
      'note': 'Answer from these passages and cite the links you used. Read a source in full with fetch_url when a passage is not enough.',
    });
  }

  static const _stop = {
    'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'is', 'are', 'was', 'what', 'how', 'why', 'when', 'who',
    'which', 'with', 'about', 'from', 'by', 'at', 'it', 'be', 'do', 'does', 'can', 'i', 'my', 'me', 'you', 'your', 'this', 'that',
  };

  /// The words of a question that a passage should contain (lowercase, no stop words).
  static List<String> keyTerms(String q) => {
        for (final w in q.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
          if (w.length > 2 && !_stop.contains(w)) w,
      }.toList();

  /// The paragraphs of [text] that mention the most [terms], in page order, up to [max] characters. Falls back to the
  /// start of the page when nothing matches.
  static String bestPassages(String text, List<String> terms, int max) {
    final paras = text.split(RegExp(r'\n\s*\n|\n')).map((p) => p.trim()).where((p) => p.length > 40).toList();
    if (paras.isEmpty) return text.length > max ? text.substring(0, max) : text;
    final scored = <(int, int)>[];
    for (var i = 0; i < paras.length; i++) {
      final l = paras[i].toLowerCase();
      var s = 0;
      for (final t in terms) {
        if (l.contains(t)) s++;
      }
      if (s > 0) scored.add((i, s));
    }
    if (scored.isEmpty) {
      final t = paras.join('\n');
      return t.length > max ? '${t.substring(0, max)}…' : t;
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final keep = <int>{};
    var len = 0;
    for (final s in scored) {
      final p = paras[s.$1];
      if (len + p.length > max && keep.isNotEmpty) continue;
      keep.add(s.$1);
      len += p.length + 1;
      if (len >= max) break;
    }
    final out = [for (final i in keep.toList()..sort()) paras[i]].join('\n');
    return out.length > max ? '${out.substring(0, max)}…' : out;
  }

  static Future<List<Map<String, String>>> _ddgLite(String q, int n) async {
    final r = await http
        .get(Uri.parse('https://lite.duckduckgo.com/lite/?q=${Uri.encodeQueryComponent(q)}'),
            headers: {'User-Agent': _browserUa})
        .timeout(const Duration(seconds: 20));
    final s = utf8.decode(r.bodyBytes, allowMalformed: true);
    final out = <Map<String, String>>[];
    final links = RegExp(r'''<a[^>]*href=["']([^"']+)["'][^>]*class=["']result-link["'][^>]*>([\s\S]*?)</a>''').allMatches(s).toList();
    final snippets = RegExp(r'''class=["']result-snippet["'][^>]*>([\s\S]*?)</td>''').allMatches(s).toList();
    for (var i = 0; i < links.length && out.length < n; i++) {
      var href = _decode(links[i].group(1)!);
      final m = RegExp(r'uddg=([^&]+)').firstMatch(href);
      if (m != null) href = Uri.decodeComponent(m.group(1)!);
      if (href.startsWith('//')) href = 'https:$href';
      out.add({
        'title': _strip(links[i].group(2)!),
        'url': href,
        'snippet': i < snippets.length ? _strip(snippets[i].group(1)!) : '',
      });
    }
    return out;
  }

  static Future<List<Map<String, String>>> _brave(String q, int n) async {
    final j = await _json(
        Uri.parse('https://api.search.brave.com/res/v1/web/search?q=${Uri.encodeQueryComponent(q)}&count=$n'),
        headers: {'X-Subscription-Token': braveKey});
    final list = (j['web']?['results'] as List?) ?? const [];
    return [
      for (final e in list)
        {
          'title': _strip((e['title'] ?? '').toString()),
          'url': (e['url'] ?? '').toString(),
          'snippet': _strip((e['description'] ?? '').toString()),
        }
    ];
  }

  static Future<List<Map<String, String>>> _tavily(String q, int n) async {
    final r = await http
        .post(Uri.parse('https://api.tavily.com/search'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'api_key': tavilyKey, 'query': q, 'max_results': n}))
        .timeout(const Duration(seconds: 25));
    if (r.statusCode >= 400) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final list = (j['results'] as List?) ?? const [];
    return [
      for (final e in list)
        {
          'title': (e['title'] ?? '').toString(),
          'url': (e['url'] ?? '').toString(),
          'snippet': (e['content'] ?? '').toString(),
        }
    ];
  }

  static Future<List<Map<String, String>>> _wikiSearch(String q, int n) async {
    final j = await _json(Uri.parse(
        'https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=$n&srsearch=${Uri.encodeQueryComponent(q)}'));
    final list = (j['query']?['search'] as List?) ?? const [];
    return [
      for (final e in list)
        {
          'title': (e['title'] ?? '').toString(),
          'url': 'https://en.wikipedia.org/wiki/${Uri.encodeComponent((e['title'] ?? '').toString().replaceAll(' ', '_'))}',
          'snippet': _strip((e['snippet'] ?? '').toString()),
        }
    ];
  }

  // ---------------- weather ----------------
  static const _codes = {
    0: 'Clear sky', 1: 'Mainly clear', 2: 'Partly cloudy', 3: 'Overcast', 45: 'Fog', 48: 'Fog',
    51: 'Light drizzle', 53: 'Drizzle', 55: 'Heavy drizzle', 61: 'Light rain', 63: 'Rain', 65: 'Heavy rain',
    66: 'Freezing rain', 67: 'Freezing rain', 71: 'Light snow', 73: 'Snow', 75: 'Heavy snow', 77: 'Snow grains',
    80: 'Rain showers', 81: 'Rain showers', 82: 'Violent rain showers', 85: 'Snow showers', 86: 'Snow showers',
    95: 'Thunderstorm', 96: 'Thunderstorm with hail', 99: 'Thunderstorm with hail',
  };

  static Future<String> weather(String place) async {
    final g = await _json(Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search?count=1&language=en&format=json&name=${Uri.encodeQueryComponent(place.split(',').first.trim())}'));
    final list = (g['results'] as List?) ?? const [];
    if (list.isEmpty) return 'Error: could not find "$place".';
    final loc = list.first as Map;
    final lat = loc['latitude'], lon = loc['longitude'];
    final w = await _json(Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,precipitation'
        '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset'
        '&timezone=auto&forecast_days=5'));
    final c = w['current'] as Map? ?? const {};
    final d = w['daily'] as Map? ?? const {};
    final sb = StringBuffer()
      ..writeln('Weather for ${loc['name']}, ${loc['admin1'] ?? ''} ${loc['country'] ?? ''} (local time ${c['time']}):')
      ..writeln('Now: ${_codes[(c['weather_code'] as num?)?.toInt()] ?? ''}, ${c['temperature_2m']}°C '
          '(feels ${c['apparent_temperature']}°C), humidity ${c['relative_humidity_2m']}%, wind ${c['wind_speed_10m']} km/h.');
    final days = (d['time'] as List?) ?? const [];
    for (var i = 0; i < days.length; i++) {
      sb.writeln('${days[i]}: ${_codes[((d['weather_code'] as List)[i] as num?)?.toInt()] ?? ''}, '
          '${(d['temperature_2m_min'] as List)[i]}–${(d['temperature_2m_max'] as List)[i]}°C, '
          'rain chance ${(d['precipitation_probability_max'] as List?)?[i] ?? '?'}%');
    }
    sb.writeln('Source: Open-Meteo (https://open-meteo.com)');
    return sb.toString();
  }

  // ---------------- wikipedia ----------------
  static Future<String> wikipedia(String q, String lang) async {
    final l = RegExp(r'^[a-z\-]{2,12}$').hasMatch(lang) ? lang : 'en';
    final s = await _json(Uri.parse(
        'https://$l.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=3&srsearch=${Uri.encodeQueryComponent(q)}'));
    final hits = (s['query']?['search'] as List?) ?? const [];
    if (hits.isEmpty) return 'No Wikipedia article found for "$q".';
    final title = (hits.first['title'] ?? '').toString();
    final sum = await _json(Uri.parse('https://$l.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}'));
    final others = hits.skip(1).map((e) => e['title']).join(', ');
    return '${sum['title']}\n${sum['description'] ?? ''}\n\n${sum['extract'] ?? ''}\n\n'
        'Link: ${sum['content_urls']?['mobile']?['page'] ?? 'https://$l.wikipedia.org/wiki/${Uri.encodeComponent(title)}'}'
        '${sum['thumbnail']?['source'] != null ? '\nImage: ${sum['thumbnail']['source']}' : ''}'
        '${others.isEmpty ? '' : '\nOther articles: $others'}';
  }

  // ---------------- currency ----------------
  static Future<String> currency(double amount, String from, String to) async {
    final f = from.trim().toUpperCase();
    final j = await _json(Uri.parse('https://open.er-api.com/v6/latest/$f'));
    if (j['result'] != 'success') return 'Error: unknown currency "$f".';
    final rates = j['rates'] as Map;
    final sb = StringBuffer();
    for (final t in to.split(',').map((e) => e.trim().toUpperCase()).where((e) => e.isNotEmpty)) {
      final r = rates[t];
      if (r == null) {
        sb.writeln('$t: unknown currency');
        continue;
      }
      final v = amount * (r as num).toDouble();
      sb.writeln('${_fmt(amount)} $f = ${_fmt(v)} $t  (1 $f = ${r.toString()} $t)');
    }
    sb.writeln('Rates updated ${j['time_last_update_utc']}. Source: ExchangeRate-API (https://www.exchangerate-api.com)');
    return sb.toString();
  }

  static String _fmt(double v) => v >= 100 ? v.toStringAsFixed(2) : v.toStringAsPrecision(6);

  // ---------------- places ----------------
  static Future<String> places(String q, int limit) async {
    final j = await _json(Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=0&limit=$limit&q=${Uri.encodeQueryComponent(q)}'));
    final list = j is List ? j : const [];
    if (list.isEmpty) return 'No places found for "$q".';
    final out = [
      for (final e in list)
        {
          'name': (e['name'] ?? '').toString(),
          'address': (e['display_name'] ?? '').toString(),
          'type': '${e['category'] ?? ''} ${e['type'] ?? ''}'.trim(),
          'lat': e['lat'],
          'lon': e['lon'],
          'map': 'https://www.google.com/maps/search/?api=1&query=${e['lat']},${e['lon']}',
        }
    ];
    return jsonEncode({'places': out, 'source': 'OpenStreetMap (Nominatim)'});
  }

  // ---------------- rss ----------------
  static Future<String> rss(String url, int limit) async {
    final r = await http.get(Uri.parse(url), headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 20));
    final s = utf8.decode(r.bodyBytes, allowMalformed: true);
    String tag(String block, String name) {
      final m = RegExp('<$name(?:\\s[^>]*)?>([\\s\\S]*?)</$name>').firstMatch(block);
      if (m == null) return '';
      var v = m.group(1)!;
      v = v.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '');
      return _strip(v);
    }

    final feedTitle = tag(s, 'title');
    final items = RegExp(r'<(item|entry)[\s>][\s\S]*?</(item|entry)>').allMatches(s).take(limit);
    final sb = StringBuffer('Feed: $feedTitle\n');
    var i = 0;
    for (final m in items) {
      final b = m.group(0)!;
      var link = tag(b, 'link');
      if (link.isEmpty) {
        final h = RegExp(r'''<link[^>]*href=["']([^"']+)["']''').firstMatch(b);
        link = h?.group(1) ?? '';
      }
      final date = [tag(b, 'pubDate'), tag(b, 'updated'), tag(b, 'published')].firstWhere((e) => e.isNotEmpty, orElse: () => '');
      var desc = [tag(b, 'description'), tag(b, 'summary')].firstWhere((e) => e.isNotEmpty, orElse: () => '');
      if (desc.length > 280) desc = '${desc.substring(0, 280)}…';
      i++;
      sb.writeln('$i. ${tag(b, 'title')}\n   $link${date.isEmpty ? '' : '\n   $date'}${desc.isEmpty ? '' : '\n   $desc'}');
    }
    if (i == 0) return 'Error: no items found. Is this an RSS/Atom feed? (HTTP ${r.statusCode})';
    return sb.toString();
  }

  // ---------------- youtube ----------------
  static String? videoId(String s) {
    final t = s.trim();
    if (RegExp(r'^[\w-]{11}$').hasMatch(t)) return t;
    final m = RegExp(r'(?:v=|youtu\.be/|shorts/|embed/|live/)([\w-]{11})').firstMatch(t);
    return m?.group(1);
  }

  static Future<String> youtube(String url, String lang) async {
    final id = videoId(url);
    if (id == null) return 'Error: that does not look like a YouTube link.';
    List tracks = const [];
    String title = '';
    // 1) Innertube player API (Android client) usually returns usable caption links.
    try {
      final r = await http
          .post(Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
              headers: {'Content-Type': 'application/json', 'User-Agent': 'com.google.android.youtube/19.44.38 (Linux; U; Android 14)'},
              body: jsonEncode({
                'videoId': id,
                'context': {
                  'client': {'clientName': 'ANDROID', 'clientVersion': '19.44.38', 'androidSdkVersion': 34, 'hl': lang}
                },
              }))
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      title = (j['videoDetails']?['title'] ?? '').toString();
      tracks = (j['captions']?['playerCaptionsTracklistRenderer']?['captionTracks'] as List?) ?? const [];
    } catch (_) {}
    // 2) Watch page fallback.
    if (tracks.isEmpty) {
      try {
        final r = await http.get(Uri.parse('https://www.youtube.com/watch?v=$id&hl=$lang'),
            headers: {'User-Agent': _browserUa, 'Accept-Language': '$lang,en;q=0.8'}).timeout(const Duration(seconds: 20));
        final s = utf8.decode(r.bodyBytes, allowMalformed: true);
        final m = RegExp(r'"captionTracks":(\[.*?\])').firstMatch(s);
        if (m != null) tracks = jsonDecode(m.group(1)!) as List;
        final t = RegExp(r'<title>([^<]*)</title>').firstMatch(s);
        if (title.isEmpty && t != null) title = _decode(t.group(1)!).replaceAll(' - YouTube', '');
      } catch (_) {}
    }
    if (tracks.isEmpty) return 'This video has no captions I can read (or YouTube blocked the request).';
    Map pick = tracks.first as Map;
    for (final t in tracks) {
      if (t is Map && (t['languageCode'] ?? '').toString().startsWith(lang)) {
        pick = t;
        break;
      }
    }
    final base = (pick['baseUrl'] ?? '').toString().replaceAll(r'\u0026', '&');
    if (base.isEmpty) return 'Error: no caption link found.';
    final r = await http.get(Uri.parse(base), headers: {'User-Agent': _browserUa}).timeout(const Duration(seconds: 20));
    final xml = utf8.decode(r.bodyBytes, allowMalformed: true);
    final parts = RegExp(r'<(?:text|p)[^>]*>([\s\S]*?)</(?:text|p)>').allMatches(xml).map((m) => _strip(_decode(m.group(1)!)));
    var text = parts.where((e) => e.isNotEmpty).join(' ');
    if (text.isEmpty) return 'Captions exist but YouTube returned them empty. Try again later.';
    if (text.length > 30000) text = '${text.substring(0, 30000)}…[truncated]';
    return 'Transcript of "$title" (https://youtu.be/$id), language ${pick['languageCode']}:\n$text';
  }
}
