import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/feedback.dart';
import '../theme.dart';
import '../ui/feedback_words.dart';
import '../ui/tokens.dart';

/// Picks pictures for feedback. The real one uses the app's image_picker; tests use a fake.
abstract class FeedbackPicker {
  Future<List<FeedbackShot>> gallery(int max);
  Future<FeedbackShot?> camera();
}

class ImageFeedbackPicker implements FeedbackPicker {
  final ImagePicker _p = ImagePicker();

  Future<FeedbackShot> _shot(XFile x) async {
    final name = x.name.isNotEmpty ? x.name : x.path.split('/').last;
    final mime = x.mimeType ?? FeedbackLimits.mimeFor(name) ?? 'application/octet-stream';
    return FeedbackShot(name: name, mime: mime, bytes: await x.readAsBytes());
  }

  @override
  Future<List<FeedbackShot>> gallery(int max) async {
    if (max <= 0) return const [];
    // image_picker needs a limit of at least 2 for several pictures.
    final xs = max == 1
        ? [if (await _p.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2048, maxHeight: 2048) case final x?) x]
        : await _p.pickMultiImage(imageQuality: 85, maxWidth: 2048, maxHeight: 2048, limit: max);
    return [for (final x in xs.take(max)) await _shot(x)];
  }

  @override
  Future<FeedbackShot?> camera() async {
    final x = await _p.pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2048, maxHeight: 2048);
    return x == null ? null : _shot(x);
  }
}

/// Settings > Help > Send feedback. A message (required), up to 5 screenshots, then Send.
/// The draft is kept on the phone until it is sent, so going offline or closing the screen loses nothing.
class FeedbackScreen extends StatefulWidget {
  final FeedbackSender? sender;
  final FeedbackDraftStore? store;
  final FeedbackPicker? picker;
  const FeedbackScreen({super.key, this.sender, this.store, this.picker});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

enum _Phase { editing, sending, sent }

class _FeedbackScreenState extends State<FeedbackScreen> {
  late final FeedbackSender _sender = widget.sender ?? FeedbackSender();
  late final FeedbackDraftStore _store = widget.store ?? FileFeedbackDraftStore();
  late final FeedbackPicker _picker = widget.picker ?? ImageFeedbackPicker();
  final _text = TextEditingController();
  final List<FeedbackShot> _shots = [];
  String? _category;
  _Phase _phase = _Phase.editing;
  FeedbackProgress? _progress;
  String? _error; // shown under the field / above Send
  bool _canRetry = false;
  Timer? _saveSoon;

  static const _categories = [('bug', 'Problem'), ('idea', 'Idea'), ('other', 'Other')];

  @override
  void initState() {
    super.initState();
    _store.load().then((d) {
      if (!mounted || d == null || d.isEmpty) return;
      if (_text.text.isNotEmpty || _shots.isNotEmpty) return;
      setState(() {
        _text.text = d.message;
        _category = d.category;
        _shots.addAll(d.shots.take(FeedbackLimits.maxShots));
      });
    });
    _text.addListener(_changed);
  }

  @override
  void dispose() {
    _saveSoon?.cancel();
    if (_phase != _Phase.sent) _store.save(_draft());
    _text.dispose();
    super.dispose();
  }

  FeedbackDraft _draft() => FeedbackDraft(message: _text.text, category: _category, shots: List.of(_shots));

  void _changed() {
    if (_error != null && _text.text.trim().isNotEmpty && !_canRetry) setState(() => _error = null);
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(milliseconds: 600), () => _store.save(_draft()));
  }

  String _words(FeedbackProblem p) => switch (p) {
        FeedbackProblem.empty => ft('Write your feedback first.'),
        FeedbackProblem.tooLong => ft('Your feedback is too long.'),
        FeedbackProblem.offline => ft('You are offline. Your feedback is kept here; send it when you are back online.'),
        FeedbackProblem.signedOut => ft('Sign in to send feedback.'),
        FeedbackProblem.tooMany => ft('You have sent a lot of feedback today. Please try again tomorrow.'),
        FeedbackProblem.tooBig => ft('That picture is too big. Each screenshot can be up to 5 MB.'),
        FeedbackProblem.badType => ft('Only pictures can be attached (PNG, JPG, WebP, GIF or HEIC).'),
        FeedbackProblem.tooManyShots => ft('You can attach up to 5 screenshots.'),
        FeedbackProblem.server => ft('Something went wrong and your feedback was not sent. It is kept here.'),
      };

