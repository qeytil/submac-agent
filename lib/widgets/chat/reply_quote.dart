import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme.dart';
import '../../ui/haptics.dart';
import '../../ui/tokens.dart';
import '../sub_icon.dart';

/// Replies (owner, 2026-10-24; Grok Bot: "Reply to a specific message… reply quotes show the quoted text and jump to the
/// replied message when clicked"). Swipe a message toward the middle, or hold it and pick Reply: a quoted preview sits
/// above the composer, the sent message shows the quote in its bubble, and a tap on the quote jumps to the original.
///
/// Used by the main Telesia chat, bot chats (the same chat screen) and team chats.

/// What a message replies to: the original's id, who wrote it, and a short quote of it.
class ReplyRef {
  const ReplyRef({required this.id, required this.author, required this.quote, this.convId = ''});
  final String id;
  final String author;
  final String quote;

  /// The chat the original lives in ('' for a team, whose posts carry the link themselves).
  final String convId;

  @override
  bool operator ==(Object other) => other is ReplyRef && other.id == id && other.convId == convId;
  @override
  int get hashCode => Object.hash(id, convId);
}

/// How a reply travels inside a chat message's text. Messages sync as rows with fixed columns (no server change for
/// this), so the link rides at the top of the user's text in a form the model reads naturally:
///
///     [Reply to Telesia · #<id>]
///     > the quoted words, on one line
///
///     the user's own words
///
/// The app shows it as a quote in the bubble; the model sees which message the user means and what it said.
class ReplyCodec {
  ReplyCodec._();

  /// Longest quote kept in the message (the model also has the original in the chat history).
  static const quoteMax = 400;

  static final _head = RegExp(r'^\[Reply to (.+?) · #([\w-]+)\]\n> ?(.*)\n\n?', dotAll: false);

  /// One line, at most [max] characters, markup and card fences dropped.
  static String quoteOf(String text, {int max = quoteMax}) {
    var t = text.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ').replaceAll(RegExp(r'[#*_>`]+'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max).trimRight()}…' : t;
  }

  static String encode(ReplyRef r, String text) {
    final author = r.author.replaceAll(RegExp(r'[\[\]·\n]'), ' ').trim();
    return '[Reply to ${author.isEmpty ? 'a message' : author} · #${r.id}]\n> ${quoteOf(r.quote)}\n\n${text.trim()}';
  }

  /// The reply link at the top of [content] (null when there is none) and the user's own words.
  static ({ReplyRef? ref, String body}) decode(String content, {String convId = ''}) {
    final m = _head.firstMatch(content);
    if (m == null) return (ref: null, body: content);
    return (
      ref: ReplyRef(id: m.group(2)!, author: m.group(1)!, quote: m.group(3)!.trim(), convId: convId),
      body: content.substring(m.end).trimLeft(),
    );
  }

  /// [content] without its reply link.
  static String bodyOf(String content) => decode(content).body;
}

/// Where each message on screen is, by id, so a quote can jump to its original. A message registers while it is built
/// (a lazy list builds only what is near the screen; [jumpToMessage] scrolls until the original is built).
class MessageAnchors {
  MessageAnchors._();
  static final Map<String, BuildContext> _at = {};

  /// The message the last jump landed on: it glows softly for a moment.
  static final flash = ValueNotifier<String?>(null);

  static BuildContext? of(String id) {
    final c = _at[id];
    return c != null && c.mounted ? c : null;
  }
}

/// Wraps one message so quotes can find it, and lets it glow when a jump lands on it.
class MessageAnchor extends StatefulWidget {
  const MessageAnchor({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  State<MessageAnchor> createState() => _MessageAnchorState();
}

class _MessageAnchorState extends State<MessageAnchor> {
  @override
  void initState() {
    super.initState();
    MessageAnchors._at[widget.id] = context;
  }

  @override
  void didUpdateWidget(MessageAnchor old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      if (MessageAnchors._at[old.id] == context) MessageAnchors._at.remove(old.id);
      MessageAnchors._at[widget.id] = context;
    }
  }

  @override
  void dispose() {
    if (MessageAnchors._at[widget.id] == context) MessageAnchors._at.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: MessageAnchors.flash,
      child: widget.child,
      builder: (context, lit, child) => AnimatedContainer(
        duration: SubMotion.of(context, SubMotion.base),
        curve: SubMotion.settle,
        decoration: BoxDecoration(color: lit == widget.id ? p.bubble : p.bubble.withValues(alpha: 0), borderRadius: Radii.rowAll),
        child: child,
      ),
    );
  }
}

/// Scrolls [scroll] until the message [id] is on screen, centres it and lets it glow. The list may be reversed (chats
/// are: the newest message at offset 0, older ones further out). False when the message is no longer in the chat.
Future<bool> jumpToMessage(ScrollController scroll, String id, {bool reversed = true, int maxSteps = 40}) async {
  if (!scroll.hasClients) return false;
  var ctx = MessageAnchors.of(id);
  for (var i = 0; ctx == null && i < maxSteps; i++) {
    final pos = scroll.position;
    // Older messages are further from the start of a reversed list.
    final next = (pos.pixels + pos.viewportDimension * 0.85).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
    if (next == pos.pixels) break;
    scroll.jumpTo(next);
    await SchedulerBinding.instance.endOfFrame;
    ctx = MessageAnchors.of(id);
  }
  if (ctx == null || !ctx.mounted) return false;
  final still = MediaQuery.maybeDisableAnimationsOf(ctx) ?? false;
  await Scrollable.ensureVisible(ctx, alignment: 0.4, duration: still ? Duration.zero : SubMotion.scroll, curve: SubMotion.settle);
  MessageAnchors.flash.value = id;
  unawaited(Future<void>.delayed(const Duration(milliseconds: 1400), () {
    if (MessageAnchors.flash.value == id) MessageAnchors.flash.value = null;
  }));
  return true;
}

/// The quote inside a bubble (or above the composer): a thin bar on the start side, who wrote it, and two lines of it.
/// Tap jumps to the original.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({super.key, required this.author, required this.quote, this.onTap, this.maxLines = 2});
  final String author;
  final String quote;
  final VoidCallback? onTap;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final body = Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Container(width: 2, height: Space.x8, decoration: BoxDecoration(color: p.faint, borderRadius: Radii.smAll)),
      const SizedBox(width: Space.x2),
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
          Text(quote, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
        ]),
      ),
    ]);
    return Semantics(
      button: onTap != null,
      label: 'Reply to $author: $quote',
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('reply-quote'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.only(bottom: Space.x1), child: body),
      ),
    );
  }
}

