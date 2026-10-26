import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/bot_package.dart';
import '../services/bots.dart';
import '../services/connector_catalog.dart';
import '../services/doc_tools.dart';
import '../services/mcp_oauth.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../widgets/brand_logo.dart';
import '../widgets/lux_kit.dart';
import '../widgets/sub_icon.dart';
import 'connectors_screen.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// The tools part of a bot's settings: Skills, Apps, Sign-in apps. (Instructions, files and notes
/// live together on the Training tab, plan 5.2.)
class BotSetupSection extends StatelessWidget {
  const BotSetupSection({super.key, required this.bot});
  final Bot bot;

  @override
  Widget build(BuildContext context) {
    final b = bot;
    final conns = b.apps.where((a) => a.kind == 'connector').toList();
    final mcps = b.apps.where((a) => a.kind == 'mcp').toList();
    String need(List<BotApp> l) {
      final n = l.where((a) => !Bots.I.appReady(a)).length;
      return n == 0 ? '' : ' · $n need connecting';
    }

    // Skill library hidden for launch (PLAN.md 3.3).
    return Column(children: [
      _Tile(
        title: 'Apps',
        sub: !b.appsScoped
            ? 'Can use all the apps you connected'
            : conns.isEmpty
                ? 'None yet'
                : '${conns.map((a) => a.name).join(', ')}${need(conns)}',
        warn: need(conns).isNotEmpty,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotAppsScreen(botId: b.id, kind: 'connector'))),
      ),
      _Tile(
        title: 'Sign-ins',
        sub: !b.appsScoped
            ? 'Can use all the apps you signed in to'
            : mcps.isEmpty
                ? 'None yet'
                : '${mcps.map((a) => a.name).join(', ')}${need(mcps)}',
        warn: need(mcps).isNotEmpty,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotAppsScreen(botId: b.id, kind: 'mcp'))),
      ),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.title, required this.sub, required this.onTap, this.warn = false});
  final String title;
  final String sub;
  final VoidCallback onTap;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LuxTap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(title), style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          // Something to connect is said in the brand red, in words.
          Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: warn ? Palette.red : p.muted)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- training (plan 5.2)

/// Training, one page: Tell it (instructions) · Give it files · What it learned (notes from its work and
/// your corrections), plus what it knows about you.
class BotTrainingView extends StatelessWidget {
  const BotTrainingView({super.key, required this.botId});
  final String botId;

  static const _textExt = {'txt', 'md', 'csv', 'json', 'html', 'htm', 'xml', 'yaml', 'yml', 'log', 'tsv', 'rtf'};
  static const _imgExt = {'png', 'jpg', 'jpeg', 'webp'};

  /// The text of a picked file: PDFs and text files directly, photos by reading the text in them.
  static Future<String?> fileText(PlatformFile f) async {
    final ext = (f.extension ?? f.name.split('.').last).toLowerCase();
    final bytes = f.bytes ?? (f.path == null ? null : await File(f.path!).readAsBytes());
    if (bytes == null) return null;
    if (ext == 'pdf') return DocTools.pdfText(bytes, maxChars: BotKnowledge.maxItemChars);
    if (_imgExt.contains(ext) && f.path != null) return DocTools.ocrFile(f.path!);
    if (_textExt.contains(ext) || !bytes.take(2000).contains(0)) return utf8.decode(bytes, allowMalformed: true);
    return null;
  }

  static String _src(String s) => switch (s) {
        'mistake' => 'after a mistake',
        'correction' => 'after you corrected it',
        'nudge' => 'after a nudge from the team lead',
        'owner' => 'written by you',
        'shared' => 'came with the bot',
        'self' => 'noted while working',
        _ => 'after a task',
      };