  void _notice(String s) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(content: Text(s)));
  }

  void _addAll(List<FeedbackShot> picked) {
    FeedbackProblem? refused;
    setState(() {
      for (final s in picked) {
        try {
          FeedbackSender.checkShot(s, already: _shots.length);
          _shots.add(s);
        } on FeedbackException catch (e) {
          refused ??= e.problem;
        }
      }
    });
    if (refused != null) _notice(_words(refused!));
    _store.save(_draft());
  }

  Future<void> _pick(bool camera) async {
    final left = FeedbackLimits.maxShots - _shots.length;
    if (left <= 0) return _notice(_words(FeedbackProblem.tooManyShots));
    try {
      if (camera) {
        final s = await _picker.camera();
        if (s != null && mounted) _addAll([s]);
      } else {
        final list = await _picker.gallery(left);
        if (mounted && list.isNotEmpty) {
          _addAll(list.take(left).toList());
          if (list.length > left) _notice(_words(FeedbackProblem.tooManyShots));
        }
      }
    } catch (_) {
      if (mounted) _notice(camera ? ft('The camera is not available.') : _words(FeedbackProblem.server));
    }
  }

  Future<void> _addSheet() async {
    final camera = await showModalBottomSheet<bool>(
      context: context,
      sheetAnimationStyle: SubMotion.sheet,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(ft('Choose from gallery')),
            onTap: () => Navigator.pop(c, false),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(ft('Take a photo')),
            onTap: () => Navigator.pop(c, true),
          ),
        ]),
      ),
    );
    if (camera != null) await _pick(camera);
  }

  void _remove(int i) {
    setState(() => _shots.removeAt(i));
    _store.save(_draft());
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    if (_text.text.trim().isEmpty) {
      setState(() {
        _error = _words(FeedbackProblem.empty);
        _canRetry = false;
      });
      return;
    }
    setState(() {
      _phase = _Phase.sending;
      _error = null;
      _canRetry = false;
      _progress = FeedbackProgress(0, _shots.length + 1, _shots.isEmpty ? 0 : 1);
    });
    await _store.save(_draft());
    try {
      await _sender.send(
        message: _text.text,
        category: _category,
        shots: List.of(_shots),
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      await _store.clear();
      if (!mounted) return;
      setState(() => _phase = _Phase.sent);
    } on FeedbackException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.editing;
        _error = _words(e.problem);
        _canRetry = e.problem == FeedbackProblem.offline || e.problem == FeedbackProblem.server;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(ft('Send feedback'))),
      body: SafeArea(child: _phase == _Phase.sent ? _sent(p) : _form(p)),
    );
  }

  Widget _sent(Palette p) => Center(
        key: const ValueKey('feedback-sent'),
        child: Padding(
          padding: const EdgeInsets.all(Space.x6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle_outline_rounded, size: Space.x8 * 2, color: p.ok),
            const SizedBox(height: Space.x4),
            Text(ft('Thank you'), style: AppText.titleStyle.copyWith(color: p.text)),
            const SizedBox(height: Space.x2),
            Text(ft('Your feedback reached the Telesia team.'),
                textAlign: TextAlign.center, style: AppText.bodyStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x6),
            FilledButton(onPressed: () => Navigator.maybePop(context), child: Text(ft('Done'))),
          ]),
        ),
      );

  Widget _form(Palette p) {
    final busy = _phase == _Phase.sending;
    final pr = _progress;
    // A short form: one scroll view with every piece built, so the error and the Send button never sit unbuilt
    // below a lazy list's edge.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, Space.x8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(ft('Tell us what went wrong or what you would like. Screenshots help.'),
            style: AppText.metaStyle.copyWith(color: p.muted)),
        const SizedBox(height: Space.x4),
        Wrap(spacing: Space.x2, runSpacing: Space.x2, children: [
          for (final (key, label) in _categories)
            ChoiceChip(
              label: Text(ft(label)),
              selected: _category == key,
              onSelected: busy
                  ? null
                  : (on) {
                      setState(() => _category = on ? key : null);
                      _store.save(_draft());
                    },
            ),
        ]),
        const SizedBox(height: Space.x3),
        TextField(
          key: const ValueKey('feedback-text'),
          controller: _text,
          enabled: !busy,
          minLines: 6,
          maxLines: 12,
          maxLength: FeedbackLimits.maxMessage,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: ft('Write your feedback'),
            border: const OutlineInputBorder(borderRadius: Radii.fieldAll),
          ),
        ),
        const SizedBox(height: Space.x4),
        Row(children: [
          Expanded(child: Text(ft('Screenshots'), style: AppText.sectionStyle.copyWith(color: p.muted))),
          Text(ft('{n} of {max}', {'n': '${_shots.length}', 'max': '${FeedbackLimits.maxShots}'}),
              style: AppText.microStyle.copyWith(color: p.muted)),
        ]),
        const SizedBox(height: Space.x2),
        Wrap(spacing: Space.x2, runSpacing: Space.x2, children: [
          for (var i = 0; i < _shots.length; i++) _Thumb(shot: _shots[i], onRemove: busy ? null : () => _remove(i), index: i),
          if (_shots.length < FeedbackLimits.maxShots)
            _AddTile(onTap: busy ? null : _addSheet),
        ]),
        const SizedBox(height: Space.x6),
        if (_error != null) ...[
          Container(
            key: const ValueKey('feedback-error'),
            padding: const EdgeInsets.all(Space.x3),
            decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.fieldAll),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline_rounded, size: IconSize.lg, color: p.muted),
              const SizedBox(width: Space.x2),
              Expanded(child: Text(_error!, style: AppText.metaStyle.copyWith(color: p.text))),
            ]),
          ),
          const SizedBox(height: Space.x3),
        ],
        if (busy && pr != null) ...[
          LinearProgressIndicator(value: pr.fraction == 0 ? null : pr.fraction),
          const SizedBox(height: Space.x2),
          Text(
            pr.shot > 0
                ? ft('Uploading screenshot {n} of {total}', {'n': '${pr.shot}', 'total': '${_shots.length}'})
                : ft('Saving your feedback'),
            style: AppText.microStyle.copyWith(color: p.muted),
          ),
          const SizedBox(height: Space.x3),
        ],
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('feedback-send'),
            onPressed: busy ? null : _send,
            child: Text(busy ? ft('Sending…') : (_canRetry ? ft('Try again') : ft('Send'))),
          ),
        ),
      ]),
    );
  }
}