/// The quote waiting above the composer while you write your reply, with a close button.
class ReplyBar extends StatelessWidget {
  const ReplyBar({super.key, required this.reply, required this.onClose, this.onTap});
  final ReplyRef reply;
  final VoidCallback onClose;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      key: const ValueKey('reply-bar'),
      margin: const EdgeInsetsDirectional.fromSTEB(Space.x2, Space.x1, Space.x2, Space.x1),
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x2, Space.x1, Space.x2),
      decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.fieldAll),
      child: Row(children: [
        SubIcon('reply', size: IconSize.sm, color: p.muted),
        const SizedBox(width: Space.x2),
        Expanded(child: ReplyQuote(author: reply.author, quote: reply.quote, maxLines: 1, onTap: onTap)),
        IconButton(
          key: const ValueKey('reply-bar-close'),
          tooltip: 'Cancel reply',
          visualDensity: VisualDensity.compact,
          onPressed: onClose,
          icon: SubIcon('close', size: IconSize.sm, color: p.muted),
        ),
      ]),
    );
  }
}

/// Swipe a message toward the middle to reply to it (WhatsApp, Telegram, Grok): it follows the finger a little, a reply
/// icon fades in behind it, and past the threshold a light tick fires and it springs back. RTL swipes the other way.
/// Vertical scrolling is untouched (only a mostly horizontal drag counts).
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, required this.onReply, this.enabled = true});
  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  /// How far the message must travel to count as a reply.
  static const double threshold = 56;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  // Made on the first spring-back only; most messages are never swiped.
  AnimationController? _backCtl;
  AnimationController get _back => _backCtl ??= AnimationController(vsync: this, duration: SubMotion.quick)..addListener(_follow);
  double _dx = 0;
  double _from = 0;
  bool _armed = false;

  void _follow() {
    if (!mounted) return;
    setState(() => _dx = _from * (1 - SubMotion.settle.transform(_back.value)));
  }

  @override
  void dispose() {
    _backCtl?.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final delta = rtl ? -d.delta.dx : d.delta.dx;
    setState(() => _dx = (_dx + delta).clamp(0.0, SwipeToReply.threshold * 1.4).toDouble());
    final armed = _dx >= SwipeToReply.threshold;
    if (armed && !_armed) SubHaptics.hold();
    _armed = armed;
  }

  void _end([DragEndDetails? _]) {
    if (!mounted) return;
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    if (SubMotion.still(context)) {
      setState(() => _dx = 0);
      return;
    }
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final p = Palette.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final shown = (_dx / SwipeToReply.threshold).clamp(0.0, 1.0).toDouble();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(alignment: AlignmentDirectional.centerStart, children: [
        if (_dx > 0)
          PositionedDirectional(
            start: Space.x2,
            child: Opacity(opacity: shown, child: SubIcon('reply', size: IconSize.md, color: p.muted)),
          ),
        Transform.translate(offset: Offset(rtl ? -_dx : _dx, 0), child: widget.child),
      ]),
    );
  }
}

/// Gives the messages of a chat list a way to jump to another message of the same list (a reply's quote).
class ChatScrollScope extends InheritedWidget {
  const ChatScrollScope({super.key, required this.controller, required super.child});
  final ScrollController controller;

  static ScrollController? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ChatScrollScope>()?.controller;

  /// Jumps to message [id] in the list around [context] (no list: nothing happens).
  static Future<bool> jump(BuildContext context, String id) {
    final c = of(context);
    if (c == null) return Future.value(false);
    return jumpToMessage(c, id);
  }

  @override
  bool updateShouldNotify(ChatScrollScope old) => old.controller != controller;
}
