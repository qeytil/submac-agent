import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../services/bot_status.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../theme.dart';
import '../ui/haptics.dart';
import '../ui/i18n.dart';
import '../ui/launch_flags.dart';
import '../ui/tokens.dart';
import '../widgets/ask_bar.dart';
import '../widgets/avatar_picker.dart';
import '../widgets/bot_list.dart';
import '../widgets/chat/activity.dart';
import '../widgets/chat/edge_fade.dart';
import '../widgets/chat/message_actions.dart';
import '../widgets/composer.dart';
import '../widgets/logo.dart' show AppLogo;
import '../widgets/message_view.dart' show selectedReply;
import '../widgets/status_ring.dart';
import '../widgets/sub_icon.dart';
import 'bot_store_screen.dart';
import 'bots_screen.dart';
import 'hire_screen.dart';
import 'home_screen.dart' show ChatGreeting, ChatList, FloatIcon, chatTopInset;
import 'offices_screen.dart' show TeamChat, showTeamActions;
import '../widgets/team_face.dart';

/// The Bots workspace (owner, 2026-10-24), Grok-style: one screen for every bot and team.
///
/// * It opens on the Chief's chat (or the bot or team it was opened for) with the full chat: the same messages, cards
///   and composer as the main chat, and no header bar. Who you are talking to shows in the rail's soft highlight and, in
///   an empty chat, in the greeting (face, name, role).
/// * Floating blurred circles on top: the rail toggle on the start side; Call and "+" on the end side.
/// * The rail is thin ([Lux.railWidth]) and folded by default. Open, it slides over the start edge with no scrim, so
///   the chat stays readable beside it: the Chief first with its crown, the other bots, then Teams, a small "+", and
///   "New bot" and "Bot store" pinned at its foot. Each head wears a [StatusRing] (working, waiting, done, idle).
/// * Tapping a head swaps the chat in place (no new screen): the conversation cross-fades, the composer stays, and
///   each chat keeps its scroll position and its draft.
/// * The rail folds when the composer takes the cursor (the keyboard opens), on a tap on the chat, or on the toggle.
///   The phone's Back folds an open rail first, then goes back to where you came from (the chat you were in).
///
/// Motion is paint-only: the rail slides and fades with transforms (the chat never relays out), the swap is one
/// cross-fade, both sit in RepaintBoundaries, and everything appears at once under reduced motion.
class BotsWorkspace extends StatefulWidget {
  const BotsWorkspace({super.key, this.open, this.share});

  /// What to open first: 'bot:<id>' or 'team:<id>'. Null opens the Chief.
  final String? open;

  /// Something shared into SubMac for the team being opened.
  final Map<String, dynamic>? share;

  /// Tests: opens a bot's chat instead of the app's own [AppState.openBot] (which reaches the network).
  @visibleForTesting
  static Future<void> Function(AppState state, Bot bot)? debugOpenBot;

  @override
  State<BotsWorkspace> createState() => BotsWorkspaceState();
}

class BotsWorkspaceState extends State<BotsWorkspace> with SingleTickerProviderStateMixin {
  late final AppState _state = context.read<AppState>();

  // One motion for the rail (v1.13.95+165, owner "glitchy open/close"): one controller, one LuxMotion duration and one
  // curve each way (the close is the open played back on the mirrored curve, so a toggle mid-flight never jumps).
  late final AnimationController _rail = AnimationController(vsync: this, duration: LuxMotion.base);
  late final Animation<double> _railCurve = CurvedAnimation(parent: _rail, curve: LuxMotion.ease, reverseCurve: LuxMotion.ease.flipped);

  /// The rail is (or is opening to be) expanded. A notifier, not state: opening or folding the rail rebuilds only the
  /// rail layer, the toggle's label and the Back guard, never the chat under it.
  final ValueNotifier<bool> _openN = ValueNotifier<bool>(false);
  bool get _open => _openN.value;

  /// The chat on screen: 'b:<botId>' or 't:<officeId>'. Empty until the first one has opened.
  String _active = '';

  /// The head just tapped (highlighted at once, while its chat gets ready).
  String _pending = '';

  /// Going back: the chat area is hidden so the restored main chat never shows through the fading page.
  bool _leaving = false;

  Map<String, dynamic>? _share;

  @visibleForTesting
  bool get railOpen => _open;

  @visibleForTesting
  String get active => _active;

