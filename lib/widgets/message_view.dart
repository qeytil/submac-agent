import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/bots.dart';
import '../services/error_copy.dart';
import '../services/house_rules.dart';
import '../services/reply_text.dart';
import '../services/rewards.dart';
import '../services/media_store.dart';
import '../services/tools.dart';
import '../screens/preview_screen.dart' show canPreview, openPreview;
import '../services/ai_models.dart';
import '../screens/settings_screen.dart';
import '../screens/bot_activity_screen.dart';
import '../theme.dart';
import 'composer.dart' show turnHeadPad, turnHeadHeight;
import 'logo.dart';
import 'motion.dart';
import 'audio_card.dart';
import 'media_cards.dart';
import 'page_cards.dart';
import 'chat_logic.dart';
import 'chat_extras.dart' show FollowUpChips;
import 'media_view.dart';
import 'output_cards.dart';
import 'hark_cards.dart';
import 'reply_blocks.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';
import 'chat/blocks.dart';
import 'chat/message_actions.dart';
import 'chat/reply_quote.dart';
import '../services/no_reply.dart';
import '../ui/i18n.dart';

/// The reply whose actions (Copy, Share…) are showing; tapping another reply moves them there.
final selectedReply = ValueNotifier<String?>(null);

/// Starts a reply to [m] in the open chat: the quote waits above the composer (owner 2026-10-24).
void startReply(BuildContext context, ChatMessage m) {
  final state = context.read<AppState>();
  final bot = Bots.I.byConv(state.currentId);
  final author = m.role == 'user' ? 'You' : (bot?.name ?? 'Telesia');
  final body = ReplyCodec.bodyOf(m.content);
  if (body.trim().isEmpty) return;
  selectedReply.value = null;
  state.replyDraft.value = ReplyRef(id: m.id, author: author, quote: ReplyCodec.quoteOf(body, max: 280), convId: state.currentId ?? '');
}

/// Your own message: a soft filled bubble on the end side (answers have none). A short message is set in the serif
/// (it reads like the question at the top of a page); a long one in the reading sans.
/// Tap for a quiet Copy · Edit row, long-press for the sheet.
/// Shown when Edit and resend is tapped while a run is going in this chat (CB-13).
const editBusyNote = 'Telesia is still answering. Stop it first, then edit your message.';

class UserMessageView extends StatelessWidget {
  final ChatMessage message;
  const UserMessageView({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // A reply carries its quote at the top of the message (ReplyCodec): shown as a quote above your words.
    final decoded = ReplyCodec.decode(message.content);
    final quote = decoded.ref;
    final text = decoded.body;
    final serif = quote == null && text.length <= Lux.promptSerifMax && !text.contains('\n\n');
    final style = serif
        ? Brand.serif(size: Lux.prompt, color: p.text, height: 1.3)
        : TextStyle(fontSize: Lux.read, height: Lux.readHeight, color: p.text);
    // Arrives like every new message (fade, slight rise and scale, 1 s); history never animates.
    return MessageArrive(
      key: ValueKey('in-${message.id}'),
      id: message.id,
      enabled: message.animateIn,
      mine: true,
      onDone: () => message.animateIn = false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Lux.promptInset, Lux.turnGap / 2, Lux.gutter, Space.x3),
        child: ValueListenableBuilder<String?>(
          valueListenable: selectedReply,
          builder: (context, sel, _) {
            final open = sel == message.id;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (message.attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.x2),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: Space.x2,
                      runSpacing: Space.x2,
                      children: [for (final a in message.attachments) AttachmentChip(attachment: a, siblings: message.attachments)],
                    ),
                  ),
                if (text.isNotEmpty)
                  SwipeToReply(
                    onReply: () => startReply(context, message),
                    child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      FocusScope.of(context).unfocus();
                      selectedReply.value = open ? null : message.id;
                    },
                    onLongPress: () => _menu(context),
                    // Your words sit in a soft filled bubble on the end side; Telesia's answers stay free-standing type,
                    // so who said what reads at a glance.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width * 0.82).clamp(0, 560).toDouble()),
                      child: Container(
                        key: ValueKey('user-bubble-${message.id}'),
                        padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3 - 2, Space.x4, Space.x3 - 2),
                        decoration: BoxDecoration(
                          color: p.bubble,
                          borderRadius: const BorderRadiusDirectional.only(
                            topStart: Radius.circular(20),
                            topEnd: Radius.circular(20),
                            bottomStart: Radius.circular(20),
                            bottomEnd: Radius.circular(6),
                          ).resolve(Directionality.of(context)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          if (quote != null)
                            ReplyQuote(author: quote.author, quote: quote.quote, onTap: () => ChatScrollScope.jump(context, quote.id)),
                          Text(text, textAlign: TextAlign.start, textDirection: textDirOf(text), style: style),
                        ]),
                      ),
                    ),
                  ),
                  ),
                // One fold for the action row (it used to fade and rise while AnimatedSize grew it, and vanished at
                // once on close before the gap closed).
                SubFold(
                  open: open,
                  alignment: AlignmentDirectional.topEnd,
                  child: MessageActionRow(end: true, actions: _actionList(context), onMore: () => _menu(context)),
                ),
                if (message.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x1),
                    child: Text(message.error!, style: AppText.microStyle.copyWith(color: p.accent)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<MessageAction> _actionList(BuildContext context) => [
        MessageAction('Reply', 'reply', () => startReply(context, message)),
        MessageAction('Copy', 'copy', () {
          Clipboard.setData(ClipboardData(text: ReplyCodec.bodyOf(message.content)));
          selectedReply.value = null;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied'))));
        }),
        MessageAction('Edit and resend', 'edit', () {
          selectedReply.value = null;
          _edit(context);
        }),
      ];

  void _menu(BuildContext context) {
    showMessageActions(context, preview: ReplyCodec.bodyOf(message.content), actions: [
      ..._actionList(context),
      MessageAction('Select text', 'select', () => showSelectableText(context, ReplyCodec.bodyOf(message.content))),
    ]);
  }

  Future<void> _edit(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    // CB-13: while Telesia is still answering, an edit cannot go out. Say so instead of a tap that does nothing.
    void busyNote() => messenger.showSnackBar(SnackBar(content: Text(tr(editBusyNote))));
    if (!state.canEditHere) return busyNote();
    final ctrl = TextEditingController(text: ReplyCodec.bodyOf(message.content));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(controller: ctrl, maxLines: 8, minLines: 1, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('Send'))),
        ],
      ),
    );
    // Disposed after the dialog's closing animation, which still reads it.
    Future.delayed(const Duration(seconds: 1), ctrl.dispose);
    if (result != null && result.trim().isNotEmpty) {
      // A run may have started while the box was open (a reminder, a bot wake): nothing went out, and it says so.
      final sent = await state.editAndResend(message, result);
      if (!sent && !state.canEditHere) busyNote();
    }
  }
}

