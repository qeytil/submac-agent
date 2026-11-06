import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/bots.dart';
import 'bots_screen.dart';
import 'bot_store_screen.dart' show hireFromLink;
import '../services/hire_links.dart';
import 'offices_screen.dart';
import 'approvals_screen.dart';
import '../services/offices.dart';
import '../app_state.dart';
import '../models.dart';
import '../services/phone_tools.dart';
import '../services/tools.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import '../widgets/ask_bar.dart';
import '../widgets/approval_card.dart' show ConfirmInline;
import '../widgets/chat_extras.dart';
import '../widgets/chat_logic.dart';
import '../widgets/composer.dart';
import '../widgets/message_view.dart';
import '../widgets/chat/reply_quote.dart';
import '../widgets/page_cards.dart' show PageBuildPlan;
import '../widgets/sidebar.dart';
import '../widgets/bot_list.dart' show ChiefFace, openBotChat;
import '../services/bot_status.dart';
import '../services/cloud.dart';
import '../widgets/sub_icon.dart';
import '../widgets/motion.dart';
import '../widgets/bot_face.dart';
import '../widgets/chat/activity.dart';
import '../widgets/chat/activity_groups.dart';
import '../widgets/chat/activity_panel.dart';
import '../widgets/chat/edge_fade.dart';
import '../widgets/chat/entrance.dart';
import '../widgets/chat/typing_text.dart';
import 'billing/billing_widgets.dart';
import 'inbox_screen.dart';
import 'live_screen.dart';
import '../services/inbox.dart';
import '../services/rewards.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    state.confirmCallback = _confirm;
    // The rings in the Bots workspace follow the real run state for the whole session.
    BotStatus.I.attach(state);
    WidgetsBinding.instance.addPostFrameCallback((_) => state.onSignedIn());
    NativeBridge.onShared = _pullShare;
    NativeBridge.listen();
    _pullShare();
    _state = state;
    state.openRequest.addListener(_openRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openRequested());
    HireLinks.I.pending.addListener(_openHireLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openHireLink());
  }

  @override
  void dispose() {
    HireLinks.I.pending.removeListener(_openHireLink);
    // After sign-out this screen is gone: a notification tap must not reach it (or open things twice).
    _state?.openRequest.removeListener(_openRequested);
    if (NativeBridge.onShared == _pullShare) NativeBridge.onShared = null;
    super.dispose();
  }

  AppState? _state;

  /// A "Hire in SubMac" link (submac.site/b/<code>) opened the app.
  Future<void> _openHireLink() async {
    if (!mounted || HireLinks.I.pending.value == null) return;
    final l = HireLinks.I.take();
    if (l == null) return;
    Navigator.of(context).popUntil((x) => x.isFirst);
    await hireFromLink(context, l.code);
  }

  /// A notification asked to open an office or the approvals inbox.
  void _openRequested() {
    if (!mounted) return;
    final state = context.read<AppState>();
    final r = state.openRequest.value;
    if (r == null) return;
    state.openRequest.value = null;
    Navigator.of(context).popUntil((x) => x.isFirst);
    if (r == 'approvals') {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const ApprovalsScreen()));
    } else if (r == 'inbox' || r.startsWith('inbox/')) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => InboxScreen(openId: r.startsWith('inbox/') ? r.substring(6) : null)));
    } else if (r.startsWith('office/') && Offices.I.byId(r.substring(7)) != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => OfficeScreen(officeId: r.substring(7))));
    } else if (r.startsWith('botchat/')) {
      // CB-16: a bot's notification opens the Bots workspace on that bot (what you see is where you type).
      final b = Bots.I.byId(r.substring(8));
      if (b != null) unawaited(openBotChat(context, b));
    }
  }

  /// Something was shared into SubMac from another app ("Share to SubMac").
  Future<void> _pullShare() async {
    final m = await NativeBridge.takeShared();
    if (m == null || !mounted) return;
    final hasText = (m['text'] ?? '').toString().trim().isNotEmpty;
    final hasFiles = (m['files'] as List? ?? const []).isNotEmpty;
    if (!hasText && !hasFiles) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    final state = context.read<AppState>();
    // With a team, shared things can go straight to a bot or an office.
    if (state.hasTeam) {
      final to = await pickShareTarget(context);
      if (to == null || !mounted) return;
      if (to.startsWith('office:')) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => OfficeScreen(officeId: to.substring(7), share: m)));
        return;
      }
      if (to.startsWith('bot:')) {
        final b = Bots.I.byId(to.substring(4));
        if (b != null) await state.openBot(b);
      } else {
        state.newChat();
      }
      if (!mounted) return;
    }
    state.shareInbox.value = m;
  }

  Future<bool> _confirm(ActionRequest req) async {
    if (!mounted) return false;
    final state = context.read<AppState>();
    // The ask waits its turn in ConfirmQueue, then shows as a thin card under the newest message of the task's
    // own chat (owner, 2026-10-31) — never a modal sheet over half the screen. A stopped task or a timeout
    // folds it away as "no".
    state.confirmQueue.onClose(state.dropConfirm);
    return state.askInChat(req.convId, req);
  }

  @override
  Widget build(BuildContext context) {
    // Only what this frame shows (v1.13.101): it watched the whole AppState, so the whole chat screen (composer,
    // footer, floating bar) was rebuilt on every streamed batch of words, about 25 times a second during a reply.
    final state = context.read<AppState>();
    context.select<AppState, (String?, String?, bool, bool, String?)>(
        (s) => (s.banner, s.currentId, s.messages.isEmpty, s.loadingMessages, Bots.I.byConv(s.currentId)?.name));
    final p = Palette.of(context);
    if (state.banner != null) {
      final msg = state.banner!;
      final args = state.bannerArgs;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !state.takeBanner(msg)) return;
        // Never an empty snackbar (a halt with no reason).
        if (msg.trim().isEmpty) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(msg, args))));
      });
    }
    final bot = Bots.I.byConv(state.currentId);
    // In a bot's chat the phone's Back returns to the chat it was opened over, instead of leaving the app.
    return PopScope(
      canPop: bot == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(state.backFromBotChat());
      },
      child: Scaffold(
      key: _scaffoldKey,
      drawer: const Sidebar(),
      drawerEdgeDragWidth: MediaQuery.of(context).size.width * 0.3,
      onDrawerChanged: (open) {
        // Opening or closing the menu never leaves the keyboard up (or brings it back).
        FocusManager.instance.primaryFocus?.unfocus();
      },
      // No top bar (owner, 2026-10-24): the menu, Call and "+" float on their own over the chat, each in a small
      // blurred circle (ChatFloatBar), and the chat scrolls full height behind them.
      body: GestureDetector(
        // A tap on the paper puts the keyboard and any open message actions away.
        onTap: () {
          FocusScope.of(context).unfocus();
          selectedReply.value = null;
        },
        // The floating circles share one backdrop read (BackdropFilter.grouped), v1.13.101.
        child: BackdropGroup(child: Stack(children: [
        // The footer floats over the chat (owner 2026-10-24): no solid strip; the messages scroll behind the composer's
        // frosted pieces, and the list keeps its newest message above them (ChatFooterInset).
        FloatingChatFrame(
          body: Builder(
            builder: (context) => Padding(
              // Loading and the greeting keep clear of the floating footer; the list scrolls behind it.
              padding: EdgeInsets.only(bottom: state.messages.isEmpty || state.loadingMessages ? ChatFooterInset.of(context) : 0),
              // Loading, the empty greeting and the chat cross-fade in one full-size box: the default switcher
              // centred each child in a loose box, so the greeting and the list jumped while they crossed.
              child: AnimatedSwitcher(
                duration: SubMotion.of(context, SubMotion.base),
                switchInCurve: SubMotion.settle,
                switchOutCurve: SubMotion.leave,
                layoutBuilder: SubMotion.fillLayout,
                // Loading and the greeting start under the floating buttons; the chat list scrolls behind them and
                // keeps its own top inset (chatTopInset).
                child: state.loadingMessages
                    ? Padding(
                        key: const ValueKey('l'),
                        padding: EdgeInsets.only(top: chatTopInset(context)),
                        child: const Center(child: StatusWord('Opening')),
                      )
                    : state.messages.isEmpty
                        ? Padding(
                            key: const ValueKey('e'),
                            padding: EdgeInsets.only(top: chatTopInset(context)),
                            child: ChatGreeting(palette: p),
                          )
                        : const ChatList(key: ValueKey('m')),
              ),
            ),
          ),
          footer: const Column(mainAxisSize: MainAxisSize.min, children: [
            AskBar(),
            TaskBar(),
            // Everyday skills (Document, Scan to PDF, Translate...) moved into the composer's "+" menu.
            // CB-29: text and picked files stay with the chat they were meant for.
            Composer(perChatDrafts: true),
          ]),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ChatFloatBar(
            onMenu: () => _scaffoldKey.currentState?.openDrawer(),
            // The old header's hold actions live on the menu button now: a bot's profile in its chat, otherwise this
            // chat's options (or today's allowance on a new chat).
            onMenuHold: () {
              if (bot != null) {
                Navigator.push(context, MaterialPageRoute(builder: (_) => BotProfileScreen(botId: bot.id)));
                return;
              }
              final c = state.current;
              if (c != null) {
                showChatActions(context, c);
              } else {
                showTodaySheet(context);
              }
            },
            menuLabel: bot != null ? '${bot.name}. Menu. Hold for the profile' : 'Menu. Hold for this chat',
            callLabel: bot != null ? 'Call ${bot.name}' : 'Call Telesia',
            onCall: () => bot != null ? state.callBot(bot) : openLive(context),
            onNew: state.newChat,
            // Replies left: only while billing is on (zero width otherwise).
            middle: const WalletChip(),
          ),
        ),
        ])),
      ),
    ),
    );
  }
}