  @override
  void initState() {
    super.initState();
    _share = widget.share;
    unawaited(RailPins.I.load());
    BotStatus.I.attach(_state);
    BotStatus.I.workspaces++;
    _state.addListener(_followOpenChat);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  /// The open chat when the workspace last settled on a chat (see [_followOpenChat]).
  String? _followed;

  /// CB-16: what you see is where you type. The composer sends to the open chat ([AppState.currentId]), so when that
  /// changes from outside the rail (a bot's notification tapped, a share sent to a bot), the workspace follows: another
  /// bot's chat comes on screen in place, and a chat that is not a bot's closes the workspace onto the main chat.
  void _followOpenChat() {
    if (!mounted || _leaving || _active.isEmpty) return;
    final id = _state.currentId;
    if (id == _followed) return;
    final b = Bots.I.byConv(id);
    if (b != null) {
      _followed = id;
      final key = BotStatus.botKey(b.id);
      if (key == _active) return;
      BotStatus.I.leave(_active);
      setState(() {
        // A head tapped a moment ago and still opening loses to the chat that is open now.
        _pending = key;
        _active = key;
      });
      BotStatus.I.open(key);
      return;
    }
    // A team's chat is not the open chat; a tap still opening a bot changes the open chat on its way.
    if (_activeBot == null || _pending != _active) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _followed = id;
    home();
  }

  @override
  void dispose() {
    if (BotStatus.I.workspaces > 0) BotStatus.I.workspaces--;
    _state.removeListener(_followOpenChat);
    BotStatus.I.leave(_active);
    if (!_leaving) {
      // Closed without Back (another screen took over): the main chat still goes back to where it was, after this
      // frame (never while the tree is being torn down).
      final s = _state;
      Future.microtask(s.backFromBotChat);
    }
    _rail.dispose();
    _openN.dispose();
    super.dispose();
  }

  String? _keyFor(String? open) {
    if (open == null) return null;
    if (open.startsWith('bot:') && Bots.I.byId(open.substring(4)) != null) return BotStatus.botKey(open.substring(4));
    if (open.startsWith('team:') && Offices.I.byId(open.substring(5)) != null) return BotStatus.teamKey(open.substring(5));
    return null;
  }

  void _start() {
    if (!mounted) return;
    var key = _keyFor(widget.open);
    if (key == null) {
      final chief = Bots.I.chief;
      final first = chief ?? Bots.I.bots.where((b) => b.active || b.convId.isNotEmpty).firstOrNull;
      if (first != null) key = BotStatus.botKey(first.id);
    }
    if (key != null) {
      unawaited(select(key, first: true));
    } else {
      setState(() {});
    }
  }

  /// Swaps the chat on screen to [key] ('b:<id>' or 't:<id>'), in place.
  Future<void> select(String key, {bool first = false}) async {
    if (key == _active && !first) return;
    if (key.startsWith('t:')) {
      if (Offices.I.byId(key.substring(2)) == null) return;
      setState(() {
        _pending = key;
        _active = key;
      });
      BotStatus.I.open(key);
      return;
    }
    final b = Bots.I.byId(key.substring(2));
    if (b == null) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final started = b.active || b.convId.isNotEmpty;
    if (!started && !Bots.I.isChief(b)) {
      // Not started yet: its profile is where it starts.
      await nav.push(MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id)));
      return;
    }
    setState(() => _pending = key);
    if (!b.active && b.convId.isEmpty) {
      // The Chief is ready from the start: set it up without a separate step.
      final err = await _state.prepareOfficeBots([b.id]);
      if (err != null) {
        messenger?.showSnackBar(SnackBar(content: Text(err)));
        if (mounted) setState(() => _pending = _active);
        return;
      }
    }
    final open = BotsWorkspace.debugOpenBot;
    if (open != null) {
      await open(_state, b);
    } else if (_state.currentId != b.convId || !b.active) {
      await _state.openBot(b);
    }
    // Another head was tapped meanwhile (or another chat was opened from outside): that one wins.
    if (!mounted || _pending != key) return;
    _followed = _state.currentId;
    setState(() => _active = key);
    BotStatus.I.open(key);
  }

  void _toggle() => _open ? collapse() : _expand();

  void _expand() {
    if (_open) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _openN.value = true;
    if (SubMotion.still(context)) {
      _rail.value = 1;
    } else {
      _rail.forward();
    }
  }

  /// Folds the rail away (the keyboard opening, a tap on the chat, the toggle, Back).
  void collapse() {
    if (!_open || !mounted) return;
    _openN.value = false;
    if (SubMotion.still(context)) {
      _rail.value = 0;
    } else {
      _rail.reverse();
    }
  }

  /// The SubMac mark at the rail's foot: back to the main SubMac chat (the same way Back leaves, rail folded first).
  @visibleForTesting
  void home() {
    if (_leaving) return;
    if (_open) {
      _openN.value = false;
      _rail.value = 0;
    }
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      // PopScope's handler runs with didPop true and leaves the way Back does.
      nav.pop();
    } else {
      _leave();
    }
  }

  void _leave() {
    if (_leaving) return;
    BotStatus.I.leave(_active);
    setState(() => _leaving = true);
    // The main chat goes back to the chat you came from once this frame has hidden ours.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_state.backFromBotChat()));
  }

  Bot? get _activeBot => _active.startsWith('b:') ? Bots.I.byId(_active.substring(2)) : null;
  Office? get _activeTeam => _active.startsWith('t:') ? Offices.I.byId(_active.substring(2)) : null;

  // ------------------------------------------------------------------ actions

  Future<void> _newTeam() async {
    if (Bots.I.bots.length > 1) {
      return newTeamFlow(context, onCreated: (o) {
        if (mounted) unawaited(select(BotStatus.teamKey(o.id)));
      });
    }
    final nav = Navigator.of(context);
    await showMessageActions(context, preview: tr('A team needs at least two bots. Make another bot first, then put them together.'), actions: [
      MessageAction(tr('New bot'), 'plus', () => nav.push(MaterialPageRoute(builder: (_) => const HireScreen()))),
    ]);
  }

  void _newBot() => Navigator.push(context, MaterialPageRoute(builder: (_) => const HireScreen()));
  void _store() => Navigator.push(context, MaterialPageRoute(builder: (_) => const BotStoreScreen()));

  List<MessageAction> get _makeActions => [
        MessageAction(tr('New bot'), 'plus', _newBot),
        if (LaunchFlags.teams || Offices.I.offices.isNotEmpty) MessageAction(tr('New team'), 'plus', _newTeam),
      ];

  /// The "+" on top: new bot or team, and this chat's options.
  Future<void> _plus() async {
    final team = _activeTeam;
    if (team != null) return showTeamActions(context, team, more: _makeActions);
    final b = _activeBot;
    final nav = Navigator.of(context);
    await showMessageActions(context, preview: b == null ? tr('New') : b.name, actions: [
      ..._makeActions,
      if (b != null) MessageAction(tr('Profile'), 'eye', () => nav.push(MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id))), inline: false),
      if (b != null) MessageAction(tr('Edit'), 'edit', () => nav.push(MaterialPageRoute(builder: (_) => HireScreen(editBotId: b.id))), inline: false),
    ]);
  }

  /// Hold a bot in the rail: profile, edit, look, pin, make Chief.
  Future<void> _botOptions(Bot b) {
    final nav = Navigator.of(context);
    final key = BotStatus.botKey(b.id);
    final pinned = RailPins.I.has(key);
    return showMessageActions(context, preview: [b.name, b.role].where((s) => s.trim().isNotEmpty).join(' · '), actions: [
      MessageAction(tr('Profile'), 'eye', () => nav.push(MaterialPageRoute(builder: (_) => BotProfileScreen(botId: b.id)))),
      MessageAction(tr('Edit'), 'edit', () => nav.push(MaterialPageRoute(builder: (_) => HireScreen(editBotId: b.id)))),
      if (!Bots.I.isChief(b)) MessageAction(pinned ? tr('Unpin') : tr('Pin'), 'check', () => RailPins.I.toggle(key)),
      MessageAction(tr('Look'), 'image', () => pickAvatar(nav.context, b), inline: false),
      if (b.active) MessageAction(tr('Call'), 'phone', () => _state.callBot(b), inline: false),
      if (!Bots.I.isChief(b)) MessageAction(tr('Make Chief'), 'crown', () => Bots.I.setChief(b), inline: false),
    ]);
  }

  /// Hold a team in the rail: its tasks, bots, folder and pin.
  Future<void> _teamOptions(Office o) {
    final key = BotStatus.teamKey(o.id);
    final pinned = RailPins.I.has(key);
    return showTeamActions(context, o, more: [MessageAction(pinned ? tr('Unpin') : tr('Pin'), 'check', () => RailPins.I.toggle(key), inline: false)]);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final bot = _activeBot;
    return ValueListenableBuilder<bool>(
      valueListenable: _openN,
      // Only the Back guard follows the rail; the screen below is the same widget (not rebuilt) when it flips.
      builder: (context, open, screen) => PopScope(
        canPop: !open,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            collapse();
            return;
          }
          _leave();
        },
        child: screen!,
      ),
      // Outside the Scaffold: the Scaffold takes the keyboard's height out of what its body sees.
      child: _KeyboardWatch(
        onKeyboard: collapse,
        child: Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: GestureDetector(
                // A tap on the chat puts the keyboard, any open message actions and the rail away.
                onTap: () {
                  FocusScope.of(context).unfocus();
                  selectedReply.value = null;
                  collapse();
                },
                child: RepaintBoundary(
                  child: Opacity(
                    opacity: _leaving ? 0 : 1,
                    child: AnimatedSwitcher(
                      duration: SubMotion.of(context, LuxMotion.base),
                      switchInCurve: SubMotion.settle,
                      switchOutCurve: SubMotion.leave,
                      layoutBuilder: SubMotion.fillLayout,
                      child: _page(context),
                    ),
                  ),
                ),
              ),
          ),
          // The rail: built once and kept (its faces are ready before it opens), painted only while it shows. It moves
          // with one paint-only slide (no width, no relayout of the chat); see [RailLayer].
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: Lux.railWidth,
            child: RailLayer(
              animation: _railCurve,
              open: _openN,
              child: _Rail(
                selected: _pending.isEmpty ? _active : _pending,
                onSelect: (k) => unawaited(select(k)),
                onBotHold: _botOptions,
                onTeamHold: _teamOptions,
                onHome: home,
                onNewBot: _newBot,
                onStore: _store,
              ),
            ),
          ),
          // The header, the same as the main SubMac chat (v1.13.95+165): no bar or band. The rail toggle, Call and "+"
          // float in blurred circles, and who you are talking to (a small face in its tiny ring + the name) floats in a
          // light blurred pill between them. The chat scrolls behind all of it and fades out under it.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WorkspaceHeader(
              key: const ValueKey('ws-header'),
              activeKey: _active,
              name: bot?.name ?? _activeTeam?.name ?? '',
              face: _headFace(),
              leading: ValueListenableBuilder<bool>(
                valueListenable: _openN,
                builder: (context, open, _) =>
                    FloatIcon(key: const ValueKey('ws-rail'), icon: 'menu', tooltip: open ? tr('Hide bots') : tr('Show bots'), onTap: _toggle),
              ),
              trailing: [
                if (bot != null) ...[
                  FloatIcon(key: const ValueKey('ws-call'), icon: 'phone', tooltip: tr('Call {name}', {'name': bot.name}), onTap: () => _state.callBot(bot)),
                  const SizedBox(width: Space.x2),
                ],
                FloatIcon(key: const ValueKey('ws-plus'), icon: 'plus', tooltip: tr('New'), onTap: _plus),
              ],
            ),
          ),
        ]),
      ),
      ),
    );
  }

  /// The face shown in the header for the chat on screen (a team shows its lead, or its first letter).
  Widget? _headFace() {
    final b = _activeBot;
    if (b != null) return ChiefFace(bot: b, size: WorkspaceHeader.faceSize);
    final o = _activeTeam;
    if (o == null) return null;
    // A team's head is one circle the size of a bot's, with the members' tiny faces inside (owner 2026-10-24).
    return TeamFace(office: o, size: WorkspaceHeader.faceSize);
  }

  Widget _page(BuildContext context) {
    final team = _activeTeam;
    if (team != null) {
      final share = _share;
      _share = null;
      return TeamChat(
        key: ValueKey('ws-$_active'),
        office: team,
        topInset: chatTopInset(context),
        onFocus: collapse,
        share: share,
      );
    }
    final bot = _activeBot;
    if (bot != null) {
      // Bot to bot keeps this subtree (and its composer); only the conversation inside cross-fades.
      return KeyedSubtree(
        key: const ValueKey('ws-bots'),
        // The composer floats over the conversation (no solid strip); the list keeps its newest message above it.
        child: FloatingChatFrame(
          body: AnimatedSwitcher(
            duration: SubMotion.of(context, LuxMotion.base),
            switchInCurve: SubMotion.settle,
            switchOutCurve: SubMotion.leave,
            layoutBuilder: SubMotion.fillLayout,
            child: _BotConversation(key: ValueKey('ws-chat-${bot.convId}'), convId: bot.convId),
          ),
          footer: Column(mainAxisSize: MainAxisSize.min, children: [
            const AskBar(),
            const TaskBar(),
            Composer(perChatDrafts: true, onFocus: collapse),
          ]),
        ),
      );
    }
    final none = Bots.I.bots.isEmpty;
    return KeyedSubtree(
      key: ValueKey(none ? 'ws-none' : 'ws-opening'),
      child: Padding(
        padding: EdgeInsets.only(top: chatTopInset(context)),
        child: Center(
          child: none
              ? _NoBots(onNew: _newBot, onStore: _store)
              : const StatusWord('Opening'),
        ),
      ),
    );
  }
}

