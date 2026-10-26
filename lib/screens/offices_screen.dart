import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../services/team_run.dart';
import '../services/system_bridge.dart';
import '../theme.dart';
import '../widgets/approval_card.dart';

import '../widgets/markdown_view.dart';
import '../widgets/message_view.dart' show textDirOf;
import '../widgets/team_parts.dart';
import '../widgets/lux_kit.dart';
import '../widgets/sub_icon.dart';
export '../widgets/team_parts.dart' show pickShareTarget, TeamLine, TeamPanel;
import 'bot_activity_screen.dart';
import 'bots_screen.dart';
import 'files_screen.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import '../widgets/chat/edge_fade.dart';
import '../widgets/chat/entrance.dart';
import '../widgets/chat/message_actions.dart';
import '../widgets/chat/long_text.dart';
import '../widgets/chat/reply_quote.dart';
import '../widgets/status_ring.dart';
import '../widgets/team_face.dart';
import '../services/bot_status.dart';
import '../ui/haptics.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'bots_workspace.dart';

/// Teams (plan 5: Offices merged into Team). A team is a few bots with a lead (the Chief in their own tools), a shared
/// task list and a folder in Files. The data is still the Office model, migrated in place (Offices.migrateToTeams).

String _name(String id) => id == 'you' ? 'You' : (Bots.I.byId(id)?.name ?? 'SubMac');

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

String _statusLabel(String s) => switch (s) {
      'proposed' => 'Waiting for your OK',
      'todo' => 'To do',
      'doing' => 'In progress',
      'review' => 'In review',
      'blocked' => 'Blocked',
      'done' => 'Done',
      'cancelled' => 'Cancelled',
      _ => s,
    };

/// "Lead Hodan · 3 bots · 2 open tasks".
String teamLine(Office o) {
  final lead = Bots.I.byId(o.chiefId)?.name ?? 'no lead';
  final open = o.tasks.where((t) => t.open && t.status != 'proposed').length;
  final mode = switch (o.mode) { 'paused' => 'Paused · ', 'supervised' => 'You approve new tasks · ', _ => '' };
  return '${mode}Lead $lead · ${o.members.length} ${o.members.length == 1 ? 'bot' : 'bots'} · $open open ${open == 1 ? 'task' : 'tasks'}';
}

/// The Teams part of the Team screen: each team, and a way to start one.
class TeamsSection extends StatelessWidget {
  const TeamsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Offices.I,
      builder: (context, _) {
        final list = Offices.I.offices;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionHeader(list.isEmpty ? 'Teams' : 'Your teams'),
          for (final o in list)
            TeamCard(
              leading: TeamFace(office: o, size: 36),
              title: o.name,
              sub: teamLine(o),
              badge: o.unread,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OfficeScreen(officeId: o.id))),
            ),
          TeamCard(
            title: 'Start a team',
            onTap: () => startTeam(context),
          ),
        ]);
      },
    );
  }
}

/// Start a team: build your own, or a ready-made one.
Future<void> startTeam(BuildContext context) async {
  final pick = await showLuxSheet<Object>(
    context,
    title: 'Start a team',
    builder: (ctx) => ListView(shrinkWrap: true, padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x4), children: [
      TeamCard(title: 'New team', onTap: () => Navigator.pop(ctx, 'custom')),
      TeamCard(title: 'From a file', onTap: () => Navigator.pop(ctx, 'file')),
      const SectionHeader('Ready-made'),
      for (final t in OfficeTemplate.all) TeamCard(title: t.name, sub: t.pitch, onTap: () => Navigator.pop(ctx, t)),
    ]),
  );
  if (pick == null || !context.mounted) return;
  if (pick == 'file') {
    final msg = await TeamFiles.pickAndAdd(context);
    if (!context.mounted) return;
    TeamFiles.toast(context, msg);
  } else if (pick is OfficeTemplate) {
    await _fromTemplate(context, pick);
  } else {
    await _newTeam(context);
  }
}

Future<void> _fromTemplate(BuildContext context, OfficeTemplate t) async {
  final state = context.read<AppState>();
  final goal = await askText(context, title: t.name, hint: 'What is it for?', initial: t.goal, action: 'Start the team');
  if (goal == null || !context.mounted) return;
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showLuxDialog(context, dismissible: false, builder: (_) => const BusyNote('Setting up your team'));
  final o = await state.createOfficeFromTemplate(t, goal: goal.trim().isEmpty ? t.goal : goal.trim());
  nav.pop();
  if (o == null) {
    messenger.showSnackBar(const SnackBar(content: Text('The team could not be set up just now. Check your internet and try again.')));
    return;
  }
  nav.push(MaterialPageRoute(builder: (_) => OfficeScreen(officeId: o.id)));
}

