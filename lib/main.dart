import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/bots_screen.dart';
import 'app_state.dart';
import 'services/forged_tools.dart';
import 'services/billing/billing_service.dart';
import 'services/bot_sync.dart';
import 'services/browser/skill_sync.dart';
import 'services/first_launch.dart';
import 'services/full_access.dart';
import 'services/intro_sound.dart';
import 'services/cloud.dart';
import 'services/hire_links.dart';
import 'services/inbox.dart';
import 'services/rewards.dart';
import 'services/push.dart';
import 'services/updater.dart';
import 'config.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/intro_screen.dart';
import 'screens/live_screen.dart';
import 'screens/settings_screen.dart' show VoiceScreen;
import 'services/live_controller.dart';
import 'theme.dart';
import 'ui/i18n.dart';
import 'ui/intro_motion.dart';
import 'ui/motion.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'widgets/browser_layer.dart';
import 'services/session_rules.dart';
import 'services/tools.dart' show AgentTools;
import 'widgets/update_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge to edge: the app (and its sky) draws behind the status bar and the navigation bar, so the sky fills the
  // whole screen on tall phones instead of stopping above a solid navigation bar.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  // Errors never crash the app or paint a red screen: log them and keep going.
  FlutterError.onError = (d) {
    FlutterError.presentError(d);
    debugPrint('SubMac UI error: ${LogScrub.clean(d.exceptionAsString())}');
  };
  PlatformDispatcher.instance.onError = (e, st) {
    debugPrint('SubMac error: ${LogScrub.clean(e)}');
    return true;
  };
  ErrorWidget.builder = (d) => const SizedBox.shrink();
  try {
    await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseAnonKey);
  } catch (e) {
    debugPrint('Supabase init failed: $e');
  }
  // "Hire in SubMac" links from submac.site/b/<code> (kept until the signed-in home screen takes them).
  HireLinks.I.listen();
  // App language: follows the phone unless chosen in Settings > Language (PLAN.md 3.4).
  await AppLang.I.load();
  await FullAccess.I.load();
  // First-launch intro flag and a sign-in tick still waiting to be saved on the account (both local, read before the
  // first frame so later starts never wait on them).
  await IntroFlag.load();
  await ConsentPending.load();
  // The workspace folder is known before the first chat draws, so cards with relative file paths find their files
  // (they said "Not found on this phone" on a fresh start).
  try {
    await AgentTools.workspaceDir();
  } catch (_) {}
  // The tools the agent made for itself (tool_make), offered from the first step.
  unawaited(ForgedTools.load().catchError((_) {}));
  final state = AppState();
  try {
    await state.initLocal();
  } catch (e) {
    debugPrint('initLocal failed: $e');
  }
  // Push (plan 2.1). Optional: if Firebase fails the app runs as before, just without push.
  unawaited(Push.I.init().catchError((_) {}));
  // Plan 2.4 rewards (invite link, claim a referral once after sign-up) and the "From SubMac" inbox.
  unawaited(Rewards.I.init().catchError((_) {}));
  unawaited(Inbox.I.init().catchError((_) {}));
  // In-app updates: the update window shows on every start while a newer version is published.
  unawaited(Updater.I.init().catchError((_) {}));
  // Billing (step 6): inert until /status says billing is on; finishes checking payments started before a restart.
  Billing.I.onToast = (m) {
    final ctx = appNavKey.currentContext;
    if (ctx != null) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(m)));
  };
  unawaited(Billing.I.init().catchError((_) {}));
  try {
    Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      if (s.event == AuthChangeEvent.signedOut) Billing.I.signedOut();
      if (s.event == AuthChangeEvent.signedIn) unawaited(Billing.I.recoverPending());
    }, onError: (_) {});
  } catch (_) {}
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: state),
      ChangeNotifierProvider<LiveController>.value(value: state.liveCtl),
    ],
    child: const AgentApp(),
  ));
}

final appNavKey = GlobalKey<NavigatorState>();

class AgentApp extends StatefulWidget {
  const AgentApp({super.key});

  @override
  State<AgentApp> createState() => _AgentAppState();
}

class _AgentAppState extends State<AgentApp> with WidgetsBindingObserver {
  /// The intro plays on the very first open, before anyone has signed in on this phone.
  late final bool _showIntro = _firstOpen();

