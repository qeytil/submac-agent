import 'package:flutter/material.dart';

import '../services/updater.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import 'motion.dart' show reduceMotion;
import '../ui/tokens.dart';
import 'logo.dart';

/// Words of the update sheet in the app's own language (Settings > Language, else the phone): English, Somali or
/// Arabic. Not the reply language: that is what the assistant writes in, not the app's buttons.
class UpdateText {
  /// 'en' | 'so' | 'ar'.
  final String lang;
  const UpdateText([this.lang = 'en']);

  static UpdateText of(BuildContext context) => UpdateText(AppLang.I.code);

  bool get so => lang == 'so';
  bool get ar => lang == 'ar';
  String _t(String en, String so, String ar) => this.so ? so : (this.ar ? ar : en);

  String get available => _t('A new version of SubMac', 'Nooc cusub oo SubMac ah', 'إصدار جديد من SubMac');
  String get required => _t('Please update SubMac', 'Fadlan cusboonaysii SubMac', 'يرجى تحديث SubMac');
  String get requiredBody => _t('This update is required. Download and install it to keep using SubMac.',
      'Cusboonaysiintan waa khasab. Soo deji oo rakib si aad u sii isticmaasho SubMac.', 'هذا التحديث إلزامي. نزّله وثبّته لمتابعة استخدام SubMac.');
  String requiredFrom(String when) => _t('Required from $when.', 'Waa khasab laga bilaabo $when.', 'إلزامي اعتبارًا من $when.');
  String version(String v) => _t('Version $v', 'Nooca $v', 'الإصدار $v');
  String get whatsNew => _t("What's new", 'Waxa cusub', 'ما الجديد');
  String whatsNewIn(String v) => _t("What's new in $v", 'Waxa cusub ee $v', 'ما الجديد في $v');
  String get gotIt => _t('Got it', 'Waan fahmay', 'حسنًا');
  String get updateNow => _t('Update now', 'Hadda cusboonaysii', 'حدّث الآن');
  String get download => _t('Download', 'Soo deji', 'تنزيل');
  String get later => _t('Later', 'Mar dambe', 'لاحقًا');
  String get cancel => _t('Cancel download', 'Jooji soo dejinta', 'إلغاء التنزيل');
  String get keepGoing => _t('Keep going in the background', 'Ku sii wad gadaal', 'تابع في الخلفية');
  String get install => _t('Install', 'Rakib', 'تثبيت');
  String get retry => _t('Try again', 'Isku day mar kale', 'حاول مرة أخرى');
  String get resume => _t('Continue download', 'Sii wad soo dejinta', 'متابعة التنزيل');
  String get tryNow => _t('Try now', 'Hadda isku day', 'حاول الآن');
  String get downloadAgain => _t('Download again', 'Mar kale soo deji', 'نزّله مرة أخرى');
  String get downloading => _t('Downloading…', 'Waa la soo dejinayaa…', 'جارٍ التنزيل…');
  String progressLine(int pct, String done, String total) => _t('$pct% · $done of $total', '$pct% · $done ka mid ah $total', '$pct٪ · $done من $total');
  String get leaveOk => _t('You can leave SubMac; the download keeps going. When it finishes, Install is waiting for you.',
      'Waad ka bixi kartaa SubMac; soo dejintu way socotaa. Markay dhammaato, Rakib ayaa ku sugaya.', 'يمكنك مغادرة SubMac؛ يستمر التنزيل. عند انتهائه سيكون زر التثبيت بانتظارك.');
  String get verifying => _t('Checking the update…', 'Cusboonaysiinta waa la hubinayaa…', 'جارٍ التحقق من التحديث…');
  String get verifyingBody => _t('Making sure the file is complete and really from SubMac.', 'Waxaa la hubinayaa in faylku dhammaystiran yahay oo uu SubMac ka yimid.',
      'نتأكد من أن الملف كامل وأنه من SubMac فعلًا.');
  String get ready => _t('Downloaded and checked. Ready to install.', 'Waa la soo dejiyay oo la hubiyay. Diyaar u ah rakibid.', 'تم التنزيل والتحقق. جاهز للتثبيت.');
  String get opening => _t("Opening Android's installer…", 'Waxaa la furayaa rakibaha Android…', 'جارٍ فتح مثبّت أندرويد…');
  String get waitingNetwork => _t('Waiting for a connection. The download continues where it stopped.',
      'Waxaa la sugayaa internet. Soo dejintu waxay ka sii socon doontaa meeshii ay ku istaagtay.', 'بانتظار الاتصال. سيُستأنف التنزيل من حيث توقف.');
  String lowStorage(String mb) => _t('Not enough space on this phone. Free up about $mb and try again.',
      'Boos kuguma filna taleefanka. Ka bannee qiyaastii $mb kadibna isku day mar kale.', 'لا توجد مساحة كافية على الهاتف. أفرغ نحو $mb ثم حاول مرة أخرى.');
  String get lowStorageShort => _t('Not enough space on this phone. Free up some space and try again.',
      'Boos kuguma filna taleefanka. Wax ka bannee kadibna isku day mar kale.', 'لا توجد مساحة كافية على الهاتف. أفرغ بعض المساحة ثم حاول مرة أخرى.');
  String get serverError => _t("The update server isn't answering right now. Try again in a moment.",
      'Server-ka cusboonaysiinta hadda ma jawaabayo. Wax yar kadib isku day.', 'خادم التحديثات لا يستجيب الآن. حاول مرة أخرى بعد قليل.');
  String get failed => _t('The download stopped. You can download it again.', 'Soo dejintu way istaagtay. Mar kale ayaad soo dejin kartaa.', 'توقف التنزيل. يمكنك تنزيله مرة أخرى.');
  String get badFile => _t("The update file didn't check out, so it was removed. Please download it again.",
      'Faylka cusboonaysiinta lama hubin karin, waa la tirtiray. Fadlan mar kale soo deji.', 'لم يجتز ملف التحديث التحقق، لذا حُذف. يرجى تنزيله مرة أخرى.');
  String get badSignature => _t("This update isn't signed by SubMac, so it was blocked to keep your phone safe. Please contact SubMac support.",
      'Cusboonaysiintan SubMac ma saxeexin, sidaas darteed waa la xannibay si taleefankaagu u nabad galo. Fadlan la xiriir taageerada SubMac.',
      'هذا التحديث غير موقّع من SubMac، لذا حُظر حفاظًا على أمان هاتفك. يرجى التواصل مع دعم SubMac.');
  String get allowTitle => _t('Allow SubMac to install updates', 'U oggolow SubMac inuu rakibo cusboonaysiinta', 'اسمح لـ SubMac بتثبيت التحديثات');
  String get allowBody => _t(
      'Android asks once. Tap Open settings, turn on "Allow from this source", then come back. Installing continues by itself.',
      'Android hal mar ayuu weydiinayaa. Taabo Fur dejinta, shid "Allow from this source", kadibna soo noqo. Rakibiddu iskeed ayay u sii socon doontaa.',
      'يطلب أندرويد ذلك مرة واحدة. اضغط فتح الإعدادات، وفعّل "السماح من هذا المصدر"، ثم عُد. سيكمل التثبيت تلقائيًا.');
  String get openSettings => _t('Open settings', 'Fur dejinta', 'فتح الإعدادات');
  String get appUpdate => _t('App update', 'Cusboonaysiinta app-ka', 'تحديث التطبيق');
  String get current => _t('This version', 'Nooca hadda', 'هذا الإصدار');
  String get checkNow => _t('Check now', 'Hubi hadda', 'تحقق الآن');
  String get checking => _t('Checking…', 'Waa la hubinayaa…', 'جارٍ التحقق…');
  String get upToDate => _t("You're up to date.", 'Waxaad haysataa noocii ugu dambeeyay.', 'لديك أحدث إصدار.');
  String get checkFailed => _t("Couldn't check right now. Check your connection.", 'Hadda lama hubin karo. Hubi internetka.', 'تعذّر التحقق الآن. تحقق من اتصالك.');
  String get notHere => _t('In-app updates work on Android.', 'Cusboonaysiinta gudaha app-ka waxay ka shaqaysaa Android oo keliya.', 'التحديثات داخل التطبيق تعمل على أندرويد.');
  String newer(String v) => _t('Version $v is ready', 'Nooca $v waa diyaar', 'الإصدار $v جاهز');
  String percent(int p) => _t('Downloading $p%', 'Soo dejin $p%', 'جارٍ التنزيل $p٪');
  String get checkUpdates => _t('Check for updates', 'Hubi cusboonaysiin', 'التحقق من التحديثات');
  String updateAvailable(String v) => _t('Update available · $v', 'Cusboonaysiin ayaa diyaar ah · $v', 'تحديث متاح · $v');
  String get readyShort => _t('Ready to install', 'Diyaar u ah rakibid', 'جاهز للتثبيت');
  String get installingShort => _t('Installing…', 'Waa la rakibayaa…', 'جارٍ التثبيت…');
  String get verifyingShort => _t('Checking…', 'Waa la hubinayaa…', 'جارٍ التحقق…');
  String get waitingShort => _t('Waiting for a connection', 'Internet ayaa la sugayaa', 'بانتظار الاتصال');
  String get upToDateShort => _t('Up to date', 'Waa noocii ugu dambeeyay', 'محدّث');
  String get notChecked => _t('See if a newer version is out', 'Hubi haddii nooc cusub jiro', 'تحقق من وجود إصدار أحدث');
  String get checkFailedShort => _t("Couldn't check right now", 'Hadda lama hubin karo', 'تعذّر التحقق الآن');
  String get size => _t('Size', 'Cabbirka', 'الحجم');
  String get details => _t('Details', 'Faahfaahin', 'التفاصيل');

