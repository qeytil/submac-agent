import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'chat/reply_quote.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../app_state.dart';
import '../services/browser_agent.dart';
import '../services/browser_jobs.dart';
import '../services/bots.dart';
import 'browser_card.dart';
import '../models.dart';
import '../screens/live_screen.dart';
import '../services/attach_limits.dart';
import '../services/full_access.dart';
import '../services/doc_tools.dart';
import '../theme.dart';
import 'chat_extras.dart';
import 'logo.dart';
import 'message_view.dart';
import 'model_picker.dart';
import 'sub_icon.dart';
import 'meeting_sheet.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import '../screens/skills_screen.dart';
import 'chat/activity.dart';
import 'chat/activity_groups.dart';
import 'chat/activity_panel.dart';
import 'chat/edge_fade.dart';

class Composer extends StatefulWidget {
  const Composer({super.key, this.perChatDrafts = false, this.onFocus});

  /// Keeps what you typed per chat (the Bots workspace): switching to another bot puts this text away and brings back
  /// what you had typed there. Only the composer on the screen in front swaps drafts.
  final bool perChatDrafts;

  /// The box took the cursor (the keyboard is coming up). The Bots workspace folds its rail away here.
  final VoidCallback? onFocus;

  /// Drafts by chat id ('' for a new chat), kept for the app run.
  static final Map<String, String> drafts = {};

  /// Files and photos picked but not sent yet, by chat id like [drafts] (CB-29: a photo picked in one chat never
  /// goes out in another).
  static final Map<String, List<Attachment>> attachmentDrafts = {};

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final List<Attachment> _attachments = [];
  final _stt = SpeechToText();
  bool _sttReady = false;
  bool _listening = false;