/// One bot's conversation in the workspace. While its chat is the open one it follows it (loading, the greeting, the
/// list); while another chat takes over (the cross-fade of a swap) it holds what it last showed, so nothing flashes.
/// It rebuilds only when the open chat, its loading or its emptiness changes; the list follows the messages itself.
class _BotConversation extends StatefulWidget {
  const _BotConversation({super.key, required this.convId});
  final String convId;

  @override
  State<_BotConversation> createState() => _BotConversationState();
}

class _BotConversationState extends State<_BotConversation> {
  String _mode = '';

  @override
  Widget build(BuildContext context) {
    final (current, loading, empty) = context.select<AppState, (String?, bool, bool)>((s) => (s.currentId, s.loadingMessages, s.messages.isEmpty));
    if (current == widget.convId || _mode.isEmpty) {
      _mode = current != widget.convId || loading ? 'l' : (empty ? 'e' : 'm');
    }
    final top = chatTopInset(context);
    final bottom = ChatFooterInset.of(context);
    return AnimatedSwitcher(
      duration: SubMotion.of(context, SubMotion.base),
      switchInCurve: SubMotion.settle,
      switchOutCurve: SubMotion.leave,
      layoutBuilder: SubMotion.fillLayout,
      child: switch (_mode) {
        'l' => Padding(key: const ValueKey('l'), padding: EdgeInsets.only(top: top, bottom: bottom), child: const Center(child: StatusWord('Opening'))),
        'e' => Padding(key: const ValueKey('e'), padding: EdgeInsets.only(top: top, bottom: bottom), child: ChatGreeting(convId: widget.convId)),
        _ => ChatList(key: const ValueKey('m'), convId: widget.convId),
      },
    );
  }
}