  /// Notification words for the native downloader (passed in from Dart; Android has no copy of these strings).
  Map<String, String> nativeWords(String versionName) => {
        'title': 'SubMac $versionName',
        'downloading': _t('Downloading the SubMac update', 'Cusboonaysiinta SubMac waa la soo dejinayaa', 'جارٍ تنزيل تحديث SubMac'),
        'ready': _t('Your SubMac update is ready. Tap to install.', 'Cusboonaysiinta SubMac waa diyaar. Taabo si aad u rakibto.', 'تحديث SubMac جاهز. اضغط للتثبيت.'),
        'readyBody': '',
      };

  /// The one line that says why a download waits or stopped.
  String reasonLine(StopReason r, {int neededBytes = 0}) => switch (r) {
        StopReason.waitingNetwork => waitingNetwork,
        StopReason.lowStorage => neededBytes > 0 ? lowStorage(mb(neededBytes)) : lowStorageShort,
        StopReason.server => serverError,
        _ => failed,
      };
}

String mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';

String _when(DateTime utc) {
  final d = utc.toLocal();
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]} ${d.year}, ${two(d.hour)}:${two(d.minute)}';
}

/// Sits above every screen (MaterialApp.builder). Optional update: a sheet from the bottom over a dimmed app, with
/// Later. Required update: a full screen without Later. After an update: "What's new in X" once.
class UpdateLayer extends StatelessWidget {
  final Widget child;
  const UpdateLayer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Updater.I,
      builder: (context, _) {
        final u = Updater.I;
        final t = UpdateText.of(context);
        u.words = t.nativeWords;
        final p = Palette.of(context);
        final r = u.release;
        if (u.showWindow && r != null) {
          final data = UpdateSheetData(release: r, state: u.state, forced: u.forced, neededBytes: u.neededBytes);
          final view = UpdateSheetView(
            t: t,
            data: data,
            onUpdate: u.download,
            onLater: u.forced ? null : u.later,
            onCancel: u.cancel,
            onRetry: u.retry,
            onInstall: u.install,
            onOpenSettings: u.openInstallSettings,
          );
          if (u.forced) {
            return Stack(children: [
              child,
              Positioned.fill(
                child: Material(
                  color: p.bg,
                  child: SafeArea(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsetsDirectional.fromSTEB(Space.x6, Space.x6, Space.x6, Space.x6),
                        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: view),
                      ),
                    ),
                  ),
                ),
              ),
            ]);
          }
          return Stack(children: [child, _Sheet(child: view)]);
        }
        final w = u.whatsNew;
        if (w != null) {
          return Stack(children: [child, _Sheet(child: WhatsNewView(t: t, release: w, onDone: u.whatsNewSeen))]);
        }
        return child;
      },
    );
  }
}