  Future<void> _addText(BuildContext context, Bot b, {BotKnowledge? edit}) async {
    final title = TextEditingController(text: edit?.title ?? '');
    final text = TextEditingController(text: edit?.text ?? '');
    final ok = await showLuxSheet<bool>(
      context,
      title: edit == null ? 'Add text' : 'Edit',
      builder: (ctx) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2, Space.x5, Space.x5),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title, e.g. Price list')),
            const SizedBox(height: 10),
            TextField(
              controller: text,
              minLines: 6,
              maxLines: 14,
              decoration: const InputDecoration(labelText: 'What they should know'),
            ),
            const SizedBox(height: 14),
            Align(alignment: AlignmentDirectional.centerEnd, child: LuxWordButton('Save', primary: true, onPressed: () => Navigator.pop(ctx, true))),
          ]),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (edit != null) {
      edit
        ..title = title.text.trim().isEmpty ? edit.title : title.text.trim()
        ..text = BotPackage.scrubSecrets(text.text.trim());
      if (edit.text.isEmpty) b.knowledge.remove(edit);
      await Bots.I.saveKnowledge(b);
      return;
    }
    final e = await Bots.I.addKnowledge(b, title.text, text.text);
    if (e != null) messenger.showSnackBar(SnackBar(content: Text(e)));
  }

  Future<void> _addFile(BuildContext context, Bot b) async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await FilePicker.pickFiles(withData: true, type: FileType.any);
    final f = res?.files.firstOrNull;
    if (f == null) return;
    String? text;
    try {
      text = await fileText(f);
    } catch (_) {}
    if (text == null || text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Can\'t read that file.')));
      return;
    }
    final e = await Bots.I.addKnowledge(b, f.name.replaceFirst(RegExp(r'\.[^.]+$'), ''), text, kind: 'file', file: f.name);
    messenger.showSnackBar(SnackBar(content: Text(e ?? 'Added ${f.name}.')));
  }

  Future<void> _editLesson(BuildContext context, Bot b, {BotLesson? l}) async {
    final raw = await luxPrompt(context,
        title: l == null ? 'Add' : 'Edit', initial: l?.text ?? '', hint: 'e.g. Always give the source link next to each number.', maxLines: 4);
    final v = raw == null ? null : (raw.length > 200 ? raw.substring(0, 200) : raw);
    if (v == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (l != null) b.lessons.remove(l);
    final e = v.trim().isEmpty ? null : await Bots.I.addLesson(b, v, source: 'owner');
    if (v.trim().isEmpty) await Bots.I.save();
    if (e != null) {
      if (l != null) b.lessons.add(l);
      await Bots.I.save();
      messenger.showSnackBar(SnackBar(content: Text(e)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Bots.I,
      builder: (context, _) {
        final b = Bots.I.byId(botId);
        if (b == null) return const SizedBox.shrink();
        final used = Bots.I.knowledgeChars(b);
        final lessons = [...b.lessons]..sort((x, y) => y.at.compareTo(x.at));
        Widget head(String t, String sub) => Padding(
              padding: const EdgeInsets.only(top: Space.x5, bottom: Space.x2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(t), style: AppText.sectionStyle.copyWith(color: p.faint)),
                const SizedBox(height: 2),
                Text(sub, style: AppText.metaStyle.copyWith(color: p.muted)),
              ]),
            );
        Widget remove(String label, VoidCallback onTap) => LuxTap(
              label: tr(label),
              onTap: onTap,
              child: Padding(padding: const EdgeInsets.all(Space.x2), child: SubIcon('close', size: IconSize.sm, color: p.muted)),
            );
        return ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 48), children: [
          head('Tell it', 'How ${b.name} should work. Shared with copies, so no personal details.'),
          _TellIt(bot: b),
          head('Files', 'Notes and files ${b.name} looks things up in.'),
          Wrap(children: [
            LuxWordButton('Add text', primary: true, onPressed: () => _addText(context, b)),
            LuxWordButton('Add a file', primary: true, onPressed: () => _addFile(context, b)),
          ]),
          LuxSwitchRow(
            title: tr('Only my files'),
            sub: b.sandbox
                ? 'On: ${b.name} answers only from what you gave it, with no web search or browser.'
                : 'Off: ${b.name} uses these first, and may look elsewhere when they are not enough.',
            value: b.sandbox,
            onChanged: (v) async {
              b.sandbox = v;
              await Bots.I.save();
            },
          ),
          if (b.knowledge.isNotEmpty)
            Text('${(used / 1000).toStringAsFixed(0)}k of ${BotKnowledge.maxTotalChars ~/ 1000}k letters used',
                style: TextStyle(color: p.muted, fontSize: AppText.micro)),
          for (final k in b.knowledge)
            LuxRow(
              padding: const EdgeInsets.symmetric(vertical: Space.x2),
              title: k.title,
              sub: '${k.kind == 'file' && k.file.isNotEmpty ? '${k.file} · ' : ''}${k.text.replaceAll(RegExp(r'\s+'), ' ').trim()}',
              onTap: () => _addText(context, b, edit: k),
              trailing: remove('Remove', () async {
                b.knowledge.remove(k);
                await Bots.I.saveKnowledge(b);
              }),
            ),
          head('Learned', 'Lessons ${b.name} learned.'),
          for (final l in lessons)
            LuxRow(
              padding: const EdgeInsets.symmetric(vertical: Space.x2),
              title: l.text,
              maxLines: 4,
              sub: '${_src(l.source)}${l.uses > 0 ? ' · confirmed ${l.uses}x' : ''}',
              onTap: () => _editLesson(context, b, l: l),
              trailing: remove('Delete', () async {
                b.lessons.remove(l);
                await Bots.I.save();
              }),
            ),
          if (lessons.isEmpty) Text(tr('Nothing yet.'), style: TextStyle(color: p.muted)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: LuxWordButton('Add', primary: true, onPressed: () => _editLesson(context, b)),
          ),
          head('Knows about you', 'Facts ${b.name} saved while working with you.'),
          if (b.memory.isEmpty) Text(tr('Nothing yet.'), style: TextStyle(color: p.muted)),
          for (final m in b.memory.reversed.take(40))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Text(m, style: AppText.metaStyle.copyWith(color: p.text))),
                remove('Remove', () async {
                  b.memory.remove(m);
                  await Bots.I.save();
                }),
              ]),
            ),
        ]);
      },
    );
  }
}