  /// Puts the cursor in the box (shares, the home-screen widget). The box is always there now: one calm
  /// field, so there is no second "open" state to get stuck in.
  void _openBox() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }
  String _beforeDictation = '';

  late final AppState _state = context.read<AppState>();

  /// The chat the text in the box belongs to (per-chat drafts only).
  String _draftFor = '';
  bool _hadFocus = false;

  void _onFocusChange() {
    final has = _focus.hasFocus;
    if (has && !_hadFocus) widget.onFocus?.call();
    _hadFocus = has;
    setState(() {});
  }

  /// Another chat came on screen: keep this one's text and bring back the new one's.
  void _swapDraft() {
    if (!widget.perChatDrafts || !mounted) return;
    // Told in the middle of a frame: swap right after it, never while widgets build.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _swapDraft());
      return;
    }
    final now = _state.currentId ?? '';
    if (now == _draftFor) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _keepDraft();
    _draftFor = now;
    final t = Composer.drafts[now] ?? '';
    _ctrl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    setState(() {
      _attachments
        ..clear()
        ..addAll(Composer.attachmentDrafts[now] ?? const []);
    });
  }

  void _keepDraft() {
    if (_ctrl.text.trim().isEmpty) {
      Composer.drafts.remove(_draftFor);
    } else {
      Composer.drafts[_draftFor] = _ctrl.text;
    }
    if (_attachments.isEmpty) {
      Composer.attachmentDrafts.remove(_draftFor);
    } else {
      Composer.attachmentDrafts[_draftFor] = List.of(_attachments);
    }
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
    _focus.addListener(_onFocusChange);
    if (widget.perChatDrafts) {
      _draftFor = _state.currentId ?? '';
      final t = Composer.drafts[_draftFor] ?? '';
      _ctrl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
      _attachments.addAll(Composer.attachmentDrafts[_draftFor] ?? const []);
      _state.addListener(_swapDraft);
    }
    _state.shareInbox.addListener(_takeShare);
    _state.widgetAction.addListener(_onWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _takeShare();
      _onWidget();
    });
  }

  /// Taps on the home-screen widget.
  void _onWidget() {
    final a = _state.widgetAction.value;
    if (a == null || !mounted) return;
    _state.widgetAction.value = null;
    if (a == 'scan') {
      _camera();
    } else {
      _openBox();
    }
  }

  /// Puts text and files shared from another app into the message box.
  Future<void> _takeShare() async {
    final m = _state.shareInbox.value;
    if (m == null || !mounted) return;
    _state.shareInbox.value = null;
    final text = [(m['subject'] ?? '').toString(), (m['text'] ?? '').toString()].where((e) => e.trim().isNotEmpty).join('\n');
    final files = [for (final f in (m['files'] as List? ?? const [])) f.toString()];
    final added = <Attachment>[];
    // CB-26: sizes first, so a huge shared file is refused before it is read into memory.
    final found = <File>[], sizes = <int>[];
    for (final path in files) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        sizes.add(await f.length());
        found.add(f);
      } catch (_) {}
    }
    final fit = AttachLimits.check(sizes, already: _attachedBytes);
    for (final i in fit.ok) {
      try {
        final name = found[i].path.split('/').last;
        added.add(Attachment(name: name, mime: Attachment.mimeFor(name), bytes: await found[i].readAsBytes()));
      } catch (_) {}
    }
    if (!mounted) return;
    _limitNotice(fit);
    setState(() {
      _attachments.addAll(added);
      if (text.isNotEmpty) {
        final t = _ctrl.text.trim().isEmpty ? text : '${_ctrl.text}\n$text';
        _ctrl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
      }
    });
    _openBox();
  }

  Future<XFile?> _shoot() async {
    try {
      return await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2048, maxHeight: 2048);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Camera is not available: $e')));
      }
      return null;
    }
  }

  Future<void> _camera() async {
    final x = await _shoot();
    if (x == null) return;
    final fit = AttachLimits.check([await x.length()], already: _attachedBytes);
    if (fit.ok.isEmpty) {
      _limitNotice(fit);
      return;
    }
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    final name = 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
    setState(() => _attachments.add(Attachment(name: name, mime: 'image/jpeg', bytes: bytes)));
  }

  Future<void> _scanText() async {
    final x = await _shoot();
    if (x == null) return;
    try {
      final text = (await DocTools.ocrFile(x.path)).trim();
      if (!mounted) return;
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No text found in that picture.')));
        return;
      }
      final t = _ctrl.text.trim().isEmpty ? text : '${_ctrl.text}\n$text';
      _ctrl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
      _openBox();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('I can\'t read the text in that picture. A sharper, closer photo helps.')));
    }
  }

  Future<void> _toggleDictation() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_sttReady) {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('SubMac needs the microphone to hear you.'),
            action: mic.isPermanentlyDenied ? SnackBarAction(label: 'Allow', onPressed: openAppSettings) : null,
          ));
        }
        return;
      }
      _sttReady = await _stt.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
    }
    if (!mounted) return;
    if (!_sttReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Voice typing needs Google speech services. Install or update the Google app, then try again.')));
      }
      return;
    }
    _beforeDictation = _ctrl.text.trim();
    setState(() => _listening = true);
    // Dictate in the reply language when one is chosen (Somali, Arabic), if the phone supports it.
    String? locale;
    // In Auto, a chat that is in Somali dictates in Somali too (the phone's default language often is not Somali).
    final want = {'Somali': 'so', 'Arabic': 'ar', 'English': 'en'}[_state.replyLanguage] ?? (_state.somaliNow ? 'so' : null);
    if (want != null) {
      try {
        final ls = await _stt.locales();
        locale = ls.where((l) => l.localeId.toLowerCase().startsWith(want)).firstOrNull?.localeId;
      } catch (_) {}
    }
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        localeId: locale,
        partialResults: true,
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 4),
      ),
      onResult: (r) {
        final words = r.recognizedWords;
        final text = _beforeDictation.isEmpty ? words : '$_beforeDictation $words';
        _ctrl.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      },
    );
  }

  @override
  void dispose() {
    if (widget.perChatDrafts) {
      _state.removeListener(_swapDraft);
      _keepDraft();
    }
    _state.shareInbox.removeListener(_takeShare);
    _state.widgetAction.removeListener(_onWidget);
    _stt.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _pick({bool images = false}) async {
    // CB-26: files are streamed, not read whole by the picker, and only the ones within the limits are read.
    final res = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: false,
      withReadStream: true,
      type: images ? FileType.image : FileType.any,
    );
    if (res == null || !mounted) return;
    final fit = AttachLimits.check([for (final f in res.files) f.size], already: _attachedBytes);
    final added = <Attachment>[];
    for (final i in fit.ok) {
      final f = res.files[i];
      final bytes = await _readPicked(f);
      if (bytes == null) continue;
      added.add(Attachment(name: f.name, mime: Attachment.mimeFor(f.name), bytes: bytes));
    }
    if (!mounted) return;
    _limitNotice(fit);
    setState(() => _attachments.addAll(added));
  }

  /// What the message already carries, in bytes (CB-26).
  int get _attachedBytes => _attachments.fold(0, (s, a) => s + (a.bytes?.length ?? 0));

  /// Tells the user a file was left out for its size (CB-26).
  void _limitNotice(AttachCheck fit) {
    final n = AttachLimits.notice(fit);
    if (n == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n)));
  }

  /// A picked file's bytes, read from its stream (never more than [AttachLimits.perFile]).
  static Future<Uint8List?> _readPicked(PlatformFile f) async {
    try {
      if (f.bytes != null) return f.bytes;
      final stream = f.readStream ?? (f.path != null ? File(f.path!).openRead() : null);
      if (stream == null) return null;
      final b = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        b.add(chunk);
        if (b.length > AttachLimits.perFile) return null;
      }
      return b.takeBytes();
    } catch (_) {
      return null;
    }
  }

  void _plusMenu() {
    final state = context.read<AppState>();
    showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Camera'),
              subtitle: const Text('Take a photo to ask about'),
              onTap: () {
                Navigator.pop(ctx);
                _camera();
              },
            ),
            ListTile(
              title: const Text('Scan text'),
              subtitle: const Text('Photograph a page and turn it into text'),
              onTap: () {
                Navigator.pop(ctx);
                _scanText();
              },
            ),
            ListTile(
              title: const Text('Photos'),
              subtitle: const Text('Share a picture to ask about'),
              onTap: () {
                Navigator.pop(ctx);
                _pick(images: true);
              },
            ),
            ListTile(
              title: Text(tr('Files')),
              subtitle: const Text('PDFs, documents, anything'),
              onTap: () {
                Navigator.pop(ctx);
                _pick();
              },
            ),
            ListTile(
              title: const Text('Record a meeting'),
              subtitle: const Text('Get notes, decisions and who does what'),
              onTap: () {
                Navigator.pop(ctx);
                showMeetingRecorder(context);
              },
            ),
            ListTile(
              title: const Text('Talk live'),
              subtitle: const Text('A voice conversation with SubMac'),
              onTap: () {
                Navigator.pop(ctx);
                openLive(context);
              },
            ),
            ListTile(
              title: Text(tr('Skills')),
              subtitle: const Text('Documents, scans, translation and more'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const SkillsScreen()));
              },
            ),
            const SizedBox(height: Space.x2),
            StatefulBuilder(
              builder: (c, set) => SwitchListTile(
                title: const Text('Deep research'),
                subtitle: const Text('One clear report, with sources'),
                value: state.deepResearch,
                onChanged: (v) {
                  state.setDeepResearch(v);
                  set(() {});
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Stops every task working in this chat (the send button is Stop while SubMac works).
  void _stop() {
    for (final r in _state.runsHere.where((r) => !r.side).toList()) {
      _state.stopRun(r);
    }
  }

  void _send() {
    final state = context.read<AppState>();
    var text = _ctrl.text;
    if (text.trim().isEmpty && _attachments.isEmpty && state.pickedSkill != null) text = state.pickedSkill!.starter;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    final atts = List<Attachment>.from(_attachments);
    if (_listening) {
      _stt.stop();
      _listening = false;
    }
    _ctrl.clear();
    setState(() => _attachments.clear());
    if (widget.perChatDrafts) {
      Composer.drafts.remove(_draftFor);
      Composer.attachmentDrafts.remove(_draftFor);
    }
    state.send(text, atts);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.watch<AppState>();
    // A chat that changed while another screen covered this one (a sheet, the Bots workspace): swap once it is in front.
    if (widget.perChatDrafts && (state.currentId ?? '') != _draftFor && (ModalRoute.of(context)?.isCurrent ?? true)) _swapDraft();
    final skill = state.pickedSkill;
    final canSend = _ctrl.text.trim().isNotEmpty || _attachments.isNotEmpty || skill != null;
    // One quiet field: "+" on the start side, the words, and one round button on the end side that is
    // the mic while the box is empty (tap to speak; calls live in the top bar), Send once there is something to send, and Stop
    // while SubMac works with nothing typed. Typing turns Stop back into Send, so a message can steer a task.
    final Widget trailing = canSend
        ? _SendButton(key: const ValueKey('send'), icon: 'send', onTap: _send)
        : _listening
            ? _BareIcon(key: const ValueKey('listening'), icon: 'stop', tip: 'Stop listening', onTap: _toggleDictation)
            : state.busy
                ? _StopButton(key: const ValueKey('stop'), onTap: _stop)
                : _BareIcon(
                    key: const ValueKey('mic'),
                    icon: 'mic',
                    tip: 'Speak',
                    onTap: _toggleDictation,
                  );
    final chips = <Widget>[
      if (skill != null && !_listening) _QuietChip(label: skill.name, onClose: () => state.pickSkill(null)),
      if (state.deepResearch && !_listening) _QuietChip(label: 'Deep research', onClose: () => state.setDeepResearch(false)),
      if (_listening)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: Space.x2),
          child: const StatusWord('Listening'),
        ),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x1, Space.x4, Space.x3),
        // No strip behind the composer (owner 2026-10-24): "+", the words and the mic float as three separate frosted
        // pieces over the chat, which scrolls behind them, blurred.
        child: Padding(
          padding: const EdgeInsets.all(Space.x1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSize(
                duration: LuxMotion.base,
                curve: LuxMotion.ease,
                alignment: AlignmentDirectional.topStart,
                child: _attachments.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : SizedBox(
                        height: 132,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsetsDirectional.fromSTEB(Space.x2, Space.x3, Space.x2, Space.x1),
                          itemCount: _attachments.length,
                          separatorBuilder: (_, __) => const SizedBox(width: Space.x3),
                          itemBuilder: (_, i) => AttachmentChip(
                            attachment: _attachments[i],
                            onRemove: () => setState(() => _attachments.removeAt(i)),
                          ),
                        ),
                      ),
              ),
              // Replying to a message: its quote waits here until you send (or close it).
              ValueListenableBuilder<ReplyRef?>(
                valueListenable: state.replyDraft,
                builder: (context, r, _) => SubSize(
                  alignment: AlignmentDirectional.bottomStart,
                  child: r == null || r.convId != (state.currentId ?? '')
                      ? const SizedBox(width: double.infinity)
                      : FrostedSurface(
                          radius: Radii.field,
                          child: ReplyBar(
                            reply: r,
                            onClose: () => state.replyDraft.value = null,
                          ),
                        ),
                ),
              ),
              if (chips.isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(Space.x2, Space.x2, Space.x2, 0),
                  child: Wrap(spacing: Space.x2, runSpacing: Space.x2, children: chips),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FrostedSurface(
                    key: const ValueKey('composer-plus'),
                    child: _BareIcon(icon: 'plus', tip: 'Add files, photos and more', onTap: _plusMenu),
                  ),
                  const SizedBox(width: Space.x2),
                  Expanded(
                    child: FrostedSurface(
                      key: const ValueKey('composer-field'),
                      radius: Lux.composerRadius,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.symmetric(horizontal: Space.x2),
                        child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      // Arabic typing flows right to left; Somali and English left to right.
                      textDirection: textDirOf(_ctrl.text),
                      style: TextStyle(fontSize: Lux.read, height: 1.4, color: p.text),
                      decoration: InputDecoration(
                        // While a task works, the box says plainly that a message can steer it.
                        hintText: _listening ? 'Speak now…' : (state.busy ? tr('Add to the task, or ask anything') : tr('Ask SubMac anything')),
                        hintMaxLines: 1,
                        hintStyle: TextStyle(color: p.faint),
                        filled: false,
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsetsDirectional.fromSTEB(Space.x1, Space.x3, Space.x2, Space.x3),
                      ),
                    ),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.x2),
                  FrostedSurface(
                    key: const ValueKey('composer-trailing'),
                    child: SizedBox(
                      width: Lux.tap,
                      height: Lux.tap,
                      child: AnimatedSwitcher(
                        duration: SubMotion.of(context, LuxMotion.quick),
                        switchInCurve: LuxMotion.ease,
                        switchOutCurve: SubMotion.leave,
                        transitionBuilder: (c, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(a), child: c)),
                        child: trailing,
                      ),
                    ),
                  ),
                ],
              ),
              // Ask or Autopilot (owner, 2026-11-03): a tiny switch under the field. Autopilot answers approval cards
              // and opencode's permission asks by itself; money and SubMac's own settings still ask.
              // The chat's model (BYOK, owner 2026-11-03) sits beside it, only when the user has models of their own.
              const Padding(
                padding: EdgeInsetsDirectional.only(top: Space.x2),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Wrap(spacing: Space.x2, runSpacing: Space.x1, crossAxisAlignment: WrapCrossAlignment.center, children: [PermissionPill(), ModelPill()]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ask · Autopilot, under the composer: two quiet words in one frosted pill, the chosen one inked.
class PermissionPill extends StatelessWidget {
  const PermissionPill({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: FullAccess.I,
      builder: (context, _) {
        final auto = FullAccess.I.on;
        Widget seg(String label, bool on, bool value) => Semantics(
              button: true,
              selected: on,
              label: label,
              child: InkWell(
                key: ValueKey('perm-$label'),
                borderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
                onTap: on ? null : () => FullAccess.I.set(value),
                child: AnimatedContainer(
                  duration: LuxMotion.quick,
                  curve: LuxMotion.ease,
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: Space.x3),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? (value ? p.accentWash : p.bubble) : Colors.transparent,
                    borderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
                  ),
                  child: Text(label,
                      style: AppText.microStyle.copyWith(
                          color: on ? p.text : p.muted, fontWeight: on ? FontWeight.w600 : FontWeight.w500)),
                ),
              ),
            );
        return FrostedSurface(
          radius: Radii.pill,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              seg(tr('Ask'), !auto, false),
              seg(tr('Autopilot'), auto, true),
            ]),
          ),
        );
      },
    );
  }
}

