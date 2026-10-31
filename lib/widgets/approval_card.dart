import 'dart:async';

import 'package:flutter/material.dart';

import '../services/bots.dart';
import '../services/full_access.dart';
import '../services/offices.dart';
import '../services/tools.dart';
import '../services/trust.dart';
import '../theme.dart';
import 'motion.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

String _who(String id) => Bots.I.byId(id)?.name ?? 'SubMac';

/// Plan 5.2: the one approval card, the same everywhere (Today, a bot's job page, a team chat, Needs your OK):
/// Approve · Edit · Not now. Similar asks come as one card ("3 emails to send") with Approve all · Review · Not now.
class ApprovalList extends StatelessWidget {
  const ApprovalList({super.key, this.botId, this.officeId, this.padding = EdgeInsets.zero, this.empty});
  /// Only this bot's asks / only this team's asks (null = all).
  final String? botId;
  final String? officeId;
  final EdgeInsetsGeometry padding;
  /// Shown when nothing waits (null = nothing).
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Offices.I,
      builder: (context, _) {
        final pending = Offices.I.pending.where((a) => (botId == null || a.botId == botId) && (officeId == null || a.officeId == officeId));
        final groups = ApprovalGroups.group(pending);
        if (groups.isEmpty) return empty ?? const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final g in groups)
              g.count == 1
                  ? ApprovalCard(g.items.first, key: ValueKey('a${g.items.first.id}'))
                  // Keyed by the kind of ask, not its members: a new ask joining the group must not reset the card
                  // (it used to fold an open "Review" back up).
                  : ApprovalGroupCard(g, key: ValueKey('g${g.key}')),
          ]),
        );
      },
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 12),
      // The shared sky surface (restyle): a soft sheet, no outline, no shadow.
      decoration: BoxDecoration(color: p.sheet, borderRadius: Radii.rowAll),
      child: child,
    );
  }
}

/// Approve · Edit · Not now, in that order of weight, and (when offered) "Allow always" under them, which approves and
/// turns on Full access. Pills, no outlines.
class _Buttons extends StatelessWidget {
  const _Buttons({required this.onApprove, required this.onEdit, required this.onNotNow, this.approve = 'Approve', this.edit = 'Edit', this.onAlways}); // English keys; shown through tr()
  final VoidCallback onApprove;
  final VoidCallback? onEdit;
  final VoidCallback onNotNow;
  final VoidCallback? onAlways;
  final String approve;
  final String edit;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(0, 42), shape: const StadiumBorder()),
            onPressed: () {
              onApprove();
            },
            child: Text(tr(approve), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (onEdit != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: p.text, backgroundColor: p.text.withValues(alpha: 0.06), side: BorderSide.none, minimumSize: const Size(0, 42), shape: const StadiumBorder()),
              onPressed: () {
                onEdit!();
              },
              child: Text(tr(edit), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
        const SizedBox(width: 4),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.muted, minimumSize: const Size(0, 42)),
          onPressed: () {
            onNotNow();
          },
          child: Text(tr('Not now'), maxLines: 1),
        ),
      ]),
      if (onAlways != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('allow-always'),
            style: TextButton.styleFrom(foregroundColor: p.muted, padding: const EdgeInsets.symmetric(horizontal: Space.x1)),
            onPressed: onAlways,
            child: Text(tr('Allow always (Full access)')),
          ),
        ),
    ]);
  }
}

/// One ask.
class ApprovalCard extends StatefulWidget {
  const ApprovalCard(this.a, {super.key});
  final Approval a;
  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  bool _details = false;
  TextEditingController? _edit;
  bool _gone = false;
  bool _right = true;

  /// Plan 5.5: the card slides away (right when approved, left when set aside), then the answer goes.
  void _leave(bool right, VoidCallback answer) {
    if (_gone) return;
    setState(() {
      _gone = true;
      _right = right;
    });
    Leaving.after(context, answer);
  }