class _Thumb extends StatelessWidget {
  final FeedbackShot shot;
  final VoidCallback? onRemove;
  final int index;
  const _Thumb({required this.shot, required this.onRemove, required this.index});

  static const double size = 84;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: Radii.fieldAll,
            child: Image.memory(
              shot.bytes,
              fit: BoxFit.cover,
              cacheWidth: 256,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => ColoredBox(color: p.bubble, child: Icon(Icons.image_outlined, color: p.muted)),
            ),
          ),
        ),
        PositionedDirectional(
          top: Space.x1,
          end: Space.x1,
          child: Semantics(
            button: true,
            label: ft('Remove screenshot'),
            child: Material(
              color: p.sheet.withValues(alpha: 0.85),
              shape: const CircleBorder(),
              child: InkWell(
                key: ValueKey('feedback-remove-$index'),
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(Space.x1),
                  child: Icon(Icons.close_rounded, size: IconSize.sm, color: p.text),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _AddTile extends StatelessWidget {
  final VoidCallback? onTap;
  const _AddTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: ft('Add screenshot'),
      child: Material(
        color: p.bubble,
        borderRadius: Radii.fieldAll,
        child: InkWell(
          key: const ValueKey('feedback-add'),
          borderRadius: Radii.fieldAll,
          onTap: onTap,
          child: SizedBox(
            width: _Thumb.size,
            height: _Thumb.size,
            child: Icon(Icons.add_photo_alternate_outlined, color: p.muted),
          ),
        ),
      ),
    );
  }
}
