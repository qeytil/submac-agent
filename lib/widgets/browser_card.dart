import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../services/browser_agent.dart';
import '../services/browser_jobs.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import 'sub_icon.dart';

/// The browser in chat, Hark style (browser-use v2): one quiet dark card with a small live picture of the page, the
/// site's icon and domain, and ONE faded status line that changes in place ("Opening amazon.com"). No step list.
/// Tap it for the full-screen live view (with Stop). Sign-in, code and approval questions appear on the card itself
/// as small forms. When the task ends the chat keeps a compact result card with the final page link.
class BrowserLiveCard extends StatefulWidget {
  const BrowserLiveCard({super.key, required this.convId});
  final String convId;

  /// Corner radius of the card (20-24 like Hark's cards) and of the page picture inside it.
  static const double radius = Radii.sheet;
  static const double thumbRadius = Radii.row;

  /// The thumbnail's size: a phone page in miniature.
  static const Size thumbSize = Size(72, 104);

  @override
  State<BrowserLiveCard> createState() => _BrowserLiveCardState();
}

class _BrowserLiveCardState extends State<BrowserLiveCard> {
  @override
  void initState() {
    super.initState();
    BrowserAgent.I.watch(true);
    BrowserJobs.I.cardShown(widget.convId, true);
  }

  @override
  void didUpdateWidget(covariant BrowserLiveCard old) {
    super.didUpdateWidget(old);
    if (old.convId != widget.convId) {
      BrowserJobs.I.cardShown(old.convId, false);
      BrowserJobs.I.cardShown(widget.convId, true);
    }
  }

  @override
  void dispose() {
    BrowserAgent.I.watch(false);
    BrowserJobs.I.cardShown(widget.convId, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([BrowserJobs.I, BrowserAgent.I]),
      builder: (context, _) {
        final job = BrowserJobs.I.activeFor(widget.convId);
        if (job == null) return const SizedBox.shrink();
        final b = BrowserAgent.I;
        final t = b.tabFor(job.id) ?? (b.active ? b.tab : null);
        final host = t?.host ?? '';
        final app = context.watch<AppState>();
        final ask = app.asks
            .where((a) => a.convId == widget.convId && (a.kind == 'login' || a.kind == 'login_confirm' || a.site == 'browser'))
            .firstOrNull;
        final approval = BrowserJobs.I.inline[widget.convId];
        return BrowserCardView(
          host: host,
          favicon: t?.favicon ?? '',
          status: job.status == 'needs' ? job.question : job.now,
          frame: b.frame,
          onOpen: b.active ? b.openWindow : null,
          form: approval != null
              ? BrowserApprovalForm(key: ValueKey(approval), ask: approval)
              : ask != null
                  ? BrowserAskForm(key: ValueKey(ask), ask: ask, onAnswer: (v) => app.answerAsk(ask, v))
                  : null,
        );
      },
    );
  }
}

/// Which asks the browser card answers inline (so the ask bar and its sheets leave them alone).
class BrowserLiveCardAsks {
  static bool inline(UserAsk a) =>
      (a.kind == 'login' || a.kind == 'login_confirm' || a.site == 'browser') && BrowserJobs.I.cardVisible(a.convId);
}

/// The card itself, free of app state (also what the widget tests render).
class BrowserCardView extends StatelessWidget {
  const BrowserCardView({super.key, required this.host, required this.status, this.favicon = '', this.frame, this.onOpen, this.form});
  final String host;
  final String favicon;
  final String status;
  final ValueListenable<Uint8List?>? frame;
  final VoidCallback? onOpen;
  final Widget? form;