/// The height the floating chat buttons take under the status bar.
const double chatFloatHeight = Space.x2 + Lux.tap + Space.x2;

/// How far the chat's content starts from the top of the screen, so the floating buttons never cover it.
double chatTopInset(BuildContext context) => MediaQuery.paddingOf(context).top + chatFloatHeight;

/// The chat's top controls without a bar (owner, 2026-10-24): the menu on the start side, Call and "+" on the end
/// side, each floating on its own in a small blurred circle. Nothing sits behind the row, so the chat shows through
/// between them. Mirrors itself in right-to-left languages.
class ChatFloatBar extends StatelessWidget {
  const ChatFloatBar({
    super.key,
    required this.onMenu,
    this.onMenuHold,
    this.menuLabel = 'Menu',
    required this.onCall,
    this.callLabel = 'Call Telesia',
    required this.onNew,
    this.middle,
  });
  final VoidCallback onMenu;
  final VoidCallback? onMenuHold;
  final String menuLabel;
  final VoidCallback onCall;
  final String callLabel;
  final VoidCallback onNew;
  final Widget? middle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter - Space.x3, Space.x2, Lux.gutter - Space.x3, Space.x2),
        child: Row(children: [
          FloatIcon(key: const ValueKey('top-menu'), icon: 'menu', tooltip: menuLabel, onTap: onMenu, onLongPress: onMenuHold),
          const Spacer(),
          if (middle != null) middle!,
          FloatIcon(key: const ValueKey('top-call'), icon: 'phone', tooltip: callLabel, onTap: onCall),
          const SizedBox(width: Space.x2),
          FloatIcon(key: const ValueKey('top-new'), icon: 'plus', tooltip: 'New chat', onTap: onNew),
        ]),
      ),
    );
  }
}