/// A plain icon with a round touch area: no outline, no fill.
class _BareIcon extends StatelessWidget {
  const _BareIcon({super.key, required this.icon, required this.tip, required this.onTap});
  final String icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: tip,
      excludeSemantics: true,
      child: Tooltip(
        message: tip,
        child: InkResponse(
          radius: Lux.tap / 2,
          onTap: onTap,
          child: SizedBox(width: Lux.tap, height: Lux.tap, child: Center(child: SubIcon(icon, size: IconSize.xl - 2, color: p.text))),
        ),
      ),
    );
  }
}

/// A small armed option above the words (a skill, Deep research): its name and a tiny close.
class _QuietChip extends StatelessWidget {
  const _QuietChip({required this.label, required this.onClose});
  final String label;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
      onTap: onClose,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: Space.x3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: AppText.metaStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
          const SizedBox(width: Space.x2),
          SubIcon('close', size: 12, color: p.muted),
        ]),
      ),
    );
  }
}

/// Ink circle with a paper square: stops what SubMac is doing in this chat.
class _StopButton extends StatelessWidget {
  const _StopButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: 'Stop',
      child: Tooltip(
        message: 'Stop',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
            child: Center(
              child: Container(width: 12, height: 12, decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(2.5))),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final String icon;
  final VoidCallback? onTap;
  const _SendButton({super.key, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedScale(
      scale: onTap == null ? 0.9 : 1,
      duration: SubMotion.of(context, SubMotion.quick),
      curve: SubMotion.settle,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
          child: SubIcon(icon, color: p.bg, size: 20),
        ),
      ),
    );
  }
}