/// Folds the rail when the keyboard comes up. Only this small widget listens to the keyboard's height, so the
/// workspace does not rebuild on every frame of the keyboard sliding in (its child is the same widget each time).
///
/// It reacts only while the keyboard is coming UP (its height grows). Before v1.13.95+165 it folded the rail on every
/// frame the keyboard showed at all, so tapping the toggle with the keyboard open (which puts the keyboard away)
/// opened the rail and snapped it shut again a frame later, while the keyboard was still sliding down.
class _KeyboardWatch extends StatefulWidget {
  const _KeyboardWatch({required this.onKeyboard, required this.child});
  final VoidCallback onKeyboard;
  final Widget child;

  @override
  State<_KeyboardWatch> createState() => _KeyboardWatchState();
}

class _KeyboardWatchState extends State<_KeyboardWatch> {
  double _last = 0;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.viewInsetsOf(context).bottom;
    if (h > _last + 0.5) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onKeyboard();
      });
    }
    _last = h;
    return widget.child;
  }
}

/// The rail's motion (v1.13.95+165). Root causes of the old glitchy open/close, all fixed here:
///
/// * The blur faded inside an opacity layer. A [BackdropFilter] under a fade samples the (empty) fade layer, not the
///   chat, so the frosted glass showed no blur while it moved and popped in on the last frame (and out on the first
///   frame of folding). Now the glass only slides; only the heads and labels inside it fade.
/// * Opening and folding called setState on the whole workspace twice (open flag, then "shown" when the controller
///   left/reached dismissed), rebuilding the chat, its list and the composer on the first and last frame of the motion.
///   Now the flag is a notifier and only this layer listens to the controller's status.
/// * The repaint boundary sat outside the slide, so the whole rail (list, rings, blur) re-recorded every frame. Now it
///   sits inside the moving transform: frames only move a cached picture.
/// * Open and fold used two durations and two unrelated curves; now one LuxMotion duration and the mirrored curve.
///
/// Folded, the rail stays built but is offstage (not painted, not hit, its tickers paused). The chat never relays out:
/// the rail is a fixed-width overlay and nothing here changes a size. Reduced motion jumps straight to the end
/// (the workspace sets the controller's value instead of animating it). Mirrors itself in right-to-left languages.
class RailLayer extends StatefulWidget {
  const RailLayer({super.key, required this.animation, required this.open, required this.child});

