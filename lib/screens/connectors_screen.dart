import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../app_state.dart';
import '../services/calm.dart';
import '../services/connector_catalog.dart';
import '../services/mcp_client.dart';
import '../services/mcp_oauth.dart';
import '../services/system_bridge.dart';
import '../services/system_tools.dart';
import 'logins_screen.dart';
import 'whatsapp_screen.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../widgets/app_key_dialog.dart';
import '../widgets/brand_logo.dart';
import '../widgets/pill_kit.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';


/// Apps Telesia can work with, each using the user's own key or account.
/// Nothing is registered with Telesia; keys stay encrypted on this phone.
class ConnectorsScreen extends StatefulWidget {
  const ConnectorsScreen({super.key, this.advanced = false});

  /// Settings > Advanced > API & tool servers: keys and tool servers only. The menu's Apps screen never shows them
  /// (PLAN.md 3.3).
  final bool advanced;

  @override
  State<ConnectorsScreen> createState() => _ConnectorsScreenState();
}

class _ConnectorsScreenState extends State<ConnectorsScreen> {
  String _q = '';
  String? _tab;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = Palette.of(context);
    final q = _q.toLowerCase();
    bool match(ConnDef d) =>
        q.isEmpty || d.name.toLowerCase().contains(q) || d.blurb.toLowerCase().contains(q) || d.category.toLowerCase().contains(q);
    // Apps that connect by signing in replace their key-based twins, so nobody is asked for an API key they don't need.
    final presetNames = {for (final pr in McpOAuth.presets) pr.name.toLowerCase()};
    final presetIds = {for (final pr in McpOAuth.presets) pr.id};
    bool twin(ConnDef d) => presetNames.contains(d.name.toLowerCase()) || presetIds.contains(d.id.toLowerCase());
    bool pmatch(McpPreset pr) =>
        q.isEmpty || pr.name.toLowerCase().contains(q) || pr.blurb.toLowerCase().contains(q) || pr.category.toLowerCase().contains(q);
    final connected = ConnectorCatalog.all.where((d) => ConnectorCatalog.connected.containsKey(d.id)).toList();
    // Three rows (plan 4): Apps for everyone (sign in or on the phone), API for keys and tokens, MCP for tool server links.
    final tabs = widget.advanced
        ? const ['Keys', 'Tool servers']
        : [
            if (ConnectorCatalog.connected.isNotEmpty || state.mcpServers.isNotEmpty) 'Connected',
            'Apps',
          ];
    var tab = _tab ?? tabs.first;
    if (!tabs.contains(tab)) tab = tabs.first;
    Widget head(String t) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 14, 20, 8),
          child: Text(t, style: AppText.sectionStyle.copyWith(color: p.muted)),
        );
    Widget note(String t) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 12),
          child: Text(t, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
        );
    final keyApps = [for (final d in ConnectorCatalog.all) if (!twin(d) || ConnectorCatalog.connected.containsKey(d.id)) d];
    final List<Widget> body;
    if (q.isNotEmpty) {
      final ps = McpOAuth.presets.where(pmatch).toList();
      final ks = keyApps.where(match).toList();
      body = [
        for (final pr in ps) _PresetTile(pr),
        for (final d in ks) _ConnTile(d),
        if (ps.isEmpty && ks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text('No app by that name yet. Try its company name, or add it under MCP.', textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
          ),
      ];
    } else if (tab == 'Connected') {
      body = [
        for (final s in state.mcpServers)
          CardRow(
            title: s.name,
            leading: BrandLogo(_serverApp(s), s.name),
            subtitle: state.mcpStatus[s.id] ?? (s.enabled ? 'Connecting…' : 'Off'),
            done: (state.mcpStatus[s.id] ?? '').startsWith('Connected'),
            action: 'Open',
            onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => McpEditScreen(existing: s))),
          ),
        for (final d in connected) _ConnTile(d),
        if (connected.isEmpty && state.mcpServers.isEmpty)
          EmptyHint(text: 'Nothing connected yet.', example: 'Browse apps', onExample: () => setState(() => _tab = 'Apps')),
      ];
    } else if (tab == 'Apps') {
      body = [
        head('Talk and sign in'),
        CardRow(
          title: 'Websites I can sign in to',
          leading: const PhoneAppTile(Icons.key_outlined),
          subtitle: 'Logins Telesia uses for you on websites. Passwords stay on this phone.',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginsScreen())),
        ),
        head('On this phone'),
        _phoneRow('calendar', 'Calendar', 'See your events and add new ones, for every account on this phone, Google included',
            () => [Permission.calendarFullAccess].request()),
        _phoneRow('contacts', 'Contacts', 'Find the right person when you ask to call, text or email someone', () => Permission.contacts.request()),
        _phoneRow('sms', 'Text messages', 'Find codes, bank and delivery messages when you ask', () => Permission.sms.request()),
        _phoneRow('notifRead', 'Notifications', '"What did I miss?" across WhatsApp, your bank and other apps',
            () => SystemBridge.I.openPermission('notifRead')),
        CardRow(
          title: 'WhatsApp',
          leading: const BrandLogo('whatsapp', 'WhatsApp'),
          subtitle: 'Read new messages, reply, send to anyone, share files and start calls, with your OK each time',
          done: SystemTools.perms['notifRead'] == true && SystemTools.perms['accessibility'] == true,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const WhatsAppScreen()));
            await SystemTools.refreshPerms();
            if (mounted) setState(() {});
          },
        ),
        for (final cat in const ['Work', 'Create', 'Business', 'Life', 'Files', 'Websites', 'Research', 'Everything']) ...[
          if (McpOAuth.presets.any((pr) => pr.category == cat)) head(cat == 'Everything' ? 'Many apps at once' : cat),
          for (final pr in McpOAuth.presets.where((pr) => pr.category == cat)) _PresetTile(pr),
        ],
      ];
    } else if (tab == 'Keys') {
      body = [
        note('Connect with a key.'),
        for (final cat in ConnectorCatalog.categories) ...[
          if (keyApps.any((d) => d.category == cat)) head(cat),
          for (final d in keyApps.where((d) => d.category == cat)) _ConnTile(d),
        ],
        head('Your own'),
        for (final c in ConnectorCatalog.custom)
          CardRow(
              title: c['name'] ?? 'API',
              subtitle: c['base'] ?? '',
              leading: const PhoneAppTile(Icons.api_rounded),
              done: true,
              onTap: () => _customSheet(context, c)),
        CardRow(
          title: 'Any API',
          leading: const PhoneAppTile(Icons.add_rounded),
          subtitle: 'A base link and a key. Telesia learns to use it.',
          action: 'Add',
          onAction: () => _customSheet(context, null),
        ),
      ];
    } else {
      body = [
        note('Add a tool server by its link.'),
        CardRow(
          title: 'Tool server',
          leading: const PhoneAppTile(Icons.hub_outlined),
          subtitle: 'Paste a link',
          action: 'Add',
          onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const McpEditScreen())),
        ),
        for (final s in state.mcpServers)
          CardRow(
            title: s.name,
            leading: BrandLogo(_serverApp(s), s.name),
            subtitle: state.mcpStatus[s.id] ?? (s.enabled ? 'Connecting…' : 'Off'),
            done: (state.mcpStatus[s.id] ?? '').startsWith('Connected'),
            action: 'Open',
            onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => McpEditScreen(existing: s))),
          ),
        head('Developer apps'),
        for (final pr in McpOAuth.presets.where((pr) => pr.category == 'Developers')) _PresetTile(pr),
      ];
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        centerTitle: true,
        title: Text(widget.advanced ? 'API & tool servers' : 'Apps'),
      ),
      // Speed: rows (and their logos) are built only as they scroll into view.
      body: Builder(builder: (context) {
        final items = <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 12),
            child: PillSearch(hint: 'Search apps', onChanged: (v) => setState(() => _q = v)),
          ),
          if (q.isEmpty) ...[
            CategoryTabs(tabs: tabs, selected: tab, onSelect: (t) => setState(() => _tab = t)),
            const SizedBox(height: 10),
          ],
          ...body,
        ];
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: items.length,
          itemBuilder: (_, i) => items[i],
        );
      }),
    );
  }

  /// The app behind a connected tool server: its preset when the link matches one, else its address.
  String _serverApp(McpServerConfig s) {
    for (final pr in McpOAuth.presets) {
      if (pr.url == s.url) return pr.id;
    }
    return BrandLogo.idFor(s.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''), url: s.url);
  }

  /// A phone app: allowed already, or one tap to allow.
  Widget _phoneRow(String key, String title, String what, Future<Object?> Function() allow) {
    final on = SystemTools.perms[key] == true;
    const icons = {
      'calendar': Icons.calendar_month_outlined,
      'contacts': Icons.people_outline_rounded,
      'sms': Icons.sms_outlined,
      'notifRead': Icons.notifications_none_rounded,
    };
    return CardRow(
      title: title,
      leading: PhoneAppTile(icons[key] ?? Icons.phone_android_rounded),
      subtitle: what,
      done: on,
      action: on ? null : 'Allow',
      onAction: on
          ? null
          : () async {
              await allow();
              await SystemTools.refreshPerms();
              if (mounted) setState(() {});
            },
      onTap: on ? () => SystemBridge.I.openPermission(key == 'notifRead' ? 'notifRead' : 'app') : null,
    );
  }

  Future<void> _customSheet(BuildContext context, Map<String, String>? existing) async {
    final state = context.read<AppState>();
    final name = TextEditingController(text: existing?['name'] ?? '');
    final base = TextEditingController(text: existing?['base'] ?? '');
    final header = TextEditingController(text: existing?['header'] ?? 'Authorization');
    final prefix = TextEditingController(text: existing?['prefix'] ?? 'Bearer ');
    final key = TextEditingController(text: existing?['key'] ?? '');
    final notes = TextEditingController(text: existing?['notes'] ?? '');
    final r = await showModalBottomSheet<String>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(20, 20, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Your own API', style: Brand.serif(size: 24, color: Palette.of(ctx).text)),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'My shop API')),
            TextField(controller: base, decoration: const InputDecoration(labelText: 'Base link', hintText: 'https://api.example.com/v1')),
            TextField(controller: header, decoration: const InputDecoration(labelText: 'Key header', hintText: 'Authorization')),
            TextField(controller: prefix, decoration: const InputDecoration(labelText: 'Before the key', hintText: 'Bearer ')),
            TextField(controller: key, obscureText: true, decoration: const InputDecoration(labelText: 'Key')),
            TextField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'What it does (optional)', hintText: 'Docs link or example paths')),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(tr('Save'))),
            ),
            if (existing != null)
              Center(child: TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Remove'))),
          ]),
        ),
      ),
    );
    if (r == 'save' && !base.text.trim().startsWith('http')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not saved: the base link needs to start with https://, like https://api.example.com/v1')));
      }
      return;
    }
    if (r == 'delete' && existing != null) {
      await state.removeCustomApi(existing['id']!);
    } else if (r == 'save') {
      await state.saveCustomApi({
        'id': existing?['id'] ?? const Uuid().v4().substring(0, 8),
        'name': name.text.trim().isEmpty ? 'My API' : name.text.trim(),
        'base': base.text.trim(),
        'header': header.text.trim(),
        'prefix': prefix.text,
        'key': key.text.trim(),
        'notes': notes.text.trim(),
      });
    }
  }
}

