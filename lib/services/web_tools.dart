import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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
          final n = ((a['max_results'] as num?)?.toInt() ?? 6).clamp(1, 10);
          return await webSearch((a['query'] ?? '').toString(), n);
        case 'get_weather':
          return await weather((a['place'] ?? '').toString());
        case 'wikipedia':
          return await wikipedia((a['query'] ?? '').toString(), (a['lang'] ?? 'en').toString());
        case 'currency_convert':
          return await currency((a['amount'] as num?)?.toDouble() ?? 1, (a['from'] ?? 'USD').toString(),
              (a['to'] ?? 'EUR').toString());
        case 'find_place':
          return await places((a['query'] ?? '').toString(), ((a['limit'] as num?)?.toInt() ?? 5).clamp(1, 10));
        case 'read_rss':
          return await rss((a['url'] ?? '').toString(), ((a['limit'] as num?)?.toInt() ?? 10).clamp(1, 30));
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
      ('DuckDuckGo', () => _ddgHtml(q, n)),
      ('DuckDuckGo', () => _ddgLite(q, n)),
      ('Wikipedia', () => _wikiSearch(q, n)),
    ];
    final errors = <String>[];
    for (final a in attempts) {
      try {
        results = await a.$2();
        if (results.isNotEmpty) {
          engine = a.$1;
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
    return jsonEncode({
      'query': q,
      'engine': engine,
      'results': results.take(n).toList(),
      'note': 'Show the sources you used to the user as a links card.',
    });
  }

  static String _strip(String html) => _decode(html.replaceAll(RegExp(r'<[^>]+>'), '')).replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _decode(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)));

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
