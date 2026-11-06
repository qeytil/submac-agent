import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../services/device_access.dart';
import '../services/tools.dart';
import '../theme.dart';
import 'library_screen.dart' show LibraryScreen;
import 'settings_screen.dart' show TrashScreen;
import 'site_screens.dart' show SitesScreen;
import '../widgets/logo.dart';
import '../widgets/motion.dart';
import '../widgets/output_cards.dart';
import '../widgets/save_sheet.dart';
import 'preview_screen.dart' show canPreview, openPreview;
import '../widgets/sub_icon.dart';
import '../ui/tokens.dart';
import '../widgets/surface.dart';
import '../ui/i18n.dart';

/// The filters Files shows. Library, Sites and Trash live here as filters, not as their own menu items (PLAN.md 3.3).
enum FilesView { files, made, sites, trash }

/// Browse SubMac's own files and (with permission) the phone's storage; filter to what SubMac made, sites, or Trash.
class FilesScreen extends StatefulWidget {
  final String? start;
  final FilesView view;
  const FilesScreen({super.key, this.start, this.view = FilesView.files});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  late FilesView _view = widget.view;
  String? _dir;
  String _workspace = '';
  List<FileSystemEntity> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _workspace = await AgentTools.workspaceDir();
    await _open(widget.start ?? _workspace);
  }

  Future<void> _open(String dir) async {
    // Left before the workspace was found: nothing to show (setState after dispose).
    if (!mounted) return;
    setState(() {
      _dir = dir;
      _loading = true;
      _error = null;
    });
    try {
      final all = await Directory(dir).list().toList();
      all.removeWhere((e) => e.path.split('/').last.startsWith('.'));
      all.sort((a, b) {
        final da = a is Directory ? 0 : 1, db = b is Directory ? 0 : 1;
        if (da != db) return da - db;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (mounted) setState(() => _items = all);
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot open this folder.');
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _atRoot => _dir == _workspace || _dir == DeviceAccess.root;

  String _title() {
    if (_view != FilesView.files) return 'Files';
    if (_dir == _workspace) return 'SubMac files';
    if (_dir == DeviceAccess.root) return 'Phone';
    return _dir?.split('/').last ?? 'Files';
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  bool _isImage(String p) => RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false).hasMatch(p);

  void _fileActions(File f) {
    final state = context.read<AppState>();
    final name = f.path.split('/').last;
    showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
            child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Brand.serif(size: 24, color: Palette.of(context).text)),
          ),
          if (canPreview(f.path))
            ListTile(
              title: Text(tr('Open')),
              onTap: () {
                Navigator.pop(ctx);
                openPreview(context, f.path);
              },
            ),
          ListTile(
            title: const Text('Save to phone or a project'),
            onTap: () {
              Navigator.pop(ctx);
              showSaveSheet(context, f.path);
            },
          ),
          ListTile(
            title: const Text('Ask SubMac about it'),
            subtitle: const Text('Adds it to a new message'),
            onTap: () {
              Navigator.pop(ctx);
              state.shareInbox.value = {
                'text': '',
                'files': [f.path]
              };
              Navigator.popUntil(context, (r) => r.isFirst);
            },
          ),
          if (_isImage(f.path))
            ListTile(
              title: const Text('View'),
              onTap: () {
                Navigator.pop(ctx);
                openImageViewer(context, f.path);
              },
            ),
          ListTile(
            title: const Text('Share'),
            onTap: () {
              Navigator.pop(ctx);
              SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
            },
          ),
          ListTile(
            title: const Text('Copy location'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: f.path));
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            title: Text('Move to Trash', style: TextStyle(color: Palette.of(context).accent)),
            onTap: () async {
              Navigator.pop(ctx);
              final r = await AgentTools.execute('delete_file', {'path': f.path});
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.startsWith('Error') ? r : 'Moved to Trash')));
                _open(_dir!);
              }
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.watch<AppState>();
    return PopScope(
      canPop: _view != FilesView.files || _atRoot || _dir == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _dir != null) _open(Directory(_dir!).parent.path);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_title(), style: Brand.serif(size: 28, color: p.text))),
        body: Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  ChoiceChip(
                    label: const Text('SubMac files'),
                    selected: _view == FilesView.files && _dir != null && _dir!.startsWith(_workspace) && _workspace.isNotEmpty,
                    onSelected: (_) {
                      setState(() => _view = FilesView.files);
                      _open(_workspace);
                    },
                  ),
                  for (final (v, label) in const [(FilesView.made, 'Made by SubMac'), (FilesView.sites, 'Sites'), (FilesView.trash, 'Trash')]) ...[
                    const SizedBox(width: Space.x2),
                    ChoiceChip(
                      label: Text(label),
                      selected: _view == v,
                      onSelected: (_) => setState(() => _view = v),
                    ),
                  ],
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Phone'),
                    selected: _view == FilesView.files && _dir != null && _dir!.startsWith(DeviceAccess.root),
                    onSelected: (_) async {
                      if (!state.phoneAccess) {
                        final ok = await state.requestPhoneAccess();
                        if (!ok) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('Allow "All files access" for SubMac Agent to browse the phone.')));
                          }
                          return;
                        }
                      }
                      setState(() => _view = FilesView.files);
                      _open(DeviceAccess.root);
                    },
                  ),
                  if (state.phoneAccess && _view == FilesView.files) ...[
                    for (final f in const ['Download', 'Documents', 'DCIM', 'Pictures'])
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 8),
                        child: ActionChip(label: Text(f), onPressed: () => _open('${DeviceAccess.root}/$f')),
                      ),
                  ],
                ],
              ),
            ),
            if (_view == FilesView.made)
              const Expanded(child: LibraryScreen(embedded: true))
            else if (_view == FilesView.sites)
              const Expanded(child: SitesScreen(embedded: true))
            else if (_view == FilesView.trash)
              const Expanded(child: TrashScreen(embedded: true)),
            if (_view == FilesView.files && !_atRoot && _dir != null)
              ListTile(
                dense: true,
                title: Text('Back to ${Directory(_dir!).parent.path.split('/').last}', style: TextStyle(color: p.muted)),
                // The back arrow (it used to borrow the send arrow).
                leading: SubIcon('back', color: p.muted, size: 18),
                onTap: () => _open(Directory(_dir!).parent.path),
              ),
            if (_view == FilesView.files)
            Expanded(
              child: _loading
                  ? const Center(child: RedDot(size: 10, animate: true))
                  : _error != null
                      ? Center(child: Text(_error!, style: TextStyle(color: p.muted)))
                      : _items.isEmpty
                          ? Center(child: Text('This folder is empty', style: TextStyle(color: p.muted)))
                          : ListView.builder(
                              itemCount: _items.length,
                              itemBuilder: (c, i) {
                                final e = _items[i];
                                final name = e.path.split('/').last;
                                final isDir = e is Directory;
                                String sub = isDir ? 'Folder' : '';
                                if (e is File) {
                                  try {
                                    sub = _size(e.lengthSync());
                                  } catch (_) {}
                                }
                                return FadeSlideIn(
                                  key: ValueKey(e.path),
                                  enabled: i < 14,
                                  delay: SubMotion.staggerFor(i) ~/ 3,
                                  child: SurfaceRow(
                                    child: ListTile(
                                    leading: isDir
                                        ? SubIcon('folder', color: p.text)
                                        : _isImage(e.path)
                                            ? ClipRRect(
                                                borderRadius: BorderRadius.circular(4),
                                                child: Image.file(File(e.path), width: 36, height: 36, fit: BoxFit.cover, cacheWidth: 96, frameBuilder: subImageFade,
                                                    errorBuilder: (_, __, ___) => SubIcon('image', color: p.muted)),
                                              )
                                            : SubIcon('file', color: p.muted),
                                    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text(sub),
                                    onTap: () => isDir
                                        ? _open(e.path)
                                        : canPreview(e.path)
                                            ? openPreview(context, e.path)
                                            : _fileActions(e as File),
                                    onLongPress: isDir ? null : () => _fileActions(e as File),
                                    trailing: isDir
                                        ? null
                                        : IconButton(
                                            tooltip: 'More',
                                            icon: SubIcon('more', size: IconSize.md, color: p.muted),
                                            onPressed: () => _fileActions(e as File),
                                          ),
                                  ),
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
