import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'chat_logic.dart';

import '../models.dart';
import '../services/choices.dart';
import '../services/turn_visuals.dart';
import 'markdown_view.dart';
import 'motion.dart';
import 'chat/blocks.dart';
import 'chat/entrance.dart';
import '../ui/tokens.dart';
import 'output_cards.dart';
import 'chat/long_text.dart';

/// One piece of a reply: plain text (markdown) or a card.
class ReplyBlock {
  final String? lang; // null = markdown text
  final String text;
  final bool complete;
  const ReplyBlock(this.lang, this.text, {this.complete = true});
}

final _split = RegExp(r'^\s*(---+|\+\+\+)\s*$');
// Any info string opens a fence (CommonMark): ```c#, ```objective-c, ```python title="x". Before PR-7 (CB-6) only
// [A-Za-z0-9_+-] words matched, so the CLOSING fence of a ```c# block was read as an opening one and swallowed the rest.
final _open = RegExp(r'^\s{0,3}(```+|~~~+)\s*([^\s`]*)[^`]*$');

/// Splits a reply into text and card blocks. Card fences only count at the top
/// level; other code fences stay inside the text so markdown renders them.
List<ReplyBlock> parseReply(String content) {
  // A bot's question written as raw code (a ```json fence, a fence opened mid-line, bare JSON) becomes its card.
  content = Choices.fixReply(content);
  final out = <ReplyBlock>[];
  final text = StringBuffer();
  final card = StringBuffer();
  String? cardLang;
  String? cardFence;
  String? innerFence; // a fence opened inside a card body
  String? otherFence;

  void flushText() {
    final t = text.toString();
    if (t.trim().isNotEmpty) out.add(ReplyBlock(null, t.trimRight()));
    text.clear();
  }

  for (final line in content.split('\n')) {
    if (cardLang != null) {
      final t = line.trim();
      final f = cardFence ?? '```';
      // A code fence inside a card body (a summary with a snippet) must not end the card.
      if (innerFence != null) {
        if (t == innerFence) innerFence = null;
        card.writeln(line);
        continue;
      }
      if (t.startsWith(f) && t.replaceAll(f[0], '').trim().isEmpty) {
        out.add(ReplyBlock(cardLang, card.toString()));
        card.clear();
        cardLang = null;
        cardFence = null;
      } else {
        final inner = RegExp(r'^(```+|~~~+)').firstMatch(t);
        if (inner != null) innerFence = inner.group(1)!;
        card.writeln(line);
      }
      continue;
    }
    if (otherFence != null) {
      text.writeln(line);
      final t = line.trim();
      final f = otherFence;
      if (t.startsWith(f) && t.replaceAll(f[0], '').trim().isEmpty) otherFence = null;
      continue;
    }
    if (_split.hasMatch(line)) {
      flushText(); // a new message bubble
      continue;
    }
    final m = _open.firstMatch(line);
    if (m != null) {
      final lang = m.group(2)!.toLowerCase();
      if (cardLanguages.contains(lang)) {
        flushText();
        cardLang = lang;
        cardFence = m.group(1)!;
        continue;
      }
      otherFence = m.group(1)!;
    }
    text.writeln(line);
  }
  flushText();
  if (cardLang != null) out.add(ReplyBlock(cardLang, card.toString(), complete: false));
  return out;
}

/// Renders a reply as blocks that fade in one after another. A card renders only
/// once its block is complete; until then a soft placeholder shows.
///
/// While a reply streams, text that arrives in bursts is let out smoothly frame by frame
/// (never slower than it arrives), and only the newest paragraph re-renders.
class ReplyView extends StatefulWidget {
  final ChatMessage message;

  /// The text to show when it differs from [message.content] (thinking or repeated media taken out).
  final String? text;
  const ReplyView({super.key, required this.message, this.text});

  @override
  State<ReplyView> createState() => _ReplyViewState();
}