  @override
  void dispose() {
    _edit?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final a = widget.a;
    final editing = _edit != null;
    return Leaving(
      gone: _gone,
      toRight: _right,
      child: _Frame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('{name} asks', {'name': _who(a.botId)}), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        const SizedBox(height: 4),
        Text(a.title, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600, height: 1.3)),
        if (editing)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _edit,
              autofocus: true,
              minLines: 2,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(isDense: true),
            ),
          )
        else if (a.body.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(a.body, maxLines: _details ? 30 : 5, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.4)),
        ],
        if (!editing && a.detail.isNotEmpty) ...[
          InkWell(
            onTap: () => setState(() => _details = !_details),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(tr(_details ? 'Hide details' : 'Show details'), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            ),
          ),
          if (_details) Text(a.detail, style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.4)),
        ],
        const SizedBox(height: 10),
        _Buttons(
          edit: editing ? 'Cancel' : 'Edit',
          onApprove: () {
            final edited = _edit?.text ?? '';
            _leave(true, () => Offices.I.answer(a.id, true, edited: edited));
          },
          onEdit: () {
            if (editing) {
              setState(() => _edit = null);
            } else if (a.editable) {
              setState(() => _edit = TextEditingController(text: a.editText));
            } else {
              // Nothing to edit in place: the bot is told to ask what to change.
              _leave(false, () => Offices.I.answer(a.id, false, change: true));
            }
          },
          onNotNow: () => _leave(false, () => Offices.I.answer(a.id, false)),
          // Grok's "Always allow": approve this and stop asking (Full access). Payments always ask, so never here.
          // This card slides away first; then Full access goes on, and every other ask still waiting (payments aside)
          // goes ahead at once instead of waiting for its own tap.
          onAlways: a.alwaysAsks || editing
              ? null
              : () => _leave(true, () {
                    unawaited(Offices.I.answer(a.id, true).then((_) => FullAccess.I.set(true)));
                  }),
        ),
      ]),
      ),
    );
  }
}

/// Similar asks as one card: "3 emails to send".
class ApprovalGroupCard extends StatefulWidget {
  const ApprovalGroupCard(this.g, {super.key});
  final ApprovalGroup g;
  @override
  State<ApprovalGroupCard> createState() => _ApprovalGroupCardState();
}

class _ApprovalGroupCardState extends State<ApprovalGroupCard> {
  bool _open = false;
  bool _gone = false;
  bool _right = true;

  @override
  void didUpdateWidget(ApprovalGroupCard old) {
    super.didUpdateWidget(old);
    // The answered asks left and new ones are waiting: show the card again for them.
    final was = {for (final a in old.g.items) a.id};
    if (_gone && widget.g.items.any((a) => !was.contains(a.id))) _gone = false;
  }

  void _leave(bool right, VoidCallback answer) {
    if (_gone) return;
    setState(() {
      _gone = true;
      _right = right;
    });
    Leaving.after(context, answer);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final g = widget.g;
    if (_open) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final a in g.items) ApprovalCard(a, key: ValueKey(a.id)),
      ]);
    }
    return Leaving(
      gone: _gone,
      toRight: _right,
      child: _Frame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('{name} asks', {'name': g.who(_who)}), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        const SizedBox(height: 4),
        Text(g.labelTr, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final a in g.items.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text('· ${a.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: AppText.meta)),
          ),
        if (g.count > 3) Text(tr('and {n} more', {'n': '${g.count - 3}'}), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        const SizedBox(height: 10),
        _Buttons(
          approve: 'Approve all',
          edit: 'Review',
          onApprove: () => _leave(true, () => Offices.I.answerAll(g.items, true)),
          onEdit: () => setState(() => _open = true),
          onNotNow: () => _leave(false, () => Offices.I.answerAll(g.items, false)),
        ),
      ]),
      ),
    );
  }
}

/// The chat's live ask (owner, 2026-10-31): a thin card under the newest message of the task's own chat —
/// never a modal sheet over half the screen. Same answer rules the old sheet had: the edit writes back into
/// the request, "Edit" on an ask with nothing to change asks for a change first, and "Allow always" (never on
/// money) approves and marks the ask for Full access.
class ConfirmInline extends StatefulWidget {
  const ConfirmInline({super.key, required this.request, required this.onAnswer});
  final ActionRequest request;
  final ValueChanged<bool> onAnswer;

  @override
  State<ConfirmInline> createState() => _ConfirmInlineState();
}

class _ConfirmInlineState extends State<ConfirmInline> {
  bool _details = false;
  bool _editing = false;
  bool _answered = false;
  TextEditingController? _edit;

  void _answer(bool ok) {
    if (_answered) return;
    _answered = true;
    widget.onAnswer(ok);
  }