class AttachmentChip extends StatelessWidget {
  final Attachment attachment;
  final VoidCallback? onRemove;

  /// The other files of the same message, so the viewer can swipe between its pictures.
  final List<Attachment> siblings;
  const AttachmentChip({super.key, required this.attachment, this.onRemove, this.siblings = const []});

  static String _extLabel(String name) {
    final e = (name.contains('.') ? name.split('.').last : 'file').toUpperCase();
    return e.length > 4 ? e.substring(0, 4) : e;
  }

  /// Opens what the user sent: pictures in the zoomable viewer (swipe between the message's pictures), other files
  /// in the preview. A file sent from another phone comes from the account; only one gone from both says so.
  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final f = await MediaStore.I.attachmentFile(attachment);
    if (!context.mounted) return;
    if (f == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('This file isn\'t on this phone or in your account any more.')));
      return;
    }
    if (attachment.isImage) {
      final paths = <String>[];
      for (final a in siblings.where((a) => a.isImage)) {
        if (identical(a, attachment)) {
          paths.add(f.path);
          continue;
        }
        final g = await MediaStore.I.attachmentFile(a);
        if (g != null) paths.add(g.path);
      }
      if (!context.mounted) return;
      openImageViewer(context, f.path, gallery: paths.length > 1 ? paths : null);
    } else if (canPreview(f.path)) {
      await openPreview(context, f.path);
    } else {
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final local = attachment.localPath;
    final localFile = local != null && local.isNotEmpty && File(local).existsSync() ? File(local) : null;
    Widget child;
    if (attachment.isImage && attachment.bytes != null) {
      child = ClipRRect(
        borderRadius: Radii.rowAll,
        child: Image.memory(attachment.bytes!, width: 120, height: 120, fit: BoxFit.cover, gaplessPlayback: true),
      );
    } else if (attachment.isImage && localFile != null) {
      child = ClipRRect(
        borderRadius: Radii.rowAll,
        child: Image.file(localFile, width: 120, height: 120, fit: BoxFit.cover, frameBuilder: subImageFade),
      );
    } else if (attachment.isImage && attachment.path != null) {
      // Still on its way from the account (the chat fetches pictures as it opens).
      child = const MediaPlaceholder(width: 120, height: 120);
    } else {
      final size = attachment.bytes?.length ?? (localFile?.lengthSync());
      final meta = [kindLabel(attachment.name), if (size != null) sizeLabel(size)].join(' · ');
      // A file you attached: the type in a quiet mono and its name, on the shared surface tone, no outline.
      child = Container(
        width: 220,
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x2, Space.x3, Space.x2),
        decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.rowAll),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                _extLabel(attachment.name),
                style: Brand.mono(size: 11, color: p.muted).copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: Space.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.text)),
                  Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.captionStyle.copyWith(color: p.faint)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (onRemove == null) {
      return Semantics(
        button: true,
        label: attachment.isImage ? 'Picture you sent. Tap to view' : '${attachment.name}. Tap to open',
        child: Pressable(onTap: () => _open(context), child: child),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -6,
          top: -6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
              padding: const EdgeInsets.all(3),
              child: SubIcon('close', size: 14, color: p.bg),
            ),
          ),
        ),
      ],
    );
  }
}

