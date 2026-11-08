import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/bots_screen.dart';
import '../screens/offices_screen.dart' show OfficeScreen;
import '../screens/bots_workspace.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../services/system_tools.dart';
import '../theme.dart';
import 'team_face.dart';
import '../ui/haptics.dart';
import '../ui/i18n.dart';
import '../ui/launch_flags.dart';
import '../ui/tokens.dart';
import 'avatar_picker.dart';
import 'bot_face.dart';
import 'chat/message_actions.dart';
import 'sub_icon.dart';

/// Pieces of the Grok-style drawer, in SubMac's own look: quiet, collapsible sections of text-first rows,
/// no cards. Used by the main menu (Sidebar) and the Bots page.

/// Which drawer sections are folded (kept for the app run).
final _folded = <String>{};

/// A section heading that folds its rows away (like the Bots and Projects sections in Grok's sidebar).
class DrawerSection extends StatefulWidget {
  const DrawerSection({super.key, required this.title, required this.children, this.trailing, this.id, this.count});
  final String title;

  /// A quiet number after the title (Grok's "Daily 4").
  final int? count;
  final List<Widget> children;
  final Widget? trailing;

  /// Remembers the fold under this name (defaults to [title]).
  final String? id;

  @override
  State<DrawerSection> createState() => _DrawerSectionState();
}

class _DrawerSectionState extends State<DrawerSection> with SingleTickerProviderStateMixin {
  String get _id => widget.id ?? widget.title;
  bool get _open => !_folded.contains(_id);

  /// The fold: one controller drives the height and the fade together, and the rows stay built while they fold away
  /// (AnimatedSize swapped them for an empty box at once, so they vanished first and the gap closed after: a jump).
  late final AnimationController _c = AnimationController(vsync: this, duration: LuxMotion.base, value: _open ? 1 : 0);
  late final Animation<double> _size = CurvedAnimation(parent: _c, curve: LuxMotion.ease, reverseCurve: SubMotion.leave);

  void _toggle() {
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    setState(() => _open ? _folded.add(_id) : _folded.remove(_id));
    if (still) {
      _c.value = _open ? 1 : 0;
    } else if (_open) {
      _c.forward();
    } else {
      _c.reverse();
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
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        button: true,
        expanded: _open,
        child: InkWell(
          borderRadius: Radii.fieldAll,
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x5, Space.x2, Space.x2),
            child: Row(children: [
              Text(widget.title, style: AppText.sectionStyle.copyWith(color: p.faint)),
              if (widget.count != null) ...[
                const SizedBox(width: Space.x2),
                Text('${widget.count}', style: AppText.sectionStyle.copyWith(color: p.faint.withValues(alpha: 0.6))),
              ],
              const SizedBox(width: Space.x1),
              AnimatedRotation(
                turns: _open ? 0 : -0.25,
                duration: reduce ? Duration.zero : LuxMotion.base,
                curve: LuxMotion.ease,
                child: Icon(Icons.expand_more_rounded, size: IconSize.sm, color: p.faint),
              ),
              const Spacer(),
              if (widget.trailing != null) widget.trailing!,
            ]),
          ),
        ),
      ),
      // Folded and still: nothing is built. Otherwise the rows fold with one clipped size + fade, no layout fights.
      AnimatedBuilder(
        animation: _c,
        builder: (context, child) => _c.value == 0 && !_c.isAnimating
            ? const SizedBox(width: double.infinity)
            : ClipRect(
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  heightFactor: _size.value,
                  child: Opacity(opacity: _size.value.clamp(0.0, 1.0), child: child),
                ),
              ),
        child: RepaintBoundary(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children)),
      ),
    ]);
  }
}

/// One bot in the drawer: its face with the presence dot, its name, and one quiet word (Working, Free, Off).
/// Tap opens its chat; hold for Message · Call · Profile.
class BotRow extends StatelessWidget {
  const BotRow({super.key, required this.bot, this.selected = false, this.onOpen, this.dense = true});
  final Bot bot;
  final bool selected;

