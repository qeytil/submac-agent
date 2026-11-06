import 'package:flutter/material.dart';

import '../services/media_store.dart';
import '../services/projects.dart';
import '../services/system_bridge.dart';
import '../theme.dart';
import 'output_cards.dart' show mediaMime;
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// "Save" for any file: the phone's Documents or Download folder, or one of the user's projects.
Future<void> showSaveSheet(BuildContext context, String path) async {
  // A file made on another phone is fetched from the account first.
  final found = MediaStore.I.localNow(path) ?? await MediaStore.I.resolve(path, retry: true);
  if (!context.mounted) return;
  if (found == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('This file isn\'t on this phone or in your account any more.')));
    return;
  }
  path = found.path;
  final f = found;
  final name = path.split('/').last;
  final mime = mediaMime(name);
  final media = mime.startsWith('image/') || mime.startsWith('video/') || mime.startsWith('audio/');
  final projects = Projects.I.list;
  final choice = await showModalBottomSheet<String>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 4),
              child: Text('Save $name', maxLines: 2, overflow: TextOverflow.ellipsis, style: Brand.serif(size: 22, color: p.text)),
            ),
            _head(ctx, 'On this phone'),
            if (media)
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(mime.startsWith('image/') ? 'Pictures' : mime.startsWith('video/') ? 'Movies' : 'Music'),
                subtitle: const Text('In the Telesia folder, shows in your gallery'),
                onTap: () => Navigator.pop(ctx, 'media'),
              ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Documents'),
              subtitle: const Text('Documents › Telesia'),
              onTap: () => Navigator.pop(ctx, 'documents'),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Downloads'),
              subtitle: const Text('Download › Telesia'),
              onTap: () => Navigator.pop(ctx, 'downloads'),
            ),
            _head(ctx, 'In a project'),
            for (final pr in projects)
              ListTile(
                leading: const Icon(Icons.work_outline_rounded),
                title: Text(pr.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, 'project:${pr.id}'),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: Text(tr('New project')),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  void say(String t) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(t)));
  }

  if (choice == 'media' || choice == 'documents' || choice == 'downloads') {
    final where = await SystemBridge.I.saveMedia(path, mime: mime, name: name, folder: choice == 'media' ? '' : choice);
    if (where.startsWith('error')) {
      say('It didn\'t save this time. Use Share, then pick Save to device.');
    } else {
      say('Saved to ${where.split('/').take(2).join(' › ')}');
    }
    return;
  }
  String? projectId;
  if (choice == 'new') {
    final name0 = await _askName(context);
    if (name0 == null || name0.trim().isEmpty || !context.mounted) return;
    projectId = (await Projects.I.create(name0.trim())).id;
  } else {
    projectId = choice.substring('project:'.length);
  }
  try {
    await Projects.I.addFile(projectId, name, await f.readAsBytes());
    say('Saved to ${Projects.I.byId(projectId)?.name ?? 'the project'}');
  } catch (_) {
    say('It didn\'t save to the project. Try again.');
  }
}

Widget _head(BuildContext ctx, String t) => Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 2),
      child: Text(t, style: AppText.sectionStyle.copyWith(color: Palette.of(ctx).muted)),
    );

Future<String?> _askName(BuildContext context) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('New project')),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Project name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('Create'))),
      ],
    ),
  );
}