class AssistantMessageView extends StatelessWidget {
  final ChatMessage message;
  final Map<String, ChatMessage> toolResults;
  final bool showActions;
  final bool isLast;
  /// This reply comes after a tool step of the same task.
  final bool midTask;
  /// The steps the task took before this final answer (shown folded as "Worked for 1m 12s · 5 steps").
  final List<StepLine> workSteps;
  final Duration? worked;

  /// The tool steps of the turn this reply ends (shown folded as "How I did it" when no "Worked for" fold is shown).
  final List<TurnStep> turnSteps;

  /// The page builds of this reply's turn (one card per page per turn). Null: plan from this message alone.
  final PageBuildPlan? pagePlan;

  /// This reply's turn is still working (its page card keeps building; no page preview shows yet).
  final bool turnRunning;

  /// The user asked to see the steps in this turn ("show steps"): narration and step rows show for it.
  final bool stepsAsked;
  const AssistantMessageView({
    super.key,
    this.stepsAsked = false,
    this.pagePlan,
    this.turnRunning = false,
    this.midTask = false,
    this.workSteps = const [],
    this.worked,
    this.turnSteps = const [],
    required this.message,
    required this.toolResults,
    required this.showActions,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final calls = message.toolCalls ?? const <ToolCall>[];
    // Steps, plans and narration stay out of the chat (owner 2026-10-24) unless the user asked for them.
    final steps = context.select<AppState, bool>((s) => s.showSteps) || stepsAsked;
    // Thinking lives in the turn's activity view (owner 2026-11-03), in the chat only when steps were asked for.
    if (message.name == 'reasoning') return steps ? ThinkingBlock(message: message) : const SizedBox.shrink();
    final busy = context.select<AppState, bool>((s) => s.busy);
    // Without a turn plan (a lone message), the message's own page writes are planned and the chat's busy state
    // stands in for the turn's.
    final plan = pagePlan ?? PageBuildPlan.of(calls);
    final pageRunning = pagePlan != null ? turnRunning : busy;
    final visible = <Widget>[];
    for (final c in calls) {
      final res = toolResults[c.id]?.content ?? '';
      // The user's own AI models (ai_call): a placeholder while it runs, then the media card.
      if (AiMediaCall.shows(c.name, toolResults[c.id]?.content)) {
        visible.add(AiMediaCall(callId: c.id, arguments: c.arguments, result: toolResults[c.id]?.content));
      } else if (res.startsWith('IMAGE_SAVED ')) {
        visible.add(ImageResultCard(path: res.substring(12).split('\n').first.trim()));
      } else if (res.startsWith('AUDIO_SAVED ')) {
        visible.add(AudioCard(res.substring(12).split('\n').first.trim()));
      } else if (res.startsWith('VIDEO_SAVED ')) {
        visible.add(MediaCard(res.substring(12).split('\n').first.trim()));
      } else if (plan.ownedBy(c.id) != null) {
        // A page being written: ONE build card per page per turn (phase, time, lines, the source as it arrives). It
        // settles into Page built / Open page only when the whole task has finished.
        final b = plan.ownedBy(c.id)!;
        visible.add(PageBuildCard(
          key: ValueKey('page-build-${c.id}'),
          call: c,
          path: b.path,
          source: b.source,
          result: toolResults[b.last.id]?.content,
          running: pageRunning,
        ));
      } else if (plan.feeds(c.id)) {
        // A later write or append of a page whose card is above: it feeds that card and shows nothing of its own.
      } else if (steps) {
        visible.add(ToolCallCard(call: c, result: toolResults[c.id]));
      }
    }
    // A short line the model writes before a step ("Checking flight prices now.") is live progress: it shows as a
    // quiet line, not a reply bubble. Text that streams mid-task shows as it arrives (it may be the answer);
    // if a step follows, it settles into a quiet line.
    final narration = !steps && calls.isNotEmpty;
    // No preview of a page while its task still runs, and never a second card for a page that has its build card.
    // A bot that chose not to speak ([no reply], or an old @silent tag) shows nothing; a stray tag after real words is cut.
    final text = NoReply.clean(hidePageCards(_dropShownMedia(_stripThinking(message.content), toolResults), running: pageRunning, plan: plan));
    // Mid-task text that reads like working notes (tool names) waits until it is clearly the answer.
    final hold = !steps && message.streaming && midTask && _workingNotes.hasMatch(text);
    final showText = text.isNotEmpty && !narration && !hold;
    // A line written before a step is narration: hidden unless the user asked to see the steps (only the status line
    // above the reply shows progress).
    final note = steps && narration && text.isNotEmpty && plainNarration(text) ? text : '';
    if (!showText && note.isEmpty && visible.isEmpty && message.error == null) return const SizedBox.shrink();
    if (!showText && visible.isEmpty && message.error == null) {
      return _arrive(Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter, Space.x1, Lux.gutter, Space.x1),
        child: Text(
          note,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textDirection: textDirOf(note),
          style: AppText.metaStyle.copyWith(color: p.faint),
        ),
      ));
    }
    final finished = showActions && !message.streaming && showText;
    // Only the likely replies to a question wait under the last answer. Copy, Read aloud, Share and Try again fade in after a tap; the long-press
    // sheet has everything, with the steps the task took and replies to tap.
    return _arrive(ValueListenableBuilder<String?>(
      valueListenable: selectedReply,
      builder: (context, sel, _) {
        final open = finished && sel == message.id;
        return SwipeToReply(
          enabled: finished,
          onReply: () => startReply(context, message),
          child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: finished
              ? () {
                  FocusScope.of(context).unfocus();
                  selectedReply.value = open ? null : message.id;
                }
              : null,
          onLongPress: finished ? () => _sheet(context, text) : null,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter, Space.x2, Lux.gutter, Space.x2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showText) ReplyView(message: message, text: text == message.content ? null : text),
                for (final w in visible) BlockSpacing(kind: BlockKind.media, child: w),
                if (message.error != null) _CalmErrorCard(raw: message.error!, isLast: isLast),
                // The last answer asks something: its likely replies wait under it, one tap each.
                if (finished && isLast && message.error == null)
                  Builder(builder: (context) {
                    // Only busy / waiting asks matter here (it watched the whole state and rebuilt on every streamed word).
                    final hold = context.select<AppState, bool>((s) => s.busy || s.asks.any((a) => a.convId.isEmpty || a.convId == s.currentId)); // CB-41: this chat's asks only
                    if (hold) return const SizedBox.shrink();
                    final state = context.read<AppState>();
                    return FollowUpChips(options: suggestFollowUps(text), onPick: (t) => state.send(t, const []));
                  }),
                SubFold(
                  open: open,
                  child: MessageActionRow(actions: _actionList(context, text), onMore: () => _sheet(context, text)),
                ),
              ],
            ),
          ),
          ),
        );
      },
    ));
  }

  /// A reply (Telesia's or a bot's) arrives like every new message: once, the moment its first words show, and only
  /// when it is new this session. It mounts with the content (not with the empty streaming message), so the second of
  /// arrival is seen; streamed words after that never restart it.
  Widget _arrive(Widget child) =>
      MessageArrive(key: ValueKey('arrive-${message.id}'), id: message.id, enabled: message.animateIn, child: child);

  List<MessageAction> _actionList(BuildContext context, String text) {
    final state = context.read<AppState>();
    final plain = _plain(message.content);
    void done() => selectedReply.value = null;
    return [
      MessageAction('Reply', 'reply', () => startReply(context, message), inline: false),
      MessageAction('Copy', 'copy', () {
        Clipboard.setData(ClipboardData(text: plain));
        done();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied'))));
      }),
      MessageAction(ReadAloud.isReading(message.id) ? 'Stop reading' : 'Read aloud', ReadAloud.isReading(message.id) ? 'speaker_stop' : 'speaker',
          () => ReadAloud.toggle(message.id, plain)),
      MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(text: withMadeBy(plain, Bots.I.byConv(state.currentId))))),
      if (isLast) MessageAction('Try again', 'refresh', () {
        done();
        state.regenerate();
      }),
    ];
  }

  /// The long-press sheet: every action, then the steps the task took, then replies to tap.
  void _sheet(BuildContext context, String text) {
    final state = context.read<AppState>();
    final bot = Bots.I.byConv(state.currentId);
    final steps = workSteps.isNotEmpty
        ? workSteps
        : [
            for (final t in turnSteps)
              if (!hiddenStepNames.contains(t.name)) StepLine(AgentTools.describe(t.name, _argsOf(t.arguments), done: true), failed: t.failed)
          ];
    final followUps = isLast && message.error == null ? suggestFollowUps(text) : const <String>[];
    showMessageActions(
      context,
      actions: [
        ..._actionList(context, text),
        MessageAction('Select text', 'select', () => showSelectableText(context, _plain(message.content))),
        // Plan 5.2: a bot's steps hide behind one question.
        if (bot != null)
          MessageAction('How did you do it?', 'steps', () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => BotActivityScreen(bot: bot, find: _plain(message.content))));
          }),
      ],
      extra: [
        if (steps.isNotEmpty && bot == null) _StepsSection(steps: steps, worked: worked),
        if (followUps.isNotEmpty) _RepliesSection(options: followUps, onPick: (t) => state.send(t, const [])),
      ],
    );
  }

  static Map<String, dynamic> _argsOf(String raw) {
    try {
      final d = jsonDecode(raw.trim().isEmpty ? '{}' : raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return const {};
  }

  static final _workingNotes = RegExp(
      r'\b(browser|phone|web|fetch|app|apps|mcp|run|read|write|make|list|knowledge|docs|bot|office|open|ask)_[a-z_]+\b|\b(tool call|function call|call the tool)\b',
      caseSensitive: false);
  static final _think = RegExp(r'<think(ing)?>[\s\S]*?(</think(ing)?>|$)', caseSensitive: false);
  /// A sound, picture or video a tool step already shows as a card is never shown a second time,
  /// even when the model repeats it in its reply as a file card, a link or a bare path.
  static String _dropShownMedia(String t, Map<String, ChatMessage> results) {
    if (t.isEmpty) return t;
    final shown = <String>{};
    for (final r in results.values) {
      final c = r.content;
      final m = RegExp(r'^(IMAGE|AUDIO|VIDEO)_SAVED (.+)').firstMatch(c);
      if (m != null) shown.add(m.group(2)!.split('\n').first.trim());
      final card = AiModels.readCard(c);
      if (card != null && card['files'] is List) shown.addAll([for (final f in card['files'] as List) '$f']);
    }
    if (shown.isEmpty) return t;
    final names = {for (final s in shown) s.split('/').last};
    bool hit(String body) => shown.any(body.contains) || names.any((n) => n.length > 6 && body.contains(n));
    var s = t.replaceAllMapped(RegExp(r'```[a-zA-Z_]*\n([\s\S]*?)```'), (m) => hit(m.group(1)!) ? '' : m.group(0)!);
    s = s.replaceAllMapped(RegExp(r'!?\[[^\]]*\]\(([^)]+)\)'), (m) => hit(m.group(1)!) ? '' : m.group(0)!);
    s = s.split('\n').where((l) => !(l.trim().isNotEmpty && hit(l) && l.trim().split(' ').length <= 2)).join('\n');
    return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static String _stripThinking(String t) {
    var s = t.contains('<think') ? t.replaceAll(_think, '').trim() : t;
    // Tool calls some models write as text are run as real steps; never show the markup.
    final cut = RegExp(r'<tool_call|<function=|<\|tool_call|<function_call').firstMatch(s);
    if (cut != null) s = s.substring(0, cut.start).trim();
    return s;
  }

}

/// Plan 2.4: a result shared out of the app from a bot's chat carries a small footer naming the bot, with its public
/// page (published or shared bots) or the sharer's invite link, so a new person who taps it counts for the sharer.
String withMadeBy(String text, Bot? bot) {
  if (bot == null || text.trim().isEmpty) return text;
  final code = Rewards.I.myCode;
  final link = bot.storeId.isNotEmpty
      ? Rewards.I.botLink(bot.storeId)
      : code != null
          ? Rewards.linkFor(code)
          : 'https://telesia.site';
  return '${text.trimRight()}\n\n— Made by ${bot.name} on Telesia · $link';
}

/// A message from the Telesia team (sent from the dashboard "in chat"). Also listed in "From Telesia".
class TeamMessageCard extends StatelessWidget {
  const TeamMessageCard({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MessageArrive(
      id: message.id,
      enabled: message.animateIn,
      child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: p.accentWash,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.verified_rounded, size: 16, color: p.text),
            const SizedBox(width: 6),
            Text('Telesia team', style: AppText.sectionStyle.copyWith(color: p.text)),
          ]),
          const SizedBox(height: 8),
          ReplyView(message: message),
        ]),
      ),
    ),
    );
  }
}

