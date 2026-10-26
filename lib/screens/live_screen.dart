import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/bots.dart';
import '../services/cloud.dart';
import '../services/live_controller.dart';
import '../services/live_session.dart';
import '../services/system_bridge.dart';
import '../widgets/lux_kit.dart';
import '../theme.dart';
import '../widgets/ask_bar.dart';
import '../widgets/composer.dart';
import '../ui/tokens.dart';
import '../ui/haptics.dart';
import '../widgets/bot_face.dart';
import '../widgets/sub_avatar.dart';
import '../widgets/surface.dart';
import '../services/full_access.dart';
import '../ui/i18n.dart';
import '../widgets/logo.dart';
import '../widgets/sub_icon.dart';
import '../widgets/chat/activity.dart';
import '../widgets/chat/entrance.dart';

Route<void> liveRoute() => PageRouteBuilder(
      opaque: true,
      transitionDuration: SubMotion.page,
      pageBuilder: (_, __, ___) => const LiveScreen(),
      // SubMac motion: the call comes up from the paper and settles.
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: SubMotion.settle, reverseCurve: SubMotion.leave),
        child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(CurvedAnimation(parent: a, curve: SubMotion.settle)), child: child),
      ),
    );

Future<void> openLive(BuildContext context, {String mode = ''}) async {
  final state = context.read<AppState>();
  state.liveMode = mode;
  // Calls have their own daily minutes, apart from the chat allowance.
  if (!state.liveAvailable || Cloud.calls.value.out) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(Cloud.calls.value.out
            ? Cloud.calls.value.usedUpMessage
            : 'Voice isn\'t available right now. You can still type to SubMac.')));
    return;
  }
  if (!context.mounted) return;
  SubHaptics.call();
  final ctl = state.liveCtl;
  if (ctl.floating) await ctl.unfloat(showScreen: false);
  await ctl.start();
  if (!context.mounted || ctl.screenOpen) return;
  await Navigator.push(context, liveRoute());
}

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  late final LiveController _ctl;
  bool _captions = true;
  bool _leaving = false;

  /// Closes the Live screen exactly once. Navigator.pop skips PopScope, so it can never get stuck.
  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  LiveSession? get _sOrNull => _ctl.session;

  @override
  void initState() {
    super.initState();
    _ctl = context.read<AppState>().liveCtl;
    _ctl.screenOpen = true;
    _ctl.addListener(_onCtl);
    if (_ctl.session == null) _ctl.start();
    if (_ctl.floating) _ctl.unfloat(showScreen: false);
  }

  void _onCtl() {
    if (!mounted) return;
    if (_ctl.session == null) {
      if (_ctl.restarting) return;
      _leave();
      return;
    }
    setState(() {});
  }

  Future<void> _end() async {
    if (_leaving) return;
    SubHaptics.call();
    _leave();
    await _ctl.end();
  }

  Future<void> _float() async {
    final ok = await _ctl.float();
    if (!mounted) return;
    if (!ok) {
      final go = await luxConfirm(context,
          title: 'Keep Live on top',
          message: 'To talk with SubMac while you use other apps, allow "Display over other apps" for SubMac.',
          action: 'Allow',
          cancel: 'Not now');
      if (go) await SystemBridge.I.openPermission('overlay');
      return;
    }
    _leave();
    await SystemBridge.I.moveToBack();
  }

  @override
  void dispose() {
    _ctl.screenOpen = false;
    _ctl.removeListener(_onCtl);
    super.dispose();
  }

  String get _statusText {
    final _s = _sOrNull;
    if (_s == null) return 'Ending';
    switch (_s.status) {
      case LiveStatus.connecting:
        return _s.reconnecting ? 'Reconnecting' : 'Connecting';
      case LiveStatus.listening:
        return _s.muted ? 'Muted' : 'Listening';
      case LiveStatus.speaking:
        return 'Speaking';
      case LiveStatus.thinking:
        return _s.toolLabel.isEmpty ? 'Thinking' : _s.toolLabel;
      case LiveStatus.ended:
        return 'Ending';
      case LiveStatus.error:
        return 'Call ended';
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final _s = _sOrNull;
    if (_s == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave());
      return const Scaffold(body: SizedBox.shrink());
    }
    final recent = _s.turns.length > 2 ? _s.turns.sublist(_s.turns.length - 2) : _s.turns;
    final ended = _s.status == LiveStatus.error;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // System back ends the call.
        if (!didPop && !_leaving) _end();
      },
      child: Scaffold(
        body: CallView(
          bot: Bots.I.byId(state.liveCtl.botId ?? ''),
          status: _statusText,
          phase: switch (_s.status) {
            LiveStatus.connecting || LiveStatus.thinking => CallPhase.thinking,
            LiveStatus.speaking => CallPhase.speaking,
            LiveStatus.listening => _s.muted ? CallPhase.muted : CallPhase.listening,
            _ => CallPhase.ended,
          },
          level: _s.level,
          trusted: state.fullAccess,
          note: _s.error == null ? (_s.notice ?? _s.minutesLeftText) : '',
          noteStrong: _s.notice != null,
          error: _s.error,
          errorDetail: _s.closeInfo,
          captions: _captions ? [for (final t in recent) (t.role == 'user', t.shown.trim())] : const [],
          captionsOn: _captions,
          canRetry: ended && !(_s.secondsLeft == 0 || Cloud.calls.value.out),
          endLabel: state.runsHere.any((r) => !r.side) ? 'End, see chat' : 'End',
          onFloat: _float,
          onCaptions: () => setState(() => _captions = !_captions),
          onMute: () => _s.toggleMute(),
          onRetry: () => _ctl.restart(),
          onEnd: _end,
          extras: const [AskBar(), TaskBar()],
        ),
      ),
    );
  }
}

