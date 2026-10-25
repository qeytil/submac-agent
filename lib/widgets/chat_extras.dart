import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/tools.dart';
import '../theme.dart';
import 'chat/fade_append.dart';
import 'chat_logic.dart';
import 'logo.dart';
import 'markdown_view.dart';
import 'motion.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// Markdown that renders block by block. Finished blocks keep their widgets, so a long reply that is
/// still streaming only re-lays out its last paragraph; a very long last block (a big code sample)
/// refreshes a few times a second instead of every frame.
class StreamingMarkdown extends StatefulWidget {
  const StreamingMarkdown(this.data, {super.key, this.live = false});
  final String data;

  /// The text is still growing.
  final bool live;

  @override
  State<StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _StreamingMarkdownState extends State<StreamingMarkdown> {
  final List<String> _texts = [];
  final List<Widget> _widgets = [];
  DateTime _lastLive = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _later;

  @override
  void dispose() {
    _later?.cancel();
    super.dispose();
  }

  Duration _gap(String chunk) {
    if (chunk.length < 1200) return Duration.zero;
    final ms = (chunk.length / 10).clamp(0, 300).round();
    return Duration(milliseconds: ms);
  }

  @override
  Widget build(BuildContext context) {
    final chunks = splitMarkdownChunks(widget.data);
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      if (i < _texts.length && _texts[i] == c) continue;
      final isLiveTail = widget.live && i == chunks.length - 1 && i < _widgets.length;
      if (isLiveTail) {
        final wait = _gap(c) - DateTime.now().difference(_lastLive);
        if (wait > Duration.zero) {
          _later ??= Timer(wait, () {
            _later = null;
            if (mounted) setState(() {});
          });
          continue; // keep showing the previous version of this block for a moment
        }
        _lastLive = DateTime.now();
      }
      // Streaming text fades in as it arrives (no letter-by-letter typing): each block keeps one FadeAppend, which
      // lays the grown text over the old and fades only the new words in. A block that starts mid-stream fades in too.
      final w = FadeAppend(key: ValueKey('md-$i'), text: c, fadeFirst: widget.live && i >= _texts.length, child: MarkdownView(c));
      if (i < _texts.length) {
        _texts[i] = c;
        _widgets[i] = w;
      } else {
        _texts.add(c);
        _widgets.add(w);
      }
    }
    if (_texts.length > chunks.length) {
      _texts.removeRange(chunks.length, _texts.length);
      _widgets.removeRange(chunks.length, _widgets.length);
    }
    // Always one Column (one block or many), so a second block arriving never rebuilds the first.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _widgets.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _widgets[i],
        ],
      ],
    );
  }
}

/// Text with a soft light passing over it: the "SubMac is working" look.
class ShimmerText extends StatefulWidget {
  const ShimmerText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: SubMotion.shimmerText);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final text = Text(widget.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style ?? const TextStyle(fontSize: AppText.meta));
    if (reduceMotion(context)) return DefaultTextStyle.merge(style: TextStyle(color: p.muted), child: text);
    return AnimatedBuilder(
      animation: _c,
      child: text,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) {
          final x = _c.value * 2 - 0.5;
          return LinearGradient(
            colors: [p.muted, p.text, p.muted],
            stops: [(x - 0.25).clamp(0.0, 1.0), x.clamp(0.0, 1.0), (x + 0.25).clamp(0.0, 1.0)],
          ).createShader(r);
        },
        child: child,
      ),
    );
  }
}

/// Shown the instant a message is sent, before the task has started: the same look as the task line,
/// so the hand-over is seamless.
class PendingLine extends StatelessWidget {
  const PendingLine({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'SubMac is thinking',
      child: const Padding(
        padding: EdgeInsetsDirectional.fromSTEB(16, 6, 14, 12),
        child: Row(children: [
          // A fine working ring (no dots in the interface).
          RedDot(size: 14, animate: true),
          SizedBox(width: 10),
          Expanded(child: ShimmerText('Thinking')),
        ]),
      ),
    );
  }
}

/// A long task's checklist as one tidy card: progress in plain words, a thin bar, and the steps.
class ChecklistCard extends StatefulWidget {
  const ChecklistCard({super.key, required this.steps, required this.done});
  final List<String> steps;
  final Set<int> done;

