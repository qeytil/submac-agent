import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/outbound_guard.dart';
import '../services/phone_tools.dart';
import '../services/reply_text.dart' show majorityDir;
import '../theme.dart';
import '../ui/tokens.dart';
import 'motion.dart' show Pressable;
import 'chat/message_actions.dart';
import 'markdown_view.dart';
import 'sub_icon.dart';
import '../ui/i18n.dart';

/// Chat cards in the hark.com style (study 2026-10-24): one card primitive with the bubble's soft corners, no
/// shadow; a quiet title with a faint hairline under it where the study saw one; muted secondary text;
/// one small rounded-square corner action at most. Theme tokens only; directional layout (RTL); no motion of their
/// own beyond the chat's entrance, and opened views use the shared page motion (reduced motion: they just appear).

/// The card primitive: a glassy take on the chat's card fill (owner, 2026-10-31) — the fill lets a little of the
/// chat through, a soft light sweeps it from its start corner, and a hairline holds the edge on any background.
class HarkSurface extends StatelessWidget {
  const HarkSurface({super.key, required this.child, this.padding = const EdgeInsets.all(Space.x4), this.color, this.maxWidth});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fill = color ?? p.bubble;
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: Radii.sheetAll,
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [fill.withValues(alpha: 0.94), fill.withValues(alpha: 0.78)],
        ),
        border: Border.all(color: p.text.withValues(alpha: 0.05)),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (maxWidth != null) {
      box = Align(alignment: AlignmentDirectional.centerStart, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth!), child: box));
    }
    return Padding(padding: const EdgeInsets.symmetric(vertical: Space.x1), child: box);
  }
}

/// The faint 1px line under a card title (a painted line, not a Divider).
class HarkHairline extends StatelessWidget {
  const HarkHairline({super.key, this.gap = Space.x3});
  final double gap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: gap),
        child: SizedBox(height: 1, width: double.infinity, child: ColoredBox(color: Palette.of(context).hairline)),
      );
}

/// The quiet corner action (a 36px rounded square, a shade lighter than the card).
class HarkCornerButton extends StatelessWidget {
  const HarkCornerButton({super.key, required this.icon, required this.label, required this.onTap});
  final String icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.composer, borderRadius: Radii.fieldAll),
          child: SubIcon(icon, size: IconSize.sm, color: p.text),
        ),
      ),
    );
  }
}

/// The card title row: title at the start, an optional corner action at the end.
class HarkTitleRow extends StatelessWidget {
  const HarkTitleRow({super.key, required this.title, this.sub, this.action});
  final String title;
  final String? sub;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
          if (sub != null && sub!.isNotEmpty) Text(sub!, style: AppText.bodyStyle.copyWith(color: p.muted)),
        ]),
      ),
      if (action != null) ...[const SizedBox(width: Space.x3), action!],
    ]);
  }
}

void harkCopy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('Copied'))));
}

// ───────────────────────────────── Email / text template

/// An email or text draft (Hark's text-template card): title (the subject, or "Draft"), a faint hairline, the body
/// in muted text with placeholders left as they are, and a Copy corner button. Hold for Share / Open in mail.
///
/// CB-42: an email draft with a "To:" line (from email_draft, when no mail account is connected) has a Send button:
/// it opens the phone's mail app (a mailto: compose intent) with the address, subject and body filled in, and the
/// user presses send there. That tap is the user's OK for the task's send.
class DraftCard extends StatelessWidget {
  final String body;
  const DraftCard(this.body, {super.key});

  (String?, String) get parts {
    final d = OutboundGuard.parse(body);
    return (d.subject, d.body);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final text = body.trim();
    final d = OutboundGuard.parse(text);
    final subject = d.subject;
    final content = d.body;
    final email = d.to.isNotEmpty;
    Future<void> openMail() async {
      OutboundGuard.approveDraft(text);
      final uri = OutboundGuard.mailto(to: d.to, cc: d.cc, subject: subject ?? '', body: content);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }

    void more() => showMessageActions(context, actions: [
          MessageAction('Copy', 'copy', () => harkCopy(context, text)),
          MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(text: content, subject: subject))),
          if (subject != null || email) MessageAction('Open in mail', 'send', openMail),
        ]);
    return GestureDetector(
      onLongPress: more,
      child: HarkSurface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          HarkTitleRow(
            title: subject ?? 'Draft',
            sub: email ? 'To ${d.to}' : null,
            action: HarkCornerButton(icon: 'copy', label: 'Copy', onTap: () => harkCopy(context, subject == null ? content : 'Subject: $subject\n\n$content')),
          ),
          const HarkHairline(),
          SelectableText(content, style: AppText.bodyStyle.copyWith(color: p.muted)),
          if (email)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const ValueKey('draft-send'),
                onPressed: openMail,
                child: Text(tr('Send'), style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
              ),
            ),
        ]),
      ),
    );
  }
}

