import 'dart:ui' show PlatformDispatcher;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/bots_screen.dart';
import 'app_state.dart';
import 'services/billing/billing_service.dart';
import 'services/bot_sync.dart';
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
import 'screens/system_screens.dart';
import 'services/live_controller.dart';
import 'theme.dart';
import 'ui/day_night.dart';
import 'ui/i18n.dart';
import 'ui/intro_motion.dart';
import 'ui/motion.dart';
import 'ui/sky.dart';
import 'ui/tokens.dart' show LuxMotion;
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
  final state = AppState();
  try {
    await state.initLocal();
  } catch (e) {
    debugPrint('initLocal failed: $e');
  }
  // Push (plan 2.1). Optional: if Firebase fails the app runs as before, just without push.
  unawaited(Push.I.init().catchError((_) {}));
  // The real build's version (touch_device reports it on sign-in), before anything sends it.
  await Updater.loadBuildVersion();
  // Plan 2.4 rewards (invite link, claim a referral once after sign-up) and the "From SubMac" inbox.
  unawaited(Rewards.I.init().catchError((_) {}));
  unawaited(Inbox.I.init().catchError((_) {}));
  // In-app updates: the update window shows while a newer version is published ("Later" snoozes that version).
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

  final Listenable _langAndLook = Listenable.merge([AppLang.I, DayNight.I]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Auto theme: a timer to the next 07:00 / 19:00 while the app is open (stopped in the background).
    DayNight.I.start();
    final state = context.read<AppState>();
    state.liveCtl.openScreen = () {
      final nav = appNavKey.currentState;
      if (nav == null || state.liveCtl.screenOpen) return;
      nav.push(liveRoute());
    };
    state.openSystemSettings = () => appNavKey.currentState?.push(MaterialPageRoute(builder: (_) => const SystemPermissionsScreen()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DayNight.I.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final state = context.read<AppState>();
    if (s == AppLifecycleState.resumed) {
      // Back in front: re-read the clock at once (the time or the time zone may have changed while away).
      DayNight.I.start();
      state.setAppVisible(true);
      unawaited(Updater.I.resumed());
      if (Supabase.instance.client.auth.currentSession != null) {
        Cloud.refreshStatus();
        // A task the phone killed while SubMac was away picks up where it left off.
        unawaited(state.resumeKilledRuns().catchError((Object e) => debugPrint('resume runs: $e')));
        BotSync.I.resumed();
        Inbox.I.refresh();
        Rewards.I.refresh();
      }
    } else if (s == AppLifecycleState.paused) {
      DayNight.I.stop();
      state.setAppVisible(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final easy = context.select<AppState, bool>((s) => s.easyMode);
    // Rebuilds on a language change and when the auto look flips (07:00 / 19:00: twice a day at most). The flip runs
    // through MaterialApp's own theme animation, so it eases like any theme change, and the system bars follow it.
    return ListenableBuilder(
      listenable: _langAndLook,
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
      // Always the time-of-day look (light 07:00-19:00, dark at night); there is no theme setting.
      themeMode: themeModeFor(DayNight.I.brightness),
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

/// How often the sky re-reads the clock with Remove animations on (it also re-reads on every resume). With motion
/// on it re-reads on every [skyStep].
const Duration skyTick = Duration(seconds: 30);

/// How often the live sky moves a step (and re-reads the clock). Its drift is a slow loop ([LuxMotion.skyDrift]), so
/// each step shifts its soft glows by a pixel or two: the sky looks alive while painting only a few times a minute,
/// never every frame (the old picture sky stepped 30 times a second and kept every frosted blur over it redrawing).
const Duration skyStep = Duration(seconds: 4);

/// The live sky behind every screen ([SkyPainter], lib/ui/sky.dart): drawn from the user's own clock (local device
/// time), with night, blue hour, an orange and pink sunrise, golden hours, a clear blue day, an orange and red sunset
/// and dusk, eased minute by minute. It moves gently (slow drifting light, twinkling stars, the sun or moon glow
/// following the time), one small step every [skyStep], and stops while the app is in the background. With Remove
/// animations it stands still on the current time's sky and switches without a fade, but it still follows the clock.
/// Each look keeps its text readable: the light look lays paper over a dark sky, the dark look lays night ink over a
/// bright one, always enough for 4.5:1 text ([lightVeilFor], [darkVeilFor]).
class SkyBackground extends StatefulWidget {
  const SkyBackground({super.key, required this.dark, required this.child, this.clock});
  final bool dark;
  final Widget child;

  /// For tests: the time the sky reads. Defaults to the device clock (local time).
  final DateTime Function()? clock;

  @override
  State<SkyBackground> createState() => SkyBackgroundState();
}

class SkyBackgroundState extends State<SkyBackground> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// The drift's loop phase (0..1), advanced every [skyStep] while the app is in front.
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);

  /// Eases from the old sky to the new one when the time jumped (back from the background, the clock changed).
  late final AnimationController _fade = AnimationController(vsync: this, duration: SubMotion.skyFade, value: 1);
  Timer? _timer;
  bool _still = false;
  bool _front = true;
  late DateTime _at;
  late SkyLook _from;
  late SkyLook _to;

  /// How dark the sky is now (0 day, 1 night). For tests.
  double get night => 1 - _to.light;

  /// The sky being shown now (the target of any fade). For tests.
  SkyLook get look => _to;

  /// Whether the slow drift is stepping right now (only in front, never with Remove animations). For tests.
  bool get driftRunning => _timer != null && _front && !_still;

  /// Whether any timer is running (none in the background). For tests.
  bool get ticking => _timer != null;

  /// The drift's loop phase (0..1). For tests.
  double get driftPhase => _phase.value;

  DateTime _now() {
    final t = (widget.clock ?? DateTime.now)();
    return t.isUtc ? t.toLocal() : t;
  }

  /// Reads the clock again and moves the sky if the minute changed. A jump of more than a few minutes eases over
  /// [SubMotion.skyFade] (none with Remove animations); the minute-by-minute change is too small to see.
  void refresh() {
    final t = _now();
    if (t.difference(_at).inMinutes.abs() < 1 && t.minute == _at.minute) return;
    final jump = (minuteOfDay(t) - minuteOfDay(_at)).abs() > 5;
    final shown = _fade.value >= 1 ? _to : SkyLook.lerp(_from, _to, SubMotion.ambient.transform(_fade.value));
    if (!mounted) return;
    setState(() {
      _at = t;
      _from = shown;
      _to = skyAt(t);
    });
    if (jump && !_still) {
      _fade.forward(from: 0);
    } else {
      _fade.value = 1;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final ls = WidgetsBinding.instance.lifecycleState;
    _front = ls == null || ls == AppLifecycleState.resumed;
    _at = _now();
    _from = _to = skyAt(_at);
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
    _sync();
  }

  /// One timer at a time: every [skyStep] with motion (drift + clock), every [skyTick] when still (clock only), none in
  /// the background.
  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (!_front) return;
    if (_still) {
      _timer = Timer.periodic(skyTick, (_) => refresh());
    } else {
      final step = skyStep.inMicroseconds / LuxMotion.skyDrift.inMicroseconds;
      _timer = Timer.periodic(skyStep, (_) {
        _phase.value = (_phase.value + step) % 1.0;
        refresh();
      });
    }
  }

  @override
  void didUpdateWidget(SkyBackground old) {
    super.didUpdateWidget(old);
    if (old.clock != widget.clock) refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still != _still || _timer == null) {
      _still = still;
      if (_still) _fade.value = 1;
      _sync();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _fade.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final look = _to;
    final still = _still;
    final lightVeil = lightVeilFor(look);
    final darkVeil = darkVeilFor(look);
    return ColoredBox(
      color: widget.dark ? Palette.dark.bg : Palette.light.bg,
      child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: Stack(fit: StackFit.expand, children: [
              // Its own layer: a drift step repaints only the sky, never the screens over it.
              RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('sky-paint'),
                  painter: SkyPainter(
                    from: _from,
                    to: _to,
                    fade: _fade,
                    phase: _phase,
                    sun: sunPosition(_at),
                    moon: moonPosition(_at),
                    still: still,
                  ),
                ),
              ),
              // The look (light 0, dark 1) eases in step with the app's theme, so the veils cross-fade instead of
              // switching at once when the look changes (at 07:00 / 19:00 in Auto).
              TweenAnimationBuilder<double>(
                tween: Tween(end: widget.dark ? 1.0 : 0.0),
                duration: still ? Duration.zero : SubMotion.base,
                curve: SubMotion.settle,
                builder: (context, lk, _) => Stack(fit: StackFit.expand, children: [
                  // The light look keeps ink-dark text: a veil of daylight paper over a dark or warm sky.
                  if (lk < 1 && lightVeil > 0)
                    IgnorePointer(
                      child: ColoredBox(key: const ValueKey('night-veil'), color: Palette.light.bg.withValues(alpha: lightVeil * (1 - lk))),
                    ),
                  // The dark look keeps light text: a veil of night ink over a bright sky.
                  if (lk > 0 && darkVeil > 0)
                    IgnorePointer(
                      child: ColoredBox(key: const ValueKey('day-veil'), color: Palette.dark.bg.withValues(alpha: darkVeil * lk)),
                    ),
                ]),
              ),
            ]),
          ),
        ),
        widget.child,
      ]),
    );
  }
}