  static const cardKey = ValueKey('browser-card');
  static const thumbKey = ValueKey('browser-card-thumb');

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final thumb = SizedBox.fromSize(
      key: thumbKey,
      size: BrowserLiveCard.thumbSize,
      // The page picture: opaque and clipped to its own rounded corners, so nothing behind (the sky) ever shows through.
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(BrowserLiveCard.thumbRadius)),
        child: ColoredBox(
          color: p.bg.withAlpha(255),
          child: frame == null
              ? const SizedBox.expand()
              : ValueListenableBuilder<Uint8List?>(
                  valueListenable: frame!,
                  builder: (context, f, _) => f == null
                      ? const SizedBox.expand()
                      : Image.memory(f, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true, excludeFromSemantics: true),
                ),
        ),
      ),
    );
    final head = Row(children: [
      _SiteMark(host: host, favicon: favicon),
      const SizedBox(width: Space.x2),
      Expanded(
        child: Text(host.isEmpty ? tr('Browser') : host,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
      ),
    ]);
    // One faded pill, the words change in place (no list of steps).
    final pill = Semantics(
      liveRegion: true,
      label: status,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: p.composer.withValues(alpha: 0.7), borderRadius: const BorderRadius.all(Radius.circular(Radii.pill))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x1),
          child: AnimatedSwitcher(
            duration: SubMotion.of(context, SubMotion.base),
            switchInCurve: SubMotion.settle,
            switchOutCurve: SubMotion.leave,
            layoutBuilder: SubMotion.topStartLayout,
            child: Text(status, key: ValueKey(status), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.muted)),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x2),
      child: Material(
        key: cardKey,
        color: p.bubble.withAlpha(255),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(BrowserLiveCard.radius))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(Space.x3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(button: onOpen != null, label: tr('Watch'), child: thumb),
                const SizedBox(width: Space.x3),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    head,
                    const SizedBox(height: Space.x2),
                    Align(alignment: AlignmentDirectional.centerStart, child: pill),
                  ]),
                ),
              ]),
              if (form != null) ...[const SizedBox(height: Space.x3), form!],
            ]),
          ),
        ),
      ),
    );
  }
}

/// The site's icon, or its first letter in a soft circle when it has none.
class _SiteMark extends StatelessWidget {
  const _SiteMark({required this.host, required this.favicon});
  final String host;
  final String favicon;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final letter = Container(
      width: IconSize.sm,
      height: IconSize.sm,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: p.composer, shape: BoxShape.circle),
      child: Text(host.isEmpty ? '' : host[0].toUpperCase(), style: AppText.captionStyle.copyWith(color: p.text, height: 1)),
    );
    if (favicon.isEmpty || !favicon.startsWith('http')) return letter;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
      child: Image.network(favicon, width: IconSize.sm, height: IconSize.sm, errorBuilder: (_, __, ___) => letter),
    );
  }
}

/// A quiet text button for the card's forms.
class _FormButton extends StatelessWidget {
  const _FormButton(this.label, this.onTap, {this.strong = false});
  final String label;
  final VoidCallback onTap;
  final bool strong;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: Space.x2),
      child: Material(
        color: strong ? p.text : p.composer,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
            child: Text(label, style: AppText.metaStyle.copyWith(color: strong ? p.bg : p.text, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}

/// "Place your order on shop.com?" — Allow / Not now (and Allow always, never for money).
class BrowserApprovalForm extends StatelessWidget {
  const BrowserApprovalForm({super.key, required this.ask});
  final InlineAsk ask;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(ask.title, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
      if (ask.detail.trim().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Space.x1),
          child: Text(ask.detail.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
        ),
      const SizedBox(height: Space.x3),
      Wrap(alignment: WrapAlignment.end, runSpacing: Space.x2, children: [
        _FormButton(tr('Not now'), () => ask.answer(false)),
        if (!ask.money) _FormButton(tr('Allow always'), () => ask.answer(true, always: true)),
        _FormButton(tr('Allow'), () => ask.answer(true), strong: true),
      ]),
    ]);
  }
}

/// Sign-in, saved-login confirm, or a question (a one-time code) the task waits on.
class BrowserAskForm extends StatefulWidget {
  const BrowserAskForm({super.key, required this.ask, required this.onAnswer});
  final UserAsk ask;
  final void Function(Map<String, String>? v) onAnswer;
  @override
  State<BrowserAskForm> createState() => BrowserAskFormState();
}