  @override
  State<ChecklistCard> createState() => _ChecklistCardState();
}

class _ChecklistCardState extends State<ChecklistCard> {
  bool _all = false;
  static const _window = 6;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final steps = widget.steps;
    final doneCount = widget.done.where((i) => i >= 0 && i < steps.length).length;
    final current = List.generate(steps.length, (i) => i).firstWhere((i) => !widget.done.contains(i), orElse: () => -1);
    var from = 0, to = steps.length;
    if (!_all && steps.length > _window) {
      from = (current < 0 ? steps.length - _window : current - 1).clamp(0, steps.length - _window);
      to = from + _window;
    }
    final reduce = reduceMotion(context);
    return Semantics(
      container: true,
      label: 'Plan, ${checklistLine(doneCount, steps.length)}',
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: p.sheet,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text('Plan', style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(checklistLine(doneCount, steps.length), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: steps.isEmpty ? 0 : doneCount / steps.length),
              duration: reduce ? Duration.zero : SubMotion.page,
              curve: SubMotion.settle,
              builder: (context, v, _) => LinearProgressIndicator(value: v, minHeight: 4, backgroundColor: p.border, color: p.text),
            ),
          ),
          const SizedBox(height: 6),
          if (from > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('$from done before', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            ),
          for (var i = from; i < to; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    widget.done.contains(i)
                        ? Icons.check_circle_rounded
                        : (i == current ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
                    size: 15,
                    color: widget.done.contains(i) ? p.muted : p.text,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    steps[i],
                    style: TextStyle(
                      fontSize: AppText.meta,
                      height: 1.35,
                      color: widget.done.contains(i) ? p.muted : p.text,
                      fontWeight: i == current ? FontWeight.w600 : FontWeight.w400,
                      decoration: widget.done.contains(i) ? TextDecoration.lineThrough : null,
                      decorationColor: p.muted,
                    ),
                  ),
                ),
              ]),
            ),
          if (steps.length > _window)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 30),
                  foregroundColor: p.muted,
                  textStyle: const TextStyle(fontSize: AppText.micro, fontWeight: FontWeight.w500),
                ),
                onPressed: () {
                  setState(() => _all = !_all);
                },
                child: Text(_all ? 'Show less' : 'Show all ${steps.length}'),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Short replies to tap after an answer that asks something ("Yes, please", "Make it shorter"):
/// one quiet row of pills that scrolls sideways, each with a reply mark, so it never pushes the answer around.
class FollowUpChips extends StatelessWidget {
  const FollowUpChips({super.key, required this.options, required this.onPick});
  final List<String> options;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.x3),
      child: SingleChildScrollView(
        key: const ValueKey('follow-ups'),
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: Space.x2),
            FadeSlideIn(
              delay: SubMotion.staggerFor(i),
              child: SoftReplyChip(label: options[i], icon: 'reply', onTap: () => onPick(options[i])),
            ),
          ],
        ]),
      ),
    );
  }
}

/// A question's answers, the way modern chat apps ask: airy full-width rows on a soft surface, no numbers, no
/// borders and no dots. Tapping one settles it in (a gentle fill and a tick at the end), the others step back
/// and nothing can be tapped twice. With [onOther] a last row, "Something else", opens a field in place for
/// your own words. Used by ```choices cards and a task's questions.
class ChoiceRows extends StatefulWidget {
  const ChoiceRows({
    super.key,
    required this.options,
    required this.onPick,
    this.enabled = true,
    this.picked,
    this.onOther,
    this.otherLabel = 'Something else',
  });
  final List<String> options;
  final ValueChanged<String> onPick;
  final bool enabled;

  /// An answer already given (shown ticked).
  final String? picked;

  /// Your own answer instead of one of the options. Null hides the "Something else" row.
  final ValueChanged<String>? onOther;
  final String otherLabel;

  @override
  State<ChoiceRows> createState() => _ChoiceRowsState();
}

class _ChoiceRowsState extends State<ChoiceRows> {
  String? _picked;
  bool _other = false;
  TextEditingController? _otherText;