  /// 0 folded .. 1 open, already curved.
  final Animation<double> animation;

  /// Whether the rail takes touches (it stops at once when folding starts).
  final ValueListenable<bool> open;
  final Widget child;

  @override
  State<RailLayer> createState() => _RailLayerState();
}

class _RailLayerState extends State<RailLayer> {
  late bool _shown = !widget.animation.isDismissed;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
  }

  @override
  void didUpdateWidget(RailLayer old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      old.animation.removeStatusListener(_status);
      widget.animation.addStatusListener(_status);
      _status(widget.animation.status);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    super.dispose();
  }

  void _status(AnimationStatus s) {
    final shown = s != AnimationStatus.dismissed;
    if (shown != _shown && mounted) setState(() => _shown = shown);
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Offstage(
      offstage: !_shown,
      child: TickerMode(
        enabled: _shown,
        child: SlideTransition(
          key: const ValueKey('rail-slide'),
          position: Tween<Offset>(begin: Offset(rtl ? 1 : -1, 0), end: Offset.zero).animate(widget.animation),
          child: RepaintBoundary(
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.open,
              builder: (context, open, child) => IgnorePointer(ignoring: !open, child: child),
              child: RailFade(opacity: widget.animation, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hands the rail's fade down to its contents (inside the blur), so the glass itself never sits in an opacity layer.
class RailFade extends InheritedWidget {
  const RailFade({super.key, required this.opacity, required super.child});
  final Animation<double> opacity;

  static Animation<double> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RailFade>()?.opacity ?? kAlwaysCompleteAnimation;

  @override
  bool updateShouldNotify(RailFade old) => old.opacity != opacity;
}

/// No bots yet: one quiet line and the two ways in.
class _NoBots extends StatelessWidget {
  const _NoBots({required this.onNew, required this.onStore});
  final VoidCallback onNew;
  final VoidCallback onStore;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Lux.gutter + Space.x4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('Bots work for you: research, keep track, message you when it matters.'),
            textAlign: TextAlign.center, style: AppText.bodyStyle.copyWith(color: p.muted)),
        const SizedBox(height: Space.x4),
        Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(onPressed: onNew, child: Text(tr('New bot'))),
          TextButton(onPressed: onStore, child: Text(tr('Bot store'))),
        ]),
      ]),
    );
  }
}