/// One floating control: a small circle of blurred sky with the icon in it. No border, no shadow.
class FloatIcon extends StatelessWidget {
  const FloatIcon({super.key, required this.icon, required this.tooltip, required this.onTap, this.onLongPress, this.frosted = true});
  final String icon;

  /// Blurs what is behind it. Off when it already sits on a frosted band (the Bots workspace header): one blur is enough.
  final bool frosted;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final hold = onLongPress;
    return Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: ClipOval(
          child: _maybeBlur(
            frosted,
            Material(
              color: p.bg.withValues(alpha: frosted ? 0.24 : 0.14),
              child: InkWell(
                onTap: () {
                  // Put the keyboard away first, so it does not spring back when the call or chat closes.
                  FocusManager.instance.primaryFocus?.unfocus();
                  onTap();
                },
                onLongPress: hold == null
                    ? null
                    : () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        hold();
                      },
                child: SizedBox.square(dimension: Lux.tap, child: Center(child: SubIcon(icon, size: IconSize.lg, color: p.text))),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _maybeBlur(bool on, Widget child) =>
      on ? BackdropFilter.grouped(filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14), child: child) : child;
}

/// The "SubMac" wordmark, free on the paper. A gentle note follows it only when today's allowance needs a
/// word, and a small dot when something from SubMac is unread. Tap: the menu. Hold: this chat's options
/// (rename, pin, archive, delete) and today's allowance.
class ChatWordmark extends StatelessWidget {
  const ChatWordmark({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    return ValueListenableBuilder<CloudUsage>(
      valueListenable: Cloud.usage,
      builder: (context, u, _) {
        final note = u.resting ? 'Limit reached' : (u.light ? 'Shorter replies today' : '');
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            button: true,
            label: 'Open the menu',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                onTap();
              },
              onLongPress: () {
                FocusManager.instance.primaryFocus?.unfocus();
                final c = state.current;
                if (c != null) {
                  showChatActions(context, c);
                } else {
                  showTodaySheet(context);
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.x2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: Inbox.I.unread,
                      builder: (context, n, _) => n <= 0
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsetsDirectional.only(start: Space.x1, bottom: Space.x3),
                              child: Text('$n', style: AppText.microStyle.copyWith(color: p.muted, fontWeight: FontWeight.w600)),
                            ),
                    ),
                    if (note.isNotEmpty) ...[
                      const SizedBox(width: Space.x3),
                      Flexible(
                        child: Text(note,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.faint)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// In a bot's chat the wordmark is the bot: its face and name, free on the paper. Tap: the menu (with your
/// bots and teams). Hold: the bot's profile.
class BotMark extends StatelessWidget {
  const BotMark({super.key, required this.bot, required this.onTap});
  final Bot bot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Bots.I,
      builder: (context, _) {
        final presence = Bots.I.presenceOf(bot);
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            button: true,
            label: '${bot.name}. Open the menu. Hold for the profile',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                onTap();
              },
              onLongPress: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => BotProfileScreen(botId: bot.id)));
              },
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                BotAvatar(bot: bot, size: 26, presence: true, mood: presence == 'working' ? BotMood.thinking : BotMood.idle),
                const SizedBox(width: Space.x3),
                Flexible(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Brand.serif(size: Lux.wordmark - 2, color: p.text, height: 1.05)),
                    Text(Bot.presenceLabels[presence] ?? bot.role,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.captionStyle.copyWith(color: p.faint)),
                  ]),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Today at a glance: how much is left, in plain words. No tokens, no model names.
Future<void> showTodaySheet(BuildContext context) async {
  unawaited(Cloud.refreshStatus(force: true));
  await showModalBottomSheet<void>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    showDragHandle: true,
    builder: (ctx) => const TodayUsage(padding: EdgeInsetsDirectional.fromSTEB(20, 0, 20, 28)),
  );
}

/// A calm bar for today's allowance (used in the sheet and in Settings).
class TodayUsage extends StatelessWidget {
  const TodayUsage({super.key, this.padding = const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 14)});
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ValueListenableBuilder<CloudUsage>(
      valueListenable: Cloud.usage,
      builder: (context, u, _) => Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Today'), style: TextStyle(color: p.text, fontSize: AppText.lead, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (1 - u.ratio).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: p.border,
                color: u.ratio >= 0.8 ? const Color(0xFFE0A030) : p.text,
              ),
            ),
            const SizedBox(height: 10),
            Text(u.line, style: TextStyle(color: p.text, fontSize: AppText.meta)),
            const SizedBox(height: 6),
            // Voice calls have their own daily minutes.
            ValueListenableBuilder<CallMinutes>(
              valueListenable: Cloud.calls,
              builder: (context, c, _) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(c.line, style: TextStyle(color: p.text, fontSize: AppText.meta)),
              ),
            ),
            // Bots and offices have their own share of the allowance (Plan 2.2), shown once there is a bot.
            // Plan 2.4: extra allowance from rewards ("+50k today from 2 hires").
            ValueListenableBuilder<RewardState?>(
              valueListenable: Rewards.I.state,
              builder: (context, r, _) => r?.line == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(r!.line!, style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
                    ),
            ),
            if (Bots.I.bots.isNotEmpty)
              ValueListenableBuilder<BackgroundShare>(
                valueListenable: Cloud.background,
                builder: (context, b, _) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(b.line, style: TextStyle(color: p.text, fontSize: AppText.meta)),
                ),
              ),
            Text('Free every day. Resets at midnight. Call minutes reset at ${Cloud.calls.value.resetClock}.',
                style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.35)),
          ],
        ),
      ),
    );
  }
}