/// Only shows when tasks are working in OTHER chats; this chat's task line sits in the
/// conversation itself, on SubMac's side (see WorkingLine).
class TaskBar extends StatelessWidget {
  const TaskBar({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.watch<AppState>();
    final here = state.runsHere.any((r) => !r.side);
    // A bot's own chat (or a team's work) is not "another chat": the owner asked that bot for it (bug audit
    // 2026-11-07: "1 task working in another chat" showed when only a bot was working).
    final elsewhere = state.runs
        .where((r) => !r.side && r.convId != state.currentId && !Bots.I.isBotConv(r.convId))
        .length;
    if (here || elsewhere == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 16, 4),
      child: Row(children: [
        Text(elsewhere == 1 ? '1 task working in another chat' : '$elsewhere tasks working in other chats',
            style: TextStyle(color: p.muted, fontSize: AppText.micro)),
      ]),
    );
  }
}

/// Geometry shared by the live task line and the finished "Worked for ..." line, so one turns into the
/// other in place (same left edge, same height): the reply below never moves when a task ends.
const turnHeadPad = EdgeInsetsDirectional.fromSTEB(18, 4, 14, 4);
const turnHeadHeight = 30.0;
const turnMarkSize = 22.0;

/// The live line at the top of SubMac's reply, in the chat right under your message (like ChatGPT, Kimi, Hark):
/// the living mark, the status with a soft shimmer, steps so far and the time it has been working. Tap it for
/// the step list. It scrolls with the chat; Stop lives in the composer (the send button turns into Stop).
/// [run] is null for the moment between sending and the task starting (saving the chat, uploading files).
/// A plain reply with no steps hands over to the answer: once the answer has been streaming for a moment
/// with no step taken, the line folds away and the text takes its place.
class WorkingLine extends StatefulWidget {
  const WorkingLine(
      {super.key, this.run, this.more = 0, this.answerShowing = false, this.writing = false, this.showSteps = false, this.activity, this.results = const {}});
  final AgentRun? run;