/// The reply as a person would copy it: prose and each card's words, no card JSON or markup (CB-8, see reply_text.dart).
String _plain(String t) => replyPlain(t);

/// Right-to-left for text that is mostly Arabic script (Arabic, Persian, Urdu), left-to-right for everything else
/// (Somali, English...). The majority of strong letters decides, not the first one (CB-9).
TextDirection textDirOf(String t) => majorityDir(t);

/// A progress line is shown only when it reads like a person talking: no element numbers, code, ids or tool names.
bool plainNarration(String t) {
  if (t.length > 400) return false;
  return !RegExp(r'\[\d+\]|[{}<>`]|\b[a-z]+_[a-z_]+\b|\b(tool|function|json|api|mcp|token|args?)\b|https?://', caseSensitive: false)
      .hasMatch(t);
}

/// The steps of the task that ended in the reply at [idx] (tool steps since the user's last message), in plain words.
List<StepLine> stepsBefore(List<ChatMessage> visible, int idx, Map<String, ChatMessage> results, String Function(String, Map<String, dynamic>) label) {
  final out = <StepLine>[];
  for (var k = idx - 1; k >= 0; k--) {
    final m = visible[k];
    if (m.role == 'user') break;
    final calls = m.toolCalls;
    if (m.role != 'assistant' || calls == null) continue;
    for (final c in calls.reversed) {
      if (c.name == 'say' || c.name == 'more_tools') continue;
      Map<String, dynamic> args = const {};
      try {
        final d = jsonDecode(c.arguments.trim().isEmpty ? '{}' : c.arguments);
        if (d is Map) args = Map<String, dynamic>.from(d);
      } catch (_) {}
      var l = AgentTools.describe(c.name, args, done: true);
      if (l == 'Done') l = label(c.name, args);
      out.add(StepLine(l, failed: AppState.stepFailed(results[c.id]?.content ?? '')));
    }
    if (out.length >= 40) break;
  }
  return out.reversed.toList();
}

