import 'dart:math' as math;

/// One piece of a bot's knowledge: text the owner wrote or pasted, or the text of a file they added.
/// Knowledge belongs to the bot's skill set, so it travels when the bot is shared, published or hired.
class BotKnowledge {
  BotKnowledge({required this.id, required this.title, required this.text, this.kind = 'text', this.file = '', DateTime? added})
      : added = added ?? DateTime.now();
  final String id;
  String title;
  String text;

  /// text | file
  String kind;

  /// The file name it came from ('' for typed text).
  String file;
  final DateTime added;

  static const maxItemChars = 60000;
  static const maxTotalChars = 300000;
  static const maxItems = 40;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'text': text, 'kind': kind, 'file': file, 'at': added.toIso8601String()};
  static BotKnowledge fromJson(Map<String, dynamic> j) => BotKnowledge(
        id: '${j['id'] ?? 'k${DateTime.now().microsecondsSinceEpoch}'}',
        title: '${j['title'] ?? 'Note'}',
        text: '${j['text'] ?? ''}',
        kind: '${j['kind'] ?? 'text'}' == 'file' ? 'file' : 'text',
        file: '${j['file'] ?? ''}',
        added: DateTime.tryParse('${j['at']}'),
      );
}

/// One app a bot is set up to use: a connected app from the catalog (by id) or an MCP server (by its address).
/// Only what identifies the app and how it is set up is stored here: which tools the bot uses, and how a new owner
/// connects it (sign in, or add a key, and the name of the header the key goes in). The login, key or token itself
/// always stays with the owner's own connection and never travels.
class BotApp {
  BotApp({required this.kind, required this.ref, required this.name, List<String>? tools, this.auth = '', this.keyHeader = ''})
      : tools = tools ?? [];

  /// connector | mcp
  final String kind;

  /// Connector catalog id, or the MCP server's https address.
  final String ref;
  String name;

  /// The tools of this app the bot uses (empty = all of them).
  final List<String> tools;

  /// How it is connected (MCP): oauth (sign in) | key (add your key) | none (open) | '' (not known; try sign in).
  String auth;

  /// For key auth: the header name the key goes in, e.g. Authorization or x-api-key (never the key).
  String keyHeader;

  Map<String, dynamic> toJson() => {
        'kind': kind, 'ref': ref, 'name': name,
        if (tools.isNotEmpty) 'tools': tools,
        if (auth.isNotEmpty) 'auth': auth,
        if (keyHeader.isNotEmpty) 'key_header': keyHeader,
      };
  static BotApp? fromJson(Map<String, dynamic> j) {
    final kind = '${j['kind'] ?? ''}';
    final ref = '${j['ref'] ?? ''}'.trim();
    if ((kind != 'connector' && kind != 'mcp') || ref.isEmpty) return null;
    if (kind == 'mcp' && !BotPackage.safeMcpUrl(ref)) return null;
    final auth = '${j['auth'] ?? ''}';
    final header = '${j['key_header'] ?? ''}';
    return BotApp(
      kind: kind,
      ref: ref,
      name: '${j['name'] ?? ref}',
      tools: [for (final t in (j['tools'] as List? ?? const [])) if (BotPackage.toolName.hasMatch('$t')) '$t'],
      auth: const {'oauth', 'key', 'none'}.contains(auth) ? auth : '',
      keyHeader: BotPackage.headerName.hasMatch(header) ? header : '',
    );
  }
}

/// A short, generic how-to lesson the bot learned from its own work (never a detail about its owner).
class BotLesson {
  BotLesson(this.text, {DateTime? at, this.uses = 0, this.source = 'task'}) : at = at ?? DateTime.now();
  String text;
  DateTime at;
  int uses;

  /// task | mistake | correction | nudge | owner | shared
  String source;

  Map<String, dynamic> toJson() => {'t': text, 'at': at.toIso8601String(), 'u': uses, 's': source};
  static BotLesson fromJson(Map<String, dynamic> j) =>
      BotLesson('${j['t'] ?? ''}', at: DateTime.tryParse('${j['at']}'), uses: (j['u'] as num?)?.toInt() ?? 0, source: '${j['s'] ?? 'task'}');
}

/// The bot package: what travels with a bot when it is shared, published to the Bot Store or hired.
///
/// [sanitize] is the one gate every package passes, on the way out and on the way in. It is an allow-list:
/// only the fields named below survive, each cut to size and scrubbed. Nothing else (credentials, keys, tokens,
/// headers, logins, the bot's memory about its owner, journal, chats, desk, follow-ups, watches, budgets used,
/// conversation ids) can get through, even if a future field is added to the bot by mistake.
class BotPackage {
  static const format = 'bot';
  static const version = 2;

