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
        icon: Icons.apps_rounded,
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
        icon: Icons.hub_outlined,
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
  const _Tile({required this.icon, required this.title, required this.sub, required this.onTap, this.warn = false});
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: p.text),
      title: Text(title),
      subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: warn ? Palette.red : p.muted)),
      trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
      onTap: onTap,
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
    final ok = await showModalBottomSheet<bool>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
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
            SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save')))),
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
    final c = TextEditingController(text: l?.text ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l == null ? 'Add' : 'Edit'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 200,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'e.g. Always give the source link next to each number.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(tr('Save'))),
        ],
      ),
    );
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
              padding: const EdgeInsets.only(top: 22, bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: AppText.sectionStyle.copyWith(color: p.muted)),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
              ]),
            );
        Widget outlined(IconData i, String t, VoidCallback onTap) => Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: p.text, backgroundColor: p.sheet, shape: const StadiumBorder(), minimumSize: const Size(0, 44)),
                onPressed: onTap,
                icon: Icon(i, size: 18),
                label: Text(t),
              ),
            );
        return ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 48), children: [
          head('Tell it', 'How ${b.name} should work. Shared with copies, so no personal details.'),
          _TellIt(bot: b),
          head('Files', 'Notes and files ${b.name} looks things up in.'),
          Row(children: [
            outlined(Icons.notes_rounded, 'Add text', () => _addText(context, b)),
            const SizedBox(width: 10),
            outlined(Icons.attach_file_rounded, 'Add a file', () => _addFile(context, b)),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Only my files'),
            subtitle: Text(
                b.sandbox
                    ? 'On: ${b.name} answers only from what you gave it, with no web search or browser.'
                    : 'Off: ${b.name} uses these first, and may look elsewhere when they are not enough.',
                style: TextStyle(color: p.muted, fontSize: AppText.micro)),
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
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(k.kind == 'file' ? Icons.description_outlined : Icons.sticky_note_2_outlined, color: p.text),
              title: Text(k.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${k.kind == 'file' && k.file.isNotEmpty ? '${k.file} · ' : ''}${k.text.replaceAll(RegExp(r'\s+'), ' ').trim()}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted),
              ),
              onTap: () => _addText(context, b, edit: k),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: Icon(Icons.close_rounded, size: 18, color: p.muted),
                onPressed: () async {
                  b.knowledge.remove(k);
                  await Bots.I.saveKnowledge(b);
                },
              ),
            ),
          head('Learned', 'Lessons ${b.name} learned.'),
          for (final l in lessons)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lightbulb_outline_rounded, color: p.text),
              title: Text(l.text),
              subtitle: Text('${_src(l.source)}${l.uses > 0 ? ' · confirmed ${l.uses}x' : ''}', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
              onTap: () => _editLesson(context, b, l: l),
              trailing: IconButton(
                tooltip: 'Delete',
                icon: Icon(Icons.close_rounded, size: 18, color: p.muted),
                onPressed: () async {
                  b.lessons.remove(l);
                  await Bots.I.save();
                },
              ),
            ),
          if (lessons.isEmpty) Text(tr('Nothing yet.'), style: TextStyle(color: p.muted)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: p.text, padding: EdgeInsets.zero),
              onPressed: () => _editLesson(context, b),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
          ),
          head('Knows about you', 'Facts ${b.name} saved while working with you.'),
          if (b.memory.isEmpty) Text(tr('Nothing yet.'), style: TextStyle(color: p.muted)),
          for (final m in b.memory.reversed.take(40))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.bookmark_border_rounded, size: 18, color: p.text),
                const SizedBox(width: 12),
                Expanded(child: Text(m, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.35))),
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () async {
                    b.memory.remove(m);
                    await Bots.I.save();
                  },
                  child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.close_rounded, size: 16, color: p.muted)),
                ),
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
    final p = Palette.of(context);
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
      AnimatedSize(
        duration: SubMotion.of(context, SubMotion.quick),
        curve: SubMotion.settle,
        alignment: AlignmentDirectional.topStart,
        child: changed
            ? Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg),
                  onPressed: () async {
                    widget.bot.instructions = BotPackage.scrubSecrets(_c.text.trim());
                    await Bots.I.save();
                    if (mounted) setState(() {});
                  },
                  child: Text(tr('Save')),
                ),
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
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: BrandLogo(BrandLogo.idForApp(app.kind, app.ref, app.name), app.name, size: 36),
      title: Text(app.name),
      subtitle: Text(
        ready ? 'Connected' : (busy ? 'Finish signing in, in your browser…' : (state.mcpConnectError[app.ref] ?? what)),
        style: TextStyle(color: ready ? p.muted : Palette.red),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!ready)
          busy
              ? TextButton(onPressed: state.cancelMcpSignIn, child: Text(tr('Cancel')))
              : TextButton(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final e = await connectBotApp(context, app);
                    if (e != null) messenger.showSnackBar(SnackBar(content: Text(e)));
                  },
                  child: const Text('Connect'),
                ),
        if (onRemove != null)
          IconButton(tooltip: 'Remove', icon: Icon(Icons.close_rounded, size: 18, color: p.muted), onPressed: onRemove),
      ]),
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
    final p = Palette.of(context);
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
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, sc) => ListView(controller: sc, children: [
          for (final o in options)
            if (!have.contains('${o.kind}|${o.ref.toLowerCase()}'))
              ListTile(
                leading: BrandLogo(BrandLogo.idForApp(o.kind, o.ref, o.name), o.name, size: 36),
                title: Text(o.name),
                subtitle: Text(Bots.I.appReady(o) ? 'Connected for you' : 'Not connected', style: TextStyle(color: p.muted)),
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
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: p.text,
            foregroundColor: p.bg,
            onPressed: () => _add(context, b),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add an app'),
          ),
          body: ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 100), children: [
            Text(
                'The apps ${b.name} works with. When you share ${b.name}, these go along, '
                'but never your logins or keys: the new owner connects each one with their own.',
                style: TextStyle(color: p.muted, height: 1.4)),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Only these apps'),
              subtitle: Text(
                  b.appsScoped ? '${b.name} uses only the apps on its own lists.' : '${b.name} can use every app you connected.',
                  style: TextStyle(color: p.muted)),
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
          ]),
        );
      },
    );
  }
}