/// Where a call is, for the look of its centre.
enum CallPhase { thinking, listening, speaking, muted, ended }

/// The call, drawn from plain values so it can be shown and tested on its own (owner, 2026-10-23):
/// no boxes, no rings, no glow, SubMac's own icons, few words, SubMac's motion. Two styles:
/// * SubMac call ([bot] null): the SubMac mark alone on the paper, calm, breathing a touch with the voice.
/// * Bot call: that bot's face (reacting to the call), its name and its role.
class CallView extends StatelessWidget {
  const CallView({
    super.key,
    required this.bot,
    required this.status,
    required this.phase,
    this.level = 0,
    this.trusted = false,
    this.note = '',
    this.noteStrong = false,
    this.error,
    this.errorDetail,
    this.captions = const [],
    this.captionsOn = true,
    this.canRetry = false,
    this.endLabel = 'End',
    required this.onFloat,
    required this.onCaptions,
    required this.onMute,
    required this.onRetry,
    required this.onEnd,
    this.extras = const [],
  });

  final Bot? bot;
  final String status;
  final CallPhase phase;
  final double level;
  final bool trusted;
  final String note;
  final bool noteStrong;
  final String? error;
  final String? errorDetail;

  /// The last turns: (yours?, words).
  final List<(bool, String)> captions;
  final bool captionsOn;
  final bool canRetry;
  final String endLabel;
  final VoidCallback onFloat;
  final VoidCallback onCaptions;
  final VoidCallback onMute;
  final VoidCallback onRetry;
  final VoidCallback onEnd;
  final List<Widget> extras;

  BotMood get _mood => switch (phase) {
        CallPhase.listening => BotMood.listening,
        CallPhase.speaking => BotMood.speaking,
        CallPhase.thinking => BotMood.thinking,
        _ => BotMood.idle,
      };