  static bool _firstOpen() {
    var signedIn = false;
    try {
      signedIn = Supabase.instance.client.auth.currentSession != null;
    } catch (_) {}
    final show = shouldShowIntro(seen: IntroFlag.seen, signedIn: signedIn);
    if (!show && !IntroFlag.seen) unawaited(IntroFlag.markSeen());
    return show;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = context.read<AppState>();
    state.liveCtl.openScreen = () {
      final nav = appNavKey.currentState;
      if (nav == null || state.liveCtl.screenOpen) return;
      nav.push(liveRoute());
    };
    state.openSystemSettings = () => appNavKey.currentState?.push(MaterialPageRoute(builder: (_) => const VoiceScreen()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final state = context.read<AppState>();
    if (s == AppLifecycleState.resumed) {
      state.setAppVisible(true);
      unawaited(Updater.I.resumed());
      if (Supabase.instance.client.auth.currentSession != null) {
        Cloud.refreshStatus();
        // A task the phone killed while SubMac was away picks up where it left off.
        unawaited(state.resumeKilledRuns().catchError((Object e) => debugPrint('resume runs: $e')));
        BotSync.I.resumed();
        SkillSync.I.resumed();
        Inbox.I.refresh();
        Rewards.I.refresh();
      }
    } else if (s == AppLifecycleState.paused) {
      state.setAppVisible(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, ThemeMode>((s) => s.themeMode);
    final easy = context.select<AppState, bool>((s) => s.easyMode);
    return ListenableBuilder(
      listenable: AppLang.I,
      builder: (context, _) => MaterialApp(
      locale: AppLang.I.locale,
      supportedLocales: const [Locale('so'), Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        SomaliMaterialFallback(),
        SomaliCupertinoFallback(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      // Switching looks eases on SubMac's own curve, in step with the sky's veils (it was a 200 ms linear fade
      // while the sky's veils switched at once).
      themeAnimationDuration: SubMotion.base,
      themeAnimationCurve: SubMotion.settle,
      navigatorKey: appNavKey,
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final page = AnnotatedRegion<SystemUiOverlayStyle>(
          // Black system bars on Ink so the whole screen is true OLED black.
          value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
            statusBarColor: Colors.transparent,
            // See-through navigation bar: the sky runs under it (edge to edge, see main()).
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
          ),
          // The sky follows the user's clock in both looks (daylight by day, starry night after dusk): behind every screen.
          // The browser layer sits OUTSIDE the sky: its hidden page lies under the app (sky included) on an opaque floor,
          // and its live view lies above it. Inside the sky, the page bled through the see-through screens.
          child: BrowserLayer(
            child: SkyBackground(
              dark: dark,
              child: UpdateLayer(child: IncomingCallLayer(child: child ?? const SizedBox.shrink())),
            ),
          ),
        );
        if (!easy) return page;
        // Easy mode: everything a little bigger and easier to read.
        final mq = MediaQuery.of(context);
        return MediaQuery(data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1.0) * 1.15)), child: page);
      },
      home: LaunchGate(showIntro: _showIntro, child: const AuthGate()),
    ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _sub;

  @override
  void initState() {
    super.initState();
    // After a reset (the emailed code, or the link in older emails) SubMac asks for the new password.
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      final codeReset = s.event == AuthChangeEvent.signedIn && AuthFlow.takePendingReset();
      if (s.event == AuthChangeEvent.passwordRecovery || codeReset) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = appNavKey.currentContext;
          if (ctx != null) showNewPasswordSheet(ctx);
        });
      }
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, _) {
        final session = auth.currentSession;
        final step = gateStep(
          signedIn: session != null,
          needsVerify: session != null && AuthRules.needsVerificationFor(session.user),
          hasConsent: session != null && AuthRules.hasConsentFor(session.user),
          ticked: ConsentPending.active,
        );
        // An account that already carries the agreement never needs the remembered tick.
        if (step == GateStep.home && ConsentPending.active) unawaited(ConsentPending.clear());
        final Widget page = switch (step) {
          GateStep.signIn => const AuthScreen(key: ValueKey('auth')),
          // An email-and-password account opens only once its email is verified.
          GateStep.verify => AuthScreen(key: const ValueKey('verify'), verifyEmail: session!.user.email),
          // Ticked on the sign-in screen: saved on the account right away, out of sight.
          GateStep.recordConsent => const ConsentRecorder(key: ValueKey('consent-save')),
          GateStep.confirmConsent => const AuthScreen(key: ValueKey('consent-confirm'), confirmOnly: true),
          GateStep.home => HomeScreen(key: ValueKey(session!.user.id)),
        };
        return GateSwitch(child: page);
      },
    );
  }
}