  /// This turn's work so far (thinking, tools, notes): the line opens to it, in categorized sections (owner 2026-11-03).
  final ActivityGroups? activity;
  final Map<String, ChatMessage> results;

  /// The user asked to see the steps: the task's checklist and its step list can open under the line. Otherwise
  /// (owner 2026-10-24) the line is one quiet status, updating in place, and nothing else.
  final bool showSteps;
  final int more;
  final bool answerShowing;

  /// How long a reply streams with no step before the line gives way to it. Long enough that a task's
  /// first line ("Comparing prices...") followed by its first step never makes the line blink.
  static const handOver = Duration(milliseconds: 1200);

  /// True when the line should give way to the answer: text is showing, the task has taken no step, and
  /// the text has been showing for at least [handOver].
  static bool yields({required bool answerShowing, required bool hasSteps, DateTime? textSince, DateTime? now}) {
    if (!answerShowing || hasSteps || textSince == null) return false;
    return (now ?? DateTime.now()).difference(textSince) >= handOver;
  }

  static bool stepsOf(AgentRun? t) => t != null && (t.trail.isNotEmpty || t.step > 0 || t.browsing || t.phone);

  /// The answer's words are appearing right now.
  final bool writing;

  /// The line for [t] (null: the message is still being saved or uploaded), in the app language.
  static String lineFor(AgentRun? t, {bool writing = false, int more = 0, DateTime? now, String? person}) {
    String key;
    Map<String, String> args;
    if (t == null) {
      key = RunStatus.sending;
      args = const {};
    } else {
      final waited = (now ?? DateTime.now()).difference(t.statusAt).inSeconds;
      key = RunStatus.shown(t.phase, t.status, waited);
      args = t.statusArgs;
      // The reply's words are on screen (a carried-over bubble too) while the run still says it waits: it is writing.
      if (writing && !t.phone && (t.phase == RunPhase.waiting || t.phase == RunPhase.thinking || t.phase == RunPhase.writing)) {
        key = RunStatus.writing;
        args = const {};
      }
    }
    var line = RunStatus.text(key, args);
    // A bot's chat speaks in the person's own voice ("Nova is thinking"), never a generic "Thinking" (owner 2026-11-08).
    if (person != null && person.isNotEmpty && t != null) line = _personLine(person, key, line);
    return more > 0 ? '$line  ·  ${RunStatus.text(RunStatus.more, {'n': '$more'})}' : line;
  }