/// One finished step of a task, in plain words.
class StepLine {
  const StepLine(this.label, {this.failed = false});
  final String label;
  final bool failed;
}

/// "Worked for 1m 12s · 5 steps" over a task's final answer; tap to see the steps.
class WorkSummary extends StatefulWidget {
  const WorkSummary({super.key, required this.steps, this.worked, this.head = false});
  final List<StepLine> steps;
  final Duration? worked;
  /// Shown at the top of the reply, where the live task line was (same geometry), with a small tick in the
  /// mark's place: the line settles into "Worked for ..." without moving anything below it.
  final bool head;

  @override
  State<WorkSummary> createState() => _WorkSummaryState();
}

class _WorkSummaryState extends State<WorkSummary> {
  bool _open = false;

  static String dur(Duration d) {
    final m = d.inMinutes, s = d.inSeconds % 60;
    if (m == 0) return '${d.inSeconds < 1 ? 1 : d.inSeconds}s';
    return s == 0 ? '${m}m' : '${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = widget.steps.length;
    final w = widget.worked;
    final head = w != null ? 'Worked for ${dur(w)} · $n ${n == 1 ? 'step' : 'steps'}' : '$n ${n == 1 ? 'step' : 'steps'}';
    final col = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () {
          setState(() => _open = !_open);
        },
        child: widget.head
            ? SizedBox(
                height: turnHeadHeight,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  // The live line's status word sits inside a quiet pill (12px inset from the start
                  // edge); the finished line's words take the same inset, so the handover from the
                  // pill to "Worked for ..." never moves the text.
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 12),
                    child: Text(head, style: TextStyle(color: p.muted, fontSize: AppText.meta)),
                  ),
                ]),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(head, style: TextStyle(color: p.muted, fontSize: AppText.meta)),
                ]),
              ),
      ),
      SubFold(
        open: _open,
        child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 2, bottom: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final st in widget.steps)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Text(st.failed ? '${st.label} (didn\'t work)' : st.label,
                              style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
                        ),
                      ]),
                    ),
                ]),
              ),
      ),
    ]);
    return widget.head ? Padding(padding: turnHeadPad, child: col) : col;
  }
}