/// A bottom sheet over a dimmed app. Slides up on the SubMac settle curve; appears in place with reduced motion.
class _Sheet extends StatelessWidget {
  final Widget child;
  const _Sheet({required this.child});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final still = reduceMotion(context);
    final sheet = SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: MediaQuery.sizeOf(context).height * 0.88),
          child: Material(
            color: p.sheet,
            elevation: 8,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x3, Space.x5, Space.x4),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: Space.x4),
                    decoration: BoxDecoration(color: p.border, borderRadius: Radii.smAll),
                  ),
                ),
                child,
              ]),
            ),
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: Stack(children: [
        const Positioned.fill(child: ModalBarrier(dismissible: false, color: Color(0x99000000))),
        Positioned.fill(
          child: still
              ? sheet
              : TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1, end: 0),
                  duration: SubMotion.sheetIn,
                  curve: SubMotion.settle,
                  builder: (context, v, c) => FractionalTranslation(translation: Offset(0, v * 0.25), child: Opacity(opacity: 1 - v, child: c)),
                  child: sheet,
                ),
        ),
      ]),
    );
  }
}

/// Everything [UpdateSheetView] shows, so it can be drawn (and tested) without the live updater.
class UpdateSheetData {
  final Release release;
  final UpdateState state;
  final bool forced;
  final int neededBytes;
  const UpdateSheetData({required this.release, this.state = const UpdateState(), this.forced = false, this.neededBytes = 0});
}