/// Build a team by hand: name, goal and people in one sheet. The first one picked leads (change it under People).
Future<void> _newTeam(BuildContext context) async {
  final state = context.read<AppState>();
  final name = TextEditingController(), goal = TextEditingController();
  final team = <String>[];
  final ok = await showLuxSheet<bool>(
    context,
    title: 'Build my own team',
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final p = Palette.of(ctx);
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2, Space.x5, Space.x4),
        child: ListView(shrinkWrap: true, children: [
          TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Hodan Coffee')),
          const SizedBox(height: 10),
          TextField(
              controller: goal,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Goal', hintText: 'What should the team achieve for you?')),
          const SizedBox(height: 14),
          Text(Bots.I.bots.isEmpty ? 'Make a bot first.' : 'Who\'s in it? First one leads.',
              style: TextStyle(color: p.muted, fontSize: AppText.meta)),
          // Picked bots are set in the full ink weight; the first one picked leads. No checkboxes.
          for (final b in Bots.I.bots)
            LuxRow(
              padding: const EdgeInsets.symmetric(vertical: Space.x2),
              leading: BotAvatar(bot: b, size: 36),
              title: b.name,
              sub: b.role,
              selected: team.contains(b.id),
              value: team.isNotEmpty && team.first == b.id ? tr('Lead') : (team.contains(b.id) ? tr('In') : null),
              onTap: () => set(() => team.contains(b.id) ? team.remove(b.id) : team.add(b.id)),
            ),
          const SizedBox(height: Space.x3),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: LuxWordButton('Start the team', primary: true, onPressed: team.isEmpty ? null : () => Navigator.pop(ctx, true)),
          ),
        ]),
      );
    }),
  );
  if (ok != true || team.isEmpty || !context.mounted) return;
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final err = await state.prepareOfficeBots(team);
  if (err != null) {
    messenger.showSnackBar(SnackBar(content: Text(err)));
    return;
  }
  final o = await Offices.I.create(name: name.text, goal: goal.text, members: team, chiefId: team.first);
  nav.push(MaterialPageRoute(builder: (_) => OfficeScreen(officeId: o.id)));
}

/// One team. There is one place for bots and teams now, the Bots workspace (owner 2026-10-24): opening a team anywhere
/// (a notification, a share, a link, the menu) opens the workspace on that team's chat. The name stays so every way in
/// keeps working.
class OfficeScreen extends StatelessWidget {
  const OfficeScreen({super.key, required this.officeId, this.share});
  final String officeId;
  final Map<String, dynamic>? share;

  @override
  Widget build(BuildContext context) => BotsWorkspace(open: 'team:$officeId', share: share);
}

/// A team's tasks on their own page (reached from the team's "+" in the workspace).
class TeamTasksScreen extends StatelessWidget {
  const TeamTasksScreen({super.key, required this.officeId});
  final String officeId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Offices.I,
        builder: (context, _) {
          final o = Offices.I.byId(officeId);
          return Scaffold(
            appBar: AppBar(title: Text(tr('Tasks'))),
            body: o == null ? Center(child: Text(tr('This team was closed.'))) : _TasksTab(office: o),
          );
        },
      );
}

/// A team's bots and settings on their own page.
class TeamPeopleScreen extends StatelessWidget {
  const TeamPeopleScreen({super.key, required this.officeId});
  final String officeId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([Offices.I, Bots.I]),
        builder: (context, _) {
          final o = Offices.I.byId(officeId);
          return Scaffold(
            appBar: AppBar(title: Text(o?.name ?? tr('Team'))),
            body: o == null ? Center(child: Text(tr('This team was closed.'))) : _PeopleTab(office: o),
          );
        },
      );
}

/// The team's options (the "+" on a team's chat and a long press on the team in the rail): tasks, bots, folder, and
/// how it works.
Future<void> showTeamActions(BuildContext context, Office o, {List<MessageAction> more = const []}) {
  final nav = Navigator.of(context);
  final proposed = o.tasks.where((t) => t.status == 'proposed').length;
  return showMessageActions(context, preview: o.name, actions: [
    MessageAction(proposed > 0 ? '${tr('Tasks')} · $proposed' : tr('Tasks'), 'steps', () => nav.push(MaterialPageRoute(builder: (_) => TeamTasksScreen(officeId: o.id)))),
    MessageAction(tr('Bots'), 'eye', () => nav.push(MaterialPageRoute(builder: (_) => TeamPeopleScreen(officeId: o.id)))),
    MessageAction(tr('Team folder'), 'folder', () => openTeamFolder(nav.context, o)),
    if (o.chiefId.isNotEmpty)
      MessageAction(tr('Ask the lead to check now'), 'refresh',
          () => Offices.I.enqueue(OfficeJob(officeId: o.id, botId: o.chiefId, kind: 'chief', instruction: 'The owner asked for a check now.')),
          inline: false),
    if (o.mode != 'manual') MessageAction(tr('Only when I ask'), 'check', () => Offices.I.setMode(o, 'manual'), inline: false),
    if (o.mode != 'supervised') MessageAction(tr('I approve new tasks'), 'check', () => Offices.I.setMode(o, 'supervised'), inline: false),
    if (o.mode != 'paused') MessageAction(tr('Pause the team'), 'stop', () => Offices.I.setMode(o, 'paused'), inline: false),
    ...more,
  ]);
}

/// The team's documents are files: open its folder in Files (Teams/<name>).
Future<void> openTeamFolder(BuildContext context, Office o) async {
  final nav = Navigator.of(context);
  final dir = await Offices.I.folderOf(o);
  await Offices.I.syncFromFolder(o);
  nav.push(MaterialPageRoute(builder: (_) => FilesScreen(start: dir.path)));
}

// ------------------------------------------------------------------ chat

/// A team's chat with no header bar (owner 2026-10-24): the conversation runs full height behind the workspace's
/// floating buttons ([topInset] keeps the first lines clear of them). An empty chat greets with the lead's face, the
/// team's name and who leads it. What you type is kept per team.
class TeamChat extends StatefulWidget {
  const TeamChat({super.key, required this.office, this.topInset = 0, this.onFocus, this.share});
  final Office office;
  final double topInset;