/// The phone's voice, behind a seam so tests can use a fake one.
abstract class Speaker {
  Future<void> stop();

  /// Speaks [text] and completes when it has been read out (or stopped).
  Future<void> speak(String text);

  /// Switches to [lang] ('so', 'ar', 'en'); false when the phone has no voice for it (the current voice stays).
  Future<bool> setLanguage(String lang);
}

class _TtsSpeaker implements Speaker {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  static const _locales = {'so': ['so-SO', 'so'], 'ar': ['ar-SA', 'ar', 'ar-EG'], 'en': ['en-US', 'en-GB', 'en']};

  Future<void> _init() async {
    if (_ready) return;
    _ready = true;
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  @override
  Future<void> speak(String text) async {
    await _init();
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  @override
  Future<bool> setLanguage(String lang) async {
    await _init();
    for (final l in _locales[lang] ?? [lang]) {
      try {
        final ok = await _tts.isLanguageAvailable(l);
        if (ok == true || ok == 1) {
          await _tts.setLanguage(l);
          return true;
        }
      } catch (_) {}
    }
    return false;
  }
}

/// Free, on-device read aloud using Android's built-in voices. One message reads at a time. The whole message is read,
/// in pieces of up to 3,900 characters one after another, each in its own language when the phone has that voice (CB-28:
/// no language was set and everything after 3,900 characters was cut).
class ReadAloud {
  ReadAloud._();

  @visibleForTesting
  static Speaker speaker = _TtsSpeaker();

  /// The message being read right now.
  static final reading = ValueNotifier<String?>(null);

  static int _gen = 0;

  static bool isReading(String id) => reading.value == id;

  static String _plain(String md) => md
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' (code) ')
      .replaceAll(RegExp(r'[#*_`>|]'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1] ?? '');

  static Future<void> toggle(String id, String text) async {
    final gen = ++_gen;
    if (reading.value == id) {
      reading.value = null;
      await speaker.stop();
      return;
    }
    await speaker.stop();
    reading.value = id;
    String? lang;
    try {
      for (final (piece, l) in speechChunks(_plain(text))) {
        if (gen != _gen) return; // stopped, or another message started
        if (l != lang) {
          lang = l;
          await speaker.setLanguage(l);
        }
        if (gen != _gen) return;
        await speaker.speak(piece);
      }
    } finally {
      if (gen == _gen && reading.value == id) reading.value = null;
    }
  }
}

/// The steps a finished task took, in plain words (in the long-press sheet).
class _StepsSection extends StatelessWidget {
  const _StepsSection({required this.steps, this.worked});
  final List<StepLine> steps;
  final Duration? worked;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = steps.length;
    final w = worked;
    final head = w != null ? 'How I did it · ${_WorkSummaryState.dur(w)} · $n ${n == 1 ? 'step' : 'steps'}' : 'How I did it · $n ${n == 1 ? 'step' : 'steps'}';
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x4, Space.x4, Space.x1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(head, style: AppText.sectionStyle.copyWith(color: p.muted)),
        const SizedBox(height: Space.x2),
        for (final st in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x1),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(st.failed ? '${st.label} (didn\'t work)' : st.label, style: AppText.metaStyle.copyWith(color: p.text)),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// Replies to tap, worked out from the answer (in the long-press sheet).
class _RepliesSection extends StatelessWidget {
  const _RepliesSection({required this.options, required this.onPick});
  final List<String> options;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(0, Space.x4, 0, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x1),
          child: Text('Quick replies', style: AppText.sectionStyle.copyWith(color: p.muted)),
        ),
        for (final o in options)
          InkWell(
            borderRadius: Radii.fieldAll,
            onTap: () {
              Navigator.pop(context);
              onPick(o);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x3),
              child: Row(children: [
                SubIcon('reply', size: IconSize.lg, color: p.muted),
                const SizedBox(width: Space.x4),
                Expanded(child: Text(o, style: AppText.bodyStyle.copyWith(color: p.text))),
              ]),
            ),
          ),
      ]),
    );
  }
}