  @override
  void initState() {
    super.initState();
    _picked = widget.picked;
  }

  @override
  void dispose() {
    _otherText?.dispose();
    super.dispose();
  }

  bool get _live => widget.enabled && _picked == null;

  void _pick(String o) {
    if (!_live) return;
    setState(() {
      _picked = o;
      _other = false;
    });
    widget.onPick(o);
  }

  void _sendOther() {
    final t = _otherText?.text.trim() ?? '';
    if (t.isEmpty || !_live) return;
    setState(() => _picked = t);
    widget.onOther?.call(t);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final picked = _picked;
    final rows = <Widget>[
      for (var i = 0; i < widget.options.length; i++)
        FadeSlideIn(
          delay: SubMotion.staggerFor(i),
          child: _row(p, i, widget.options[i], picked),
        ),
      if (widget.onOther != null) FadeSlideIn(delay: SubMotion.staggerFor(widget.options.length), child: _otherRow(p, picked)),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const SizedBox(height: Space.x2),
        rows[i],
      ],
    ]);
  }

  Widget _surface(Palette p, {required Key key, required bool on, required Widget child}) => AnimatedContainer(
        key: key,
        duration: LuxMotion.base,
        curve: LuxMotion.ease,
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x3, Space.x3),
        decoration: BoxDecoration(color: on ? p.bubble : p.sheet, borderRadius: Radii.rowAll),
        child: child,
      );

  Widget _row(Palette p, int i, String o, String? picked) {
    final on = picked == o;
    final dim = picked != null && !on;
    return Semantics(
      button: true,
      selected: on,
      enabled: _live,
      label: o,
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: LuxMotion.base,
        opacity: dim ? 0.45 : (widget.enabled || on ? 1 : 0.55),
        child: Pressable(
          onTap: _live ? () => _pick(o) : null,
          child: _surface(
            p,
            key: ValueKey('choice-$i'),
            on: on,
            child: Row(children: [
              Expanded(
                child: Text(o,
                    style: AppText.bodyStyle.copyWith(color: p.text, height: 1.35, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
              ),
              const SizedBox(width: Space.x3),
              // The tick settles in on the chosen answer; the others keep the space so nothing shifts.
              AnimatedSwitcher(
                duration: SubMotion.of(context, LuxMotion.base),
                switchInCurve: SubMotion.settle,
                switchOutCurve: SubMotion.leave,
                // A small settle, not a grow from nothing (scaling from 0 popped the tick in from a dot).
                transitionBuilder: (c, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(a), child: c)),
                child: on
                    ? SubIcon('check', key: const ValueKey('choice-check'), size: IconSize.md, color: p.text)
                    : SizedBox(key: const ValueKey('choice-none'), width: IconSize.md, height: IconSize.md, child: picked == null ? SubIcon('chevron_right', size: IconSize.sm, color: p.faint) : null),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _otherRow(Palette p, String? picked) {
    final mine = picked != null && !widget.options.contains(picked);
    final dim = picked != null && !mine;
    final String shown = mine ? picked : widget.otherLabel;
    return AnimatedOpacity(
      duration: LuxMotion.base,
      opacity: dim ? 0.45 : (widget.enabled || mine ? 1 : 0.55),
      child: AnimatedSize(
        duration: LuxMotion.base,
        curve: LuxMotion.ease,
        alignment: AlignmentDirectional.topStart,
        child: _other && !mine
            ? _surface(
                p,
                key: const ValueKey('choice-other-field'),
                on: true,
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _otherText ??= TextEditingController(),
                      // Opened by a tap on "Something else", so the keyboard is expected here.
                      autofocus: true,
                      enabled: _live,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendOther(),
                      style: AppText.bodyStyle.copyWith(color: p.text),
                      decoration: InputDecoration(
                        hintText: widget.otherLabel,
                        isDense: true,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.x2),
                  Semantics(
                    button: true,
                    label: 'Send',
                    child: InkResponse(
                      radius: Lux.tap / 2,
                      onTap: _live ? _sendOther : null,
                      child: Padding(padding: const EdgeInsets.all(Space.x1), child: SubIcon('send', size: IconSize.lg, color: p.text)),
                    ),
                  ),
                ]),
              )
            : Semantics(
                button: true,
                selected: mine,
                enabled: _live,
                label: shown,
                excludeSemantics: true,
                child: Pressable(
                  onTap: _live ? () => setState(() => _other = true) : null,
                  child: _surface(
                    p,
                    key: const ValueKey('choice-other'),
                    on: mine,
                    child: Row(children: [
                      Expanded(
                        child: Text(shown,
                            style: AppText.bodyStyle.copyWith(
                                color: mine ? p.text : p.muted, height: 1.35, fontWeight: mine ? FontWeight.w600 : FontWeight.w400)),
                      ),
                      const SizedBox(width: Space.x3),
                      mine
                          ? SubIcon('check', key: const ValueKey('choice-check'), size: IconSize.md, color: p.text)
                          : SubIcon('edit', size: IconSize.sm, color: p.faint),
                    ]),
                  ),
                ),
              ),
      ),
    );
  }
}

/// One rounded reply chip (follow-ups, answers to a task's question).
class SoftReplyChip extends StatelessWidget {
  const SoftReplyChip({super.key, required this.label, required this.onTap, this.strong = false, this.icon});
  final String label;
  final VoidCallback onTap;
  final bool strong;

  /// A small mark before the words (follow-ups use 'reply').
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: strong ? p.text : p.sheet,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[SubIcon(icon!, size: 14, color: strong ? p.bg : p.muted), const SizedBox(width: 6)],
            Flexible(
              child: Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: strong ? p.bg : p.text, fontSize: AppText.meta, fontWeight: FontWeight.w500)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// "How I did it · 4 steps": the steps of a finished task in plain words, folded away until asked.
class HowIDidIt extends StatefulWidget {
  const HowIDidIt({super.key, required this.steps});
  final List<TurnStep> steps;

  @override
  State<HowIDidIt> createState() => _HowIDidItState();
}

class _HowIDidItState extends State<HowIDidIt> {
  bool _open = false;

  static Map<String, dynamic> _args(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return const {};
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final steps = widget.steps.where((s) => !hiddenStepNames.contains(s.name)).toList();
    if (steps.isEmpty) return const SizedBox.shrink();
    final n = steps.length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              setState(() => _open = !_open);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('How I did it', style: TextStyle(color: p.muted, fontSize: AppText.meta, fontWeight: FontWeight.w500)),
                Text('  ·  $n ${n == 1 ? 'step' : 'steps'}', style: TextStyle(color: p.muted, fontSize: AppText.meta)),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: SubMotion.of(context, SubMotion.base),
                  curve: SubMotion.settle,
                  child: Icon(Icons.expand_more_rounded, size: 18, color: p.muted),
                ),
              ]),
            ),
          ),
        ),
        SubFold(
          open: _open,
          child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4, top: 2, bottom: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final s in steps)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(
                            child: Text(
                              s.failed
                                  ? '${AgentTools.describe(s.name, _args(s.arguments), done: true)} (didn\'t work)'
                                  : AgentTools.describe(s.name, _args(s.arguments), done: true),
                              style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.35),
                            ),
                          ),
                        ]),
                      ),
                  ]),
                ),
        ),
      ]),
    );
  }
}

/// The round "back to the newest message" button, with a quiet "New" when something arrived meanwhile.
class JumpToBottom extends StatelessWidget {
  const JumpToBottom({super.key, required this.onTap, this.fresh = false});
  final VoidCallback onTap;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: fresh ? 'New reply. Go to the newest message' : 'Go to the newest message',
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: Container(
          height: 38,
          padding: EdgeInsets.symmetric(horizontal: fresh ? 14 : 0),
          constraints: const BoxConstraints(minWidth: 38),
          decoration: BoxDecoration(
            color: p.composer,
            borderRadius: BorderRadius.circular(19),
            boxShadow: isDark ? null : [BoxShadow(color: const Color(0xFF17150F).withValues(alpha: 0.08), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            if (fresh) ...[
              Text(tr('New'), style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
            ],
            Icon(Icons.arrow_downward_rounded, size: 18, color: p.text),
          ]),
        ),
      ),
    );
  }
}