/// The intro plays on the first open of an install, and only before anyone is signed in on this phone.
bool shouldShowIntro({required bool seen, required bool signedIn}) => !seen && !signedIn;

/// Where the app opens, given the account on this phone.
enum GateStep { signIn, verify, recordConsent, confirmConsent, home }

/// Every account confirms 18+ and agrees to the Terms and Privacy Policy once (again if consentVersion goes up). The
/// box is on the sign-in screen, so after sign-in the agreement is saved without another page ([GateStep.recordConsent]).
/// Accounts that already agreed go straight in. Only a session kept from an older SubMac that never agreed and never
/// ticked the box on this phone is asked on the sign-in screen's own agreement view ([GateStep.confirmConsent]).
GateStep gateStep({required bool signedIn, required bool needsVerify, required bool hasConsent, required bool ticked}) {
  if (!signedIn) return GateStep.signIn;
  if (needsVerify) return GateStep.verify;
  if (hasConsent) return GateStep.home;
  return ticked ? GateStep.recordConsent : GateStep.confirmConsent;
}

/// The move between sign-in and chat (and the intro and sign-in): the new page fades in while settling from a
/// slight scale, over [IntroMotion.handoff], instead of a hard cut. With Remove animations it simply switches.
class GateSwitch extends StatelessWidget {
  const GateSwitch({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: SubMotion.of(context, IntroMotion.handoff),
      switchInCurve: IntroMotion.easeInOut,
      switchOutCurve: SubMotion.leave,
      layoutBuilder: SubMotion.fillLayout,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween<double>(begin: 0.97, end: 1).animate(a), child: child),
      ),
      child: child,
    );
  }
}

/// The first-launch intro in front of the sign-in screen. It plays once per install, only when nobody is signed in
/// yet (someone updating SubMac while signed in goes straight to chat and never sees it), and hands over to sign-in
/// with [GateSwitch]. Later starts never wait on it: [IntroFlag.seen] is read before the first frame.
class LaunchGate extends StatefulWidget {
  const LaunchGate({super.key, required this.child, required this.showIntro, this.sound});
  final Widget child;
  final bool showIntro;
  final IntroSound? sound;

  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate> {
  late bool _intro = widget.showIntro;

  void _done() {
    unawaited(IntroFlag.markSeen());
    if (mounted) setState(() => _intro = false);
  }

  @override
  Widget build(BuildContext context) => GateSwitch(
        child: _intro
            ? IntroScreen(key: const ValueKey('intro'), onDone: _done, sound: widget.sound)
            : KeyedSubtree(key: const ValueKey('app'), child: widget.child),
      );
}


/// How much of the night sky shows at a given local time: 0 by day, 1 at night, easing over dusk
/// (17:00 to 19:00) and dawn (05:00 to 07:00) so the change is never a jump.
double skyNightness(DateTime t) {
  final h = t.hour + t.minute / 60.0;
  double ease(double x) => x * x * (3 - 2 * x);
  if (h >= 19 || h < 5) return 1;
  if (h >= 7 && h < 17) return 0;
  if (h >= 17) return ease((h - 17) / 2);
  return 1 - ease((h - 5) / 2);
}

/// The sky's slow drift at loop phase [a] (radians): a zoom about the centre and a shift (fractions of the screen,
/// applied before the zoom). The zoom always stays larger than the shift needs: the picture already covers the screen
/// (BoxFit.cover at the screen's own size, whatever its shape), and at every frame the zoomed, shifted picture still
/// reaches past every edge, so no gap ever shows on any screen size, shape or rotation. [skyCovers] checks it.
({double scale, double dx, double dy}) skyDrift(double a) =>
    (scale: 1.16 + 0.04 * math.sin(a), dx: 0.025 * math.sin(a), dy: 0.018 * math.cos(a));

/// True when a picture covering the screen, zoomed by [d].scale about the centre after a shift of ([d].dx, [d].dy)
/// screen fractions, still covers the whole screen with at least [margin] (a fraction of the screen) to spare.
bool skyCovers(({double scale, double dx, double dy}) d, {double margin = 0.005}) {
  final room = (d.scale - 1) / 2;
  return room - d.dx.abs() * d.scale >= margin && room - d.dy.abs() * d.scale >= margin;
}

/// How much daylight paper covers the night sky in the light look, so its dark text stays readable.
const double lightNightVeil = 0.62;

/// How much night ink covers the daylight sky in the dark look (Ink), so its light text stays readable by day.
const double darkDayVeil = 0.58;

/// How often the sky re-reads the clock while the app is open (it also re-reads on every resume).
const Duration skyTick = Duration(seconds: 30);

/// The sky behind every screen. It follows the user's own clock (local device time, never UTC) in both looks:
/// daylight 07:00 to 17:00, dusk 17:00 to 19:00, night 19:00 to 05:00, dawn 05:00 to 07:00 (owner, 2026-10-24: "the day and
/// night bg should change automatically with the time of the user"). It re-reads the clock every [skyTick] and whenever
/// the app comes back to the front, so it changes while the app is open. Each look keeps its text readable: the light
/// look lays daylight paper over the night, the dark look lays night ink over the day. It is alive but calm: the
/// picture drifts and breathes slowly (a 40-second loop) and a soft glow wanders across it. On a wide screen the tall
/// pictures are turned a quarter so they fill it without being blown up. With Remove animations it stands still and
/// switches without a fade, but it still follows the clock.
class SkyBackground extends StatefulWidget {
  const SkyBackground({super.key, required this.dark, required this.child, this.clock});
  final bool dark;
  final Widget child;