// ───────────────────────────────── Summary / document

/// Long text as Hark's summary card: bubble-wide. Folded by default (owner, 2026-10-31): a fixed-height preview
/// that fades out at the bottom, with a card-shaped "Show more" chip that opens it right here ("Show less" folds
/// it back). A tap on the folded preview still opens the full-screen reader.
class SummaryCard extends StatefulWidget {
  final String body;
  const SummaryCard(this.body, {super.key});

  @override
  State<SummaryCard> createState() => _SummaryCardState();
}

class _SummaryCardState extends State<SummaryCard> {
  bool _open = false;

  (String, String) get parts {
    var lines = widget.body.trim().split('\n');
    var title = '';
    if (lines.isNotEmpty && lines.first.startsWith('#')) {
      title = lines.first.replaceFirst(RegExp(r'^#+\s*'), '');
      lines = lines.sublist(1);
    }
    return (title, lines.join('\n').trim());
  }

  void _reader(BuildContext context) => openSummaryReader(context, title: parts.$1, body: parts.$2, raw: widget.body.trim());

  /// The fold control: a quiet link — the folded preview is the card, the fold itself stays quiet.
  Widget chip(BuildContext context, String label) {
    final p = Palette.of(context);
    return Pressable(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(color: p.muted, fontSize: AppText.meta, fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          SubIcon('chevron_down', size: 14, color: p.muted),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (title, rest) = parts;
    // The card takes the direction of its own words, like a plain reply does (CB-9): an Arabic document split out of a
    // long reply previews right-to-left, aligned to the right edge, even though the chat around it is left-to-right.
    final dir = summaryDirOf(title, rest);
    return Semantics(
      container: true,
      button: !_open,
      textDirection: dir,
      label: 'Open summary${title.isEmpty ? '' : ': $title'}',
      child: GestureDetector(
        onTap: _open ? null : () => _reader(context),
        onLongPress: () => showMessageActions(context, actions: [
          MessageAction('Open', 'expand', () => _reader(context)),
          MessageAction('Copy', 'copy', () => harkCopy(context, widget.body.trim())),
          MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(text: widget.body.trim()))),
        ]),
        child: HarkSurface(
          maxWidth: 420,
          padding: EdgeInsets.zero,
          child: AnimatedSize(
            duration: SubMotion.base,
            curve: SubMotion.settle,
            alignment: AlignmentDirectional.topCenter,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              if (!_open)
                SizedBox(
                  height: 178,
                  child: ShaderMask(
                    shaderCallback: (r) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, 0.7, 1],
                      colors: [p.text, p.text, p.text.withValues(alpha: 0)],
                    ).createShader(r),
                    blendMode: BlendMode.dstIn,
                    child: ClipRect(
                      // The preview's start edge follows the card's own words (CB-9).
                      child: OverflowBox(
                        alignment: dir == TextDirection.rtl ? Alignment.topRight : Alignment.topLeft,
                        maxHeight: double.infinity,
                        child: Padding(
                          padding: const EdgeInsets.all(Space.x4),
                          child: IgnorePointer(child: _SummaryBody(title: title, body: rest)),
                        ),
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(Space.x4),
                  child: _SummaryBody(title: title, body: rest),
                ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x3),
                child: Align(alignment: AlignmentDirectional.centerStart, child: chip(context, _open ? 'Show less' : 'Show more')),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The direction of a summary card (or any card split out of a long reply): the majority of the strong letters in its
/// title and body decides, the same rule as plain message text (CB-9).
TextDirection summaryDirOf(String title, String body) => majorityDir(title.isEmpty ? body : '$title\n$body');

class _SummaryBody extends StatelessWidget {
  const _SummaryBody({required this.title, required this.body});
  final String title, body;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dir = summaryDirOf(title, body);
    // Used by the card preview and by the reader; both get the words' own direction (CB-9).
    return Directionality(
      textDirection: dir,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (title.isNotEmpty) ...[
          Text(title, textDirection: dir, style: Brand.serif(size: AppText.display, color: p.text, height: 1.15)),
          const SizedBox(height: Space.x2),
        ],
        if (body.isNotEmpty) MarkdownView(body),
      ]),
    );
  }
}

/// The summary reader: the chat frosted and dimmed behind, Close at the top start, "Summary" in the middle, a "More"
/// button with Copy and Share at the top end, and the whole document on a centred card that scrolls.
Future<void> openSummaryReader(BuildContext context, {required String title, required String body, required String raw}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: false,
    transitionDuration: SubMotion.of(context, SubMotion.page),
    reverseTransitionDuration: SubMotion.of(context, SubMotion.sheetOut),
    pageBuilder: (c, __, ___) => HarkOverlay(
      title: 'Summary',
      closeIcon: 'chevron_down',
      actions: [
        MessageAction('Copy', 'copy', () => harkCopy(c, raw)),
        MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(text: raw))),
      ],
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: DecoratedBox(
            decoration: BoxDecoration(color: Palette.of(c).bubble, borderRadius: Radii.sheetAll),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Space.x6),
              child: _SummaryBody(title: title, body: body),
            ),
          ),
        ),
      ),
    ),
    transitionsBuilder: (_, a, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: SubMotion.settle, reverseCurve: SubMotion.leave),
      child: child,
    ),
  ));
}

