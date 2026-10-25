import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/updater.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import 'logo.dart';

/// Words of the update window, in English and Somali (Somali when the reply language is Somali).
class UpdateText {
  final bool so;
  const UpdateText(this.so);

  static UpdateText of(BuildContext context) {
    String lang = 'auto';
    try {
      lang = context.select<AppState, String>((s) => s.replyLanguage);
    } catch (_) {}
    return UpdateText(lang == 'Somali');
  }

  String get available => so ? 'Cusboonaysiin cusub' : 'A new version is ready';
  String get required => so ? 'Fadlan cusboonaysii SubMac' : 'Please update SubMac';
  String get requiredBody => so
      ? 'Noocan cusub waa khasab. Soo deji oo rakib si aad u sii isticmaasho SubMac.'
      : 'This update is required. Download and install it to keep using SubMac.';
  String requiredFrom(String when) => so ? 'Waa khasab laga bilaabo $when.' : 'Required from $when.';
  String version(String v) => so ? 'Nooca $v' : 'Version $v';
  String get whatsNew => so ? 'Waxa cusub' : "What's new";
  String get download => so ? 'Soo deji' : 'Download';
  String get later => so ? 'Mar dambe' : 'Later';
  String get cancel => so ? 'Jooji soo dejinta' : 'Cancel download';
  String get keepGoing => so ? 'Ku sii wad gadaal' : 'Keep going in the background';
  String get install => so ? 'Rakib' : 'Install';
  String get downloading => so ? 'Waa la soo dejinayaa…' : 'Downloading…';
  String get leaveOk => so
      ? 'Waad ka bixi kartaa SubMac; soo dejintu way socotaa. Markay dhammaato, Rakib ayaa kuu diyaar ah.'
      : 'You can leave SubMac; the download keeps going. When it finishes, Install is waiting for you.';
  String get ready => so ? 'Diyaar u ah rakibid.' : 'Downloaded and checked. Ready to install.';
  String get opening => so ? 'Waxaa la furayaa rakibaha Android…' : "Opening Android's installer…";
  String get failed => so ? 'Soo dejintu way istaagtay. Mar kale isku day.' : 'The download stopped. You can download it again.';
  String get badFile => so
      ? 'Faylka cusboonaysiinta lama hubin karin, waa la tirtiray. Mar kale soo deji.'
      : "The update file didn't check out, so it was removed. Please download it again.";
  String get allowTitle => so ? 'U oggolow SubMac inuu rakibo' : 'Allow SubMac to install updates';
  String get allowBody => so
      ? 'Android wuxuu u baahan yahay oggolaanshahaaga. Fur dejinta, shid "Allow from this source", kadibna soo noqo. Rakibiddu way sii socon doontaa.'
      : 'Android needs your OK once. Open settings, turn on "Allow from this source", then come back. Installing continues by itself.';
  String get openSettings => so ? 'Fur dejinta' : 'Open settings';
  String get appUpdate => so ? 'Cusboonaysiinta app-ka' : 'App update';
  String get current => so ? 'Nooca hadda' : 'This version';
  String get checkNow => so ? 'Hubi hadda' : 'Check now';
  String get checking => so ? 'Waa la hubinayaa…' : 'Checking…';
  String get upToDate => so ? 'Waxaad haysataa noocii ugu dambeeyay.' : "You're up to date.";
  String get checkFailed => so ? 'Hadda lama hubin karo. Hubi internetka.' : "Couldn't check right now. Check your connection.";
  String get notHere => so ? 'Cusboonaysiinta gudaha app-ka waxay ka shaqaysaa Android oo keliya.' : 'In-app updates work on Android.';
  String newer(String v) => so ? 'Nooca $v waa diyaar' : 'Version $v is ready';
  String percent(int p) => so ? 'Soo dejin $p%' : 'Downloading $p%';
  String get checkUpdates => so ? 'Hubi cusboonaysiin' : 'Check for updates';
  String updateAvailable(String v) => so ? 'Cusboonaysiin ayaa diyaar ah · $v' : 'Update available · $v';
  String get readyShort => so ? 'Diyaar u ah rakibid' : 'Ready to install';
  String get installingShort => so ? 'Waa la rakibayaa…' : 'Installing…';
  String get upToDateShort => so ? 'Waa noocii ugu dambeeyay' : 'Up to date';
  String get notChecked => so ? 'Hubi haddii nooc cusub jiro' : 'See if a newer version is out';
  String get checkFailedShort => so ? 'Hadda lama hubin karo' : "Couldn't check right now";
  String get size => so ? 'Cabbirka' : 'Size';
  String get details => so ? 'Faahfaahin' : 'Details';
}