class ToolCallCard extends StatefulWidget {
  final ToolCall call;
  final ChatMessage? result;
  const ToolCallCard({super.key, required this.call, this.result});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _open = false;

  Map<String, dynamic> get _args {
    try {
      final d = jsonDecode(widget.call.arguments);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return {};
  }

  String get _raw {
    final a = _args;
    switch (widget.call.name) {
      case 'run_shell':
        return '\$ ${a['command'] ?? ''}';
      case 'read_file':
      case 'write_file':
      case 'append_file':
      case 'edit_file':
      case 'list_dir':
      case 'delete_file':
        return '${widget.call.name} ${a['path'] ?? '.'}';
      case 'fetch_url':
        return 'GET ${a['url'] ?? ''}';
      case 'web_search':
        return 'search "${a['query'] ?? ''}"';
      case 'bash':
        return '\$ ${a['command'] ?? ''}';
      case 'read':
      case 'write':
      case 'edit':
        return '${widget.call.name} ${a['filePath'] ?? a['path'] ?? ''}';
      case 'webfetch':
        return 'GET ${a['url'] ?? ''}';
      default:
        return '${widget.call.name} ${widget.call.arguments}';
    }
  }

  bool get _failed {
    final r = widget.result?.content ?? '';
    return r.startsWith('Error') || r.startsWith('The user said no') || RegExp(r'^exit_code: [1-9-]').hasMatch(r);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final done = widget.result != null;
    final label = ocStepLabel(widget.call.name, _args) ?? AgentTools.describe(widget.call.name, _args, done: done);
    final res = widget.result?.content ?? '';
    final image = res.startsWith('IMAGE_SAVED ') ? res.substring(12).split('\n').first.trim() : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () {
              setState(() => _open = !_open);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
              child: Row(
                children: [
                  // A fine ring while the step runs; nothing once it is done (no dots: the words say how it went).
                  if (!done) ...[
                    const SizedBox(width: 18, child: Center(child: RedDot(size: 12, animate: true))),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      _failed && done ? '$label (didn\'t work)' : label,
                      style: TextStyle(color: done ? p.muted : p.text, fontSize: AppText.body),
                    ),
                  ),
                  Text(_open ? 'Hide' : 'Details', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                ],
              ),
            ),
          ),
          SubFold(
            open: _open,
            alignment: Alignment.topCenter,
            child: Container(
                    margin: const EdgeInsetsDirectional.only(start: 24, top: 2, bottom: 6),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '$_raw\n\n${widget.result?.content ?? 'Running…'}',
                        style: Brand.mono(size: 12.5, color: Palette.of(context).muted, height: 1.45),
                      ),
                    ),
                  ),
          ),
          if (image != null) ImageResultCard(path: image),
          if (widget.call.name == 'web_search' && done && !_failed) _Sources(result: res),
        ],
      ),
    );
  }
}