class _ReplyViewState extends State<ReplyView> with SingleTickerProviderStateMixin {
  late int _shown;
  Ticker? _ticker;
  Duration? _released;

  String get _full => widget.text ?? widget.message.content;

  bool get _reveals => widget.message.streaming || widget.message.animateIn;

  /// Whether block i rises in on its own, decided once when the block first shows: never while the whole message is
  /// still arriving (MessageArrive), so the two entrances never stack, and never flipped by a later rebuild.
  final Map<int, bool> _blockEnters = {};

  @override
  void initState() {
    super.initState();
    // A reply that is still arriving shows whole words as they come; an old one shows at once.
    _shown = widget.message.streaming ? revealTarget(_full, streaming: true) : _full.length;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) _shown = _full.length;
    _sync();
  }

  @override
  void didUpdateWidget(covariant ReplyView old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Streaming (owner 2026-10-24): no letter-by-letter typing. New words are let out in small batches, whole words
  /// only, at most every [revealEvery]; each batch then fades in where it lands (FadeAppend in the markdown), so the
  /// text never jitters and the lines never jump. Reduced motion: everything at once.
  void _sync() {
    final full = _full;
    if (_shown > full.length) _shown = full.length; // the text was replaced by a shorter one
    if (!_reveals || reduceMotion(context)) {
      _shown = full.length;
      _ticker?.stop();
      return;
    }
    final target = revealTarget(full, streaming: widget.message.streaming);
    if (_shown >= target) {
      _ticker?.stop();
      return;
    }
    _ticker ??= createTicker(_tick);
    if (!_ticker!.isActive) {
      _released = null;
      _ticker!.start();
    }
  }

  void _tick(Duration now) {
    final last = _released;
    if (last != null && now - last < revealEvery) return;
    _released = now;
    final target = revealTarget(_full, streaming: widget.message.streaming);
    if (target != _shown) setState(() => _shown = target);
    if (_shown >= target) _ticker?.stop();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final full = _full;
    final text = _shown >= full.length ? full : full.substring(0, _shown);
    final live = message.streaming || _shown < full.length;
    // A picture written as markdown on its own line (`![chart](chart.svg)`, opencode's way) shows as the chat's card.
    final blocks = parseReply(TurnVisuals.liftImages(text));
    // Each block is its own component (prose, document, table, chart, code, plan...), set apart by air, not
    // boxes. A finished reply's blocks rise in one after another with a short, capped stagger; while a reply
    // streams, each new block simply fades in as it starts.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++)
          BlockSpacing(
            key: ValueKey('${message.id}-$i'),
            kind: blockKindOf(blocks[i].lang),
            first: i == 0,
            child: Entrance(
              enabled: _blockEnters.putIfAbsent(i, () => message.animateIn && !MessageArrive.playingAround(context)),
              delay: live ? Duration.zero : Entrance.staggerFor(i),
              child: _block(blocks[i], live && i == blocks.length - 1),
            ),
          ),
      ],
    );
  }

  Widget _block(ReplyBlock b, bool live) {
    if (b.lang == null) {
      // A long, structured answer (owner 2026-10-24, Hark style): a short lead in the bubble, the document as a
      // summary card (serif title, faded preview, tap for the reader). Anything else stays plain readable text.
      final split = longReplySplit(b.text);
      final d = SubMotion.of(context, LuxMotion.base);
      // SubSize, never a zero-length AnimatedSize under Remove animations (CB-12).
      return SubSize(
        duration: LuxMotion.base,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: d,
          switchInCurve: SubMotion.settle,
          switchOutCurve: SubMotion.leave,
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, if (current != null) current]),
          child: split == null
              // A long plain answer folds into a preview with Show more / Open once it has arrived (hark.com style). One
              // that streamed in while you watched stays open, with the control to fold it.
              ? KeyedSubtree(
                  key: const ValueKey('plain'),
                  child: ExpandableText(
                    text: b.text,
                    startOpen: live || widget.message.streaming || widget.message.animateIn,
                    child: ReplyBubble(child: MessageText(b.text, live: live)),
                  ),
                )
              : Column(
                  key: const ValueKey('long'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (split.$1.isNotEmpty) ReplyBubble(child: MessageText(split.$1, live: false)),
                    if (split.$1.isNotEmpty) const SizedBox(height: Lux.blockGap),
                    Align(alignment: AlignmentDirectional.centerStart, child: SummaryCard(split.$2)),
                  ],
                ),
        ),
      );
    }
    Widget child;
    if (!b.complete && live) {
      child = CardShimmer(key: const ValueKey('shimmer'), label: cardKicker(b.lang!));
    } else {
      child = KeyedSubtree(
        key: const ValueKey('card'),
        child: buildOutputCard(b.lang!, b.text, owner: widget.message.id) ??
            // A card whose JSON is broken beyond repair (CB-7) shows what it holds as plain lines, never raw JSON and
            // never nothing. A choices card that can't be read is dropped (its answers mean nothing without the card).
            (cardLanguages.contains(b.lang) ? BrokenCard(lang: b.lang!, body: b.text) : CodeBlock(code: b.text.trimRight(), language: b.lang!)),
      );
    }
    // The shimmer and the finished card cross-fade in one box whose height eases to the card's (the box kept the
    // taller child's height until the fade ended, then snapped to the new one).
    final d = SubMotion.of(context, LuxMotion.base);
    return SubSize(
      duration: LuxMotion.base,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: d,
        switchInCurve: LuxMotion.ease,
        switchOutCurve: SubMotion.leave,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, if (current != null) current],
        ),
        child: child,
      ),
    );
  }
}