  /// Called before the bot's chat opens (the drawer closes itself here).
  final VoidCallback? onOpen;

  /// Drawer rows are slimmer than rows on the Bots page.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final presence = Bots.I.presenceOf(bot);
    final started = bot.active || bot.convId.isNotEmpty || Bots.I.isChief(bot);
    final word = !started ? 'Not started' : (Bot.presenceLabels[presence] ?? '');
    return Material(
      color: selected ? p.bubble : Colors.transparent,
      borderRadius: Radii.fieldAll,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: () => openBotChat(context, bot, before: onOpen),
        onLongPress: () => showBotOptions(context, bot, before: onOpen),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Space.x3, vertical: dense ? Space.x2 : Space.x3),
          child: Row(children: [
            ChiefFace(bot: bot, size: dense ? 26 : 34, presence: started, mood: presence == 'working' ? BotMood.thinking : BotMood.idle),
            const SizedBox(width: Space.x3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
                if (!dense && _sub(bot).isNotEmpty)
                  Text(_sub(bot), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.faint)),
              ]),
            ),
            if (word.isNotEmpty)
              Text(word, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppText.captionStyle.copyWith(color: presence == 'working' ? p.text : p.faint)),
          ]),
        ),
      ),
    );
  }
}

/// Under the name on the Bots page: a health note when something needs a look, otherwise the role.
String _sub(Bot b) {
  final h = Bots.I.health(b);
  if (h.isNotEmpty) return h + (SystemTools.perms['battery'] == false ? ' · may pause' : '');
  return b.role;
}

/// One team in the drawer: its name and who leads it (the Chief), with unread posts as a quiet count.
class TeamRow extends StatelessWidget {
  const TeamRow({super.key, required this.team, this.onOpen, this.dense = true});
  final Office team;
  final VoidCallback? onOpen;

  /// Same sizes as [BotRow], so faces and names line up between the sections.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lead = Bots.I.byId(team.chiefId);
    final n = team.members.length;
    final sub = lead == null ? '$n ${n == 1 ? 'bot' : 'bots'}' : 'Led by ${lead.name} · $n ${n == 1 ? 'bot' : 'bots'}';
    return InkWell(
      borderRadius: Radii.fieldAll,
      onTap: () {
        onOpen?.call();
        Navigator.push(context, MaterialPageRoute(builder: (_) => OfficeScreen(officeId: team.id)));
      },
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: Space.x3, vertical: dense ? Space.x2 : Space.x3),
        child: Row(children: [
          SizedBox(
            width: dense ? 26 : 34,
            height: dense ? 26 : 34,
            // One head the size of a bot's, made of the members' tiny faces (owner 2026-10-24).
            child: Center(child: TeamFace(office: team, size: dense ? 26 : 34)),
          ),
          const SizedBox(width: Space.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(team.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.captionStyle.copyWith(color: p.faint)),
            ]),
          ),
          if (team.unread > 0) Text('${team.unread}', style: AppText.captionStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// Teams show once the launch flag is on, or when the user already has a team (made before the flag closed
/// the way in), so nobody loses a team they have.
bool showTeams() => LaunchFlags.teams || Offices.I.offices.isNotEmpty;

/// Opens a bot's chat in the Bots workspace (one place for bots and teams, owner 2026-10-24). A bot that has not
/// started yet opens its profile instead.
Future<void> openBotChat(BuildContext context, Bot b, {VoidCallback? before}) async {
  final state = context.read<AppState>();
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  before?.call();
  // The Chief is ready from the start: its chat opens straight away, without a setup step.
  if (!b.active && b.convId.isEmpty && Bots.I.isChief(b)) {
    final err = await state.prepareOfficeBots([b.id]);
    if (err != null) {
      messenger?.showSnackBar(SnackBar(content: Text(err)));
      return;
    }
  }
  if (!b.active && b.convId.isEmpty) {
    await nav.push(MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id)));
    return;
  }
  nav.popUntil((r) => r.isFirst);
  await nav.push(MaterialPageRoute(builder: (_) => BotsWorkspace(open: 'bot:${b.id}')));
}