/// The update sheet: logo, version and size, what's new, then what fits the moment: Update now / Later, a real
/// progress bar with Cancel, checking, Install, the "install unknown apps" guidance, or why it stopped with a retry.
class UpdateSheetView extends StatelessWidget {
  final UpdateText t;
  final UpdateSheetData data;
  final VoidCallback? onUpdate, onLater, onCancel, onRetry, onInstall, onOpenSettings;
  const UpdateSheetView({
    super.key,
    required this.t,
    required this.data,
    this.onUpdate,
    this.onLater,
    this.onCancel,
    this.onRetry,
    this.onInstall,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = data.release;
    final s = data.state;
    final forced = data.forced;
    final canLater = !forced && onLater != null;
    final meta = TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4);
    final body = TextStyle(color: p.text, fontSize: AppText.body, height: 1.45);

    final children = <Widget>[
      Row(children: [
        const AppLogo(size: 40),
        const SizedBox(width: Space.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(forced ? t.required : t.available,
                key: const ValueKey('upd_title'), style: Brand.serif(size: forced ? AppText.displayLarge : AppText.display, color: p.text, height: 1.1)),
            const SizedBox(height: Space.x1),
            Text('${t.version(r.versionName)} · ${mb(r.sizeBytes)}', key: const ValueKey('upd_meta'), style: meta),
          ]),
        ),
      ]),
    ];
    if (forced) {
      children.add(const SizedBox(height: Space.x3));
      children.add(Text(t.requiredBody, style: body));
    } else if (r.requiredAt != null) {
      children.add(const SizedBox(height: Space.x2));
      children.add(Text(t.requiredFrom(_when(r.requiredAt!)), style: meta));
    }
    if (r.notes.trim().isNotEmpty) {
      children.add(const SizedBox(height: Space.x4));
      children.add(Text(t.whatsNew, style: AppText.sectionStyle.copyWith(color: p.muted)));
      children.add(const SizedBox(height: Space.x2));
      children.add(Container(
        constraints: BoxConstraints(maxHeight: forced ? 280 : 180),
        padding: const EdgeInsets.all(Space.x3),
        decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.fieldAll),
        child: SingleChildScrollView(child: Text(r.notes.trim(), key: const ValueKey('upd_notes'), style: body)),
      ));
    }
    children.add(const SizedBox(height: Space.x4));

    // What is happening right now.
    switch (s.phase) {
      case UpdatePhase.downloading:
        final pct = s.percent;
        children.add(_Bar(value: s.progress));
        children.add(const SizedBox(height: Space.x2));
        children.add(Text(
          pct == null ? t.downloading : t.progressLine(pct, mb(s.bytes), mb(s.total)),
          key: const ValueKey('upd_progress'),
          style: TextStyle(color: p.text, fontSize: AppText.meta, fontFeatures: const [FontFeature.tabularFigures()]),
        ));
        children.add(const SizedBox(height: Space.x1));
        children.add(Text(s.reason == StopReason.waitingNetwork ? t.waitingNetwork : t.leaveOk, key: const ValueKey('upd_hint'), style: meta));
      case UpdatePhase.verifying:
        children.add(Row(children: [
          _Busy(still: reduceMotion(context)),
          const SizedBox(width: Space.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.verifying, key: const ValueKey('upd_verifying'), style: body.copyWith(fontWeight: FontWeight.w600)),
              Text(t.verifyingBody, style: meta),
            ]),
          ),
        ]));
      case UpdatePhase.downloaded:
        if (s.issue == UpdateIssue.needsPermission) {
          children.add(_AllowCard(t: t));
        } else {
          children.add(Text(t.ready, style: meta));
        }
      case UpdatePhase.installing:
        children.add(Text(t.opening, style: meta));
      case UpdatePhase.cancelled:
      case UpdatePhase.idle:
        final line = switch (s.issue) {
          UpdateIssue.failed => t.reasonLine(s.reason, neededBytes: data.neededBytes),
          UpdateIssue.badFile => t.badFile,
          UpdateIssue.badSignature => t.badSignature,
          _ => null,
        };
        if (line != null) children.add(_IssueLine(line, danger: s.issue == UpdateIssue.badSignature));
    }

    // Buttons: one primary, Later / Cancel quiet.
    Widget? primary;
    final quiet = <Widget>[];
    switch (s.phase) {
      case UpdatePhase.idle:
      case UpdatePhase.cancelled:
        if (s.issue == UpdateIssue.badSignature) {
          break;
        } else if (s.issue == UpdateIssue.failed) {
          primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onRetry, child: Text(s.bytes > 0 ? t.resume : t.retry));
        } else if (s.issue == UpdateIssue.badFile) {
          primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onUpdate, child: Text(t.downloadAgain));
        } else {
          primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onUpdate, child: Text(s.bytes > 0 ? t.resume : t.updateNow));
        }
      case UpdatePhase.downloading:
        if (s.reason == StopReason.waitingNetwork) quiet.add(TextButton(key: const ValueKey('upd_retry'), onPressed: onRetry, child: Text(t.tryNow)));
        quiet.add(TextButton(key: const ValueKey('upd_cancel'), onPressed: onCancel, child: Text(t.cancel)));
        if (canLater) primary = OutlinedButton(key: const ValueKey('upd_hide'), onPressed: onLater, child: Text(t.keepGoing));
      case UpdatePhase.verifying:
        break;
      case UpdatePhase.downloaded:
        primary = s.issue == UpdateIssue.needsPermission
            ? FilledButton(key: const ValueKey('upd_primary'), onPressed: onOpenSettings, child: Text(t.openSettings))
            : FilledButton(key: const ValueKey('upd_primary'), onPressed: onInstall, child: Text(t.install));
      case UpdatePhase.installing:
        primary = const FilledButton(
            key: ValueKey('upd_primary'), onPressed: null, child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final showLater = canLater && s.phase != UpdatePhase.downloading && s.phase != UpdatePhase.installing;
    if (showLater) quiet.insert(0, TextButton(key: const ValueKey('upd_later'), onPressed: onLater, child: Text(t.later)));
    if (primary != null || quiet.isNotEmpty) {
      children.add(const SizedBox(height: Space.x4));
      children.add(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (primary != null) primary,
        if (quiet.isNotEmpty) Wrap(alignment: WrapAlignment.center, spacing: Space.x2, children: quiet),
      ]));
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// A real progress bar. Eases between readings; jumps with reduced motion.
class _Bar extends StatelessWidget {
  final double? value;
  const _Bar({this.value});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget bar(double? v) => ClipRRect(
          borderRadius: Radii.smAll,
          child: LinearProgressIndicator(key: const ValueKey('upd_bar'), value: v, minHeight: 6, backgroundColor: p.bubble, color: p.text),
        );
    final v = value;
    if (v == null || reduceMotion(context)) return bar(v);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: v),
      duration: SubMotion.base,
      curve: SubMotion.ink,
      builder: (context, x, _) => bar(x),
    );
  }
}