/// Small source chips under a web search, so the user sees where answers come from.
class _Sources extends StatelessWidget {
  final String result;
  const _Sources({required this.result});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    List results = const [];
    try {
      final j = jsonDecode(result);
      if (j is Map && j['results'] is List) results = j['results'] as List;
    } catch (_) {}
    if (results.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 24, bottom: 4),
      child: SizedBox(
        height: 34,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: results.length > 8 ? 8 : results.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (c, i) {
            final r = results[i] as Map;
            final url = (r['url'] ?? '').toString();
            final host = (Uri.tryParse(url)?.host ?? '').replaceFirst('www.', '');
            return Pressable(
              onTap: () {
                final u = Uri.tryParse(url);
                if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Favicon(host: host),
                  const SizedBox(width: 6),
                  Text(host.isEmpty ? 'source' : host, style: TextStyle(color: p.text, fontSize: AppText.micro)),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}


/// A failure in plain words: what happened, one button to fix it, the technical text tucked away.
class _CalmErrorCard extends StatefulWidget {
  const _CalmErrorCard({required this.raw, required this.isLast});
  final String raw;
  final bool isLast;

  @override
  State<_CalmErrorCard> createState() => _CalmErrorCardState();
}

class _CalmErrorCardState extends State<_CalmErrorCard> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    // The app's own words in the app's language, chosen by the error's code (CB-27); the raw text only under Details.
    final e = ErrorCopy.explain(widget.raw);
    String b(String en) => ErrorCopy.button(en);
    Widget button(String label, VoidCallback onTap, {bool strong = false}) => TextButton(
          style: TextButton.styleFrom(
            foregroundColor: strong ? p.accent : p.muted,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 30),
            textStyle: TextStyle(fontSize: AppText.meta, fontWeight: strong ? FontWeight.w600 : FontWeight.w500),
          ),
          onPressed: () {
            onTap();
          },
          child: Text(label),
        );
    final actions = <Widget>[
      if (widget.isLast && (e.action == 'retry' || e.action == 'settings'))
        button(b('Try again'), () => state.regenerate(), strong: e.action == 'retry'),
      if (e.action == 'settings')
        button(b('Open Settings'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())), strong: true),
      if (e.action == 'newchat') button(b('New chat'), () => state.newChat(), strong: true),
      button(b(_details ? 'Hide details' : 'Details'), () => setState(() => _details = !_details)),
    ];
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsetsDirectional.fromSTEB(0, 10, 6, 4),
      // A soft wash, no border: a problem is said plainly without a box shouting it.
      decoration: const BoxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(e.title, style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600))),
          ]),
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 3, end: 6),
            child: Text(e.body, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
          ),
          SubFold(
            open: _details,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(top: 6, end: 6),
              child: SelectableText(HouseRules.scrub(e.raw), style: Brand.mono(size: 11.5, color: p.muted)),
            ),
          ),
          // The buttons' own inner padding lines their words up under the text.
          Transform.translate(
            offset: Offset(Directionality.of(context) == TextDirection.rtl ? 10 : -10, 0),
            child: Wrap(children: actions),
          ),
        ],
      ),
    );
  }
}


/// opencode's own tools, labelled the way opencode's desktop chat labels them (owner, 2026-11-03). Null for others.
String? ocStepLabel(String name, Map<String, dynamic> a) {
  String file() {
    final f = '${a['filePath'] ?? a['path'] ?? ''}';
    final i = f.lastIndexOf('/');
    return i >= 0 && i < f.length - 1 ? f.substring(i + 1) : f;
  }

  switch (name) {
    case 'bash':
      final d = '${a['description'] ?? ''}'.trim();
      final c = '${a['command'] ?? ''}'.trim();
      return d.isNotEmpty ? d : '\$ $c';
    case 'read':
      return 'Read ${file()}';
    case 'write':
      return 'Write ${file()}';
    case 'edit':
    case 'multiedit':
    case 'patch':
      return 'Edit ${file()}';
    case 'list':
      return 'List ${a['path'] ?? '.'}';
    case 'glob':
      return 'Glob "${a['pattern'] ?? ''}"';
    case 'grep':
      return 'Grep "${a['pattern'] ?? ''}"';
    case 'webfetch':
      return 'Fetch ${a['url'] ?? ''}';
    case 'websearch':
      return 'Search "${a['query'] ?? ''}"';
    case 'todowrite':
    case 'todoread':
      return 'To-dos';
    case 'task':
      return 'Task: ${a['description'] ?? ''}';
    case 'skill':
      return 'Skill ${a['name'] ?? ''}';
    case 'question':
      return 'Question';
  }
  return null;
}

/// opencode's thinking, as its desktop chat shows it: a muted "Thinking" block that streams open while it is being
/// written and folds to one line once a step or the answer follows. Tap to open or close.
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({super.key, required this.message});
  final ChatMessage message;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final live = widget.message.streaming;
    final open = _open ?? live;
    final text = widget.message.content.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => setState(() => _open = !open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(live ? 'Thinking…' : 'Thinking',
                        style: TextStyle(color: p.muted, fontSize: AppText.body, fontStyle: FontStyle.italic)),
                  ),
                  Text(open ? 'Hide' : 'Show', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                ],
              ),
            ),
          ),
          SubFold(
            open: open,
            alignment: Alignment.topCenter,
            child: Container(
              margin: const EdgeInsetsDirectional.only(start: 2, bottom: 6),
              padding: const EdgeInsetsDirectional.only(start: 10),
              decoration: BoxDecoration(border: BorderDirectional(start: BorderSide(color: p.muted.withValues(alpha: 0.35), width: 2))),
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                reverse: live,
                child: SelectableText(text,
                    style: TextStyle(color: p.muted, fontSize: AppText.body - 1, fontStyle: FontStyle.italic, height: 1.45)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
