import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../config.dart';
import 'calm.dart';
import 'cloud.dart';
import 'mcp_client.dart';
import 'mcp_oauth.dart';
import 'projects.dart';
import 'tools.dart';

/// Where a site lives once published.
class SiteHost {
  static const free = 'submac'; // free 7-day link on submac-sites.pages.dev
  static const vercel = 'vercel'; // the user's own Vercel account
}

/// A website SubMac built on this phone: its main page, where it is published and how often it changed.
class Site {
  final String id;
  String title;

  /// The page the site opens on (an .html file in SubMac's workspace).
  String entryPath;
  String host; // '' until the first publish
  String url;
  DateTime? expiresAt; // free links only
  String vercelProject;
  int publishCount;
  bool projectOffered;
  String? projectId;
  DateTime updated;

  Site({
    required this.id,
    required this.title,
    required this.entryPath,
    this.host = '',
    this.url = '',
    this.expiresAt,
    this.vercelProject = '',
    this.publishCount = 0,
    this.projectOffered = false,
    this.projectId,
    DateTime? updated,
  }) : updated = updated ?? DateTime.now();

  bool get isLive => url.isNotEmpty && !isExpired;
  bool get isExpired => host == SiteHost.free && expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// "Free link · 6 days left", "On your Vercel", "Free link ended", "Not online yet".
  String get statusLine {
    if (url.isEmpty) return 'Not online yet';
    if (host == SiteHost.vercel) return 'On your Vercel';
    if (isExpired) return 'Free link ended · publish again for 7 more days';
    final left = expiresAt == null ? 7 * 24 : expiresAt!.difference(DateTime.now()).inHours;
    final days = (left / 24).ceil();
    if (expiresAt != null && left < 24) return 'Free link · ends today';
    return 'Free link · $days ${days == 1 ? 'day' : 'days'} left';
  }

  String get hostName => host == SiteHost.vercel ? 'Vercel' : 'SubMac free link';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'entry': entryPath,
        'host': host,
        'url': url,
        if (expiresAt != null) 'expires': expiresAt!.toIso8601String(),
        'vercel': vercelProject,
        'n': publishCount,
        'offered': projectOffered,
        if (projectId != null) 'project': projectId,
        'updated': updated.toIso8601String(),
      };

  factory Site.fromJson(Map<String, dynamic> j) => Site(
        id: '${j['id']}',
        title: '${j['title'] ?? 'My site'}',
        entryPath: '${j['entry'] ?? ''}',
        host: '${j['host'] ?? ''}',
        url: '${j['url'] ?? ''}',
        expiresAt: DateTime.tryParse('${j['expires'] ?? ''}'),
        vercelProject: '${j['vercel'] ?? ''}',
        publishCount: (j['n'] as num?)?.toInt() ?? 0,
        projectOffered: j['offered'] == true,
        projectId: j['project'] as String?,
        updated: DateTime.tryParse('${j['updated'] ?? ''}'),
      );
}

/// A file going online: its path inside the site ("index.html", "img/logo.png") and its bytes.
class SiteFile {
  final String path;
  final List<int> bytes;
  const SiteFile(this.path, this.bytes);
}

class PublishException implements Exception {
  final String message;
  PublishException(this.message);
  @override
  String toString() => message;
}

/// Sites SubMac built, and publishing them: a free 7-day link (edge function `site-preview`) or the user's own Vercel
/// (through the Vercel sign-in app's `deploy_to_vercel`, with the files read here, never retyped by the model).
class Sites extends ChangeNotifier {
  Sites._();
  static final I = Sites._();

  static const maxFiles = 60;
  static const maxBytes = 5 * 1024 * 1024;
  static const _key = 'sites_v1';
  static const _textExt = {'html', 'htm', 'css', 'js', 'mjs', 'json', 'txt', 'xml', 'svg', 'webmanifest', 'md'};
  static const _webExt = {
    ..._textExt, 'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'ico', 'woff', 'woff2', 'ttf', 'otf', 'mp4', 'webm', 'mp3', 'wav', 'pdf',
  };