  /// The box took the cursor (the workspace folds its rail away).
  final VoidCallback? onFocus;

  /// Something shared into SubMac for this team.
  final Map<String, dynamic>? share;

  /// Drafts by team id, kept for the app run.
  static final Map<String, String> drafts = {};

  @override
  State<TeamChat> createState() => _TeamChatState();
}

class _TeamChatState extends State<TeamChat> {
  late final TextEditingController _ctrl = TextEditingController(text: TeamChat.drafts[widget.office.id] ?? '');
  final _focus = FocusNode();
  late final AppState _state = context.read<AppState>();
  final _scroll = ScrollController();

  /// The post you are replying to (swipe or hold a message), shown above the box.
  OfficePost? _replyTo;

  /// Posts that arrive after the chat opened fade in; older ones are simply there.
  final DateTime _openedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    final o = widget.office;
    _state.viewingOffice = o.id;
    if (o.unread > 0) {
      o.unread = 0;
      Offices.I.saveSoon();
    }
    final share = widget.share;
    if (share != null) WidgetsBinding.instance.addPostFrameCallback((_) => _state.shareToOffice(o, share));
    _ctrl.addListener(() {
      final t = _ctrl.text;
      if (t.trim().isEmpty) {
        TeamChat.drafts.remove(o.id);
      } else {
        TeamChat.drafts[o.id] = t;
      }
    });
    _focus.addListener(() {
      if (_focus.hasFocus) widget.onFocus?.call();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _backgroundCheck());
  }

  /// Once: Android stops apps in the background to save battery, which would stop the team. Ask to allow it.
  Future<void> _backgroundCheck() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('office_bg_asked') == true) return;
    final perms = await SystemBridge.I.permissions();
    if (perms['battery'] != false || !mounted) return;
    await prefs.setBool('office_bg_asked', true);
    if (!mounted) return;
    final ok = await luxConfirm(context,
        title: 'Keep working while you\'re away',
        message: 'Allow SubMac to keep running so your team can work and reach you.',
        action: 'Allow',
        cancel: 'Not now');
    if (ok) await SystemBridge.I.openPermission('battery');
  }

  @override
  void dispose() {
    if (_state.viewingOffice == widget.office.id) _state.viewingOffice = null;
    _ctrl.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    // Grok-style group chat: whoever is addressed (an @mention, the bot you reply to, a name) answers; otherwise the
    // team decides who, if anyone, should (TeamRun).
    if (!TeamRun.I.send(widget.office, t, replyTo: _replyTo?.id ?? '')) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('The team is still on your last message.'))));
      return;
    }
    _ctrl.clear();
    if (_replyTo != null) setState(() => _replyTo = null);
  }

  void _reply(OfficePost post) {
    SubHaptics.hold();
    setState(() => _replyTo = post);
    _focus.requestFocus();
  }

  Future<void> _jump(String id) => jumpToMessage(_scroll, id);

  Widget _post(Office o, OfficePost x) {
    final fresh = x.at.isAfter(_openedAt);
    final quoted = x.replyTo.isEmpty ? null : o.posts.where((q) => q.id == x.replyTo).firstOrNull;
    final view = _PostView(x, quoted: quoted, onJump: _jump, onReply: x.kind == 'system' ? null : () => _reply(x));
    return MessageAnchor(
      key: ValueKey('post-${x.id}'),
      id: x.id,
      child: SwipeToReply(
        enabled: x.kind != 'system',
        onReply: () => _reply(x),
        // New posts arrive like the main chat (MessageArrive: 1 s fade, slight rise and scale; yours from the box side).
        // Reduced motion: none.
        child: MessageArrive(id: 'post-${x.id}', enabled: fresh, mine: x.from == 'you', child: view),
      ),
    );
  }

  void _mention(String n) {
    if (!_ctrl.text.contains(n)) _ctrl.text = '$n ${_ctrl.text}';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([Offices.I, Bots.I]),
      builder: (context, _) {
        final o = Offices.I.byId(widget.office.id) ?? widget.office;
        // On screen: what the team posts is read as it arrives.
        if (o.unread > 0) o.unread = 0;
        final posts = o.posts.reversed.toList();
        final proposed = o.tasks.where((t) => t.status == 'proposed').length;
        final asks = Offices.I.pending.any((a) => a.officeId == o.id);
        final lead = Bots.I.byId(o.chiefId);
        final top = asks || proposed > 0;
        return Column(children: [
          if (top)
            Padding(
              padding: EdgeInsets.only(top: widget.topInset),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ApprovalList(officeId: o.id, padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 0)),
                if (proposed > 0)
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 0),
                    child: TeamCard(
                      title: '$proposed new ${proposed == 1 ? 'task waits' : 'tasks wait'} for your OK',
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamTasksScreen(officeId: o.id))),
                    ),
                  ),
              ]),
            ),
          // The footer floats over the posts (owner 2026-10-24): no solid strip; posts scroll behind the frosted
          // composer and fade softly at both edges.
          Expanded(
            child: FloatingChatFrame(
              body: Builder(
                builder: (context) => posts.isEmpty && context.watch<AppState>().officeActivity(o.id).isEmpty
                ? Padding(
                    padding: EdgeInsets.only(top: top ? 0 : widget.topInset, bottom: ChatFooterInset.of(context)),
                    child: _TeamGreeting(office: o, lead: lead),
                  )
                : ChatEdgeFade(
                    top: top ? 0 : widget.topInset,
                    bottom: MediaQuery.paddingOf(context).bottom,
                    topFade: top ? 0 : ChatEdgeFade.defaultFade,
                    child: ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    // The oldest post clears the floating buttons; the chat scrolls behind them.
                    padding: EdgeInsets.fromLTRB(12, 12 + (top ? 0 : widget.topInset), 12, 12 + ChatFooterInset.of(context)),
                    // Who is working on what sits in the chat itself, on the team's side under the newest message,
                    // and scrolls with it (never docked over the message box).
                    itemCount: posts.length + 1,
                    findChildIndexCallback: (key) {
                      final v = key is ValueKey ? key.value : null;
                      if (v is! String || !v.startsWith('post-')) return null;
                      final i = posts.indexWhere((x) => 'post-${x.id}' == v);
                      return i < 0 ? null : i + 1;
                    },
                    itemBuilder: (_, i) => i == 0 ? _TeamActivity(key: const ValueKey('team-live'), officeId: o.id) : _post(o, posts[i - 1]),
                  ),
                  ),
              ),
              footer: Column(mainAxisSize: MainAxisSize.min, children: [
          // The lead's plan waits for the owner: Start hands it out, Cancel sets it aside (typing works too).
          ListenableBuilder(
            listenable: TeamRun.I,
            builder: (_, __) => !TeamRun.I.awaitingGo(o)
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 0),
                    child: Row(children: [
                      TextButton(onPressed: () => TeamRun.I.approve(o), child: Text(tr('Start'))),
                      TextButton(onPressed: () => TeamRun.I.cancelPlan(o), child: Text(tr('Cancel'))),
                    ]),
                  ),
          ),
          // Who is in the team, small and quiet: a tiny face in its status ring and the name. Tap to @mention.
          _MemberStrip(office: o, onMention: _mention),
          SubSize(
            alignment: AlignmentDirectional.bottomStart,
            child: _replyTo == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsetsDirectional.symmetric(horizontal: Space.x2),
                    child: ReplyBar(
                      reply: ReplyRef(id: _replyTo!.id, author: _name(_replyTo!.from), quote: ReplyCodec.quoteOf(_replyTo!.text, max: 160)),
                      onTap: () => _jump(_replyTo!.id),
                      onClose: () => setState(() => _replyTo = null),
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 10),
              child: Row(children: [
                Expanded(
                  child: FrostedSurface(
                    key: const ValueKey('team-composer-field'),
                    radius: Lux.composerRadius,
                    child: TextField(
                    key: const ValueKey('team-composer'),
                    controller: _ctrl,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: tr('Message the team'),
                      // The frosted surface behind it is the fill (no solid pill).
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      // No outline (restyle): the composer is a soft pill on the sky.
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                  ),
                ),
                const SizedBox(width: 6),
                // The same send mark as the main composer: SubMac's send glyph on an ink disc.
                LuxTap(
                  key: const ValueKey('team-send'),
                  label: tr('Send'),
                  onTap: _send,
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
                    child: SubIcon('send', color: p.bg, size: IconSize.lg),
                  ),
                ),
              ]),
            ),
          ),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