/// The opened-card frame every Hark preview shares: frosted, dimmed chat behind; round Close at the top start; a plain
/// title in the middle; an optional "More" button whose actions open in the shared action sheet.
class HarkOverlay extends StatelessWidget {
  const HarkOverlay({super.key, required this.title, required this.child, this.actions = const [], this.closeIcon = 'close'});
  final String title;
  final Widget child;
  final List<MessageAction> actions;
  final String closeIcon;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget round(String icon, String label, VoidCallback onTap) => Semantics(
          container: true,
          button: true,
          label: label,
          excludeSemantics: true,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: p.bubble, shape: BoxShape.circle),
              child: SubIcon(icon, size: IconSize.md, color: p.text),
            ),
          ),
        );
    return Material(
      type: MaterialType.transparency,
      child: Stack(children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: ColoredBox(color: p.bg.withValues(alpha: 0.82)),
          ),
        ),
        SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.all(Space.x3),
              child: Row(children: [
                round(closeIcon, 'Close', () => Navigator.of(context).maybePop()),
                Expanded(
                  child: Text(title, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppText.metaStyle.copyWith(color: p.text)),
                ),
                if (actions.isNotEmpty)
                  round('more', 'More', () => showMessageActions(context, actions: actions))
                else
                  const SizedBox(width: 48),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x4, Space.x4),
                child: child,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Opens any card (a chart, a diagram) large in the shared preview frame.
Future<void> openCardPreview(BuildContext context, {required String title, required Widget child}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: SubMotion.of(context, SubMotion.page),
    reverseTransitionDuration: SubMotion.of(context, SubMotion.sheetOut),
    pageBuilder: (c, __, ___) => HarkOverlay(
      title: title,
      child: Center(
        child: SingleChildScrollView(
          child: DecoratedBox(
            decoration: BoxDecoration(color: Palette.of(c).bubble, borderRadius: Radii.sheetAll),
            child: Padding(padding: const EdgeInsets.all(Space.x5), child: child),
          ),
        ),
      ),
    ),
    transitionsBuilder: (_, a, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: SubMotion.settle, reverseCurve: SubMotion.leave),
      child: child,
    ),
  ));
}

// ───────────────────────────────── Calendar

/// One event (```event {"title","start","end","place","notes","all_day"}```).
class CalendarEvent {
  CalendarEvent({required this.title, required this.start, this.end, this.place = '', this.notes = '', this.allDay = false});
  final String title;
  final DateTime start;
  final DateTime? end;
  final String place;
  final String notes;
  final bool allDay;