/// A ready-made app: one tap, sign in, done.
class _PresetTile extends StatelessWidget {
  const _PresetTile(this.pr);
  final McpPreset pr;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final on = state.mcpServers.where((s) => s.url == pr.url).firstOrNull;
    final busy = state.mcpSigningIn.contains(pr.id);
    final status = on == null ? null : state.mcpStatus[on.id];
    final failed = !busy && on == null ? state.mcpConnectError[pr.id] : null;
    Future<void> connect() async {
      String? key;
      if (pr.needsKey) {
        key = await askAppKey(context, pr);
        if (key == null || !context.mounted) return;
      }
      final err = await state.connectMcpPreset(pr, key: key);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? '${pr.name} is connected.')));
    }
    return CardRow(
      title: pr.name,
      subtitle: busy
          ? (pr.signIn && !pr.needsKey ? 'Finish signing in, in your browser…' : 'Connecting…')
          : on != null
              ? (status ?? 'Connected')
              : (failed ?? pr.blurb),
      leading: BrandLogo(pr.id, pr.name),
      done: on != null && (status ?? 'Connected').startsWith('Connected'),
      action: busy
          ? (pr.signIn ? 'Cancel' : '…')
          : (on != null ? (status != null && !status.startsWith('Connected') ? 'Reconnect' : 'Manage') : (failed != null ? 'Try again' : 'Connect')),
      onAction: busy
          ? (pr.signIn ? state.cancelMcpSignIn : null)
          : on != null && (status == null || status.startsWith('Connected'))
              ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => McpEditScreen(existing: on)))
              : connect,
    );
  }
}