/// A team's empty chat: who you are talking to, in place of a header. The lead's face, the team's name, and who leads.
class _TeamGreeting extends StatelessWidget {
  const _TeamGreeting({required this.office, required this.lead});
  final Office office;
  final Bot? lead;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = office.members.length;
    final line = [
      if (lead != null) tr('Led by {name}', {'name': lead!.name}),
      '$n ${n == 1 ? tr('bot') : tr('bots')}',
    ].join(' · ');
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Lux.gutter + Space.x4),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // The team's own head: one circle the size of a bot's, with the members' tiny faces inside.
            Entrance(child: TeamFace(office: office, size: Lux.greetingFace)),
            const SizedBox(height: Space.x4),
            Entrance(
              delay: LuxMotion.stagger,
              child: Text(office.name,
                  key: const ValueKey('greeting-team-name'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Brand.serif(size: AppText.displayLarge, color: p.text, height: 1.2)),
            ),
            const SizedBox(height: Space.x2),
            Entrance(
              delay: LuxMotion.stagger * 2,
              child: Text(line, textAlign: TextAlign.center, style: AppText.bodyStyle.copyWith(color: p.muted)),
            ),
            const SizedBox(height: Space.x3),
            Entrance(
              delay: LuxMotion.stagger * 3,
              child: Text(tr('Say hi, or give a job.'), textAlign: TextAlign.center, style: AppText.metaStyle.copyWith(color: p.faint)),
            ),
            const SizedBox(height: Lux.turnGap * 2),
          ]),
        ),
      ),
    );
  }
}


/// Who on the team is working right now and on what, live, with the time it has taken (ticks every second).
class _TeamActivity extends StatefulWidget {
  const _TeamActivity({super.key, required this.officeId});
  final String officeId;

  @override
  State<_TeamActivity> createState() => _TeamActivityState();
}

