import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/inbox.dart';
import '../services/rewards.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../widgets/surface.dart';
import '../ui/i18n.dart';

/// "From SubMac": messages from the SubMac team, reward gifts and reward notices, newest first.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, this.openId});

  /// An item to open right away (a tapped push).
  final String? openId;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  @override
  void initState() {
    super.initState();
    Inbox.I.refresh().then((_) {
      final id = widget.openId;
      if (!mounted || id == null) return;
      final it = Inbox.I.byId(id);
      if (it != null && !it.deleted) _open(it);
    });
  }

  static String when(DateTime d) {
    final now = DateTime.now();
    final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    return days == 0 ? hm : days == 1 ? 'Yesterday $hm' : '${d.day}/${d.month}/${d.year}';
  }

  static IconData iconFor(String kind) => switch (kind) {
        'reward_grant' => Icons.card_giftcard_rounded,
        'reward_earned' => Icons.auto_awesome_rounded,
        _ => Icons.campaign_rounded,
      };

  static String labelFor(String kind) => switch (kind) {
        'reward_grant' => 'Gift',
        'reward_earned' => 'Reward',
        _ => 'SubMac team',
      };

  void _open(InboxItem it) {
    if (it.unread) Inbox.I.mark([it.id]);
    final p = Palette.of(context);
    showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(22, 0, 22, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(iconFor(it.kind), size: 18, color: p.text),
              const SizedBox(width: 8),
              Text('${labelFor(it.kind)} · ${when(it.createdAt)}', style: TextStyle(color: p.muted, fontSize: AppText.meta)),
            ]),
            const SizedBox(height: 12),
            Text(it.title, style: Brand.serif(size: 26, color: p.text)),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(it.body, style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.5)),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              TextButton.icon(
                icon: const Icon(Icons.mark_email_unread_outlined, size: 18),
                label: const Text('Mark unread'),
                onPressed: () {
                  Inbox.I.mark([it.id], read: false);
                  Navigator.pop(ctx);
                },
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(tr('Copy')),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '${it.title}\n\n${it.body}'));
                  Navigator.pop(ctx);
                },
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Inbox.I,
      builder: (context, _) {
        final items = Inbox.I.items;
        return Scaffold(
          appBar: AppBar(
            title: Text(tr('From SubMac'), style: Brand.serif(size: 28, color: p.text)),
            actions: [
              if (items.any((i) => i.unread))
                TextButton(onPressed: Inbox.I.markAllRead, child: const Text('Mark all read')),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: Inbox.I.refresh,
            child: ListView(padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 32), children: [
              const InviteCard(),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(8, 24, 8, 8),
                  child: Text(
                      Inbox.I.loading
                          ? 'Checking…'
                          : 'Nothing yet. Messages from the SubMac team, gifts and rewards you earn show up here.',
                      style: TextStyle(color: p.muted, height: 1.4)),
                )
              else
                for (final it in items)
                  SurfaceRow(
                    margin: const EdgeInsets.symmetric(vertical: Space.x1),
                    child: ListTile(
                      leading: Icon(iconFor(it.kind), color: it.unread ? p.text : p.muted),
                      title: Text(it.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: it.unread ? FontWeight.w700 : FontWeight.w500, color: p.text)),
                      subtitle: Text('${it.body.replaceAll('\n', ' ')}\n${labelFor(it.kind)} · ${when(it.createdAt)}',
                          maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, height: 1.35)),
                      isThreeLine: true,
                      onTap: () => _open(it),
                      onLongPress: () => Inbox.I.mark([it.id], read: !it.unread),
                    ),
                  ),
            ]),
          ),
        );
      },
    );
  }
}

/// A small bell with the unread count, for app bars (Today, Settings).
class InboxBell extends StatelessWidget {
  const InboxBell({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: Inbox.I.unread,
      builder: (context, n, _) => IconButton(
        tooltip: 'From SubMac',
        icon: Badge(
          isLabelVisible: n > 0,
          label: Text(n > 9 ? '9+' : '$n'),
          child: const Icon(Icons.notifications_none_rounded),
        ),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InboxScreen())),
      ),
    );
  }
}

/// The user's bonus today and personal invite link with a share button (Today, Settings, From SubMac).
class InviteCard extends StatefulWidget {
  const InviteCard({super.key, this.compact = false});
  final bool compact;

  @override
  State<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<InviteCard> {
  @override
  void initState() {
    super.initState();
    if (Rewards.I.state.value == null) Rewards.I.refresh();
  }

  Future<void> _share() async {
    final link = await Rewards.I.inviteLink();
    final code = Rewards.I.myCode;
    if (!mounted) return;
    if (link == null || code == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your invite link needs the internet. Try again once you\'re online.')));
      return;
    }
    await SharePlus.instance.share(ShareParams(text: Rewards.inviteText(link, code), subject: 'Join me on SubMac'));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ValueListenableBuilder<RewardState?>(
      valueListenable: Rewards.I.state,
      builder: (context, s, _) {
        if (s != null && !s.enabled && s.bonus <= 0) return const SizedBox.shrink();
        final line = s?.line;
        return SurfaceRow(
          margin: const EdgeInsets.symmetric(vertical: Space.x2),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 8, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (line != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Icon(Icons.auto_awesome_rounded, size: 18, color: p.text),
                    const SizedBox(width: 8),
                    Expanded(child: Text(line, style: TextStyle(color: p.text, fontWeight: FontWeight.w600))),
                  ]),
                ),
              Text(tr('Invite friends'), style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                  s == null
                      ? 'Share your link. When a friend joins, you get extra daily allowance.'
                      : '${s.offer}${s.joined + s.hires > 0 ? ' So far: ${s.joined} joined, ${s.hires} added your bots.' : ''}',
                  style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
              if (!widget.compact && s?.inviteCode != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SelectableText('Your code: ${s!.inviteCode}', style: TextStyle(color: p.text, fontSize: AppText.meta)),
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(onPressed: _share, icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('Share my link')),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// "Have an invite code?" for someone who just joined (the server only counts new accounts, once).
Future<void> enterInviteCode(BuildContext context) async {
  final c = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Invite code'),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(hintText: 'The code a friend gave you'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Use code')),
      ],
    ),
  );
  if (code == null || code.trim().isEmpty || !context.mounted) return;
  await Rewards.I.setRef(code, source: 'code', replace: true, claimNow: false);
  final why = await Rewards.I.claimPending();
  if (!context.mounted) return;
  final msg = switch (why) {
    null || 'counted' => 'Thanks! Your friend gets a bonus for inviting you.',
    'already' => 'You already joined with an invite.',
    'self' => 'That is your own code.',
    'not_new' => 'Invite codes only work in the first days after you join.',
    'unknown_code' => 'No one has that code. Check it and try again.',
    'offline' => 'No connection. The code will be used when you are back online.',
    _ => 'That code could not be used.',
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