class _Busy extends StatelessWidget {
  final bool still;
  const _Busy({required this.still});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Reduced motion: a still mark instead of a spinner.
    if (still) return Icon(Icons.verified_outlined, size: IconSize.md, color: p.muted);
    return SizedBox(width: IconSize.md, height: IconSize.md, child: CircularProgressIndicator(strokeWidth: 2, color: p.muted));
  }
}

class _IssueLine extends StatelessWidget {
  final String text;
  final bool danger;
  const _IssueLine(this.text, {this.danger = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      key: const ValueKey('upd_issue'),
      padding: const EdgeInsets.all(Space.x3),
      decoration: BoxDecoration(color: danger ? p.accentWash : p.bubble, borderRadius: Radii.fieldAll),
      child: Text(text, softWrap: true, style: TextStyle(color: danger ? p.accent : p.text, fontSize: AppText.meta, height: 1.4)),
    );
  }
}

/// Android's "Install unknown apps" switch: what to do and a promise that installing continues when the user comes
/// back. The sheet's primary button (Open settings) deep-links to that page.
class _AllowCard extends StatelessWidget {
  final UpdateText t;
  const _AllowCard({required this.t});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      key: const ValueKey('upd_allow'),
      padding: const EdgeInsets.all(Space.x3),
      decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.fieldAll),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.allowTitle, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
        const SizedBox(height: Space.x1),
        Text(t.allowBody, softWrap: true, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.4)),
      ]),
    );
  }
}