String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';

String _when(DateTime utc) {
  final d = utc.toLocal();
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]} ${d.year}, ${two(d.hour)}:${two(d.minute)}';
}

/// Sits above every screen (MaterialApp.builder). Optional update: a card over a dimmed app, with Later.
/// Required update: a full screen with only Download / Install.
class UpdateLayer extends StatelessWidget {
  final Widget child;
  const UpdateLayer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Updater.I,
      builder: (context, _) {
        final u = Updater.I;
        if (!u.showWindow) return child;
        final p = Palette.of(context);
        if (u.forced) {
          return Stack(children: [
            child,
            Positioned.fill(
              child: Material(
                color: p.bg,
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsetsDirectional.fromSTEB(28, 24, 28, 24),
                      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: const UpdatePanel(full: true)),
                    ),
                  ),
                ),
              ),
            ),
          ]);
        }
        return Stack(children: [
          child,
          const Positioned.fill(child: ModalBarrier(dismissible: false, color: Color(0x99000000))),
          Positioned.fill(
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Material(
                      color: p.sheet,
                      elevation: 8,
                      borderRadius: BorderRadius.circular(22),
                      clipBehavior: Clip.antiAlias,
                      child: const SingleChildScrollView(padding: EdgeInsetsDirectional.fromSTEB(22, 22, 22, 16), child: UpdatePanel()),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

/// The update content: what's new, size, progress and the one or two buttons that fit the moment.
/// Used by the window, the required-update screen and Settings > App update ([embedded]).
class UpdatePanel extends StatelessWidget {
  final bool full;
  final bool embedded;
  const UpdatePanel({super.key, this.full = false, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Updater.I,
      builder: (context, _) {
        final u = Updater.I;
        final r = u.release;
        final t = UpdateText.of(context);
        final p = Palette.of(context);
        if (r == null) return const SizedBox.shrink();
        final s = u.state;
        final forced = u.forced;
        final req = r.requiredAt;
        final children = <Widget>[];
        if (!embedded) {
          children.add(Row(children: [
            const AppLogo(size: 28),
            const SizedBox(width: 12),
            Expanded(child: Text(forced ? t.required : t.available, style: Brand.serif(size: full ? 34 : 28, color: p.text))),
          ]));
          children.add(const SizedBox(height: 10));
        }
        children.add(Text('${t.version(r.versionName)} · ${_mb(r.sizeBytes)}', style: TextStyle(color: p.muted, fontSize: AppText.meta)));
        if (forced) {
          children.add(const SizedBox(height: 8));
          children.add(Text(t.requiredBody, style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.35)));
        } else if (req != null) {
          children.add(const SizedBox(height: 6));
          children.add(Text(t.requiredFrom(_when(req)), style: TextStyle(color: p.muted, fontSize: AppText.meta)));
        }
        if (r.notes.trim().isNotEmpty) {
          children.add(const SizedBox(height: 14));
          children.add(Text(t.whatsNew, style: TextStyle(color: p.text, fontWeight: FontWeight.w600, fontSize: AppText.meta)));
          children.add(const SizedBox(height: 4));
          children.add(ConstrainedBox(
            constraints: BoxConstraints(maxHeight: full ? 280 : 200),
            child: SingleChildScrollView(child: Text(r.notes.trim(), style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.4))),
          ));
        }
        children.add(const SizedBox(height: 16));
        switch (s.phase) {
          case UpdatePhase.downloading:
            final pr = s.progress;
            children.add(ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: pr, minHeight: 6, backgroundColor: p.bubble, color: p.text),
            ));
            children.add(const SizedBox(height: 6));
            children.add(Text(
              pr == null ? t.downloading : '${t.percent((pr * 100).floor())} · ${_mb(s.bytes)} / ${_mb(s.total)}',
              style: TextStyle(color: p.muted, fontSize: AppText.micro),
            ));
            children.add(const SizedBox(height: 4));
            children.add(Text(t.leaveOk, style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.35)));
          case UpdatePhase.downloaded:
            children.add(Text(t.ready, style: TextStyle(color: p.muted, fontSize: AppText.meta)));
          case UpdatePhase.installing:
            children.add(Text(t.opening, style: TextStyle(color: p.muted, fontSize: AppText.meta)));
          case UpdatePhase.cancelled:
          case UpdatePhase.idle:
            break;
        }
        if (s.issue == UpdateIssue.failed || s.issue == UpdateIssue.badFile) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.issue == UpdateIssue.badFile ? t.badFile : t.failed, style: TextStyle(color: p.accent, fontSize: AppText.meta)),
          ));
        }
        if (s.issue == UpdateIssue.needsPermission && s.phase == UpdatePhase.downloaded) {
          children.add(Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.allowTitle, style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(t.allowBody, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.35)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: u.openInstallSettings, child: Text(t.openSettings)),
            ]),
          ));
        }
        children.add(const SizedBox(height: 14));
        final primary = <Widget>[];
        final secondary = <Widget>[];
        switch (s.phase) {
          case UpdatePhase.idle:
          case UpdatePhase.cancelled:
            primary.add(FilledButton(onPressed: u.download, child: Text(t.download)));
            if (!forced && !embedded) secondary.add(TextButton(onPressed: u.later, child: Text(t.later)));
          case UpdatePhase.downloading:
            secondary.add(TextButton(onPressed: u.cancel, child: Text(t.cancel)));
            if (!forced && !embedded) primary.add(OutlinedButton(onPressed: u.later, child: Text(t.keepGoing)));
          case UpdatePhase.downloaded:
            primary.add(FilledButton(onPressed: u.install, child: Text(t.install)));
            if (!forced && !embedded) secondary.add(TextButton(onPressed: u.later, child: Text(t.later)));
          case UpdatePhase.installing:
            primary.add(const FilledButton(onPressed: null, child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))));
        }
        children.add(Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [...secondary, ...primary]));
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      },
    );
  }
}