/// A free-floating icon in the top bar: no circle, no border.
class BarIcon extends StatelessWidget {
  const BarIcon({super.key, required this.icon, required this.onTap, required this.tooltip});
  final String icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          radius: Lux.tap / 2,
          onTap: () {
            // Put the keyboard away first, so it does not spring back when the call or chat closes.
            FocusManager.instance.primaryFocus?.unfocus();
            onTap();
          },
          child: SizedBox(width: Lux.tap + Space.x1, height: Lux.tap + Space.x1, child: Center(child: SubIcon(icon, size: IconSize.xl, color: p.text))),
        ),
      ),
    );
  }
}

/// A new chat: one quiet question in the serif that types itself out, your team in one line under it,
/// and nothing else. Lots of paper. In a bot's empty chat (no header bar, owner 2026-10-24) the greeting says who you
/// are talking to instead: the bot's face, its name and a short role line.
class ChatGreeting extends StatelessWidget {
  final Palette? palette;

  /// The chat this greeting belongs to (the Bots workspace keeps one per chat). Null follows the open chat.
  final String? convId;
  const ChatGreeting({super.key, this.palette, this.convId});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = palette ?? Palette.of(context);
    final bot = Bots.I.byConv(convId ?? state.currentId);
    // Only the plain greeting uses your name (read from the account); a bot's greeting shows the bot instead.
    final name = bot == null ? state.firstName : '';
    final List<Widget> words = bot != null
        ? [
            Entrance(child: ChiefFace(key: ValueKey('greeting-face-${bot.id}'), bot: bot, size: Lux.greetingFace)),
            const SizedBox(height: Space.x4),
            Entrance(
              delay: LuxMotion.stagger,
              child: Text(bot.name,
                  key: const ValueKey('greeting-bot-name'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Brand.serif(size: AppText.displayLarge, color: p.text, height: 1.2)),
            ),
            if (bot.role.trim().isNotEmpty) ...[
              const SizedBox(height: Space.x2),
              Entrance(
                delay: LuxMotion.stagger * 2,
                child: Text(bot.role.trim(),
                    key: const ValueKey('greeting-bot-role'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyStyle.copyWith(color: p.muted)),
              ),
            ],
          ]
        : [
            // The greeting's letters fade in once per empty chat (keyed by the chat), then it simply stays.
            // With Remove animations it stands there from the start.
            Entrance(
              child: TypingText(
                name.isEmpty ? tr('What can I do?') : tr('Hi {name}. What can I do?', {'name': name}),
                key: ValueKey('greeting-${state.currentId}'),
                textAlign: TextAlign.center,
                style: Brand.serif(size: AppText.displayLarge, color: p.text, height: 1.2),
              ),
            ),
            const SizedBox(height: Space.x5),
            // Your team in one quiet line: who is working, what needs you, what got done.
            Entrance(delay: LuxMotion.stagger * 2, child: const TeamLine()),
          ];
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Lux.gutter + Space.x4),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ...words,
              // Room under the words so they sit a little above the middle, where the eye rests.
              const SizedBox(height: Lux.turnGap * 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// The chat itself: a reversed list, so it always rests on the newest message. Something you send appears at the
/// bottom, in view, with the reply growing under it (it never jumps to the top of the screen).
class ChatList extends StatefulWidget {
  const ChatList({super.key, this.convId});

  /// The Bots workspace keeps one list per chat: this list belongs to [convId]. It remembers where you had scrolled
  /// to, and while another chat takes over (the cross-fade of a swap) it keeps showing its own messages instead of
  /// flashing the new chat's. Null on the main chat, which follows whatever chat is open.
  final String? convId;

  /// Scroll offsets by chat, kept for the app run (the newest message is 0).
  static final Map<String, double> offsets = {};

  @override
  State<ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<ChatList> {
  late final ScrollController _scroll =
      ScrollController(initialScrollOffset: widget.convId == null ? 0 : (ChatList.offsets[widget.convId] ?? 0));

  /// This chat's messages, kept while another chat is open (a per-chat list only).
  List<ChatMessage>? _own;
  /// Scrolled away from the newest message far enough to offer the way back.
  final _away = ValueNotifier<bool>(false);
  /// Something new arrived while the user was reading further up.
  final _fresh = ValueNotifier<bool>(false);
  String? _lastId;
  int _lastLen = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _away.dispose();
    _fresh.dispose();
    super.dispose();
  }

  void _onScroll() {
    // The list is reversed: offset 0 is the newest message.
    final away = _scroll.hasClients && _scroll.offset > 420;
    final id = widget.convId;
    if (id != null && _scroll.hasClients) ChatList.offsets[id] = _scroll.offset;
    if (away != _away.value) _away.value = away;
    if (!away && _fresh.value) _fresh.value = false;
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _fresh.value = false;
    final far = _scroll.offset > 2400;
    if (far || reduceMotion(context)) {
      _scroll.jumpTo(0);
    } else {
      _scroll.animateTo(0, duration: SubMotion.scroll, curve: SubMotion.settle);
    }
  }

  /// The tool steps of the turn that [idx] ends: every assistant step since the user last wrote.
  static List<TurnStep> _turnSteps(List<ChatMessage> visible, int idx, Map<String, ChatMessage> results) {
    final out = <TurnStep>[];
    for (var k = idx; k >= 0; k--) {
      final m = visible[k];
      if (m.role == 'user') break;
      final calls = m.toolCalls;
      if (calls == null || calls.isEmpty) continue;
      for (final c in calls.reversed) {
        out.add(TurnStep(c.name, c.arguments, results[c.id]?.content));
      }
    }
    return out.reversed.toList();
  }

  @override
  Widget build(BuildContext context) => _list(context);

  Widget _list(BuildContext context) {
    final state = context.watch<AppState>();
    // A per-chat list shows only its own chat: while another one is open it keeps the messages it last had.
    final mine = widget.convId == null || state.currentId == widget.convId;
    if (mine) _own = state.messages;
    final all = mine ? state.messages : (_own ?? const <ChatMessage>[]);
    final toolResults = <String, ChatMessage>{
      for (final m in all)
        if (m.role == 'tool' && m.toolCallId != null) m.toolCallId!: m,
    };
    // Messages SubMac wrote to wake a bot never show.
    final visible = all
        .where((m) => (m.role == 'user' && !m.content.startsWith(botWakeMark)) || m.role == 'assistant')
        .toList();
    // Neighbours for the action row (system notes never show).
    ChatMessage? near(int i, int dir) {
      for (var k = i + dir; k >= 0 && k < visible.length; k += dir) {
        if (visible[k].role != 'system') return visible[k];
      }
      return null;
    }
    final lastIndex = visible.length - 1;
    // The current turn: your newest message and everything SubMac has said since. It is one block at the
    // bottom of the chat, with the task line at the top of SubMac's reply (right under your message), so the
    // line scrolls with the chat and turns into the reply in place, like ChatGPT, Kimi and Hark.
    // A wake (a hidden message that starts a bot's work) also starts a turn, so a bot's new work never puts
    // the line above what it said before.
    var turnStart = visible.length;
    for (var k = all.length - 1; k >= 0; k--) {
      final m = all[k];
      if (m.role != 'user') continue;
      if (m.content.startsWith(botWakeMark)) {
        final after = all.skip(k + 1).where((x) => x.role == 'assistant').map((x) => x.id).toSet();
        turnStart = visible.indexWhere((v) => after.contains(v.id));
        if (turnStart < 0) turnStart = visible.length;
      } else {
        turnStart = visible.indexWhere((v) => v.id == m.id);
        if (turnStart < 0) turnStart = visible.length;
      }
      break;
    }
    final working = mine ? state.runsHere.where((r) => !r.side).toList() : <AgentRun>[];
    // One page build card per page per turn (owner bug 2026-10-24: two previews for one build). Each turn's page
    // writes are planned together: the first write of a page owns its card, later writes and appends feed it.
    final pagePlans = <String, PageBuildPlan>{};
    // Steps, plans and narration stay hidden (owner 2026-10-24) unless the user asked for them in that turn.
    final stepsAsked = <String>{};
    var askedNow = false;
    // The quiet activity view (owner 2026-11-03): each turn's thinking and notes fold away; a finished turn shows its
    // work as one line at the place its work began, opening to categorized sections.
    final folded = <String>{};
    final foldAt = <String, (ActivityGroups, String?)>{}; // first work message -> the turn's groups, its answer's id
    var turnGroups = ActivityGroups.of(const []);
    {
      final seg = <ChatMessage>[];
      var asked = false;
      void close() {
        final calls = [for (final m in seg) ...?m.toolCalls];
        final plan = calls.isEmpty ? PageBuildPlan.empty : PageBuildPlan.of(calls);
        for (final m in seg) {
          pagePlans[m.id] = plan;
          if (asked) stepsAsked.add(m.id);
        }
        final g = ActivityGroups.of(seg);
        turnGroups = g;
        if (!asked && !g.isEmpty) {
          String? first;
          for (var i = 0; i < seg.length; i++) {
            final work = ActivityGroups.folds(seg, i) || (seg[i].toolCalls?.isNotEmpty ?? false);
            if (ActivityGroups.folds(seg, i)) folded.add(seg[i].id);
            if (work) first ??= seg[i].id;
          }
          final answer = seg.lastWhere((m) => m.role == 'assistant' && m.name != 'reasoning' && (m.toolCalls?.isEmpty ?? true) && m.content.trim().isNotEmpty,
              orElse: () => seg.last);
          if (first != null) foldAt[first] = (g, answer.id);
        }
        seg.clear();
      }
      for (final m in visible) {
        if (m.role == 'user') {
          close();
          asked = asksForSteps(m.content);
        } else {
          seg.add(m);
        }
      }
      close();
      askedNow = asked;
    }
    final showStepsNow = state.showSteps || askedNow;
    // Sent, but the task has not started yet (saving the chat, uploading): show the thinking line at once.
    final pending = mine &&
        working.isEmpty &&
        visible.isNotEmpty &&
        visible.last.role == 'user' &&
        state.awaitingReply == visible.last.id;
    final live = working.isNotEmpty || pending;
    final turn = visible.sublist(turnStart);
    final hasBlock = turn.isNotEmpty || live;
    final history = turnStart; // items before the block
    final itemCount = history + (hasBlock ? 1 : 0);
    // The reply is being written right now (its words are on screen): the task line says so.
    final lastMsg = visible.isEmpty ? null : visible.last;
    final writing = lastMsg != null && lastMsg.role == 'assistant' && lastMsg.name != 'reasoning' && lastMsg.streaming && lastMsg.content.trim().isNotEmpty &&
        (lastMsg.toolCalls?.isEmpty ?? true) && (state.showSteps || near(lastIndex, -1)?.toolCalls?.isNotEmpty != true);

    // The user just sent something: bring the newest message into view. Something else arrived while
    // they read further up: leave them where they are and light up "New".
    final newestId = lastMsg?.id;
    if (newestId != _lastId || visible.length != _lastLen) {
      final mine = lastMsg?.role == 'user' && lastMsg?.animateIn == true;
      final grew = _lastId != null && visible.length > _lastLen;
      _lastId = newestId;
      _lastLen = visible.length;
      if (mine) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients && _scroll.offset > 0) _toBottom();
        });
      } else if (grew && _away.value) {
        _fresh.value = true;
      }
    }