  MarkMode get _mark => switch (phase) {
        CallPhase.thinking => MarkMode.thinking,
        CallPhase.speaking => MarkMode.working,
        _ => MarkMode.idle,
      };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = bot;
    final lv = level.clamp(0.0, 1.0);
    final quiet = phase == CallPhase.muted || phase == CallPhase.ended;
    final ended = phase == CallPhase.ended;
    final Widget centre = b == null
        ? Column(key: const ValueKey('submac-call'), mainAxisSize: MainAxisSize.min, children: [
            RepaintBoundary(
              child: AnimatedScale(
                duration: SubMotion.quick,
                curve: SubMotion.settle,
                scale: quiet ? 0.94 : 1 + 0.08 * lv,
                child: AnimatedOpacity(duration: SubMotion.base, opacity: quiet ? 0.45 : 1, child: AgentMark(size: 96, mode: _mark)),
              ),
            ),
            const SizedBox(height: Space.x6),
            Text('SubMac', style: Brand.display(size: 40, color: p.text)),
          ])
        : Column(key: const ValueKey('bot-call'), mainAxisSize: MainAxisSize.min, children: [
            RepaintBoundary(
              child: AnimatedScale(
                duration: SubMotion.quick,
                curve: SubMotion.settle,
                scale: 1 + 0.05 * lv,
                // The face the owner chose for this bot (Grok-style avatar); an older animated face still reacts to the call.
                child: AvatarSpec.parse(b.look) != null || (b.look ?? '').isEmpty
                    ? AnimatedOpacity(
                        duration: SubMotion.base,
                        opacity: quiet ? 0.6 : 1,
                        child: SubAvatar(spec: AvatarSpec.parse(b.look) ?? AvatarSpec.seeded(b.id), size: 132),
                      )
                    : BotFace(mood: _mood, seed: b.id, size: 132, dim: quiet || !b.active),
              ),
            ),
            const SizedBox(height: Space.x6),
            Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Brand.display(size: 40, color: p.text)),
            const SizedBox(height: Space.x1),
            Text(b.role, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.muted)),
          ]);
    return SafeArea(
      child: Column(
        children: [
          // Top: two quiet words, free on the paper.
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x2, 0),
            child: Row(children: [
              if (trusted || FullAccess.I.on)
                Text(tr(FullAccess.I.on ? 'Full access' : 'Trusted'), style: TextStyle(color: p.faint, fontSize: AppText.micro)),
              const Spacer(),
              _CallText(label: 'Float', onTap: onFloat),
              _CallText(label: captionsOn ? 'Hide words' : 'Words', onTap: onCaptions),
            ]),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Entrance(child: centre),
                  const SizedBox(height: Space.x5),
                  // The status: plain words only, settling in and breathing while it connects or thinks.
                  SizedBox(
                    height: 28,
                    child: StatusWord(status,
                        kind: phase == CallPhase.thinking ? ActivityKind.thinking : ActivityKind.working,
                        style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w500),
                        color: ended ? p.text : p.muted),
                  ),
                  if (error == null && note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(32, Space.x2, 32, 0),
                      child: Text(note,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: noteStrong ? p.text : p.faint,
                              fontSize: AppText.meta,
                              fontWeight: noteStrong ? FontWeight.w500 : FontWeight.w400)),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(32, Space.x3, 32, 0),
                      child: Text(error!, textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
                    ),
                  if (error != null && errorDetail != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(32, 6, 32, 0),
                      child: Text(errorDetail!, textAlign: TextAlign.center, style: TextStyle(color: p.faint, fontSize: AppText.caption, height: 1.3)),
                    ),
                ]),
              ),
            ),
          ),
          if (captions.isNotEmpty)
            // The words sit on the shared sky surface so they read on the day and the night sky alike.
            SurfaceGroup(
              margin: const EdgeInsetsDirectional.fromSTEB(Lux.gutter - Space.x2, 0, Lux.gutter - Space.x2, Space.x4),
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x4, Space.x1),
              children: [
                for (final (mine, words) in captions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.x2),
                    child: Entrance(
                      key: ValueKey(words.hashCode),
                      child: Text(words,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: mine ? p.faint : p.text, fontSize: AppText.lead, height: 1.45)),
                    ),
                  ),
              ],
            ),
          ...extras,
          // Controls: SubMac's own icons over one short word each. No buttons, no fills, no outlines.
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x6, Space.x2, Space.x6, Space.x6),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              canRetry
                  ? _CallControl(key: const ValueKey('call-again'), icon: 'refresh', label: 'Again', onTap: onRetry)
                  : _CallControl(
                      key: const ValueKey('call-mute'),
                      icon: 'mic',
                      label: phase == CallPhase.muted ? 'Unmute' : 'Mute',
                      dim: phase == CallPhase.muted,
                      onTap: ended ? null : onMute,
                    ),
              _CallControl(key: const ValueKey('call-end'), icon: 'close', label: endLabel, color: p.accent, onTap: onEnd),
            ]),
          ),
        ],
      ),
    );
  }
}

/// A quiet word in the call's top corner.
class _CallText extends StatelessWidget {
  const _CallText({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
        style: TextButton.styleFrom(foregroundColor: Palette.of(context).muted, visualDensity: VisualDensity.compact),
        onPressed: onTap,
        child: Text(tr(label), style: const TextStyle(fontSize: AppText.meta, fontWeight: FontWeight.w500)),
      );
}

/// A call control: SubMac's own icon over one short word. No circle, no fill, no outline.
class _CallControl extends StatelessWidget {
  const _CallControl({super.key, required this.icon, required this.label, required this.onTap, this.color, this.dim = false});
  final String icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = onTap == null ? p.faint : (color ?? (dim ? p.muted : p.text));
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        radius: 44,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedOpacity(duration: SubMotion.quick, opacity: dim ? 0.5 : 1, child: SubIcon(icon, size: 28, color: c)),
            const SizedBox(height: Space.x2),
            Text(label, style: TextStyle(color: c, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}