class _ConnTile extends StatelessWidget {
  const _ConnTile(this.d);
  final ConnDef d;

  @override
  Widget build(BuildContext context) {
    final on = ConnectorCatalog.connected.containsKey(d.id);
    void open() => showModalBottomSheet<void>(
          sheetAnimationStyle: SubMotion.sheet,
          context: context,
          isScrollControlled: true,
          builder: (_) => ConnectSheet(d),
        );
    return CardRow(
      title: d.name,
      subtitle: on ? 'Connected' : d.blurb,
      leading: BrandLogo(d.id, d.name),
      action: on ? 'Manage' : 'Connect',
      onAction: open,
    );
  }
}

/// Connect (or disconnect) one app: its fields, where to get the key, and a test.
class ConnectSheet extends StatefulWidget {
  const ConnectSheet(this.d, {super.key});
  final ConnDef d;

  @override
  State<ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<ConnectSheet> {
  final Map<String, TextEditingController> _c = {};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final have = ConnectorCatalog.connected[widget.d.id] ?? const {};
    for (final f in widget.d.fields) {
      _c[f.key] = TextEditingController(text: f.secret ? '' : (have[f.key] ?? ''));
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final have = ConnectorCatalog.connected[widget.d.id] ?? const <String, String>{};
    final v = <String, String>{};
    for (final f in widget.d.fields) {
      var t = _c[f.key]!.text.trim();
      if (t.isEmpty && f.secret) t = have[f.key] ?? '';
      if (t.isEmpty) {
        setState(() => _error = 'Please fill in "${f.label}".');
        return;
      }
      if (f.key == 'url') {
        if (!t.startsWith('http')) t = 'https://$t';
      } else if (const {'site', 'store', 'sub', 'domain'}.contains(f.key)) {
        t = t.replaceFirst(RegExp(r'^https?://'), '');
      }
      while (t.endsWith('/')) {
        t = t.substring(0, t.length - 1);
      }
      v[f.key] = t;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? err;
    try {
      // Never spin forever: a slow or silent service ends in a plain line after 40 seconds.
      err = await ConnectorCatalog.test(widget.d, v)
          .timeout(const Duration(seconds: 40), onTimeout: () => '${widget.d.name} is slow to answer. Check the details, then try again.');
    } catch (e) {
      err = Calm.short(e, app: widget.d.name);
    }
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = 'Not connected yet. $err';
      });
      return;
    }
    await state.connectApp(widget.d.id, v);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = widget.d;
    final on = ConnectorCatalog.connected.containsKey(d.id);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(20, 20, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            BrandLogo(d.id, d.name, size: 44),
            const SizedBox(width: 12),
            Expanded(child: Text(d.name, style: Brand.serif(size: 26, color: p.text))),
          ]),
          const SizedBox(height: 10),
          Text(d.help, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => launchUrl(Uri.parse(d.helpUrl), mode: LaunchMode.externalApplication),
            child: Text('Get it here', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
          ),
          for (final f in d.fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _c[f.key],
                obscureText: f.secret,
                autocorrect: false,
                enableSuggestions: !f.secret,
                decoration: InputDecoration(
                  labelText: f.label,
                  hintText: f.secret && on ? 'Saved. Paste a new one to change it' : (f.hint.isEmpty ? null : f.hint),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(_error!, style: TextStyle(color: p.accent, fontSize: AppText.meta)),
            ),
          const SizedBox(height: 8),
          // Full-width button (the theme's buttons are full width, so never put one in a Row with a Spacer).
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Checking…' : (on ? 'Save' : 'Connect')),
            ),
          ),
          if (on)
            Center(
              child: TextButton(
                onPressed: () async {
                  await context.read<AppState>().disconnectApp(d.id);
                  if (context.mounted) Navigator.pop(context);
                },
                child: Text('Disconnect', style: TextStyle(color: p.muted)),
              ),
            ),
        ]),
      ),
    );
  }
}

