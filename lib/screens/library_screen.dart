import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/tools.dart';
import '../theme.dart';
import '../ui/embed.dart';
import '../widgets/logo.dart';
import '../widgets/output_cards.dart';
import '../widgets/sub_icon.dart';
import 'preview_screen.dart';
import '../ui/tokens.dart';

/// Everything Telesia created: images now, more media types later.
class LibraryScreen extends StatefulWidget {
  final bool embedded;
  const LibraryScreen({super.key, this.embedded = false});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<File> _files = [];
  bool _loading = true;

  static final _img = RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = await AgentTools.workspaceDir();
    final dir = Directory('$ws/media');
    var files = <File>[];
    if (await dir.exists()) {
      files = (await dir.list().toList()).whereType<File>().where((f) => !f.path.endsWith('.svg')).toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    }
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  Future<void> _actions(File f) async {
    await showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('Save to phone'),
            subtitle: const Text('Gallery, Music or Downloads'),
            onTap: () {
              Navigator.pop(ctx);
              saveToPhone(context, f.path);
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
            title: Text('Move to Trash', style: TextStyle(color: Palette.of(context).accent)),
            onTap: () async {
              Navigator.pop(ctx);
              await AgentTools.execute('delete_file', {'path': f.path});
              _load();
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return maybeScaffold(
      embedded: widget.embedded,
      appBar: AppBar(title: Text('Library', style: Brand.serif(size: 28, color: p.text))),
      body: _loading
          ? const Center(child: RedDot(size: 10, animate: true))
          : _files.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Nothing here yet', style: Brand.serif(size: 30, color: p.text)),
                      const SizedBox(height: 8),
                      Text('Images and files Telesia creates for you will appear here.',
                          textAlign: TextAlign.center, style: TextStyle(color: p.muted, height: 1.4)),
                    ]),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: _files.length,
                    itemBuilder: (_, i) {
                      final f = _files[i];
                      final isImg = _img.hasMatch(f.path);
                      return GestureDetector(
                        onTap: isImg
                            ? () => openImageViewer(context, f.path)
                            : (RegExp(r'\.(wav|mp3|m4a|ogg|webm|mp4|mov)$', caseSensitive: false).hasMatch(f.path)
                                ? () => openPreview(context, f.path)
                                : () => _actions(f)),
                        onLongPress: () => _actions(f),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: isImg
                              ? Image.file(f, fit: BoxFit.cover, cacheWidth: 400, frameBuilder: subImageFade)
                              : Container(
                                  color: p.bubble,
                                  padding: const EdgeInsets.all(8),
                                  alignment: Alignment.center,
                                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                                    if (RegExp(r'\.(wav|mp3|m4a|ogg|webm|mp4|mov)$', caseSensitive: false).hasMatch(f.path))
                                      Container(
                                        width: 34,
                                        height: 34,
                                        margin: const EdgeInsets.only(bottom: 6),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(color: p.muted, shape: BoxShape.circle),
                                        child: const SubIcon('play', color: Colors.white, size: 15),
                                      ),
                                    Text(f.path.split('/').last.replaceAll(RegExp(r'_\d{10,}'), ''),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: p.text, fontSize: AppText.micro)),
                                  ]),
                                ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