  /// For tests: the time the sky reads. Defaults to the device clock (local time).
  final DateTime Function()? clock;

  @override
  State<SkyBackground> createState() => SkyBackgroundState();
}

/// How often the sky's slow drift moves (v1.13.101). The drift is a 40-second loop that moves a few pixels a second,
/// so 30 steps a second look the same as 120, while the old per-frame ticker kept the whole screen (and every frosted
/// blur over the sky) redrawing at the display's full rate all the time, even with nothing else moving. Other
/// animations still run at the full refresh rate; only the sky's own steps are spaced out.
const Duration skyStep = Duration(milliseconds: 33);

class SkyBackgroundState extends State<SkyBackground> with WidgetsBindingObserver {
  /// The drift's loop phase (0..1), advanced by [_drift] every [skyStep] while the app is in front.
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);
  Timer? _drift;
  bool _still = false;
  bool _front = true;
  Timer? _tick;
  double _night = 0;

  /// How much of the night shows right now (0 day, 1 night). For tests.
  double get night => _night;

  /// Whether the slow drift is stepping right now (only in front, never with Remove animations). For tests.
  bool get driftRunning => _drift != null;

  /// The drift's loop phase (0..1). For tests.
  double get driftPhase => _phase.value;

  DateTime _now() {
    final t = (widget.clock ?? DateTime.now)();
    return t.isUtc ? t.toLocal() : t;
  }

  /// Reads the clock again and moves the sky if the time of day changed.
  void refresh() {
    final n = skyNightness(_now());
    if ((n - _night).abs() > 0.001 && mounted) setState(() => _night = n);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final ls = WidgetsBinding.instance.lifecycleState;
    _front = ls == null || ls == AppLifecycleState.resumed;
    _night = skyNightness(_now());
    _tick = Timer.periodic(skyTick, (_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    _front = s == AppLifecycleState.resumed;
    if (_front) {
      refresh();
      // Edge to edge again on every return: the engine outlives the screen, so a new screen (after Back, a recreate)
      // started with the platform's default insets and the sky stopped above the navigation bar (MainActivity
      // re-applies it natively too).
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).catchError((_) {}));
    }
    _syncDrift();
  }

  /// The drift runs only while the app is in front and animations are allowed.
  void _syncDrift() {
    final run = _front && !_still;
    if (run && _drift == null) {
      final step = skyStep.inMicroseconds / SubMotion.skyDrift.inMicroseconds;
      _drift = Timer.periodic(skyStep, (_) => _phase.value = (_phase.value + step) % 1.0);
    } else if (!run) {
      _drift?.cancel();
      _drift = null;
    }
  }