class _TeamActivityState extends State<_TeamActivity> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _el(DateTime? since) {
    if (since == null) return '';
    final d = DateTime.now().difference(since);
    if (d.inSeconds < 5) return '';
    return d.inMinutes > 0 ? '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}' : '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.watch<AppState>();
    final rows = state.officeActivity(widget.officeId);
    return SubSize(
      duration: SubMotion.quick,
      alignment: AlignmentDirectional.topStart,
      child: rows.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                for (final r in rows.take(4))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    // Same left edge as a teammate's message: avatar, then the live line where their reply will be.
                    child: Row(children: [
                      // Tiny: a small face in its working ring, then one quiet line.
                      StatusRing(state: RingState.working, size: _MemberStrip.face, child: BotAvatar(bot: r.bot, size: _MemberStrip.face)),
                      const SizedBox(width: Space.x2),
                      Expanded(
                        child: Text('${r.bot.name} · ${r.text}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.captionStyle.copyWith(color: p.muted)),
                      ),
                      if (_el(r.since).isNotEmpty)
                        Text(_el(r.since), style: TextStyle(color: p.muted, fontSize: AppText.caption, fontFeatures: const [FontFeature.tabularFigures()])),
                    ]),
                  ),
              ]),
            ),
    );
  }
}

class _PostView extends StatelessWidget {
  const _PostView(this.post, {this.quoted, this.onJump, this.onReply});
  final OfficePost post;

  /// The post this one replies to (shown as a quote; tap jumps to it).
  final OfficePost? quoted;
  final void Function(String id)? onJump;
  final VoidCallback? onReply;

  Widget _quote() {
    final q = quoted;
    if (q == null) return const SizedBox.shrink();
    return ReplyQuote(author: _name(q.from), quote: ReplyCodec.quoteOf(q.text, max: 160), onTap: onJump == null ? null : () => onJump!(q.id));
  }

  void _menu(BuildContext context) {
    final x = post;
    showMessageActions(context, preview: x.text, actions: [
      if (onReply != null) MessageAction(tr('Reply'), 'reply', onReply!),
      MessageAction(tr('Copy'), 'copy', () {
        Clipboard.setData(ClipboardData(text: x.text));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied'))));
      }),
      MessageAction(tr('Select text'), 'select', () => showSelectableText(context, x.text)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final x = post;
    if (x.kind == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(child: Text(x.text, textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.micro))),
      );
    }
    if (x.from == 'you') {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: GestureDetector(
          onLongPress: () => _menu(context),
          child: Container(
            margin: const EdgeInsetsDirectional.only(top: 6, bottom: 6, start: 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.sheetAll),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              _quote(),
              ExpandableText(
                text: x.text,
                child: Text(x.text, textDirection: textDirOf(x.text), style: TextStyle(color: p.text, fontSize: AppText.body, height: 1.4)),
              ),
            ]),
          ),
        ),
      );
    }
    final b = Bots.I.byId(x.from);
    if (x.kind == 'update') {
      // Progress is one plain line: who, and what they are doing. No icons.
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(40, 3, 0, 3),
        child: Text('${b?.name ?? 'SubMac'} · ${x.text}', style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
      );
    }
    if (x.kind == 'answer') return GestureDetector(onLongPress: () => _menu(context), child: _AnswerView(x));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _menu(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (b != null) BotAvatar(bot: b, size: 30) else const SizedBox(width: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(b?.name ?? 'SubMac', style: TextStyle(color: p.text, fontWeight: FontWeight.w600, fontSize: AppText.meta)),
                if (x.kind == 'report') Text('  ·  Daily report', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                if (x.kind == 'ask') Text('  ·  Needs you', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                const Spacer(),
                Text(_ago(x.at), style: TextStyle(color: p.muted, fontSize: AppText.caption)),
              ]),
              const SizedBox(height: 4),
              _quote(),
              // Reports and questions stand on their own like every post (no card behind them); the label above says
              // what they are. Long posts fold into a preview with Show more / Open (hark.com style).
              SizedBox(
                width: double.infinity,
                child: ExpandableText(
                  text: x.text,
                  title: b?.name ?? '',
                  child: Directionality(textDirection: textDirOf(x.text), child: MarkdownView(x.text)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The team's members under the chat, small and quiet (owner 2026-10-24: status indicators "smaller and tiny"): a tiny
/// face in its status ring (green working, yellow waiting, blue finished, grey idle) and the name. Tap to @mention.
class _MemberStrip extends StatelessWidget {
  const _MemberStrip({required this.office, required this.onMention});
  final Office office;
  final void Function(String name) onMention;

  /// The face size: small enough that a row of members never shouts.
  static const double face = 18;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final o = office;
    final bots = [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>().toList();
    Widget item({required String key, required String label, Widget? head, required VoidCallback onTap}) => Padding(
          padding: const EdgeInsetsDirectional.only(end: Space.x1),
          child: LuxTap(
            key: ValueKey(key),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x1, Space.x1, Space.x2, Space.x1),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (head != null) ...[head, const SizedBox(width: Space.x1)],
                Text(label, style: AppText.captionStyle.copyWith(color: p.muted)),
              ]),
            ),
          ),
        );
    return SizedBox(
      height: 30,
      child: ListenableBuilder(
        listenable: BotStatus.I,
        builder: (context, _) => ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: Space.x3), children: [
          for (final b in bots)
            item(
              key: 'member-${b.id}',
              label: b.id == o.chiefId ? '${b.name} · ${tr('Lead')}' : b.name,
              head: StatusRing(key: ValueKey('member-ring-${b.id}'), state: BotStatus.I.of(BotStatus.botKey(b.id)), size: face, child: BotAvatar(bot: b, size: face)),
              onTap: () => onMention('@${b.name}'),
            ),
          item(key: 'member-team', label: '@team', onTap: () => onMention('@team')),
        ]),
      ),
    );
  }
}