/// Settings > App update entry.
class AppUpdateTile extends StatelessWidget {
  const AppUpdateTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Updater.I,
      builder: (context, _) {
        final u = Updater.I;
        final t = UpdateText.of(context);
        String sub = t.version(u.currentName);
        if (u.pending) {
          final s = u.state;
          sub = s.phase == UpdatePhase.downloading && s.progress != null
              ? t.percent((s.progress! * 100).floor())
              : t.newer(u.release!.versionName);
        }
        return ListTile(
          leading: const Icon(Icons.system_update_outlined),
          title: Text(t.appUpdate),
          subtitle: Text(sub),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppUpdateScreen())),
        );
      },
    );
  }
}

/// Settings > App update. Styled like the rest of Settings: a header card (logo, this version, one status line),
/// one primary button, a tidy progress bar while downloading and "What's new" in its own card.
class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  bool _checked = false;

  Future<void> _check() async {
    await Updater.I.check(manual: true);
    if (mounted) setState(() => _checked = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = UpdateText.of(context);
    return ListenableBuilder(
      listenable: Updater.I,
      builder: (context, _) {
        final u = Updater.I;
        return AppUpdateView(
          t: t,
          data: AppUpdateViewData(
            currentName: u.currentName,
            supported: u.supported,
            checking: u.checking,
            checked: _checked || u.lastCheck != null,
            checkFailed: u.checkFailed && _checked,
            release: u.pending ? u.release : null,
            state: u.state,
          ),
          onCheck: _check,
          onDownload: u.download,
          onCancel: u.cancel,
          onInstall: u.install,
          onOpenSettings: u.openInstallSettings,
        );
      },
    );
  }
}

/// Everything [AppUpdateView] shows, so it can be drawn (and tested) without the live updater.
class AppUpdateViewData {
  final String currentName;
  final bool supported;
  final bool checking;
  final bool checked;
  final bool checkFailed;
  final Release? release; // a newer release, or null when up to date
  final UpdateState state;
  const AppUpdateViewData({
    required this.currentName,
    this.supported = true,
    this.checking = false,
    this.checked = false,
    this.checkFailed = false,
    this.release,
    this.state = const UpdateState(),
  });
}