/// The instructions box, saved with one tap (the button shows only when something changed).
class _TellIt extends StatefulWidget {
  const _TellIt({required this.bot});
  final Bot bot;
  @override
  State<_TellIt> createState() => _TellItState();
}

class _TellItState extends State<_TellIt> {
  late final TextEditingController _c = TextEditingController(text: widget.bot.instructions);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changed = _c.text.trim() != widget.bot.instructions.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _c,
        minLines: 4,
        maxLines: 14,
        maxLength: 8000,
        onChanged: (_) => setState(() {}),
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'e.g. Always answer in short bullet points. Ask for the country before giving legal advice. Never book anything without asking me.',
        ),
      ),
      SubSize(
        duration: SubMotion.quick,
        alignment: AlignmentDirectional.topStart,
        child: changed
            ? Align(
                alignment: AlignmentDirectional.centerEnd,
                child: LuxWordButton('Save', primary: true, onPressed: () async {
                  widget.bot.instructions = BotPackage.scrubSecrets(_c.text.trim());
                  await Bots.I.save();
                  if (mounted) setState(() {});
                }),
              )
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- apps and MCP servers

/// Connects one app a bot came with, for the current owner: sign in, add a key, or the app's connect sheet.
/// Returns null when connected (or the sheet was shown), or a plain sentence.
Future<String?> connectBotApp(BuildContext context, BotApp a) async {
  final state = context.read<AppState>();
  if (a.kind == 'connector') {
    final d = ConnectorCatalog.byId(a.ref);
    if (d == null) return '${a.name} is not available in this version of SubMac.';
    await showModalBottomSheet<void>(sheetAnimationStyle: SubMotion.sheet, context: context, isScrollControlled: true, builder: (_) => ConnectSheet(d));
    return null;
  }
  if (a.auth == 'key') {
    // Keys are not typed inside a bot (plan 5.3): the owner connects the app once in Apps, then every bot can use it.
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectorsScreen()));
    return Bots.I.appReady(a) ? null : 'Connect ${a.name} in Apps with its link and key, then it works for every bot.';
  }
  return state.connectBotMcp(a);
}

/// A row for one of the bot's apps: connected, or "Needs connecting" with a one-tap Connect.
class BotAppRow extends StatelessWidget {
  const BotAppRow({super.key, required this.app, this.onRemove, this.onTap});
  final BotApp app;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.watch<AppState>();
    final ready = Bots.I.appReady(app);
    final busy = state.mcpSigningIn.contains(app.ref);
    const what = 'Not connected';
    final status = ready ? tr('Connected') : (busy ? tr('Finish signing in, in your browser…') : (state.mcpConnectError[app.ref] ?? tr(what)));
    return LuxTap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x2),
        child: Row(children: [
          BrandLogo(BrandLogo.idForApp(app.kind, app.ref, app.name), app.name, size: 36),
          const SizedBox(width: Space.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
              Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: ready ? p.muted : Palette.red)),
            ]),
          ),
          if (!ready)
            busy
                ? LuxWordButton('Cancel', onPressed: state.cancelMcpSignIn)
                : LuxWordButton('Connect', primary: true, onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final e = await connectBotApp(context, app);
                    if (e != null) messenger.showSnackBar(SnackBar(content: Text(e)));
                  }),
          if (onRemove != null)
            LuxTap(
              label: tr('Remove'),
              onTap: onRemove,
              child: Padding(padding: const EdgeInsets.all(Space.x2), child: SubIcon('close', size: IconSize.sm, color: p.muted)),
            ),
        ]),
      ),
    );
  }
}