/// Hold a bot: Message · Call · Profile.
Future<void> showBotOptions(BuildContext context, Bot b, {VoidCallback? before}) {
  final state = context.read<AppState>();
  final nav = Navigator.of(context);
  return showMessageActions(context, preview: '${b.name} · ${b.role}', actions: [
    MessageAction('Message', 'reply', () => openBotChat(nav.context, b, before: before)),
    if (b.active) MessageAction('Call', 'phone', () => state.callBot(b)),
    MessageAction('Profile', 'eye', () {
      before?.call();
      nav.push(MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id)));
    }),
    MessageAction('Look', 'edit', () => pickAvatar(nav.context, b), inline: false),
    if (!Bots.I.isChief(b)) MessageAction('Make Chief', 'check', () => Bots.I.setChief(b), inline: false),
  ]);
}

/// The drawer's bot sections (RESTYLE.md Dev 2): Chief, Bots and Teams, each foldable. With a search, only what matches.
class DrawerBots extends StatelessWidget {
  const DrawerBots({super.key, this.query = '', this.selectedConv, this.onOpen});
  final String query;
  final String? selectedConv;
  final VoidCallback? onOpen;

  static bool _hit(String q, List<String> words) => q.isEmpty || words.any((w) => w.toLowerCase().contains(q));

  // Every bot, started or not: a bot the Chief just made is not active and has no chat yet, so filtering on "started"
  // hid it from search too and the owner could not even find it by name. BotRow says "Not started" for those, and
  // tapping one opens its profile, which is where Start lives.
  static List<Bot> _bots(String q) => [
        for (final b in Bots.I.bots)
          if (!Bots.I.isChief(b) && _hit(q, [b.name, b.role])) b,
      ];

  static List<Office> _teams(String q) => showTeams() ? [for (final o in Offices.I.offices) if (_hit(q, [o.name])) o] : const [];

  static Bot? _chief(String q) {
    final c = Bots.I.chief;
    return c != null && _hit(q, [c.name, c.role, 'chief']) ? c : null;
  }

  /// Something here matches the search (the drawer then does not say "No results").
  static bool anyHit(String q) => _chief(q) != null || _bots(q).isNotEmpty || _teams(q).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final p = Palette.of(context);
    // No search: one "Bots" entry. Tapping it opens the Bots workspace on the Chief's chat (owner 2026-10-24); every
    // bot and team is in the workspace's own rail, so the menu stays short.
    if (q.isEmpty) {
      final chief = Bots.I.chief;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x1),
        child: InkWell(
          key: const ValueKey('drawer-bots'),
          borderRadius: Radii.fieldAll,
          onTap: () {
            final nav = Navigator.of(context);
            onOpen?.call();
            nav.push(MaterialPageRoute(builder: (_) => const BotsWorkspace()));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x2),
            child: Row(children: [
              SizedBox(
                width: 26,
                height: 26,
                child: Center(child: chief != null ? ChiefFace(bot: chief, size: 26) : SubIcon('plus', size: IconSize.md, color: p.muted)),
              ),
              const SizedBox(width: Space.x3),
              Expanded(child: Text(tr('Bots'), style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500))),
              SubIcon('chevron_right', size: IconSize.sm, color: p.faint),
            ]),
          ),
        ),
      );
    }
    // Searching: the bots and teams that match, each opening in the workspace.
    final chief = _chief(q);
    final bots = _bots(q);
    final teams = _teams(q);
    final here = Bots.I.byConv(selectedConv);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (chief != null || bots.isNotEmpty)
        DrawerSection(
          key: const ValueKey('drawer-bots-found'),
          title: tr('Bots'),
          children: [
            if (chief != null) BotRow(key: const ValueKey('drawer-bot-chief'), bot: chief, selected: here?.id == chief.id, onOpen: onOpen),
            for (final b in bots) BotRow(bot: b, selected: here?.id == b.id, onOpen: onOpen),
          ],
        ),
      if (teams.isNotEmpty)
        DrawerSection(
          title: tr('Teams'),
          children: [for (final o in teams) TeamRow(team: o, onOpen: onOpen)],
        ),
    ]);
  }
}