/// What a card that could not be drawn still says (CB-7): its words as plain lines (keys and JSON marks left out), or a
/// quiet code block when there are no words to show.
class BrokenCard extends StatelessWidget {
  const BrokenCard({super.key, required this.lang, required this.body});
  final String lang;
  final String body;

  @override
  Widget build(BuildContext context) {
    if (lang == 'choices' || body.trim().isEmpty) return const SizedBox.shrink();
    final text = brokenCardText(body);
    if (text.isEmpty) return CodeBlock(code: body.trimRight(), language: '');
    // One paragraph per line (a single newline is only a soft break in markdown).
    return ReplyBubble(child: MessageText(text.split('\n').join('\n\n')));
  }
}

/// The words in a broken card body, one line per source line: each string value (keys are skipped) joined with " | ".
/// A body that is not JSON at all keeps its own non-empty lines.
String brokenCardText(String body) {
  final str = RegExp(r'"((?:[^"\\]|\\.)*)"(\s*:)?');
  final out = <String>[];
  var sawJson = false;
  for (final line in body.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (RegExp(r'^[\[\]{},]+$').hasMatch(t)) {
      sawJson = true;
      continue;
    }
    final cells = <String>[];
    for (final m in str.allMatches(t)) {
      sawJson = true;
      if (m.group(2) != null) continue; // a key
      final v = m.group(1)!.replaceAll(r'\"', '"').replaceAll(r'\n', ' ').trim();
      if (v.isNotEmpty) cells.add(v);
    }
    // One line of JSON with many rows: split it by its inner brackets so each row reads as its own line.
    if (cells.isNotEmpty) {
      final rows = RegExp(r'\[([^\[\]]*)\]').allMatches(t).toList();
      if (rows.length > 1) {
        for (final r in rows) {
          final rc = [
            for (final m in str.allMatches(r.group(1)!))
              if (m.group(2) == null && m.group(1)!.trim().isNotEmpty) m.group(1)!.replaceAll(r'\"', '"').trim()
          ];
          if (rc.isNotEmpty) out.add(rc.join(' | '));
        }
        continue;
      }
      out.add(cells.join(' | '));
    } else if (!sawJson && !RegExp(r'[{}\[\]]').hasMatch(t)) {
      out.add(t);
    }
  }
  return out.join('\n');
}