  @override
  void dispose() {
    _edit?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = widget.request;
    return Container(
      margin: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 10),
      padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 10),
      decoration: BoxDecoration(color: p.sheet, borderRadius: Radii.rowAll, border: Border.all(color: p.text.withValues(alpha: 0.05))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(tr('Needs your OK'), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        const SizedBox(height: 3),
        Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600, height: 1.3)),
        if (!_editing && r.body.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(r.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
          ),
        if (_editing)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextField(
              controller: _edit,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(isDense: true),
            ),
          ),
        if (!_editing && r.detail.trim().isNotEmpty) ...[
          InkWell(
            onTap: () => setState(() => _details = !_details),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(tr(_details ? 'Hide details' : 'Show details'), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            ),
          ),
          if (_details)
            Text(r.detail, maxLines: 8, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.4)),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton(
              key: const ValueKey('confirm-approve'),
              style: (r.destructive
                      ? FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: Colors.white)
                      : FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg))
                  .copyWith(
                      minimumSize: const Size(0, 38),
                      shape: const StadiumBorder(),
                      textStyle: TextStyle(fontSize: AppText.meta, fontWeight: FontWeight.w600)),
              onPressed: () {
                final e = r.edit;
                if (e != null && _edit != null && _edit!.text.trim().isNotEmpty && _edit!.text.trim() != e.value.trim()) {
                  e.value = _edit!.text.trim();
                  e.edited = true;
                }
                _answer(true);
              },
              child: Text(tr(r.confirmLabel == 'Allow' ? 'Approve' : r.confirmLabel), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
                foregroundColor: p.text,
                minimumSize: const Size(0, 38),
                backgroundColor: p.text.withValues(alpha: 0.06),
                side: BorderSide.none,
                shape: const StadiumBorder(),
                textStyle: TextStyle(fontSize: AppText.meta)),
            onPressed: () {
              if (_editing) {
                setState(() => _editing = false);
              } else if (r.edit != null) {
                setState(() {
                  _edit ??= TextEditingController(text: r.edit!.value);
                  _editing = true;
                });
              } else {
                // Nothing to change in place: SubMac asks what to change.
                r.wantsChange = true;
                _answer(false);
              }
            },
            child: Text(tr(_editing ? 'Cancel' : 'Edit'), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 4),
          TextButton(
            key: const ValueKey('confirm-not-now'),
            style: TextButton.styleFrom(foregroundColor: p.muted, minimumSize: const Size(0, 38)),
            onPressed: () => _answer(false),
            child: Text(tr('Not now'), maxLines: 1),
          ),
        ]),
        // Grok's "Always allow": approve and turn on Full access; money never offers it.
        if (!_editing && !_isMoney(r))
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('allow-always'),
              style: TextButton.styleFrom(foregroundColor: p.muted, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
              onPressed: () {
                r.allowAlways = true;
                _answer(true);
              },
              child: Text(tr('Allow always (Full access)'), style: const TextStyle(fontSize: AppText.micro)),
            ),
          ),
      ]),
    );
  }

  /// A payment never offers "Allow always": by the router's own reading (tool name included) or by its words.
  static bool _isMoney(ActionRequest r) =>
      r.kind == 'money' || r.kind == 'settings' || BotTrust.kindOf('', '${r.title} ${r.detail}', destructive: r.destructive) == 'money';
}

/// "Nova has earned your trust": offered after ten approvals in a row with no edits.
class TrustOfferCard extends StatelessWidget {  const TrustOfferCard({super.key, required this.bot});
  final Bot bot;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = bot;
    return _Frame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Trust level'), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        const SizedBox(height: 4),
        Text(tr('Make {name} Trusted?', {'name': b.name}), style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
            tr('You approved the last {n} asks from {name} without changes. Trusted means routine work gets done without asking. '
                '{name} still asks before money, sending or deleting.', {'name': b.name, 'n': '${b.cleanOk}'}),
            style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.4)),
        const SizedBox(height: 10),
        _Buttons(
          approve: 'Make Trusted',
          edit: '',
          onApprove: () => Bots.I.setTrust(b, BotTrust.levelTrusted),
          onEdit: null,
          onNotNow: () => Bots.I.snoozeTrust(b),
        ),
      ]),
    );
  }
}