/// The rail itself: heads with names, Chief first, then the bots, Teams, a small "+", and "New bot" and "Bot store"
/// pinned at the foot. A blurred strip of sky with no edge line, so the chat shows through softly.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.selected,
    required this.onSelect,
    required this.onBotHold,
    required this.onTeamHold,
    required this.onHome,
    required this.onNewBot,
    required this.onStore,
  });
  final String selected;
  final ValueChanged<String> onSelect;
  final void Function(Bot) onBotHold;
  final void Function(Office) onTeamHold;
  final VoidCallback onHome;
  final VoidCallback onNewBot;
  final VoidCallback onStore;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // The open side (owner 2026-10-24): softly rounded corners and a faint shadow instead of a flat cut. Same width,
    // mirrored in right-to-left languages.
    final edge = railEdge(Directionality.of(context));
    return DecoratedBox(
      key: const ValueKey('rail-edge'),
      decoration: BoxDecoration(
        borderRadius: edge,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 16)],
      ),
      child: ClipRRect(
      borderRadius: edge,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: ColoredBox(
          color: p.bg.withValues(alpha: 0.72),
          // Only the contents fade (see RailLayer): the blur above is never inside an opacity layer.
          child: FadeTransition(
            key: const ValueKey('rail-content-fade'),
            opacity: RailFade.of(context),
            child: RepaintBoundary(
              child: AnimatedBuilder(
            animation: Listenable.merge([Bots.I, Offices.I, RailPins.I]),
            builder: (context, _) {
              final pins = RailPins.I;
              final chief = Bots.I.chief;
              DateTime botAt(Bot b) => botLast(b).at ?? DateTime(2000);
              DateTime teamAt(Office o) => teamLast(o).at ?? DateTime(2000);
              int pinFirst(String a, String b) => (pins.has(a) ? 0 : 1) - (pins.has(b) ? 0 : 1);
              // Every bot the owner has, started or not. A bot the Chief just made is not active and has no chat yet
              // (Bots.create leaves both empty), so filtering on "started" made it invisible here AND in the drawer
              // search: created, told "it is in Bots", and impossible to find. Unstarted heads show dimmed and open
              // the profile (where Start lives) when tapped.
              final bots = [
                for (final b in Bots.I.bots)
                  if (!Bots.I.isChief(b)) b,
              ]..sort((a, b) {
                  final pin = pinFirst(BotStatus.botKey(a.id), BotStatus.botKey(b.id));
                  return pin != 0 ? pin : botAt(b).compareTo(botAt(a));
                });
              final teams = showTeams() ? ([...Offices.I.offices]..sort((a, b) {
                  final pin = pinFirst(BotStatus.teamKey(a.id), BotStatus.teamKey(b.id));
                  return pin != 0 ? pin : teamAt(b).compareTo(teamAt(a));
                })) : const <Office>[];
              Widget botHead(Bot b) {
                final k = BotStatus.botKey(b.id);
                return RailHead(
                  key: ValueKey('rail-$k'),
                  statusKey: k,
                  name: b.name,
                  selected: selected == k,
                  face: ChiefFace(bot: b, size: Lux.railFace),
                  onTap: () => onSelect(k),
                  onHold: () => onBotHold(b),
                );
              }

              return Column(children: [
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.only(top: chatTopInset(context), bottom: Space.x3),
                    children: [
                      if (chief != null) botHead(chief),
                      for (final b in bots) botHead(b),
                      if (teams.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Space.x1, Space.x4, Space.x1, Space.x1),
                          child: Text(tr('Teams'),
                              key: const ValueKey('rail-teams'),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.sectionStyle.copyWith(color: p.faint)),
                        ),
                        for (final o in teams)
                          Builder(builder: (context) {
                            final k = BotStatus.teamKey(o.id);
                            return RailHead(
                              key: ValueKey('rail-$k'),
                              statusKey: k,
                              name: o.name,
                              selected: selected == k,
                              face: TeamFace(office: o, size: Lux.railFace),
                              onTap: () => onSelect(k),
                              onHold: () => onTeamHold(o),
                            );
                          }),
                      ],
                      const SizedBox(height: Space.x2),
                      // The SubMac mark (owner 2026-10-24): back to the main SubMac chat. It replaced a small "+" here,
                      // which made three "+" on one screen (the header and "New bot" already have one).
                      Center(
                        child: Semantics(
                          button: true,
                          label: tr('Back to SubMac'),
                          excludeSemantics: true,
                          child: IconButton(
                            key: const ValueKey('rail-submac'),
                            tooltip: tr('Back to SubMac'),
                            onPressed: onHome,
                            icon: const AppLogo(size: IconSize.lg),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Pinned at the foot.
                RailAction(key: const ValueKey('rail-new-bot'), icon: 'plus', label: tr('New bot'), onTap: onNewBot),
                RailAction(key: const ValueKey('rail-store'), icon: 'store', label: tr('Bot store'), onTap: onStore),
                SizedBox(height: MediaQuery.paddingOf(context).bottom + Space.x2),
              ]);
            },
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// The rail's corners: rounded on its open (trailing) side only, so it meets the chat with a soft edge.
BorderRadius railEdge(TextDirection dir) =>
    const BorderRadiusDirectional.only(topEnd: Radius.circular(Radii.sheet), bottomEnd: Radius.circular(Radii.sheet)).resolve(dir);

/// One head in the rail: the face in its status ring, the name under it. The one on screen has a soft highlight
/// behind it (no dot, no border). Tap swaps to it; hold for its options.
class RailHead extends StatelessWidget {
  const RailHead({
    super.key,
    required this.statusKey,
    required this.name,
    required this.face,
    required this.selected,
    required this.onTap,
    required this.onHold,
  });
  final String statusKey;
  final String name;
  final Widget face;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHold;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.x1, vertical: 2),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: Radii.fieldAll,
            onTap: onTap,
            onLongPress: () {
              SubHaptics.hold();
              onHold();
            },
            child: AnimatedContainer(
              duration: SubMotion.of(context, LuxMotion.quick),
              curve: LuxMotion.ease,
              padding: const EdgeInsets.symmetric(vertical: Space.x2),
              decoration: BoxDecoration(color: selected ? p.bubble : p.bubble.withValues(alpha: 0), borderRadius: Radii.fieldAll),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListenableBuilder(
                  listenable: BotStatus.I,
                  builder: (context, _) => StatusRing(key: ValueKey('ring-$statusKey'), state: BotStatus.I.of(statusKey), size: Lux.railFace, child: face),
                ),
                const SizedBox(height: Space.x1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppText.microStyle.copyWith(color: selected ? p.text : p.muted, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// An action pinned at the foot of the rail: SubMac's icon over a small label. No border, no fill.
class RailAction extends StatelessWidget {
  const RailAction({super.key, required this.icon, required this.label, required this.onTap});
  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.x2, horizontal: 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SubIcon(icon, size: IconSize.md, color: p.text),
            const SizedBox(height: 2),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: AppText.microStyle.copyWith(color: p.muted)),
          ]),
        ),
      ),
    );
  }
}

/// Bots and teams pinned to the top of the rail (after the Chief), kept on the phone.
class RailPins extends ChangeNotifier {
  RailPins._();
  static final RailPins I = RailPins._();
  static const _prefsKey = 'bots_rail_pins';

  final List<String> _ids = [];
  bool _loaded = false;

  bool has(String key) => _ids.contains(key);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _ids
        ..clear()
        ..addAll(p.getStringList(_prefsKey) ?? const []);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggle(String key) async {
    _ids.contains(key) ? _ids.remove(key) : _ids.add(key);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_prefsKey, List.of(_ids));
    } catch (_) {}
  }

  @visibleForTesting
  void reset() {
    _ids.clear();
    _loaded = true;
  }
}


/// The Bots workspace header, the same as the main SubMac chat (v1.13.95+165; it replaced a frosted band that read as
/// too big and solid). There is no bar or band: the rail toggle on the start side and Call / "+" on the end side each
/// float in their own small blurred circle ([FloatIcon]), and who you are talking to floats in a light blurred pill
/// beside the toggle: a small face in its tiny status ring and the name. Nothing sits behind the row, so the chat shows
/// through between the pieces and fades out under them ([ChatEdgeFade]). Switching chats swaps the pill's face and name
/// in place with one cross-fade (instant under reduced motion). Its height is exactly [chatTopInset], so the chat's own
/// top inset and edge fade line up with it. Mirrors itself in right-to-left languages.
class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.activeKey,
    required this.name,
    required this.face,
    required this.leading,
    this.trailing = const [],
  });

  /// 'b:<id>' or 't:<id>' of the chat on screen ('' while the first one opens).
  final String activeKey;
  final String name;
  final Widget? face;
  final Widget leading;
  final List<Widget> trailing;

  /// The face size in the pill (the tiny ring sits just outside it).
  static const double faceSize = 22;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final who = activeKey.isEmpty || name.isEmpty
        ? const SizedBox.shrink(key: ValueKey('ws-who-none'))
        : Semantics(
            key: ValueKey('ws-who-$activeKey'),
            header: true,
            label: name,
            excludeSemantics: true,
            child: FrostedSurface(
              key: const ValueKey('ws-who-pill'),
              wash: 0.24,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x1 + 2, Space.x1, Space.x3, Space.x1),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (face != null) ...[
                    ListenableBuilder(
                      listenable: BotStatus.I,
                      builder: (context, _) => StatusRing(
                        key: ValueKey('ws-head-ring-$activeKey'),
                        state: BotStatus.I.of(activeKey),
                        size: faceSize,
                        child: face!,
                      ),
                    ),
                    const SizedBox(width: Space.x2),
                  ],
                  Flexible(
                    child: Text(
                      name,
                      key: const ValueKey('ws-header-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600, height: 1.2),
                    ),
                  ),
                ]),
              ),
            ),
          );
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter - Space.x3, Space.x2, Lux.gutter - Space.x3, Space.x2),
        child: SizedBox(
          height: Lux.tap,
          child: Row(children: [
            leading,
            const SizedBox(width: Space.x2),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: AnimatedSwitcher(
                  duration: SubMotion.of(context, LuxMotion.base),
                  switchInCurve: SubMotion.settle,
                  switchOutCurve: SubMotion.leave,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: [...previous, if (current != null) current],
                  ),
                  child: who,
                ),
              ),
            ),
            const SizedBox(width: Space.x2),
            ...trailing,
          ]),
        ),
      ),
    );
  }
}