/// A new team from the drawer: a name, its bots, and who leads (the Chief when it is in the team). Plain rows, no boxes.
Future<void> newTeamFlow(BuildContext context, {VoidCallback? before, void Function(Office team)? onCreated}) async {
  final state = context.read<AppState>();
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final name = TextEditingController();
  final picked = <String>[];
  String lead = '';
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final p = Palette.of(ctx);
      if (lead.isNotEmpty && !picked.contains(lead)) lead = '';
      if (lead.isEmpty && picked.isNotEmpty) lead = picked.contains(Bots.I.chiefId) ? Bots.I.chiefId : picked.first;
      return SafeArea(
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x4, Space.x5, MediaQuery.of(ctx).viewInsets.bottom + Space.x4),
          child: ListView(shrinkWrap: true, children: [
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => set(() {}),
              style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: tr('Team name'),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
              ),
            ),
            const SizedBox(height: Space.x3),
            Text(tr('Bots'), style: AppText.sectionStyle.copyWith(color: p.faint)),
            for (final b in Bots.I.bots)
              InkWell(
                borderRadius: Radii.fieldAll,
                onTap: () => set(() => picked.contains(b.id) ? picked.remove(b.id) : picked.add(b.id)),
                // Hold a picked bot to make it the lead.
                onLongPress: picked.contains(b.id)
                    ? () {
                        SubHaptics.hold();
                        set(() => lead = b.id);
                      }
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.x2),
                  child: Row(children: [
                    BotAvatar(bot: b, size: 26),
                    const SizedBox(width: Space.x3),
                    Expanded(
                      child: Text(b.name,
                          style: AppText.bodyStyle.copyWith(
                              color: picked.contains(b.id) ? p.text : p.muted,
                              fontWeight: picked.contains(b.id) ? FontWeight.w600 : FontWeight.w400)),
                    ),
                    if (b.id == lead) Text(tr('Lead'), style: AppText.captionStyle.copyWith(color: p.text)),
                  ]),
                ),
              ),
            if (picked.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: Space.x1),
                child: Text(tr('Hold a bot to make it the lead.'), style: AppText.microStyle.copyWith(color: p.faint)),
              ),
            const SizedBox(height: Space.x4),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: picked.isEmpty || name.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true),
                child: Text(tr('Start'), style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      );
    }),
  );
  if (ok != true || picked.isEmpty) return;
  final members = [lead, for (final id in picked) if (id != lead) id];
  final err = await state.prepareOfficeBots(members);
  if (err != null) {
    messenger?.showSnackBar(SnackBar(content: Text(err)));
    return;
  }
  final o = await Offices.I.create(name: name.text.trim(), members: members, chiefId: lead);
  before?.call();
  // Inside the Bots workspace the new team simply opens in place.
  if (onCreated != null) {
    onCreated(o);
    return;
  }
  await nav.push(MaterialPageRoute(builder: (_) => OfficeScreen(officeId: o.id)));
}


/// A bot's face, with SubMac's crown over it when it is the Chief.
class ChiefFace extends StatelessWidget {
  const ChiefFace({super.key, required this.bot, required this.size, this.presence = false, this.mood = BotMood.idle});
  final Bot bot;
  final double size;
  final bool presence;
  final BotMood mood;