  static CalendarEvent? fromJson(Map j) {
    final start = DateTime.tryParse('${j['start'] ?? j['when'] ?? j['date'] ?? ''}');
    if (start == null) return null;
    final title = '${j['title'] ?? j['name'] ?? ''}'.trim();
    return CalendarEvent(
      title: title.isEmpty ? 'Event' : title,
      start: start,
      end: DateTime.tryParse('${j['end'] ?? ''}'),
      place: '${j['place'] ?? j['location'] ?? ''}'.trim(),
      notes: '${j['notes'] ?? j['description'] ?? ''}'.trim(),
      allDay: j['all_day'] == true || j['allDay'] == true || !'${j['start'] ?? j['when'] ?? j['date']}'.contains(':'),
    );
  }

  DateTime get endOr => end ?? (allDay ? start.add(const Duration(days: 1)) : start.add(const Duration(hours: 1)));

  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Friday, Oct 30"
  String get dateLine => '${_days[start.weekday - 1]}, ${_months[start.month - 1]} ${start.day}';

  static String _t(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  /// "7:00 – 9:00 PM", or "All day".
  String get timeLine {
    if (allDay) return 'All day';
    final e = endOr;
    final a = _t(start), b = _t(e);
    final sameHalf = (start.hour < 12) == (e.hour < 12);
    return sameHalf ? '${a.substring(0, a.length - 3)} – $b' : '$a – $b';
  }

  /// The event as an iCalendar file (for phones without the calendar app's insert screen).
  String toIcs() {
    String f(DateTime d) => d.toUtc().toIso8601String().replaceAll(RegExp(r'[-:]'), '').split('.').first + 'Z';
    String esc(String s) => s.replaceAll('\\', '\\\\').replaceAll(',', '\\,').replaceAll(';', '\\;').replaceAll('\n', '\\n');
    return [
      'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Telesia//Agent//EN', 'BEGIN:VEVENT',
      'UID:${start.millisecondsSinceEpoch}-${title.hashCode.toUnsigned(32)}@submac',
      'DTSTAMP:${f(DateTime.now())}', 'DTSTART:${f(start)}', 'DTEND:${f(endOr)}', 'SUMMARY:${esc(title)}',
      if (place.isNotEmpty) 'LOCATION:${esc(place)}', if (notes.isNotEmpty) 'DESCRIPTION:${esc(notes)}',
      'END:VEVENT', 'END:VCALENDAR',
    ].join('\r\n');
  }
}

/// Hark's calendar card: compact, the date small and muted, the time larger, a faint line, the title. The whole card
/// adds the event: it opens the phone's calendar with everything filled in (the user saves it there).
class CalendarCard extends StatelessWidget {
  const CalendarCard({super.key, required this.event, this.onAdd});
  final CalendarEvent event;

  /// Tests replace the phone's calendar screen.
  final Future<void> Function(CalendarEvent e)? onAdd;

  static Future<void> addToPhone(CalendarEvent e) async {
    await NativeBridge.call('addEvent', {
      'title': e.title,
      'begin': e.start.millisecondsSinceEpoch,
      'end': e.endOr.millisecondsSinceEpoch,
      'allDay': e.allDay,
      'location': e.place,
      'description': e.notes,
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: 'Add ${event.title} to your calendar, ${event.dateLine}, ${event.timeLine}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () async {
          final messenger = ScaffoldMessenger.maybeOf(context);
          try {
            await (onAdd ?? addToPhone)(event);
          } catch (_) {
            messenger?.showSnackBar(const SnackBar(content: Text('The calendar didn\'t open. Share the event to add it.')));
          }
        },
        onLongPress: () => showMessageActions(context, actions: [
          MessageAction('Add to calendar', 'plus', () => (onAdd ?? addToPhone)(event)),
          MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(text: event.toIcs(), subject: event.title))),
        ]),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 290),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: Space.x1),
              padding: const EdgeInsets.all(Space.x4),
              decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.sheetAll, border: Border.all(color: p.hairline)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(event.dateLine, style: AppText.metaStyle.copyWith(color: p.muted)),
                      Text(event.timeLine, style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
                    ]),
                  ),
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.composer, borderRadius: Radii.fieldAll),
                    child: SubIcon('plus', size: IconSize.sm, color: p.text),
                  ),
                ]),
                const HarkHairline(),
                Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text)),
                if (event.place.isNotEmpty) Text(event.place, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.muted)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