class AppUpdateView extends StatelessWidget {
  final UpdateText t;
  final AppUpdateViewData data;
  final VoidCallback? onCheck, onDownload, onCancel, onInstall, onOpenSettings;
  const AppUpdateView({
    super.key,
    required this.t,
    required this.data,
    this.onCheck,
    this.onDownload,
    this.onCancel,
    this.onInstall,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = data;
    final r = d.release;
    final s = d.state;
    final pr = s.phase == UpdatePhase.downloading ? s.progress : null;

    // One status line: what is true right now, in plain words.
    String status;
    if (!d.supported) {
      status = t.notHere;
    } else if (r != null) {
      status = switch (s.phase) {
        UpdatePhase.downloading => pr == null ? t.downloading : t.percent((pr * 100).floor()),
        UpdatePhase.downloaded => t.readyShort,
        UpdatePhase.installing => t.installingShort,
        _ => t.updateAvailable(r.versionName),
      };
    } else if (d.checking) {
      status = t.checking;
    } else if (d.checkFailed) {
      status = t.checkFailedShort;
    } else if (d.checked) {
      status = t.upToDateShort;
    } else {
      status = t.notChecked;
    }

    final header = _UpdCard(children: [
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const AppLogo(size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SubMac', style: Brand.serif(size: 26, color: p.text, height: 1.05)),
              const SizedBox(height: 2),
              Text(t.version(d.currentName), style: TextStyle(color: p.muted, fontSize: AppText.meta)),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text(status,
                      key: const ValueKey('upd_status'),
                      softWrap: true,
                      style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600, height: 1.3)),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      if (pr != null || s.phase == UpdatePhase.downloading)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                key: const ValueKey('upd_bar'),
                value: pr,
                minHeight: 6,
                backgroundColor: p.bubble,
                color: p.accent,
              ),
            ),
            const SizedBox(height: 8),
            Text(pr == null ? t.leaveOk : '${_mb(s.bytes)} / ${_mb(s.total)} · ${t.leaveOk}',
                softWrap: true, style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.35)),
          ]),
        ),
    ]);

    // Plain help lines (never raw errors).
    final notes = <Widget>[];
    if (r != null && (s.issue == UpdateIssue.failed || s.issue == UpdateIssue.badFile)) {
      notes.add(Text(s.issue == UpdateIssue.badFile ? t.badFile : t.failed, softWrap: true, style: TextStyle(color: p.accent, fontSize: AppText.meta, height: 1.35)));
    }
    if (d.checkFailed && r == null) {
      notes.add(Text(t.checkFailed, softWrap: true, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)));
    }
    final needsAllow = r != null && s.issue == UpdateIssue.needsPermission && s.phase == UpdatePhase.downloaded;

    // One primary button for the moment.
    Widget? primary;
    Widget? quiet;
    if (d.supported) {
      if (r == null) {
        primary = FilledButton(
          key: const ValueKey('upd_primary'),
          onPressed: d.checking ? null : onCheck,
          child: d.checking
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.checkUpdates),
        );
      } else if (needsAllow) {
        primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onOpenSettings, child: Text(t.openSettings));
      } else {
        switch (s.phase) {
          case UpdatePhase.idle:
          case UpdatePhase.cancelled:
            primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onDownload, child: Text('${t.download} · ${_mb(r.sizeBytes)}'));
          case UpdatePhase.downloading:
            quiet = TextButton(key: const ValueKey('upd_cancel'), onPressed: onCancel, child: Text(t.cancel));
          case UpdatePhase.downloaded:
            primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onInstall, child: Text(t.install));
          case UpdatePhase.installing:
            primary = const FilledButton(
              key: ValueKey('upd_primary'),
              onPressed: null,
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            );
        }
      }
    }

    final req = r?.requiredAt;
    return Scaffold(
      appBar: AppBar(title: Text(t.appUpdate, style: Brand.serif(size: 28, color: p.text))),
      body: ListView(padding: const EdgeInsets.only(top: 4, bottom: 28), children: [
        Padding(padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 8), child: header),
        if (needsAllow)
          _UpdSection(t.allowTitle, [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(t.allowBody, softWrap: true, style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.4)),
            ),
          ]),
        if (notes.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: notes),
          ),
        if (primary != null || quiet != null)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (primary != null) primary,
              if (quiet != null) quiet,
            ]),
          ),
        if (r != null && r.notes.trim().isNotEmpty)
          _UpdSection(t.whatsNew, [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 16),
              child: Text(r.notes.trim(),
                  key: const ValueKey('upd_notes'), softWrap: true, style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.5)),
            ),
          ]),
        if (r != null)
          _UpdSection(t.details, [
            _UpdRow(t.version(r.versionName), _mb(r.sizeBytes)),
            if (req != null) _UpdRow(t.requiredFrom(_when(req)), ''),
          ]),
      ]),
    );
  }
}

class _UpdCard extends StatelessWidget {
  final List<Widget> children;
  const _UpdCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.sheet,
        borderRadius: Radii.fieldAll,
        border: Border.all(color: p.border, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 18, color: p.border),
            children[i],
          ],
        ]),
      ),
    );
  }
}

/// Same look as the Settings sections: a small caps title over a rounded card.
class _UpdSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _UpdSection(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
          child: Text(title.toUpperCase(),
              style: TextStyle(color: p.muted, fontSize: AppText.caption, fontWeight: FontWeight.w600, letterSpacing: 0.8)),
        ),
        _UpdCard(children: children),
      ]),
    );
  }
}

class _UpdRow extends StatelessWidget {
  final String label;
  final String value;
  const _UpdRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(label, softWrap: true, style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.3))),
        if (value.isNotEmpty) ...[
          const SizedBox(width: 12),
          Text(value, style: TextStyle(color: p.muted, fontSize: AppText.body)),
        ],
      ]),
    );
  }
}