  @override
  void didUpdateWidget(SkyBackground old) {
    super.didUpdateWidget(old);
    if (old.clock != widget.clock) refresh();
  }

  bool _precached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode both pictures up front, so the sky never paints a blank frame before the daylight picture, and the night
    // picture is ready when dusk comes (it popped in half-decoded).
    if (!_precached) {
      _precached = true;
      for (final a in const ['assets/bg/daylight.webp', 'assets/bg/night.webp']) {
        precacheImage(AssetImage(a), context, onError: (_, __) {});
      }
    }
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncDrift();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _drift?.cancel();
    _phase.dispose();
    super.dispose();
  }

  Widget _picture(String asset, String key, bool wide) {
    Widget img = Image.asset(
      asset,
      key: ValueKey(key),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    if (wide) img = RotatedBox(quarterTurns: 1, child: img);
    return img;
  }

  @override
  Widget build(BuildContext context) {
    final night = _night;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final base = widget.dark ? Palette.dark.bg : Color.lerp(Palette.light.bg, Palette.dark.bg, night)!;
    return ColoredBox(
      color: base,
      child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth > c.maxHeight;
              // The look (light 0, dark 1) eases too, in step with the app's theme, so the veils cross-fade instead of
              // switching at once when the look changes.
              final sky = TweenAnimationBuilder<double>(
                tween: Tween(end: widget.dark ? 1.0 : 0.0),
                duration: still ? Duration.zero : SubMotion.base,
                curve: SubMotion.settle,
                builder: (context, look, _) => TweenAnimationBuilder<double>(
                tween: Tween(end: night),
                duration: still ? Duration.zero : SubMotion.skyFade,
                curve: SubMotion.ambient,
                builder: (context, n, _) => Stack(fit: StackFit.expand, children: [
                  if (n < 1) _picture('assets/bg/daylight.webp', 'daylight-bg', wide),
                  if (n > 0) Opacity(opacity: n, child: _picture('assets/bg/night.webp', 'night-bg', wide)),
                  // The light look keeps ink-dark text, which would vanish on the night picture: a soft veil of
                  // daylight paper over the night keeps every word readable while the stars still show through.
                  if (look < 1 && n > 0)
                    IgnorePointer(
                      child: ColoredBox(key: const ValueKey('night-veil'), color: Palette.light.bg.withValues(alpha: lightNightVeil * n * (1 - look))),
                    ),
                  // The dark look keeps light text, which would wash out on the bright daylight picture: a veil of night
                  // ink over the day keeps every word readable while the sky still shows it is daytime.
                  if (look > 0 && n < 1)
                    IgnorePointer(
                      child: ColoredBox(key: const ValueKey('day-veil'), color: Palette.dark.bg.withValues(alpha: darkDayVeil * (1 - n) * look)),
                    ),
                ]),
              ),
              );
              if (still) return sky;
              final glow = Color.lerp(Colors.white, const Color(0xFF3D6BFF), night)!;
              final glowBase = 0.22 - 0.12 * night;
              final glowSwing = 0.10 - 0.04 * night;
              return AnimatedBuilder(
                animation: _phase,
                // Its own layer: the slow drift then only moves a cached picture instead of repainting it every frame.
                child: RepaintBoundary(child: sky),
                builder: (context, child) {
                  final a = _phase.value * 2 * math.pi;
                  final d = skyDrift(a);
                  final scale = d.scale;
                  final dx = d.dx;
                  final dy = d.dy;
                  return Stack(fit: StackFit.expand, children: [
                    Transform.scale(
                      scale: scale,
                      child: FractionalTranslation(translation: Offset(dx, dy), child: child),
                    ),
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment(0.6 * math.cos(a), 0.7 * math.sin(a)),
                            radius: 0.9,
                            colors: [glow.withValues(alpha: glowBase + glowSwing * math.sin(a * 2)), glow.withValues(alpha: 0)],
                          ),
                        ),
                      ),
                    ),
                  ]);
                },
              );
            }),
          ),
        ),
        widget.child,
      ]),
    );
  }
}