  static const _icons = {
    'person', 'school', 'gavel', 'trending_up', 'travel_explore', 'fitness_center', 'payments', 'edit', 'code', 'work', 'favorite', 'campaign', 'storefront', 'health',
  };
  static const _powers = {'web', 'browser', 'phone', 'files', 'apps'};
  static final toolName = RegExp(r'^[A-Za-z0-9_.\-]{1,80}$');
  static final headerName = RegExp(r'^[A-Za-z0-9\-]{1,40}$');

  static const _voices = {'', 'Aoede', 'Kore', 'Charon', 'Puck', 'Fenrir', 'Leda', 'Orus', 'Zephyr'};

  static String _str(dynamic v, int max) {
    var s = v == null ? '' : '$v';
    s = scrubSecrets(s).trim();
    return s.length > max ? s.substring(0, max) : s;
  }

  static int _int(dynamic v, int lo, int hi, int dflt) => v is num ? v.toInt().clamp(lo, hi).toInt() : (int.tryParse('$v') ?? dflt).clamp(lo, hi).toInt();

  static List<Map<String, dynamic>> _maps(dynamic v) => [
        for (final e in (v is List ? v : const []))
          if (e is Map) Map<String, dynamic>.from(e),
      ];

  /// Only a plain https address with no login inside it (no user:pass@, no key in the query).
  static bool safeMcpUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty) return false;
    final q = u.query.toLowerCase();
    if (RegExp(r'(key|token|secret|auth|password|sig|session|code)').hasMatch(q)) return false;
    return true;
  }

  static String _mcpUrl(String url) => url.trim().split('#').first;

  /// The model the bot prefers, without the owner's provider id: just the model name, or 'auto'.
  static String modelHint(String model) {
    if (model.isEmpty || model == 'auto') return 'auto';
    final i = model.indexOf('|');
    final m = (i >= 0 ? model.substring(i + 1) : model).trim();
    return m.isEmpty ? 'auto' : _str(m, 80);
  }

  static final _hidden = RegExp('[\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]');
  static final _redFlags = <RegExp, String>{
    RegExp(r'ignore (all |any )?(the )?(previous|prior|above|earlier|system) (instructions|rules|prompts?)', caseSensitive: false):
        'tries to override Telesia\'s own rules',
    RegExp(r"(do not|don't|never) (tell|inform) (the )?(user|owner)", caseSensitive: false): 'hides what it does from you',
    RegExp(r'(send|forward|upload|post|share|copy|export)\b[^.\n]{0,60}\b(contacts?|address book|sms|text messages|passwords?|codes?|otp|photos|location|notifications)\b[^.\n]{0,60}\b(to|at)\b',
        caseSensitive: false): 'sends your private data somewhere',
    RegExp(r'(webhook\.site|requestbin|ngrok|discord(app)?\.com/api/webhooks|api\.telegram\.org/bot)', caseSensitive: false):
        'sends data to a collection link',
    RegExp(r'[A-Za-z0-9+/]{120,}={0,2}'): 'contains a long encoded block',
  };

  /// Safety check for a bot before it is published or hired (plan 2.5). Returns plain warnings, empty when clean.
  static List<String> warnings(Map<String, dynamic>? pkg) {
    if (pkg == null) return const [];
    final texts = <String>[
      '${pkg['persona'] ?? ''}',
      '${pkg['instructions'] ?? ''}',
      '${pkg['first_meeting'] ?? ''}',
      for (final r in _maps(pkg['routines'])) '${r['do'] ?? ''}',
      for (final k in _maps(pkg['knowledge'])) '${k['text'] ?? k['content'] ?? ''}',
      for (final s in _maps(pkg['skills'])) '${s['content'] ?? s['body'] ?? ''}',
      for (final l in (pkg['lessons'] is List ? pkg['lessons'] as List : const [])) '$l',
    ];
    final out = <String>{};
    for (final t in texts) {
      if (_hidden.hasMatch(t)) out.add('contains hidden characters');
      for (final e in _redFlags.entries) {
        if (e.key.hasMatch(t)) out.add(e.value);
      }
    }
    return out.toList();
  }

  /// Removes anything that looks like a key, token or password from free text.
  static String scrubSecrets(String s) {
    if (s.isEmpty) return s;
    return s
        .replaceAll(RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'), '[removed key]')
        .replaceAll(RegExp(r'\b(sk|pk|rk)[-_](live|test|proj|ant|or)?[-_]?[A-Za-z0-9_\-]{16,}'), '[removed key]')
        .replaceAll(RegExp(r'\bAIza[0-9A-Za-z_\-]{30,}'), '[removed key]')
        .replaceAll(RegExp(r'\b(ghp|gho|ghu|ghs|github_pat|glpat|xox[abprs])[-_][A-Za-z0-9_\-]{16,}'), '[removed key]')
        .replaceAll(RegExp(r'\bAKIA[0-9A-Z]{16}\b'), '[removed key]')
        .replaceAll(RegExp(r'\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}'), '[removed token]')
        .replaceAll(RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/\-]{16,}=*', caseSensitive: false), '[removed token]')
        .replaceAllMapped(
            RegExp(r'\b(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|secret|password|passwd|pwd|client[_ -]?secret)(\s*[:=]\s*)\S+',
                caseSensitive: false),
            (m) => '${m.group(1)}${m.group(2)}[removed]');
  }

  /// Removes details about a person from a lesson: emails, phone numbers, links with ids, card-like numbers,
  /// street addresses and @handles. Lessons must read as general know-how.
  static String scrubPersonal(String s) {
    var t = scrubSecrets(s);
    t = t
        .replaceAll(RegExp(r'[\w.+\-]+@[\w\-]+\.[\w.\-]+'), 'someone@email')
        .replaceAll(RegExp(r'(?<![\w])\+?\d[\d\s().\-]{7,}\d'), '[number]')
        .replaceAll(RegExp(r'\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{1,4}\b'), '[number]')
        .replaceAll(RegExp(r'(?<![\w])@[A-Za-z0-9_]{2,}'), '@someone')
        .replaceAllMapped(RegExp(r'https?://([^/\s]+)\S*'), (m) => m.group(1)!)
        .replaceAll(RegExp(r'\b\d{1,5}\s+\w+\s+(street|st|road|rd|avenue|ave|lane|ln|drive|dr|blvd)\b', caseSensitive: false), '[address]');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// True when a lesson is about the owner rather than about how to do the work (these never travel).
  static bool personalLesson(String s) {
    final t = s.toLowerCase();
    return RegExp(
            r"\b(my owner|owner's|(his|her|their|my) (wife|husband|son|daughter|kids?|child|children|family|boss|mother|father|mom|dad)|"
            r"lives in|birthday|born on|home address|phone number|salary|password|account number|diagnos\w*|allerg\w*|religion|pregnan\w*)\b")
        .hasMatch(t);
  }

  /// The one gate. Takes anything shaped like a bot package (or an older shared bot) and returns only the allowed,
  /// cleaned fields. Returns null when it is not a SubMac bot.
  static Map<String, dynamic>? sanitize(Map<String, dynamic> raw) {
    if ('${raw['submac']}' != format) return null;
    final name = _str(raw['name'], 40);
    if (name.isEmpty) return null;
    final icon = '${raw['icon'] ?? 'person'}';
    final voice = '${raw['voice'] ?? ''}';
    final pro = '${raw['proactivity'] ?? 'balanced'}';

    // Knowledge: kept whole (it is meant to be shared), but scrubbed of secrets and cut to the limits.
    final knowledge = <Map<String, dynamic>>[];
    var total = 0;
    for (final k in _maps(raw['knowledge']).take(BotKnowledge.maxItems)) {
      var text = scrubSecrets('${k['text'] ?? ''}');
      if (text.trim().isEmpty) continue;
      if (text.length > BotKnowledge.maxItemChars) text = text.substring(0, BotKnowledge.maxItemChars);
      if (total + text.length > BotKnowledge.maxTotalChars) text = text.substring(0, math.max(0, BotKnowledge.maxTotalChars - total));
      if (text.isEmpty) break;
      total += text.length;
      knowledge.add({
        'title': _str(k['title'], 80).isEmpty ? 'Note' : _str(k['title'], 80),
        'text': text,
        'kind': '${k['kind']}' == 'file' ? 'file' : 'text',
        'file': _str(k['file'], 120).replaceAll(RegExp(r'^.*[/\\]'), ''),
      });
    }

    // Apps: only which app it is. Never headers, tokens, keys or the owner's account details.
    final apps = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final a in _maps(raw['apps']).take(20)) {
      final kind = '${a['kind'] ?? ''}';
      var ref = '${a['ref'] ?? ''}'.trim();
      if (kind == 'connector') {
        ref = ref.toLowerCase();
        if (!RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(ref) || ref.startsWith('c_')) continue; // custom APIs are the owner's own
      } else if (kind == 'mcp') {
        if (!safeMcpUrl(ref)) continue;
        ref = _mcpUrl(ref);
      } else {
        continue;
      }
      if (!seen.add('$kind|$ref')) continue;
      final auth = '${a['auth'] ?? ''}';
      final header = '${a['key_header'] ?? ''}';
      apps.add({
        'kind': kind,
        'ref': ref,
        'name': _str(a['name'], 40).isEmpty ? ref : _str(a['name'], 40),
        'tools': [for (final t in (a['tools'] is List ? a['tools'] as List : const []).take(80)) if (toolName.hasMatch('$t')) '$t'],
        if (kind == 'mcp' && const {'oauth', 'key', 'none'}.contains(auth)) 'auth': auth,
        if (kind == 'mcp' && auth == 'key' && headerName.hasMatch(header)) 'key_header': header,
      });
    }

    // Lessons: generic know-how only.
    final lessons = <String>[];
    for (final l in (raw['lessons'] is List ? raw['lessons'] as List : const [])) {
      final t = scrubPersonal('${l is Map ? (l['t'] ?? l['text'] ?? '') : l}');
      if (t.length < 8 || personalLesson(t)) continue;
      final line = t.length > 200 ? t.substring(0, 200) : t;
      if (!lessons.any((x) => x.toLowerCase() == line.toLowerCase())) lessons.add(line);
      if (lessons.length >= 30) break;
    }

    return {
      'submac': format,
      'v': version,
      'name': name,
      'role': _str(raw['role'], 60),
      'icon': _icons.contains(icon) ? icon : 'person',
      'blurb': _str(raw['blurb'], 160),
      'persona': _str(raw['persona'], 4000),
      'instructions': _str(raw['instructions'], 8000),
      'first_meeting': _str(raw['first_meeting'], 800),
      'voice': _voices.contains(voice) ? voice : '',
      // A bot's model is its owner's own choice (owner 2026-11-05): never carried in a package, a copy starts on its
      // default (same as SubMac).
      'model': 'auto',
      'proactivity': const {'quiet', 'balanced', 'active'}.contains(pro) ? pro : 'balanced',
      'heartbeat_hours': _int(raw['heartbeat_hours'], 0, 48, 0),
      'quiet_from': _int(raw['quiet_from'], 0, 23, 22),
      'quiet_to': _int(raw['quiet_to'], 0, 23, 7),
      'calls': raw['calls'] != false,
      'sandbox': raw['sandbox'] == true,
      'token_budget_k': _int(raw['token_budget_k'], 0, 100000, 0),
      'powers_off': [for (final p in (raw['powers_off'] is List ? raw['powers_off'] as List : const [])) if (_powers.contains('$p')) '$p'],
      'routines': [
        for (final r in _maps(raw['routines']).take(12))
          if (RegExp(r'^\d{1,2}:\d{2}$').hasMatch('${r['time']}') && _str(r['do'] ?? r['instruction'], 600).isNotEmpty)
            {
              'time': '${r['time']}',
              'days': RegExp(r'^[a-z, ]{1,40}$').hasMatch('${r['days'] ?? 'daily'}') ? '${r['days'] ?? 'daily'}' : 'daily',
              'kind': const {'work', 'message', 'call'}.contains('${r['kind']}') ? '${r['kind']}' : 'work',
              'do': _str(r['do'] ?? r['instruction'], 600),
            },
      ],
      'skills': [
        for (final s in (raw['skills'] is List ? raw['skills'] as List : const []).take(60))
          if (RegExp(r'^[a-z0-9_\-]{1,80}$').hasMatch('$s')) '$s',
      ],
      'apps': apps,
      'knowledge': knowledge,
      'lessons': lessons,
    };
  }

  // ---------------------------------------------------------------- knowledge search

  static List<String> _words(String s) =>
      s.toLowerCase().split(RegExp(r'[^a-z0-9\u00c0-\u024f\u0600-\u06ff]+')).where((w) => w.length > 2).toList();

  /// The best passages for a question across a bot's knowledge, as (item, offset, passage).
  static List<(BotKnowledge, int, String)> search(List<BotKnowledge> items, String query, {int limit = 5, int size = 700}) {
    final q = _words(query).toSet();
    final hits = <(double, BotKnowledge, int, String)>[];
    for (final k in items) {
      final title = k.title.toLowerCase();
      for (var off = 0; off < k.text.length; off += size - 150) {
        final end = math.min(k.text.length, off + size);
        final chunk = k.text.substring(off, end);
        final lower = chunk.toLowerCase();
        var score = 0.0;
        for (final w in q) {
          if (title.contains(w)) score += 1.5;
          var i = lower.indexOf(w), n = 0;
          while (i >= 0 && n < 6) {
            n++;
            i = lower.indexOf(w, i + w.length);
          }
          score += n == 0 ? 0 : 1 + math.log(n);
        }
        if (q.isEmpty) score = 1;
        if (score > 0) hits.add((score, k, off, chunk));
        if (end >= k.text.length) break;
      }
    }
    hits.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final h in hits.take(limit)) (h.$2, h.$3, h.$4)];
  }
}
