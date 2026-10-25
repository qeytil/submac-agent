import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../services/projects.dart';
import '../theme.dart';
import '../widgets/motion.dart';
import '../widgets/sub_icon.dart';
import 'preview_screen.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// Asks for a name and makes a project. Returns it, or null.
Future<Project?> createProjectFlow(BuildContext context) async {
  final ctrl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('New project')),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'e.g. My shop, Thesis, Trip to Nairobi'),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(d, ctrl.text), child: Text(tr('Create'))),
      ],
    ),
  );
  if (name == null || name.trim().isEmpty) return null;
  return Projects.I.create(name);
}

/// One project: its chats, its instructions and its files, all on one calm page.
class ProjectScreen extends StatefulWidget {
  final String projectId;
  const ProjectScreen({super.key, required this.projectId});

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  List<File> _files = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  static String _kb(File f) {
    try {
      return '${(f.lengthSync() / 1024).ceil()} KB';
    } catch (_) {
      return '';
    }
  }

  Future<void> _fileMenu(File f) async {
    final pick = await showModalBottomSheet<String>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (canPreview(f.path)) ListTile(title: Text(tr('Open')), onTap: () => Navigator.pop(c, 'open')),
          ListTile(title: const Text('Share'), onTap: () => Navigator.pop(c, 'share')),
          ListTile(title: Text(tr('Remove from project')), onTap: () => Navigator.pop(c, 'remove')),
        ]),
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == 'open') {
      await openPreview(context, f.path);
    } else if (pick == 'share') {
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
    } else if (pick == 'remove') {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      await _loadFiles();
    }
  }

  Future<void> _loadFiles() async {
    final f = await Projects.I.files(widget.projectId);
    if (mounted) setState(() => _files = f);
  }

  Future<void> _addFiles() async {
    final res = await FilePicker.pickFiles(allowMultiple: true, withData: true);
    if (res == null) return;
    for (final f in res.files) {
      final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes != null) await Projects.I.addFile(widget.projectId, f.name, bytes);
    }
    await _loadFiles();
  }

  Future<void> _editInstructions(Project p) async {
    final ctrl = TextEditingController(text: p.instructions);
    final v = await showModalBottomSheet<String>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(20, 8, 20, MediaQuery.of(c).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Instructions'), style: Brand.serif(size: 24, color: Palette.of(c).text)),
            const SizedBox(height: 6),
            Text('How SubMac should work in this project: tone, facts to remember, what to always or never do.',
                style: TextStyle(color: Palette.of(c).muted, height: 1.4)),
            const SizedBox(height: 12),
            TextField(controller: ctrl, autofocus: true, minLines: 4, maxLines: 10),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(onPressed: () => Navigator.pop(c, ctrl.text), child: Text(tr('Save'))),
            ),
          ],
        ),
      ),
    );
    if (v != null) await Projects.I.update(p, instructions: v);
  }

  Future<void> _rename(Project p) async {
    final ctrl = TextEditingController(text: p.name);
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(d, ctrl.text), child: Text(tr('Save'))),
        ],
      ),
    );
    if (v != null) await Projects.I.update(p, name: v);
  }

  Future<void> _delete(Project p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete project?'),
        content: const Text('Its chats move back to your main list. Its files stay in Files.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Delete'))),
        ],
      ),
    );
    if (ok == true) {
      await Projects.I.delete(p);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.watch<AppState>();
    return ListenableBuilder(
      listenable: Projects.I,
      builder: (context, _) {
        final proj = Projects.I.byId(widget.projectId);
        if (proj == null) return const Scaffold(body: SizedBox.shrink());
        final ids = Projects.I.chatsIn(proj.id).toSet();
        final chats = state.conversations.where((c) => ids.contains(c.id)).toList();
        return Scaffold(
          appBar: AppBar(
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'rename') _rename(proj);
                  if (v == 'delete') _delete(proj);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'rename', child: Text(tr('Rename'))),
                  const PopupMenuItem(value: 'delete', child: Text('Delete project')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 32),
            children: [
              FadeSlideIn(child: Text(proj.name, style: Brand.serif(size: 34, color: p.text, height: 1.1))),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () {
                  state.newChat(projectId: proj.id);
                  Navigator.of(context).popUntil((r) => r.isFirst);
                },
                child: const Text('New chat in this project'),
              ),
              const SizedBox(height: 26),
              FadeSlideIn(
                delay: SubMotion.staggerFor(1),
                child: _Section(
                title: 'Instructions',
                action: proj.instructions.isEmpty ? 'Add' : 'Edit',
                onAction: () => _editInstructions(proj),
                child: Text(
                  proj.instructions.isEmpty ? 'Tell SubMac how to work here. Every chat in this project follows it.' : proj.instructions,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: proj.instructions.isEmpty ? p.muted : p.text, height: 1.45),
                ),
              )),
              const SizedBox(height: 22),
              FadeSlideIn(
                delay: SubMotion.staggerFor(2),
                child: _Section(
                title: 'Files',
                action: 'Add',
                onAction: _addFiles,
                child: _files.isEmpty
                    ? Text('Add documents, notes or images SubMac should use in this project.',
                        style: TextStyle(color: p.muted, height: 1.45))
                    : Column(
                        children: [
                          for (final f in _files)
                            InkWell(
                              onTap: () => canPreview(f.path) ? openPreview(context, f.path) : _fileMenu(f),
                              onLongPress: () => _fileMenu(f),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Row(children: [
                                  Expanded(
                                    child: Text(f.path.split('/').last,
                                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text)),
                                  ),
                                  Text(_kb(f), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: 'More',
                                    icon: SubIcon('more', color: p.muted, size: IconSize.md),
                                    onPressed: () => _fileMenu(f),
                                  ),
                                ]),
                              ),
                            ),
                        ],
                      ),
              )),
              const SizedBox(height: 22),
              FadeSlideIn(
                delay: SubMotion.staggerFor(3),
                child: _Section(
                title: 'Chats',
                child: chats.isEmpty
                    ? Text('No chats yet.', style: TextStyle(color: p.muted))
                    : Column(
                        children: [
                          for (final c in chats)
                            InkWell(
                              onTap: () {
                                state.openConversation(c.id);
                                Navigator.of(context).popUntil((r) => r.isFirst);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Row(children: [
                                  Expanded(
                                    child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: AppText.body)),
                                  ),
                                ]),
                              ),
                            ),
                        ],
                      ),
              )),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final Widget child;
  const _Section({required this.title, required this.child, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x3, Space.x4),
      // The shared sky surface (restyle): a soft sheet, no outline, readable on the day and night sky.
      decoration: BoxDecoration(color: p.sheet, borderRadius: Radii.rowAll),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(title, style: AppText.sectionStyle.copyWith(color: p.muted)),
            const Spacer(),
            if (action != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(minimumSize: const Size(0, 32), padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: Text(action!, style: TextStyle(color: p.text)),
              ),
          ]),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