class BrowserAskFormState extends State<BrowserAskForm> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _save = true;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  InputDecoration _field(BuildContext context, String hint) {
    final p = Palette.of(context);
    return InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: p.composer,
      border: const OutlineInputBorder(borderRadius: Radii.fieldAll, borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x3),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final a = widget.ask;
    final title = Text(a.title, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600));
    final children = <Widget>[title];
    if (a.prompt.trim().isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: Space.x1),
        child: Text(a.prompt, style: AppText.microStyle.copyWith(color: p.muted)),
      ));
    }
    children.add(const SizedBox(height: Space.x3));
    switch (a.kind) {
      case 'login':
        children.addAll([
          TextField(controller: _a, decoration: _field(context, tr('Email or username')), keyboardType: TextInputType.emailAddress, autocorrect: false),
          const SizedBox(height: Space.x2),
          TextField(controller: _b, decoration: _field(context, tr('Password')), obscureText: true, autocorrect: false, enableSuggestions: false),
          const SizedBox(height: Space.x2),
          InkWell(
            onTap: () => setState(() => _save = !_save),
            child: Row(children: [
              Checkbox(value: _save, onChanged: (v) => setState(() => _save = v ?? false)),
              Text(tr('Save on this phone'), style: AppText.microStyle.copyWith(color: p.muted)),
            ]),
          ),
          Wrap(alignment: WrapAlignment.end, children: [
            _FormButton(tr('Not now'), () => widget.onAnswer(null)),
            _FormButton(tr('Sign in'), () {
              if (_a.text.trim().isEmpty && _b.text.isEmpty) return;
              widget.onAnswer({'username': _a.text.trim(), 'password': _b.text, 'save': _save ? 'true' : 'false'});
            }, strong: true),
          ]),
        ]);
      case 'login_confirm':
        children.add(Wrap(alignment: WrapAlignment.end, runSpacing: Space.x2, children: [
          _FormButton(tr('Not now'), () => widget.onAnswer(null)),
          _FormButton(tr('Another account'), () => widget.onAnswer({'choice': 'Use another account'})),
          _FormButton(tr('Use this login'), () => widget.onAnswer({'choice': 'Continue'}), strong: true),
        ]));
      default:
        final opts = a.options.where((o) => o.trim().isNotEmpty).take(5).toList();
        if (opts.isNotEmpty) {
          children.add(Wrap(alignment: WrapAlignment.end, runSpacing: Space.x2, children: [
            for (final o in opts) _FormButton(o, () => widget.onAnswer({'answer': o})),
          ]));
          children.add(const SizedBox(height: Space.x2));
        }
        children.addAll([
          TextField(
            controller: _a,
            decoration: _field(context, tr('Your answer')),
            obscureText: a.secret,
            autocorrect: false,
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) widget.onAnswer({'answer': v.trim()});
            },
          ),
          const SizedBox(height: Space.x2),
          Wrap(alignment: WrapAlignment.end, children: [
            _FormButton(tr('Not now'), () => widget.onAnswer(null)),
            _FormButton(tr('Answer'), () {
              if (_a.text.trim().isNotEmpty) widget.onAnswer({'answer': _a.text.trim()});
            }, strong: true),
          ]),
        ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// The compact card a finished browser task leaves in the chat: site, how it ended, one or two lines, and the final
/// page link (```browser {json}```).
class BrowserResultCard extends StatelessWidget {
  const BrowserResultCard({super.key, required this.data});
  final Map<String, dynamic> data;

  static BrowserResultCard? fromBody(String body) {
    try {
      final j = jsonDecode(body.trim());
      if (j is Map) return BrowserResultCard(data: Map<String, dynamic>.from(j));
    } catch (_) {}
    return null;
  }

  static const cardKey = ValueKey('browser-result');

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final url = '${data['url'] ?? ''}';
    var host = Uri.tryParse(url)?.host ?? '';
    if (host.startsWith('www.')) host = host.substring(4);
    final status = '${data['status'] ?? 'done'}';
    final secs = (data['secs'] as num?)?.toInt() ?? 0;
    final time = secs <= 0 ? '' : ' ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    final ended = switch (status) {
      'done' => tr('Done'),
      'stopped' => tr('Stopped'),
      _ => tr('Could not finish'),
    };
    final summary = '${data['summary'] ?? ''}'.trim();
    final title = '${data['title'] ?? ''}'.trim();
    final canOpen = url.startsWith('http');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x1),
      child: Material(
        key: cardKey,
        color: p.bubble.withAlpha(255),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(BrowserLiveCard.radius))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: canOpen ? () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication) : null,
          child: Padding(
            padding: const EdgeInsets.all(Space.x3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _SiteMark(host: host, favicon: ''),
              const SizedBox(width: Space.x2),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title.isNotEmpty ? title : (host.isEmpty ? tr('Browser') : host),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                  Text('${host.isEmpty ? '' : '$host  '}$ended$time',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
                  if (summary.isNotEmpty && status != 'stopped')
                    Padding(
                      padding: const EdgeInsets.only(top: Space.x1),
                      child: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
                    ),
                ]),
              ),
              if (canOpen)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: Space.x2),
                  child: Semantics(button: true, label: tr('Open page'), child: SubIcon('expand', size: IconSize.sm, color: p.muted)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