    // Chat content reads a touch smaller than the rest of the app: calm and roomy, not shouty.
    final mq = MediaQuery.of(context);

    Widget assistantView(ChatMessage m, int idx, {bool inTurn = false}) {
      // A reply held on screen while the work is still checked is progress, not the answer: while the task runs only
      // the status line shows (the checked final reply replaces it), unless the user asked to see the steps.
      if (!state.showSteps && !stepsAsked.contains(m.id) && working.any((r) => identical(r.heldReply, m))) {
        return SizedBox.shrink(key: ValueKey(m.id));
      }
      // Show actions only on the final assistant message of a turn.
      final next = near(idx, 1), prev = near(idx, -1);
      final nextIsAssistant = next?.role == 'assistant';
      final midTask = prev?.role == 'assistant' && (prev?.toolCalls?.isNotEmpty ?? false);
      // The final answer of a task carries its steps, folded ("Worked for 1m 12s · 5 steps"). In the current
      // turn the fold sits at the top of the reply instead (where the task line was), so nothing jumps.
      final finalAnswer = m.name != 'reasoning' && (m.toolCalls?.isEmpty ?? true) && m.content.trim().isNotEmpty && !nextIsAssistant;
      // The steps behind a final answer are not shown in the chat any more; they wait in the answer's
      // long-press sheet ("How I did it").
      final work = finalAnswer && !state.showSteps && !m.streaming ? stepsBefore(visible, idx, toolResults, state.stepLabel) : const <StepLine>[];
      return AssistantMessageView(
        key: ValueKey(m.id),
        pagePlan: pagePlans[m.id] ?? PageBuildPlan.empty,
        stepsAsked: stepsAsked.contains(m.id),
        // The newest turn is still working: its page card stays in its building state and no page preview shows yet.
        turnRunning: inTurn && live,
        midTask: midTask,
        workSteps: work,
        worked: state.workedFor[m.id],
        message: m,
        toolResults: toolResults,
        showActions: !nextIsAssistant && !state.busy,
        isLast: idx == lastIndex,
        turnSteps: !nextIsAssistant && !state.busy && midTask ? _turnSteps(visible, idx, toolResults) : const [],
      );
    }