  @override
  Widget build(BuildContext context) {
    final face = BotAvatar(bot: bot, size: size, presence: presence, mood: mood);
    if (!Bots.I.isChief(bot)) return face;
    // Grok marks its Primary Bot with a small badge; SubMac's Chief wears the crown on the face's top corner, cut out of
    // the page colour so it reads on a dark or light face. It stays inside the face's box, so no row can clip it.
    final c = (size * 0.5).clamp(14.0, 20.0).toDouble();
    final p = Palette.of(context);
    return Semantics(
      label: tr('Chief'),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(clipBehavior: Clip.none, children: [
          face,
          PositionedDirectional(
            top: -c * 0.3,
            end: -c * 0.3,
            child: DecoratedBox(
              decoration: BoxDecoration(color: p.bg, shape: BoxShape.circle),
              child: Padding(padding: const EdgeInsets.all(2), child: SubIcon('crown', size: c - 4, color: p.text)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Hand the crown to another bot.
Future<void> pickChief(BuildContext context) async {
  final id = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: Space.x3), children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x3),
            child: Text(tr('Who leads?'), style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
          ),
          for (final b in Bots.I.bots)
            InkWell(
              onTap: () => Navigator.pop(ctx, b.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.x5, vertical: Space.x3),
                child: Row(children: [
                  ChiefFace(bot: b, size: 30),
                  const SizedBox(width: Space.x3),
                  Expanded(child: Text(b.name, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500))),
                  Text(b.role, style: AppText.captionStyle.copyWith(color: p.faint)),
                ]),
              ),
            ),
        ]),
      );
    },
  );
  final b = id == null ? null : Bots.I.byId(id);
  if (b == null || Bots.I.isChief(b)) return;
  await Bots.I.setChief(b);
}

/// Short time for a roster row, Grok-style: "8:20" today, "Yesterday", then "9/1".
String rosterTime(DateTime? t) {
  if (t == null) return '';
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  if (d <= 0) return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  if (d == 1) return tr('Yesterday');
  return '${t.month}/${t.day}';
}

/// One roster row on the Bots screen (Grok's sidebar): face, name, time on the end, and one line of what it did last.
class RosterRow extends StatelessWidget {
  const RosterRow({super.key, required this.face, required this.name, required this.line, this.time, this.onTap, this.onHold, this.busy = false});
  final Widget face;
  final String name;
  final String line;
  final DateTime? time;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  /// Working right now: the line reads "Working", in plain text.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      borderRadius: Radii.fieldAll,
      onTap: onTap,
      onLongPress: onHold == null
          ? null
          : () {
              SubHaptics.hold();
              onHold!();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x3),
        child: Row(children: [
          SizedBox(width: 40, height: 40, child: Center(child: face)),
          const SizedBox(width: Space.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                ),
                if (rosterTime(time).isNotEmpty) Text(rosterTime(time), style: AppText.captionStyle.copyWith(color: p.faint)),
              ]),
              const SizedBox(height: 2),
              Text(busy ? tr('Working') : line, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppText.metaStyle.copyWith(color: busy ? p.text : p.muted)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The last thing a bot did, for its roster line.
({String line, DateTime? at}) botLast(Bot b) {
  final j = b.journal.where((e) => e.text.trim().isNotEmpty).lastOrNull;
  return j == null ? (line: b.role, at: null) : (line: j.text.replaceAll(RegExp(r'\s+'), ' ').trim(), at: j.at);
}

/// The last post in a team, for its roster line.
({String line, DateTime? at}) teamLast(Office o) {
  final x = o.posts.where((e) => e.kind != 'update' && e.text.trim().isNotEmpty).lastOrNull;
  if (x == null) return (line: '${o.members.length} ${o.members.length == 1 ? 'bot' : 'bots'}', at: null);
  final who = x.from == 'you' ? tr('You') : (Bots.I.byId(x.from)?.name ?? 'SubMac');
  return (line: '$who: ${x.text.replaceAll(RegExp(r'\s+'), ' ').trim()}', at: x.at);
}