  final List<Site> list = [];
  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        list
          ..clear()
          ..addAll([for (final e in (jsonDecode(raw) as List)) Site.fromJson(Map<String, dynamic>.from(e as Map))]);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    list.sort((a, b) => b.updated.compareTo(a.updated));
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final s in list) s.toJson()]));
    notifyListeners();
  }

  /// The site for a page file, made on first use.
  Future<Site> forPage(String path, {String? title}) async {
    await init();
    final found = list.where((s) => s.entryPath == path).firstOrNull;
    if (found != null) return found;
    final t = title ?? await titleOf(path);
    // A changed page from chat is a new file with the same title: it is the same site, so it keeps its address.
    if (t != 'My site' && path.contains('/pages/')) {
      final same = list.where((s) => s.title == t && s.entryPath.contains('/pages/')).firstOrNull;
      if (same != null) {
        same.entryPath = path;
        same.updated = DateTime.now();
        await _save();
        return same;
      }
    }
    final s = Site(id: 's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}', title: t, entryPath: path);
    list.insert(0, s);
    await _save();
    return s;
  }

  Site? byPath(String path) => list.where((s) => s.entryPath == path).firstOrNull;

  /// The site a page belongs to, without making one: the same file, or a newer version of a page from chat (same title).
  Future<Site?> find(String path) async {
    await init();
    final direct = byPath(path);
    if (direct != null || !path.contains('/pages/')) return direct;
    final t = await titleOf(path);
    if (t == 'My site') return null;
    return list.where((s) => s.title == t && s.entryPath.contains('/pages/')).firstOrNull;
  }

  static Future<String> titleOf(String path) async {
    try {
      final head = await File(path).openRead(0, 20000).transform(utf8.decoder).join();
      final m = RegExp(r'<title>([^<]*)</title>', caseSensitive: false).firstMatch(head);
      final t = m?.group(1)?.trim() ?? '';
      if (t.isNotEmpty) return t.length > 60 ? t.substring(0, 60) : t;
    } catch (_) {}
    final n = path.split('/').last.replaceAll(RegExp(r'\.html?$', caseSensitive: false), '');
    return n.startsWith('page_') || n.isEmpty || n == 'index' ? 'My site' : n;
  }

  // ------------------------------------------------------------------ files

  /// The files that make up the site. A page alone in a shared folder (SubMac's pages folder, the workspace) goes up
  /// on its own as index.html; a page in its own folder goes up with that folder (pictures, styles, other pages).
  static Future<List<SiteFile>> collect(String entryPath) async {
    final entry = File(entryPath);
    if (!await entry.exists()) throw PublishException('This page is not on the phone any more.');
    final ws = await AgentTools.workspaceDir();
    final dir = entry.parent;
    final shared = dir.path == ws || dir.path == '$ws/pages' || dir.path.endsWith('/Download') || dir.path.endsWith('/Downloads');
    final out = <SiteFile>[];
    var total = 0;
    void add(String rel, List<int> bytes) {
      total += bytes.length;
      if (total > maxBytes) throw PublishException('This site is bigger than 5 MB. Ask SubMac to make the pictures smaller, then publish again.');
      out.add(SiteFile(rel, bytes));
    }

    final entryBytes = await entry.readAsBytes();
    if (shared) {
      add('index.html', entryBytes);
      return out;
    }
    final entryName = entry.path.split('/').last;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(dir.path.length + 1);
      if (rel.split('/').any((p) => p.startsWith('.'))) continue;
      final ext = rel.contains('.') ? rel.split('.').last.toLowerCase() : '';
      if (!_webExt.contains(ext)) continue;
      if (out.length >= maxFiles) throw PublishException('This site has more than $maxFiles files, too many to publish from the phone.');
      add(rel, await e.readAsBytes());
    }
    if (entryName.toLowerCase() != 'index.html' && !out.any((f) => f.path.toLowerCase() == 'index.html')) {
      add('index.html', entryBytes);
    }
    return out;
  }

  // ------------------------------------------------------------------ free link

  static Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('${AppConfig.supabaseUrl}/functions/v1/site-preview'),
              headers: await Cloud.headers(source: 'sites'), body: jsonEncode(body))
          .timeout(const Duration(seconds: 90));
    } on CloudException catch (e) {
      throw PublishException(e.message);
    } catch (e) {
      throw PublishException(Calm.short(e));
    }
    Map<String, dynamic> j = {};
    try {
      j = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (_) {}
    if (r.statusCode != 200 || j['ok'] != true) {
      throw PublishException('${j['error'] ?? 'The free link service is busy. Please try again in a minute.'}');
    }
    return j;
  }

  Future<String> _publishFree(Site s, List<SiteFile> files) async {
    final j = await _call({
      'action': 'publish',
      'site_key': s.id,
      'title': s.title,
      'files': [for (final f in files) {'path': f.path, 'data': base64Encode(f.bytes)}],
    });
    s.url = '${j['url']}';
    s.expiresAt = DateTime.tryParse('${j['expires_at']}')?.toLocal();
    return s.url;
  }

  /// Takes a free link offline now.
  Future<void> removeFreeLink(Site s) async {
    await _call({'action': 'remove', 'site_key': s.id});
    if (s.host == SiteHost.free) {
      s.url = '';
      s.expiresAt = null;
    }
    s.updated = DateTime.now();
    await _save();
  }

  /// Brings free-link states (ended, removed elsewhere) in line with the server. Quiet on failure.
  Future<void> refresh() async {
    await init();
    try {
      final j = await _call({'action': 'list'});
      final byKey = {for (final e in (j['sites'] as List? ?? const [])) '${(e as Map)['site_key']}': e};
      var changed = false;
      for (final s in list.where((x) => x.host == SiteHost.free && x.url.isNotEmpty)) {
        final e = byKey[s.id];
        if (e == null) continue;
        final exp = DateTime.tryParse('${e['expires_at']}')?.toLocal();
        if (exp != null && exp != s.expiresAt) {
          s.expiresAt = exp;
          changed = true;
        }
      }
      if (changed) await _save();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ Vercel

  static McpPreset get vercelPreset => McpOAuth.presetFor('vercel')!;

  static McpServerConfig? vercelServer(AppState app) {
    final url = vercelPreset.url;
    return app.mcpServers.where((s) => s.url == url && s.enabled).firstOrNull;
  }

  static bool vercelConnected(AppState app) => vercelServer(app) != null;

  /// A Vercel project name from the site title: lowercase letters, digits and dashes.
  static String projectName(Site s) {
    var n = s.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (n.length > 40) n = n.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
    if (n.isEmpty) n = 'my-site';
    final tail = s.id.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return '$n-${tail.substring(tail.length > 4 ? tail.length - 4 : 0)}';
  }

  Future<String> _publishVercel(AppState app, Site s, List<SiteFile> files) async {
    final server = vercelServer(app);
    if (server == null) throw PublishException('Vercel isn\'t connected yet.');
    final client = McpClient.of(server);
    final tools = await client.listTools().timeout(const Duration(seconds: 30));
    final deployTool = tools.where((t) => t.name == 'deploy_to_vercel').firstOrNull;
    if (deployTool == null) {
      throw PublishException('Your Vercel connection can\'t publish files. Disconnect Vercel in Apps, connect it again, then retry.');
    }
    // Follow the connection's own file format (it can differ between connections).
    final item = (((deployTool.schema['properties'] as Map?)?['files'] as Map?)?['items'] as Map?) ?? const {};
    final props = ((item['properties'] as Map?) ?? const {}).keys.map((k) => '$k').toSet();
    final pathKey = props.contains('file') ? 'file' : (props.contains('path') ? 'path' : (props.contains('name') ? 'name' : 'file'));
    final dataKey = props.contains('data') ? 'data' : (props.contains('content') ? 'content' : (props.contains('contents') ? 'contents' : 'data'));
    final canBase64 = props.contains('encoding');
    final payload = <Map<String, dynamic>>[];
    var total = 0;
    for (final f in files) {
      final ext = f.path.contains('.') ? f.path.split('.').last.toLowerCase() : '';
      final text = _textExt.contains(ext);
      if (!text && !canBase64) {
        throw PublishException('This site has pictures or fonts, and your Vercel connection only takes text files. Use the free SubMac link instead.');
      }
      final data = text ? utf8.decode(f.bytes, allowMalformed: true) : base64Encode(f.bytes);
      total += data.length;
      payload.add({pathKey: f.path, dataKey: data, if (!text) 'encoding': 'base64'});
    }
    if (total > 4 * 1024 * 1024) throw PublishException('This site is too big for Vercel from the phone (4 MB). Ask SubMac to make the pictures smaller.');

    final name = s.vercelProject.isNotEmpty ? s.vercelProject : projectName(s);
    Future<String> send([String? teamId]) => client
        .callTool('deploy_to_vercel', {'target': 'production', 'name': name, 'files': payload, if (teamId != null) 'teamId': teamId})
        .timeout(const Duration(seconds: 90));
    var res = await send();
    // Some accounts need the team named (every Vercel account has at least a personal team): take the first one.
    if (res.startsWith('Error') && res.toLowerCase().contains('team') && tools.any((t) => t.name == 'list_teams')) {
      try {
        final teams = await client.callTool('list_teams', {}).timeout(const Duration(seconds: 30));
        final teamId = _firstMatch(teams, [RegExp(r'"id"\s*:\s*"(team_[A-Za-z0-9]+)"'), RegExp(r'\b(team_[A-Za-z0-9]+)\b')]);
        if (teamId != null) res = await send(teamId);
      } catch (_) {}
    }
    if (res.startsWith('Error')) throw PublishException(_vercelError(res));
    s.vercelProject = name;

    // The build runs on Vercel; wait for it (up to ~2 minutes) and take the address people can open.
    final id = _firstMatch(res, [RegExp(r'"id"\s*:\s*"(dpl_[A-Za-z0-9]+)"'), RegExp(r'\b(dpl_[A-Za-z0-9]+)\b')]);
    var url = _bestUrl(res, name);
    final getTool = tools.where((t) => t.name == 'get_deployment').firstOrNull;
    if (id != null && getTool != null) {
      final gp = ((getTool.schema['properties'] as Map?) ?? const {}).keys.map((k) => '$k').toList();
      final idKey = gp.firstWhere((k) => k.toLowerCase().contains('id') || k.toLowerCase().contains('url'), orElse: () => 'idOrUrl');
      var misses = 0;
      for (var i = 0; i < 24; i++) {
        await Future<void>.delayed(const Duration(seconds: 5));
        String st;
        try {
          st = await client.callTool('get_deployment', {idKey: id}).timeout(const Duration(seconds: 30));
        } catch (_) {
          if (++misses >= 3) break;
          continue;
        }
        if (st.startsWith('Error')) {
          if (++misses >= 3) break;
          continue;
        }
        final state = _firstMatch(st, [RegExp(r'"(?:readyState|state|status)"\s*:\s*"([A-Z_]+)"')]) ?? '';
        url = _bestUrl(st, name) ?? url;
        if (state == 'READY') break;
        if (state == 'ERROR' || state == 'CANCELED') throw PublishException('Vercel couldn\'t build the site this time. Try Publish again in a minute.');
      }
    }
    if (url == null) throw PublishException('Vercel took the site but didn\'t give an address yet. Open your Vercel dashboard to see it.');
    s.url = url;
    s.expiresAt = null;
    return url;
  }

  static String _vercelError(String res) {
    final t = res.toLowerCase();
    if (t.contains('unauthor') || t.contains('forbidden') || t.contains('401') || t.contains('403')) {
      return 'Vercel needs you to sign in again. Open Apps > Vercel and connect it, then publish again.';
    }
    if (t.contains('team')) return 'Vercel asked which team to use. Open Apps > Vercel and give SubMac access to your personal account.';
    return 'Vercel didn\'t take the site this time. Try Publish again in a minute.';
  }

  static String? _firstMatch(String s, List<RegExp> res) {
    for (final r in res) {
      final m = r.firstMatch(s);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// Prefers the clean project address (name.vercel.app) over a one-off deployment address.
  @visibleForTesting
  static String? bestVercelUrl(String s, String name) => _bestUrl(s, name);

  static String? _bestUrl(String s, String name) {
    final all = RegExp(r'(?:https://)?([a-z0-9][a-z0-9.-]*\.vercel\.app)', caseSensitive: false)
        .allMatches(s)
        .map((m) => m.group(1)!.toLowerCase())
        .toSet()
        .toList();
    if (all.isEmpty) return null;
    final clean = all.where((h) => h == '$name.vercel.app').firstOrNull ?? all.where((h) => !RegExp(r'-[a-z0-9]{9}-').hasMatch(h)).firstOrNull;
    return 'https://${clean ?? all.first}';
  }

  // ------------------------------------------------------------------ publish

  /// Publishes the site where [host] says. Returns the live address. Throws [PublishException] with a plain sentence.
  Future<String> publish(AppState app, Site s, String host, {String? chatId}) async {
    final files = await collect(s.entryPath);
    final url = host == SiteHost.vercel ? await _publishVercel(app, s, files) : await _publishFree(s, files);
    s.host = host;
    s.publishCount++;
    s.updated = DateTime.now();
    await _save();
    return url;
  }

  /// True when SubMac should offer (once) to keep this site as a project: it went online three times and its chat
  /// is not in a project yet.
  bool shouldOfferProject(Site s, String? chatId) =>
      !s.projectOffered && s.projectId == null && s.publishCount >= 3 && (chatId == null || Projects.I.forChat(chatId) == null);

  Future<void> markOffered(Site s) async {
    s.projectOffered = true;
    await _save();
  }

  /// Makes a project for the site: the chat joins it and the site's files are copied into the project's files.
  Future<Project> makeProject(Site s, {String? chatId}) async {
    final p = await Projects.I.create(s.title,
        instructions: 'This project is the website "${s.title}". Its main page is ${s.entryPath}'
            '${s.url.isEmpty ? '' : ', online at ${s.url}'}. Keep changes in that page (and its folder), then remind the user to tap Publish.');
    if (chatId != null) await Projects.I.assign(chatId, p.id);
    try {
      for (final f in await collect(s.entryPath)) {
        if (!f.path.contains('/')) await Projects.I.addFile(p.id, f.path, f.bytes);
      }
    } catch (_) {}
    s.projectId = p.id;
    s.projectOffered = true;
    await _save();
    return p;
  }

  Future<void> forget(Site s) async {
    list.remove(s);
    await _save();
  }
}