    Widget assistant(int idx, {bool inTurn = false}) {
      final m = visible[idx];
      if (m.name == 'submac_team') return TeamMessageCard(key: ValueKey(m.id), message: m);
      final quiet = !state.showSteps && !stepsAsked.contains(m.id);
      // The finished turn's work, as one line where it began (the live turn has the working line instead).
      final fold = quiet && !(inTurn && live) ? foldAt[m.id] : null;
      if (fold != null) {
        return Column(key: ValueKey('fold-${m.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          ActivityFold(groups: fold.$1, results: toolResults, worked: fold.$2 == null ? null : state.workedFor[fold.$2]),
          if (!folded.contains(m.id)) assistantView(m, idx, inTurn: inTurn),
        ]);
      }
      if (quiet && folded.contains(m.id)) return SizedBox.shrink(key: ValueKey(m.id));
      return assistantView(m, idx, inTurn: inTurn);
    }

    /// The live approval ask (owner, 2026-10-31): a thin card under the newest message of this chat —
    /// never a modal sheet. An ask from another chat waits there, not here.
    Widget confirmSlot() {
      return ValueListenableBuilder<ConfirmAsk?>(
        valueListenable: state.confirmNow,
        builder: (context, ask, _) {
          if (ask == null || (ask.convId != null && ask.convId != state.currentId)) return const SizedBox.shrink();
          return ConfirmInline(key: ValueKey('ask-${ask.req.hashCode}'), request: ask.req, onAnswer: ask.answer);
        },
      );
    }