/// A team run's one combined answer from the lead, with each member's part under it as a quiet name that opens on tap.
class _AnswerView extends StatefulWidget {
  const _AnswerView(this.post);
  final OfficePost post;
  @override
  State<_AnswerView> createState() => _AnswerViewState();
}

class _AnswerViewState extends State<_AnswerView> {
  final _open = <int>{};

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final x = widget.post;
    final lead = Bots.I.byId(x.from);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (lead != null) BotAvatar(bot: lead, size: 30) else const SizedBox(width: 30),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(lead?.name ?? 'SubMac', style: TextStyle(color: p.text, fontWeight: FontWeight.w600, fontSize: AppText.meta)),
            const SizedBox(height: 4),
            ExpandableText(text: x.text, title: lead?.name ?? '', child: Directionality(textDirection: textDirOf(x.text), child: MarkdownView(x.text))),
            for (final (i, part) in x.parts.indexed) ...[
              LuxTap(
                onTap: () => setState(() => _open.contains(i) ? _open.remove(i) : _open.add(i)),
                child: Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 2),
                  child: Text(
                    '${Bots.I.byId(part.from)?.name ?? 'A bot'}${_open.contains(i) ? '' : '\'s part'}',
                    style: TextStyle(color: _open.contains(i) ? p.text : p.muted, fontSize: AppText.meta, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              SubSize(
                duration: SubMotion.base,
                alignment: AlignmentDirectional.topStart,
                child: _open.contains(i)
                    ? ExpandableText(
                        text: part.text,
                        title: Bots.I.byId(part.from)?.name ?? '',
                        child: Directionality(textDirection: textDirOf(part.text), child: MarkdownView(part.text)),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ the shared task list

class _TasksTab extends StatelessWidget {
  const _TasksTab({required this.office});
  final Office office;

  static const _order = ['proposed', 'blocked', 'doing', 'review', 'todo', 'done'];

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final o = office;
    final proposed = o.tasks.where((t) => t.status == 'proposed').length;
    final st = OfficeStats(o);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x4, Space.x8 * 2), children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: LuxWordButton('New task', key: const ValueKey('team-new-task'), primary: true, onPressed: () => _addTask(context, o)),
        ),
        Text('${st.doneWeek} done this week · ${st.open} open${st.blocked > 0 ? ' · ${st.blocked} blocked' : ''}',
            style: TextStyle(color: p.muted, fontSize: AppText.meta)),
        for (final k in o.kpis) Text(k.line, style: TextStyle(color: p.muted, fontSize: AppText.meta)),
        LuxRow(
          padding: const EdgeInsets.symmetric(vertical: Space.x3),
          title: tr('Team folder'),
          sub: '${o.docs.length} ${o.docs.length == 1 ? 'file' : 'files'} · reports and files you share with the team',
          onTap: () => openTeamFolder(context, o),
        ),
        if (proposed > 0)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: LuxWordButton('Approve all $proposed proposed', primary: true, onPressed: () => Offices.I.approveProposed(o)),
          ),
        if (o.tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No tasks yet. Add one, or ask the lead in the chat to plan the work.', textAlign: TextAlign.center, style: TextStyle(color: p.muted, height: 1.4)),
          ),
        for (final s in _order)
          if (o.tasks.any((t) => t.status == s)) ...[
            const SizedBox(height: 10),
            SectionHeader('${_statusLabel(s)} (${o.tasks.where((t) => t.status == s).length})'),
            for (final t in (s == 'done' ? o.tasks.where((t) => t.status == s).toList().reversed.take(10) : o.tasks.where((t) => t.status == s)))
              _TaskTile(office: o, task: t),
          ],
      ]),
    );
  }

  static Future<void> _addTask(BuildContext context, Office o) async {
    final title = TextEditingController();
    var owner = '';
    var urgent = false;
    final ok = await showLuxSheet<bool>(
      context,
      title: 'New task',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2, Space.x5, Space.x5),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
                controller: title,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'What needs doing')),
            const SizedBox(height: 12),
            LuxWords([
              LuxWord('The lead decides', selected: owner.isEmpty, onTap: () => set(() => owner = '')),
              for (final b in [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>())
                LuxWord(b.name, selected: owner == b.id, onTap: () => set(() => owner = b.id)),
              LuxWord('Urgent', selected: urgent, onTap: () => set(() => urgent = !urgent)),
            ]),
            const SizedBox(height: Space.x3),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: LuxWordButton('Add', primary: true, onPressed: () => Navigator.pop(ctx, true)),
            ),
          ]),
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    final t = OfficeTask(
        id: 'k${(DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0')}',
        title: title.text.trim(),
        owner: owner,
        priority: urgent ? 'high' : 'normal');
    o.tasks.add(t);
    Offices.I.post(o, 'you', 'New task: ${t.title}${owner.isEmpty ? '' : ' → ${_name(owner)}'}', kind: 'update', taskId: t.id);
    if (owner.isEmpty) {
      if (o.chiefId.isNotEmpty) {
        Offices.I.enqueue(OfficeJob(officeId: o.id, botId: o.chiefId, kind: 'chief', instruction: 'The owner added a task for you to assign: [${t.id}] ${t.title}.'));
      }
    } else {
      Offices.I.taskChanged(o, t, by: 'you');
    }
    await Offices.I.save();
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.office, required this.task});
  final Office office;
  final OfficeTask task;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = task;
    final bits = [
      t.owner.isEmpty ? 'Unassigned' : _name(t.owner),
      if (t.priority == 'high') 'Urgent',
      if (t.due != null) 'Due ${t.due!.toIso8601String().substring(5, 16).replaceFirst('T', ' ')}',
      _ago(t.updatedAt),
    ];
    final done = t.status == 'done';
    // The status is the section the task sits in (plain words), so the row carries no status icon.
    return LuxTap(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: done ? p.muted : p.text, fontSize: AppText.body, fontWeight: t.priority == 'high' ? FontWeight.w600 : FontWeight.w500)),
              Text(bits.join(' · '), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            ]),
          ),
        ]),
      ),
    );
  }

  void _open(BuildContext context) {
    final o = office;
    final t = task;
    showModalBottomSheet(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, sc) {
          final p = Palette.of(ctx);
          void setStatus(String s) {
            if (s == 'proposed-ok') {
              Offices.I.approveProposed(o, t.id);
            } else {
              t.status = s;
              if (s == 'todo') t.attempts = 0;
              Offices.I.post(o, 'you', '${_statusLabel(s)}: ${t.title}', kind: 'update', taskId: t.id);
              Offices.I.taskChanged(o, t, by: 'you');
            }
            Navigator.pop(ctx);
          }

          return ListView(controller: sc, padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x5, Space.x5, Space.x6), children: [
            Text(t.title, style: Brand.display(size: AppText.display, color: p.text, height: 1.2)),
            const SizedBox(height: 6),
            Text('${_statusLabel(t.status)} · ${t.owner.isEmpty ? 'Unassigned' : _name(t.owner)}'
                '${t.reviewer.isEmpty ? '' : ' · checked by ${_name(t.reviewer)}'} · added by ${_name(t.createdBy)}',
                style: TextStyle(color: p.muted)),
            if (t.detail.isNotEmpty) ...[const SizedBox(height: 14), SelectableText(t.detail, style: TextStyle(color: p.text, height: 1.4))],
            if (t.result.isNotEmpty) ...[const SizedBox(height: 18), const SectionHeader('Result'), MarkdownView(t.result.replaceFirst('[reviewed] ', ''))],
            const SizedBox(height: 18),
            const SectionHeader('Who does it'),
            LuxWords([
              for (final b in [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>())
                LuxWord(
                  b.name,
                  selected: t.owner == b.id,
                  onTap: () {
                    t.owner = b.id;
                    if (t.status == 'blocked' || t.status == 'doing') t.status = 'todo';
                    Offices.I.post(o, 'you', '${t.title} → ${b.name}', kind: 'update', taskId: t.id);
                    Offices.I.taskChanged(o, t, by: 'you');
                    Navigator.pop(ctx);
                  },
                ),
            ]),
            const SizedBox(height: 18),
            const SectionHeader('Status'),
            LuxWords([
              if (t.status == 'proposed') LuxWord('Approve', onTap: () => setStatus('proposed-ok')),
              if (t.status != 'todo') LuxWord('To do', onTap: () => setStatus('todo')),
              if (t.status != 'done') LuxWord('Done', onTap: () => setStatus('done')),
              if (t.status != 'blocked' && t.open) LuxWord('Blocked', onTap: () => setStatus('blocked')),
              if (t.open) LuxWord('Cancel task', onTap: () => setStatus('cancelled')),
            ]),
            const SizedBox(height: 18),
            if (t.open && t.owner.isNotEmpty && t.status != 'proposed')
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: LuxWordButton('Start now with ${_name(t.owner)}', primary: true, onPressed: () {
                  t.attempts = 0;
                  if (t.status != 'todo') t.status = 'todo';
                  Offices.I.enqueue(OfficeJob(officeId: o.id, botId: t.owner, kind: 'task', taskId: t.id));
                  Navigator.pop(ctx);
                }),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: LuxWordButton('Delete task', destructive: true, onPressed: () {
                o.tasks.remove(t);
                Offices.I.save();
                Navigator.pop(ctx);
              }),
            ),
          ]);
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ people and settings

class _PeopleTab extends StatelessWidget {
  const _PeopleTab({required this.office});
  final Office office;

  static Future<void> _add(BuildContext context, Office o) async {
    final state = context.read<AppState>();
    final others = Bots.I.bots.where((b) => !o.members.contains(b.id)).toList();
    final pick = await showLuxSheet<String>(
      context,
      title: 'Add a bot',
      builder: (ctx) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: Space.x3), children: [
        for (final b in others) LuxRow(leading: BotAvatar(bot: b, size: 36), title: b.name, sub: b.role, onTap: () => Navigator.pop(ctx, b.id)),
        LuxRow(title: tr('Describe a new bot'), onTap: () => Navigator.pop(ctx, '+new')),
      ]),
    );
    if (pick == null || !context.mounted) return;
    var id = pick;
    if (pick == '+new') {
      final desc = await askText(context, title: 'Describe them', hint: 'e.g. A bookkeeper who tracks expenses and sends me a weekly summary', action: 'Create');
      if (desc == null || desc.trim().isEmpty || !context.mounted) return;
      final nav = Navigator.of(context);
      showLuxDialog(context, dismissible: false, builder: (_) => const BusyNote('Bringing them on'));
      final b = await state.createBotFromText(desc.trim());
      nav.pop();
      if (b == null) return;
      id = b.id;
    }
    if (await state.prepareOfficeBots([id]) != null) return;
    await Offices.I.addMember(o, id);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final o = office;
    final state = context.read<AppState>();
    Future<void> saved() async {
      await Offices.I.save();
      await Offices.I.arm(o);
    }

    Future<void> edit(String title, String initial, String hint, void Function(String) set) async {
      final v = await askText(context, title: title, initial: initial, action: 'Save', hint: hint);
      if (v == null) return;
      set(v.trim());
      await saved();
    }

    return ListView(padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 40), children: [
      const SectionHeader('Bots'),
      for (final b in [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>())
        Builder(builder: (context) {
          final doing = o.tasks.where((t) => t.owner == b.id && t.status == 'doing').map((t) => t.title).firstOrNull;
          final open = o.tasks.where((t) => t.owner == b.id && t.open && t.status != 'proposed').length;
          // Tap opens the bot; hold for Make lead / Open their chat / Remove (no overflow-menu glyph on the row).
          return LuxRow(
            padding: const EdgeInsets.symmetric(horizontal: Space.x1, vertical: Space.x3),
            leading: BotAvatar(bot: b, size: 40),
            title: b.name,
            value: b.id == o.chiefId ? tr('Lead') : null,
            sub: doing != null ? 'Working on: $doing' : '${b.role} · $open open ${open == 1 ? 'task' : 'tasks'}',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id))),
            onLongPress: () async {
              final v = await showLuxChoices<String>(context, title: b.name, choices: [
                if (b.id != o.chiefId) const LuxChoice('lead', 'Make lead'),
                const LuxChoice('chat', 'Open their chat'),
                const LuxChoice('remove', 'Remove from the team', destructive: true),
              ]);
              switch (v) {
                case 'lead':
                  await Offices.I.setChief(o, b.id);
                case 'chat':
                  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                  await state.openBot(b);
                case 'remove':
                  await Offices.I.removeMember(o, b.id);
              }
            },
          );
        }),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: LuxWordButton('Add a bot', primary: true, onPressed: () => _add(context, o)),
      ),
      const SizedBox(height: 14),
      const SectionHeader('Purpose'),
      ChoiceRow.text('Name', o.name, () => edit('Team name', o.name, '', (v) => o.name = v.isEmpty ? o.name : v)),
      ChoiceRow.text('Goal', o.goal.isEmpty ? 'Not set' : o.goal, () => edit('Goal', o.goal, 'What should the team achieve?', (v) {
            o.goal = v;
            Offices.I.post(o, 'system', 'New goal: ${o.goal}', kind: 'system');
          })),
      ChoiceRow.text('Your rules', o.rules.isEmpty ? 'When to ask you, spend limits, what never to do' : o.rules,
          () => edit('Your rules', o.rules, 'e.g. Ask me before spending over \$20. Message me only about urgent things.', (v) => o.rules = v)),
      const SizedBox(height: 14),
      const SectionHeader('How it works'),
      ChoiceRow(
        label: 'Mode',
        value: o.mode,
        // "Works on its own" is gone (owner 2026-10-24: no automation; bots wait for the owner or the lead).
        options: const {'manual': 'Only when I ask', 'supervised': 'I approve new tasks', 'paused': 'Paused'},
        onChanged: (v) => Offices.I.setMode(o, v),
      ),
      ChoiceRow(
        label: 'Freedom',
        value: o.trust,
        options: const {
          'ask': 'Each bot asks first (recommended)',
          'trusted': 'Whole team: no asking, not even before sending or paying'
        },
        onChanged: (v) {
          o.trust = v;
          saved();
        },
      ),
      ChoiceRow(
        label: 'Daily limit',
        value: '${o.dailyLimit}',
        options: const {'10': 'Light', '25': '25 a day', '40': '40 a day', '80': '80 a day', '200': 'Heavy'},
        onChanged: (v) {
          o.dailyLimit = int.parse(v);
          saved();
        },
      ),
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 10),
        child: Text('Used today: ${o.runsToday} of ${o.dailyLimit}.', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
      ),
      if (o.brief.isNotEmpty || o.decisions.isNotEmpty) ...[
        const SizedBox(height: 8),
        const SectionHeader('Agreed'),
        for (final x in o.brief)
          RemovableLine(text: x, onRemove: () {
            o.brief.remove(x);
            saved();
          }),
        for (final x in o.decisions)
          RemovableLine(text: 'Decided: $x', onRemove: () {
            o.decisions.remove(x);
            saved();
          }),
      ],
      const SizedBox(height: 12),
      LuxRow(
        padding: const EdgeInsets.symmetric(horizontal: Space.x1, vertical: Space.x3),
        title: tr('Share this team'),
        sub: tr('Setup and bots only.'),
        onTap: () => TeamFiles.share(context, o.name, Offices.I.export(o)),
      ),
      const SizedBox(height: Space.x3),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: LuxWordButton('Close', destructive: true, onPressed: () async {
          final ok = await luxConfirm(context,
              title: tr('Close {name}?', {'name': o.name}), message: 'Tasks and chat are deleted. Bots stay.', action: 'Close', cancel: 'Keep', destructive: true);
          if (ok && context.mounted) {
            Navigator.pop(context);
            await Offices.I.remove(o);
          }
        }),
      ),
    ]);
  }
}