  /// The same live line said as the person: "Nova is thinking", "Nova is reading a file". Plain words only (never a
  /// glyph before the line), and the long-silence phrases are said in her voice too.
  static String _personLine(String person, String key, String line) {
    if (key == RunStatus.failed) return '$person stopped with an error';
    if (key == RunStatus.retryIn || key == RunStatus.reconnecting) return '$person is reconnecting';
    if (key == RunStatus.waitingLong || key == RunStatus.waitingSlow) return '$person is still waiting';
    if (key == RunStatus.thinkingLong) return '$person is still thinking';
    if (key == RunStatus.reading) return '$person is reading your message';
    if (line.isEmpty) return person;
    final lower = '${line[0].toLowerCase()}${line.substring(1)}';
    return '$person is $lower';
  }

  /// How the line breathes: waiting/thinking, working (a tool, an approval), or roaming (driving the browser or phone).
  static ActivityKind kindOf(AgentRun? t) {
    if (t == null) return ActivityKind.thinking;
    if (t.browsing || t.phone) return ActivityKind.roaming;
    return switch (t.phase) {
      RunPhase.starting || RunPhase.waiting || RunPhase.thinking || RunPhase.retrying => ActivityKind.thinking,
      _ => ActivityKind.working,
    };
  }

  @override
  State<WorkingLine> createState() => _WorkingLineState();
}