class McpEditScreen extends StatefulWidget {
  final McpServerConfig? existing;
  const McpEditScreen({super.key, this.existing});

  @override
  State<McpEditScreen> createState() => _McpEditScreenState();
}

class _McpEditScreenState extends State<McpEditScreen> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  late final _headerName = TextEditingController(text: widget.existing?.headers.keys.firstOrNull ?? 'Authorization');
  late final _headerValue = TextEditingController(text: widget.existing?.headers.values.firstOrNull ?? '');
  late bool _enabled = widget.existing?.enabled ?? true;
  late bool _readOnly = widget.existing?.readOnly ?? false;
  String? _status;
  bool _testing = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _headerName.dispose();
    _headerValue.dispose();
    super.dispose();
  }

  McpServerConfig _build() => McpServerConfig(
        id: widget.existing?.id ?? const Uuid().v4(),
        name: _name.text.trim().isEmpty ? 'Tool server' : _name.text.trim(),
        url: _url.text.trim(),
        headers: {
          if (_headerName.text.trim().isNotEmpty && _headerValue.text.trim().isNotEmpty)
            _headerName.text.trim(): _headerValue.text.trim(),
        },
        enabled: _enabled,
        readOnly: _readOnly,
      );

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _status = null;
    });
    try {
      final tools = await McpClient(_build()).listTools();
      if (mounted) setState(() => _status = 'Connected: ${tools.length} tools ready.');
    } catch (e) {
      if (mounted) setState(() => _status = Calm.short(e, app: _name.text.trim().isEmpty ? null : _name.text.trim()));
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing?.name ?? 'Tool server'),
        actions: [
          if (widget.existing != null)
            TextButton(
              onPressed: () async {
                await state.deleteMcpServer(widget.existing!.id);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text('Remove', style: TextStyle(color: p.accent)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Paste the link of an MCP tool server. If it needs a key, add it as a header.',
            style: TextStyle(color: p.muted, height: 1.4),
          ),
          const SizedBox(height: 12),
          _label('Name'),
          TextField(controller: _name),
          const SizedBox(height: 14),
          _label('Server link'),
          TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'https://…/mcp')),
          const SizedBox(height: 14),
          _label('Key header (optional)'),
          TextField(controller: _headerName, decoration: const InputDecoration(hintText: 'Authorization')),
          const SizedBox(height: 14),
          _label('Key value'),
          TextField(
            controller: _headerValue,
            obscureText: true,
            decoration: const InputDecoration(hintText: 'Bearer …'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use this connector'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Read only'),
            subtitle: const Text('Telesia can look things up here but never change, send or delete anything. '
                'When off, it still asks you before every change.'),
            value: _readOnly,
            onChanged: (v) => setState(() => _readOnly = v),
          ),
          if (_status != null) ...[
            const SizedBox(height: 4),
            Text(_status!, style: TextStyle(color: p.muted)),
          ],
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _testing || _url.text.trim().isEmpty ? null : _test,
            child: Text(_testing ? 'Testing…' : 'Test connection'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () async {
              if (_url.text.trim().isEmpty) return;
              final built = _build();
              // Keep the sign-in tokens of an app connected by signing in.
              if (widget.existing != null && widget.existing!.oauth.isNotEmpty && built.url == widget.existing!.url) {
                built.oauth = widget.existing!.oauth;
                built.headers['Authorization'] ??= widget.existing!.headers['Authorization'] ?? '';
              }
              // No key given and the server wants a sign-in: do it in the browser instead of asking for one.
              if (built.headers.isEmpty && built.oauth.isEmpty && built.enabled) {
                final w = await McpOAuth.probe(built.url);
                if (w != null && w.isNotEmpty) {
                  final err = await state.connectMcpUrl(built.url, name: built.name, signIn: true);
                  if (!context.mounted) return;
                  if (err != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                    return;
                  }
                  Navigator.pop(context);
                  return;
                }
              }
              await state.upsertMcpServer(built);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsetsDirectional.only(bottom: 6, start: 4),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppText.meta)),
      );
}