class BotAppsScreen extends StatelessWidget {
  const BotAppsScreen({super.key, required this.botId, required this.kind});
  final String botId;

  /// connector | mcp
  final String kind;

  Future<void> _add(BuildContext context, Bot b) async {
    final state = context.read<AppState>();
    final have = {for (final a in b.apps) '${a.kind}|${a.ref.toLowerCase()}'};
    final options = <BotApp>[];
    if (kind == 'connector') {
      for (final d in ConnectorCatalog.all) {
        options.add(BotApp(kind: 'connector', ref: d.id, name: d.name));
      }
      // Connected ones first.
      options.sort((x, y) => (ConnectorCatalog.connected.containsKey(x.ref) ? 0 : 1).compareTo(ConnectorCatalog.connected.containsKey(y.ref) ? 0 : 1));
    } else {
      for (final s in state.mcpServers) {
        if (BotPackage.safeMcpUrl(s.url)) options.add(state.botAppFromServer(s));
      }
      for (final pr in McpOAuth.presets) {
        if (!options.any((o) => o.ref == pr.url)) {
          options.add(BotApp(kind: 'mcp', ref: pr.url, name: pr.name, auth: pr.signIn ? 'oauth' : 'none'));
        }
      }
    }
    final pick = await showModalBottomSheet<Object>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.only(top: Space.x4), children: [
          for (final o in options)
            if (!have.contains('${o.kind}|${o.ref.toLowerCase()}'))
              LuxRow(
                leading: BrandLogo(BrandLogo.idForApp(o.kind, o.ref, o.name), o.name, size: 36),
                title: o.name,
                sub: tr(Bots.I.appReady(o) ? 'Connected for you' : 'Not connected'),
                onTap: () => Navigator.pop(ctx, o),
              ),
        ]),
      ),
    );
    if (pick == null || !context.mounted) return;
    BotApp? app = pick is BotApp ? pick : null;
    if (app == null) return;
    b.apps.add(app);
    b.appsScoped = true;
    await Bots.I.save();
    if (!Bots.I.appReady(app) && context.mounted) await connectBotApp(context, app);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    context.watch<AppState>();
    return AnimatedBuilder(
      animation: Bots.I,
      builder: (context, _) {
        final b = Bots.I.byId(botId);
        if (b == null) return const Scaffold(body: SizedBox.shrink());
        final mine = b.apps.where((a) => a.kind == kind).toList();
        final label = kind == 'mcp' ? 'Sign-ins' : 'Apps';
        return Scaffold(
          appBar: AppBar(title: Text(label)),
          body: ListView(padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x1, Space.x5, Space.x8 * 2), children: [
            Text(
                'The apps ${b.name} works with. When you share ${b.name}, these go along, '
                'but never your logins or keys: the new owner connects each one with their own.',
                style: TextStyle(color: p.muted, height: 1.4)),
            const SizedBox(height: 8),
            LuxSwitchRow(
              title: tr('Only these apps'),
              sub: b.appsScoped ? '${b.name} uses only the apps on its own lists.' : '${b.name} can use every app you connected.',
              value: b.appsScoped,
              onChanged: (v) async {
                b.appsScoped = v;
                await Bots.I.save();
              },
            ),
            const SizedBox(height: 6),
            if (mine.isEmpty)
              EmptyHint(text: 'No apps yet.', example: 'Add an app', onExample: () => _add(context, b), padding: const EdgeInsetsDirectional.fromSTEB(8, 16, 8, 8))
            else
              for (final a in mine)
                BotAppRow(
                  app: a,
                  onRemove: () async {
                    b.apps.remove(a);
                    await Bots.I.save();
                  },
                ),
            if (mine.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: LuxWordButton('Add an app', key: const ValueKey('bot-add-app'), primary: true, onPressed: () => _add(context, b)),
              ),
          ]),
        );
      },
    );
  }
}