class _WorkingLineState extends State<WorkingLine> with SingleTickerProviderStateMixin {
  Timer? _tick;
  Timer? _hand;
  bool _open = false;
  DateTime? _textSince;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _noteText();
  }

  @override
  void didUpdateWidget(covariant WorkingLine old) {
    super.didUpdateWidget(old);
    _noteText();
  }

  void _noteText() {
    if (widget.answerShowing && _textSince == null) {
      _textSince = DateTime.now();
      _hand?.cancel();
      _hand = Timer(WorkingLine.handOver + const Duration(milliseconds: 20), () {
        if (mounted) setState(() {});
      });
    } else if (!widget.answerShowing) {
      _textSince = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _hand?.cancel();
    super.dispose();
  }

  String _elapsed() {
    final t = widget.run;
    if (t == null) return '';
    final d = DateTime.now().difference(t.started);
    if (d.inSeconds < 5) return '';
    final m = d.inMinutes, sec = d.inSeconds % 60;
    return m > 0 ? '$m:${sec.toString().padLeft(2, '0')}' : '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = widget.run;
    final gone = WorkingLine.yields(answerShowing: widget.answerShowing, hasSteps: WorkingLine.stepsOf(t), textSince: _textSince);
    // The line folds away with the shared fold (it vanished at once, then its space closed).
    return SubFold(open: !gone, child: _line(context, p, t));
  }

  Widget _line(BuildContext context, Palette p, AgentRun? t) {
    return AnimatedBuilder(
      animation: Listenable.merge([BrowserAgent.I, BrowserJobs.I]),
      builder: (context, _) {
        // A browser task in this chat: the quiet live card IS the status (one line inside it), nothing else.
        final browsing = t == null ? null : BrowserJobs.I.activeFor(t.convId);
        if (t != null && browsing != null) {
          return Padding(padding: turnHeadPad, child: BrowserLiveCard(key: ValueKey('browser-card-${t.convId}'), convId: t.convId));
        }
        // R2 item 1: the line is the run's real phase (RunStatus), in the app language. Only a long silence in the same
        // phase changes it by itself ("Still waiting for a response"), never a rotating phrase.
        final status = WorkingLine.lineFor(t, writing: widget.writing, more: widget.more,
            person: t == null ? null : Bots.I.byConv(t.convId)?.name);
        final el = _elapsed();
        final trail = t?.trail ?? const <RunStep>[];
        final act = widget.activity;
        final hasActivity = act != null && !act.isEmpty;
        final canOpen = hasActivity || (widget.showSteps && trail.isNotEmpty);
        final kind = WorkingLine.kindOf(t);
        final row = SizedBox(
          height: turnHeadHeight,
          child: Row(children: [
            // Plain text only (owner rule): the status word, breathing calmly while SubMac works. No mark,
            // no dots, no glyph before it; tap it to see the steps.
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: !canOpen
                    ? null
                    : () {
                        setState(() => _open = !_open);
                      },
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: StatusWord(status, kind: kind, color: p.text),
                ),
              ),
            ),
            if (el.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 8, end: 4),
                child: Text(el, style: TextStyle(color: p.muted, fontSize: AppText.micro, fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            if (canOpen)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _open = !_open),
                child: ActivityChevron(open: _open),
              ),
          ]),
        );
        return Padding(
          padding: turnHeadPad,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(liveRegion: true, child: row),
            // The task's own checklist (long builds): always in view as one tidy card.
            if (widget.showSteps && t != null && t.todo.isNotEmpty)
              Padding(
                padding: EdgeInsetsDirectional.zero,
                child: ChecklistCard(steps: List.of(t.todo), done: Set.of(t.todoDone)),
              ),
            // The browser agent's live checklist: what is done, what is next.
            SubFold(
              open: _open && canOpen,
              child: SubSize(
                duration: SubMotion.quick,
                alignment: AlignmentDirectional.topStart,
                child: hasActivity
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(top: 4, bottom: 6),
                        child: ActivityPanel(groups: act, results: widget.results),
                      )
                    : Padding(
                      padding: const EdgeInsetsDirectional.only(top: 4, bottom: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // What the task has done so far, newest last, with how long each step took.
                        for (final st in trail.length > 12 ? trail.sublist(trail.length - 12) : trail)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: st.done
                                    ? Icon(st.failed ? Icons.error_outline_rounded : Icons.check_rounded, size: 14, color: st.failed ? p.accent : p.muted)
                                    : const SizedBox(width: 14, height: 14, child: Center(child: RedDot(size: 6, animate: true))),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(st.failed ? '${st.label} (didn\'t work)' : st.label,
                                    style: TextStyle(fontSize: AppText.micro, color: st.done ? p.muted : p.text, height: 1.35)),
                              ),
                              if (st.done && st.ended!.difference(st.started).inSeconds >= 2)
                                Text('${st.ended!.difference(st.started).inSeconds}s',
                                    style: TextStyle(color: p.muted, fontSize: AppText.caption, fontFeatures: const [FontFeature.tabularFigures()])),
                            ]),
                          ),
                      ]),
                    ),
              ),
            ),
          ]),
        );
      },
    );
  }
}