    Widget block() {
      final userFirst = turn.isNotEmpty && turn.first.role == 'user';
      final replies = userFirst ? turn.skip(1).toList() : turn;
      // Text of the reply is on screen (not just steps): a plain answer then takes over from the line.
      final answerShowing = replies.any((m) => m.role == 'assistant' && m.name != 'reasoning' && (m.toolCalls?.isEmpty ?? true) && m.content.trim().isNotEmpty);
      // Only the live activity line sits at the top of the reply. When the task ends it folds away softly
      // (the steps it took moved into the answer's long-press sheet), so a turn never shows two lines.
      final Widget head = live
          ? WorkingLine(
              key: const ValueKey('turn-live'),
              run: working.isEmpty ? null : working.last,
              more: working.isEmpty ? 0 : working.length - 1,
              answerShowing: answerShowing,
              writing: writing,
              showSteps: showStepsNow,
              activity: showStepsNow ? null : turnGroups,
              results: toolResults,
            )
          : const SizedBox(key: ValueKey('turn-none'), width: double.infinity);
      // The turn takes only its own height: the list is reversed, so it sits at the bottom, in view. (It used to
      // be stretched to a whole screen, which left each new message stranded at the top until you scrolled.)
      return KeyedSubtree(
        key: ValueKey('turn-${turn.isEmpty ? 'live' : turn.first.id}'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (userFirst) MessageAnchor(key: ValueKey(turn.first.id), id: turn.first.id, child: UserMessageView(message: turn.first)),
            SubSize(
              duration: LuxMotion.base,
              alignment: AlignmentDirectional.topStart,
              child: AnimatedSwitcher(
                duration: SubMotion.of(context, LuxMotion.base),
                switchInCurve: SubMotion.settle,
                switchOutCurve: SubMotion.leave,
                layoutBuilder: SubMotion.topStartLayout,
                child: head,
              ),
            ),
            for (var k = userFirst ? turnStart + 1 : turnStart; k < turnStart + turn.length; k++)
              MessageAnchor(
                key: ValueKey('a-${visible[k].id}'),
                id: visible[k].id,
                child: visible[k].role == 'user' ? UserMessageView(key: ValueKey(visible[k].id), message: visible[k]) : assistant(k, inTurn: true),
              ),
          ],
        ),
      );
    }

    final list = MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1.0) * 0.93)),
      child: ChatScrollScope(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          reverse: true,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          // The top of the list clears the floating buttons, so the oldest line you scroll to is never under them.
          // The bottom clears the floating composer, so the newest message rests fully above it.
          padding: EdgeInsets.only(top: Space.x3 + chatTopInset(context), bottom: Space.x6 + ChatFooterInset.of(context)),
          itemCount: itemCount + 1,
          // Keep each bubble's state when the list shifts (a new message), so nothing re-animates on send.
          findChildIndexCallback: (key) {
            if (key is! ValueKey) return null;
            final v = key.value;
            if (v is! String) return null;
            if (v.startsWith('turn-')) return hasBlock ? 1 : null;
            final idx = visible.indexWhere((m) => m.id == v);
            if (idx < 0 || idx >= history) return null;
            return (history - 1 - idx) + (hasBlock ? 2 : 1);
          },
          itemBuilder: (context, i) {
            // The live approval ask: a thin card under the newest message of this chat (owner, 2026-10-31).
            if (i == 0) return confirmSlot();
            i -= 1;
            if (hasBlock) {
              if (i == 0) return block();
              i -= 1;
            }
            final idx = history - 1 - i;
            final m = visible[idx];
            // Each message can be found by a reply's quote (tap the quote to jump here).
            return MessageAnchor(
              key: ValueKey(m.id),
              id: m.id,
              child: m.role == 'user' ? UserMessageView(message: m) : assistant(idx),
            );
          },
        ),
      ),
    );
    // Soft edges (owner 2026-10-24): older messages fade out under the floating top controls, the newest ones fade
    // softly at the bottom edge above the navigation bar while the composer floats over them.
    return Stack(children: [
      Positioned.fill(
        child: ChatEdgeFade(
          top: chatTopInset(context),
          bottom: MediaQuery.paddingOf(context).bottom,
          child: list,
        ),
      ),
      Positioned(
        right: 0,
        left: 0,
        bottom: 10 + ChatFooterInset.of(context),
        child: ValueListenableBuilder<bool>(
          valueListenable: _away,
          builder: (context, away, _) => IgnorePointer(
            ignoring: !away,
            // The fade and the rise share one duration and curve (they ran 180 ms linear against 220 ms eased).
            child: AnimatedOpacity(
              opacity: away ? 1 : 0,
              duration: SubMotion.of(context, SubMotion.quick),
              curve: SubMotion.settle,
              child: AnimatedSlide(
                offset: away ? Offset.zero : const Offset(0, 0.4),
                duration: SubMotion.of(context, SubMotion.quick),
                curve: SubMotion.settle,
                child: Center(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _fresh,
                    builder: (context, fresh, _) => JumpToBottom(onTap: _toBottom, fresh: fresh),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