/// "What's new in X", once, on the first start after updating.
class WhatsNewView extends StatelessWidget {
  final UpdateText t;
  final Release release;
  final VoidCallback? onDone;
  const WhatsNewView({super.key, required this.t, required this.release, this.onDone});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const AppLogo(size: 40),
        const SizedBox(width: Space.x3),
        Expanded(
          child: Text(t.whatsNewIn(release.versionName),
              key: const ValueKey('whats_new_title'), style: Brand.serif(size: AppText.display, color: p.text, height: 1.1)),
        ),
      ]),
      const SizedBox(height: Space.x4),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: Text(release.notes.trim(),
              key: const ValueKey('whats_new_notes'), style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.5)),
        ),
      ),
      const SizedBox(height: Space.x5),
      FilledButton(key: const ValueKey('whats_new_done'), onPressed: onDone, child: Text(t.gotIt)),
    ]);
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
          sub = s.phase == UpdatePhase.downloading && s.percent != null ? t.percent(s.percent!) : t.newer(u.release!.versionName);
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
        u.words = t.nativeWords;
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
            neededBytes: u.neededBytes,
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
  final int neededBytes;
  const AppUpdateViewData({
    required this.currentName,
    this.supported = true,
    this.checking = false,
    this.checked = false,
    this.checkFailed = false,
    this.release,
    this.state = const UpdateState(),
    this.neededBytes = 0,
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
        UpdatePhase.downloading => s.reason == StopReason.waitingNetwork ? t.waitingShort : (pr == null ? t.downloading : t.percent(s.percent!)),
        UpdatePhase.verifying => t.verifyingShort,
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
              Text(status,
                  key: const ValueKey('upd_status'),
                  softWrap: true,
                  style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600, height: 1.3)),
            ]),
          ),
        ]),
      ),
      if (s.phase == UpdatePhase.downloading && r != null)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Bar(value: pr),
            const SizedBox(height: 8),
            Text(
                pr == null
                    ? t.leaveOk
                    : '${t.progressLine(s.percent!, mb(s.bytes), mb(s.total))} · ${s.reason == StopReason.waitingNetwork ? t.waitingNetwork : t.leaveOk}',
                softWrap: true,
                style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.35)),
          ]),
        ),
    ]);

    // Plain help lines (never raw errors).
    final notes = <Widget>[];
    if (r != null) {
      final line = switch (s.issue) {
        UpdateIssue.failed => t.reasonLine(s.reason, neededBytes: d.neededBytes),
        UpdateIssue.badFile => t.badFile,
        UpdateIssue.badSignature => t.badSignature,
        _ => null,
      };
      if (line != null && (s.phase == UpdatePhase.cancelled || s.phase == UpdatePhase.idle)) {
        notes.add(_IssueLine(line, danger: s.issue == UpdateIssue.badSignature));
      }
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
          child: d.checking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(t.checkUpdates),
        );
      } else if (needsAllow) {
        primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onOpenSettings, child: Text(t.openSettings));
      } else {
        switch (s.phase) {
          case UpdatePhase.idle:
          case UpdatePhase.cancelled:
            if (s.issue != UpdateIssue.badSignature) {
              final label = s.issue == UpdateIssue.failed
                  ? (s.bytes > 0 ? t.resume : t.retry)
                  : (s.bytes > 0 ? t.resume : '${t.download} · ${mb(r.sizeBytes)}');
              primary = FilledButton(key: const ValueKey('upd_primary'), onPressed: onDownload, child: Text(label));
            }
          case UpdatePhase.downloading:
            quiet = TextButton(key: const ValueKey('upd_cancel'), onPressed: onCancel, child: Text(t.cancel));
          case UpdatePhase.verifying:
            break;
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
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: notes),
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
            _UpdRow(t.version(r.versionName), mb(r.sizeBytes)),
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
