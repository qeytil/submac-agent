import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui/tokens.dart';
import '../chat_extras.dart' show StreamingMarkdown;
import '../message_view.dart' show textDirOf;

/// The kinds of output a reply is made of. Each one is its own free-standing component with its own
/// spacing; none of them is wrapped in a message bubble.
enum BlockKind { text, document, media, report, chart, code, table, plan, action, other }

/// Which component a fenced block becomes. `null` is plain prose.
BlockKind blockKindOf(String? lang) {
  if (lang == null) return BlockKind.text;
  switch (lang) {
    case 'file':
    case 'page':
      return BlockKind.document;
    case 'photos':
    case 'images':
    case 'video':
    case 'qr':
    case 'visual':
      return BlockKind.media;
    case 'summary':
    case 'draft':
    case 'template':
    case 'sections':
    case 'list':
    case 'links':
      return BlockKind.report;
    case 'graph':
    case 'chart':
    case 'diagram':
    case 'flow':
    case 'roadmap':
    case 'timeline':
    case 'math':
      return BlockKind.chart;
    case 'table':
    case 'grid':
    case 'data':
      return BlockKind.table;
    case 'plan':
      return BlockKind.plan;
    case 'choices':
    case 'confirm':
    case 'receipt':
    case 'order':
    case 'order_summary':
    case 'browser':
      return BlockKind.action;
  }
  return BlockKind.code;
}

/// Telesia's prose: no bubble, no fill, just well-set type in the reading column.
/// Arabic-script text flows right to left; Somali and English left to right.
class MessageText extends StatelessWidget {
  const MessageText(this.text, {super.key, this.live = false});
  final String text;

  /// Still streaming: only the newest paragraph re-renders.
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Directionality(textDirection: textDirOf(text), child: StreamingMarkdown(text, live: live));
  }
}

/// Telesia's words in a reply: a light card-colored bubble with a hairline edge on the start side, its corner
/// tucked at the bottom start. Yours are the filled bubble on the end side, so the two never look alike.
class ReplyBubble extends StatelessWidget {
  const ReplyBubble({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width * 0.9).clamp(0, 760).toDouble()),
        child: Container(
          key: const ValueKey('reply-bubble'),
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x4, Space.x3),
          decoration: BoxDecoration(
            color: p.sheet,
            borderRadius: const BorderRadiusDirectional.only(
              topStart: Radius.circular(20),
              topEnd: Radius.circular(20),
              bottomStart: Radius.circular(6),
              bottomEnd: Radius.circular(20),
            ).resolve(Directionality.of(context)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The air around one block of a reply. Prose sits close to prose; a document, table, chart or plan gets
/// room above and below so it reads as its own object, without a box around it.
class BlockSpacing extends StatelessWidget {
  const BlockSpacing({super.key, required this.kind, required this.child, this.first = false});
  final BlockKind kind;
  final Widget child;

  /// The first block of a reply takes no space above it.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final top = first ? 0.0 : (kind == BlockKind.text ? Space.x3 : Lux.blockGap);
    final bottom = kind == BlockKind.text ? 0.0 : Space.x1;
    return Padding(padding: EdgeInsets.only(top: top, bottom: bottom), child: child);
  }
}

/// The quiet label over an output ("Plan · 4 steps", "Table", "File"): small, faint, sentence case.
class BlockLabel extends StatelessWidget {
  const BlockLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x2),
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: Lux.label, height: 1.3, color: p.faint, fontWeight: FontWeight.w500)),
    );
  }
}
