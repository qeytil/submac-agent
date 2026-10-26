import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../config.dart';
import '../services/first_launch.dart';
import '../services/rewards.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import '../widgets/logo.dart';
import '../widgets/sub_icon.dart';

/// Plain rules behind sign-up, kept free of widgets so they can be tested.
class AuthRules {
  const AuthRules._();

  /// The emailed verification and reset codes are this long.
  static const codeLength = 6;

  /// Seconds before another code can be requested.
  static const resendSeconds = 60;

  static final _emailShape = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static bool validEmail(String email) => _emailShape.hasMatch(email.trim());

  static String cleanCode(String raw) => raw.replaceAll(RegExp(r'\D'), '');

  static bool validCode(String raw) => cleanCode(raw).length == codeLength;

  /// Email-and-password accounts must verify their email; Google accounts arrive verified.
  static bool needsVerification({required String? emailConfirmedAt, required String? provider}) =>
      (emailConfirmedAt == null || emailConfirmedAt.isEmpty) && (provider == null || provider == 'email');

  static bool needsVerificationFor(User user) => needsVerification(
        emailConfirmedAt: user.emailConfirmedAt,
        provider: user.appMetadata['provider'] as String?,
      );

  /// Reads the public auth settings: is Google sign-in switched on?
  static bool googleEnabled(String settingsJson) {
    try {
      final j = jsonDecode(settingsJson);
      return j is Map && j['external'] is Map && j['external']['google'] == true;
    } catch (_) {
      return false;
    }
  }

  static bool isUnconfirmed(String raw) => raw.toLowerCase().contains('email not confirmed');

  /// Raise this when the Terms or Privacy Policy change enough that everyone must agree again.
  /// The pages themselves always live at the same addresses (AppConfig.termsUrl / privacyUrl).
  static const consentVersion = 2; // 2 = billing v2 terms (packages + pay as you go, no coins), 23 Oct 2026

  /// Has this account confirmed it is 18+ and agreed to the current Terms and Privacy Policy?
  static bool hasConsent(Map<String, dynamic>? meta) {
    if (meta == null) return false;
    final v = meta['consent_v'];
    final n = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return n >= consentVersion && meta['age_18'] == true;
  }

  static bool hasConsentFor(User user) => hasConsent(user.userMetadata);

  /// What is saved on the account when the person agrees.
  static Map<String, dynamic> consentData({DateTime? now}) => {
        'consent_v': consentVersion,
        'age_18': true,
        'consent_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
      };
}

Future<void> openLegal(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Where the agreement is saved on the account: Supabase auth user_metadata ({consent_v, age_18, consent_at}), the same
/// write the old post-sign-in consent page made. Tests swap [write] for a fake.
class ConsentStore {
  ConsentStore._();

  static Future<void> Function(Map<String, dynamic> data) write = _supabase;

  static Future<void> _supabase(Map<String, dynamic> data) async {
    await Supabase.instance.client.auth.updateUser(UserAttributes(data: data)).timeout(const Duration(seconds: 30));
  }

  /// Saves the agreement now (fires a user update, so the app opens).
  static Future<void> save() => write(AuthRules.consentData());
}

/// The 18+ / Terms / Privacy tick, with both pages one tap away. It sits on the sign-in screen itself: signing in or up
/// (Google included) stays off until it is ticked.
class ConsentTick extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const ConsentTick({super.key, required this.value, required this.onChanged});

  /// The sentence, in the app language, with {terms} and {privacy} where the two links go.
  static const sentence = 'I am 18 or older and I agree to the {terms} and the {privacy}.';

  /// [text] cut into plain runs and its {terms} / {privacy} holes, in order (the holes can sit anywhere in a language).
  static List<String> splitHoles(String text) {
    final out = <String>[];
    var at = 0;
    for (final m in RegExp(r'\{terms\}|\{privacy\}').allMatches(text)) {
      if (m.start > at) out.add(text.substring(at, m.start));
      out.add(m.group(0)!);
      at = m.end;
    }
    if (at < text.length) out.add(text.substring(at));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final small = AppText.metaStyle.copyWith(color: p.muted);
    final link = AppText.metaStyle.copyWith(color: p.text, decoration: TextDecoration.underline);
    WidgetSpan linkTo(String words, String url) => WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(onTap: () => openLegal(url), child: Text(words, style: link)),
        );
    final spans = <InlineSpan>[];
    for (final part in splitHoles(tr(sentence))) {
      if (part == '{terms}') {
        spans.add(linkTo(tr('Terms of Use'), AppConfig.termsUrl));
      } else if (part == '{privacy}') {
        spans.add(linkTo(tr('Privacy Policy'), AppConfig.privacyUrl));
      } else if (part.isNotEmpty) {
        spans.add(TextSpan(text: part));
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: GestureDetector(
              onTap: () => onChanged(!value),
              child: Text.rich(TextSpan(style: small, children: spans)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Right after sign-in, for an account that ticked the box on the sign-in screen but has no agreement saved yet
/// (Google sign-ins, accounts made before this check, a new phone): saves it quietly with the same write as before,
/// showing only the logo. Only a failure shows anything: try again, or sign out.
class ConsentRecorder extends StatefulWidget {
  const ConsentRecorder({super.key});

  @override
  State<ConsentRecorder> createState() => _ConsentRecorderState();
}

class _ConsentRecorderState extends State<ConsentRecorder> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _save();
  }

  Future<void> _save() async {
    if (_failed) setState(() => _failed = false);
    try {
      await ConsentStore.save();
      await ConsentPending.clear();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppLogo(size: 48),
                if (_failed) ...[
                  const SizedBox(height: Space.x5),
                  Text(tr('We couldn\'t save your agreement. Check your connection, then try again.'),
                      textAlign: TextAlign.center, style: AppText.bodyStyle.copyWith(color: p.muted)),
                  const SizedBox(height: Space.x5),
                  FilledButton(onPressed: _save, child: Text(tr('Try again'))),
                  const SizedBox(height: Space.x2),
                  TextButton(onPressed: () => Supabase.instance.client.auth.signOut(), child: Text(tr('Sign out'))),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Set just before a reset code is checked, so the app asks for the new password once signed in.
class AuthFlow {
  AuthFlow._();

  static bool pendingNewPassword = false;

  static bool takePendingReset() {
    final v = pendingNewPassword;
    pendingNewPassword = false;
    return v;
  }
}

enum _Mode { welcome, signUp, logIn, verify, resetCode, confirm }

class AuthScreen extends StatefulWidget {
  /// Opens straight on the code screen for an account that is signed in but not verified.
  final String? verifyEmail;

  /// Opens on the agreement alone, for an account that is already signed in on this phone but has never agreed and
  /// didn't tick the box here (a session kept from an older version of SubMac). Rare: every new sign-in ticks it.
  final bool confirmOnly;

  /// For tests: whether to show the Google button without asking the server.
  final bool? google;

  const AuthScreen({super.key, this.verifyEmail, this.confirmOnly = false, this.google});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _Mode _mode = _Mode.welcome;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _invite = TextEditingController();
  final _code = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  String? _info;
  String _pendingEmail = '';

  bool _google = false;
  bool _agree = false;

  Timer? _tick;
  int _wait = 0;

  @override
  void initState() {
    super.initState();
    final pending = widget.verifyEmail;
    if (pending != null && pending.isNotEmpty) {
      _pendingEmail = pending;
      _mode = _Mode.verify;
    }
    if (widget.confirmOnly) _mode = _Mode.confirm;
    if (widget.google != null) {
      _google = widget.google!;
    } else {
      _checkGoogle();
    }
  }

  /// Signing in or up is only possible with the box ticked; the tick is remembered until the account carries it.
  bool _ticked() {
    if (!_agree) {
      setState(() => _error = tr(_needTick));
      return false;
    }
    unawaited(ConsentPending.mark());
    return true;
  }

  static const _needTick = 'Please confirm you are 18 or older and agree to the Terms and Privacy Policy.';

  Widget _consentTick() => ConsentTick(
      value: _agree,
      onChanged: (v) => setState(() {
            _agree = v;
            _error = null;
          }));

  /// The agreement alone, for a kept session that never agreed: saved with the same write as before.
  Future<void> _confirm() async {
    if (!_ticked()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ConsentStore.save();
      await ConsentPending.clear();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyAuthError('$e'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The Google button shows only once Google sign-in is switched on for SubMac.
  Future<void> _checkGoogle() async {
    try {
      final res = await http.get(
        Uri.parse('${AppConfig.supabaseUrl}/auth/v1/settings'),
        headers: {'apikey': AppConfig.supabaseAnonKey},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && AuthRules.googleEnabled(res.body) && mounted) setState(() => _google = true);
    } catch (_) {}
  }

  Future<void> _signInWithGoogle() async {
    if (!_ticked()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'com.submac.agent://login-callback',
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (mounted) setState(() => _error = friendlyAuthError('$e'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _email.dispose();
    _password.dispose();
    _invite.dispose();
    _code.dispose();
    super.dispose();
  }

  void _go(_Mode m) => setState(() {
        _mode = m;
        _error = null;
        _info = null;
      });

  void _startCooldown() {
    _tick?.cancel();
    setState(() => _wait = AuthRules.resendSeconds);
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait = _wait > 0 ? _wait - 1 : 0);
      if (_wait == 0) t.cancel();
    });
  }

  void _toCode(_Mode m, String email, {String? info}) {
    _code.clear();
    setState(() {
      _pendingEmail = email;
      _mode = m;
      _error = null;
      _info = info;
    });
    _startCooldown();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pw = _password.text;
    if (!AuthRules.validEmail(email)) {
      setState(() => _error = 'That email doesn\'t look right. Check it and try again.');
      return;
    }
    if (pw.length < 6) {
      setState(() => _error = 'Choose a password of at least 6 characters.');
      return;
    }
    if (!_ticked()) return;
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_mode == _Mode.signUp) {
        // An invite code typed here is claimed once, right after the new account signs in (plan 2.4).
        if (_invite.text.trim().isNotEmpty) await Rewards.I.setRef(_invite.text, source: 'code', replace: true);
        final res = await auth
            .signUp(email: email, password: pw, data: AuthRules.consentData())
            .timeout(const Duration(seconds: 30));
        // No session means the email must be verified first: a 6-digit code is on its way.
        if (res.session == null && mounted) _toCode(_Mode.verify, email);
      } else {
        await auth.signInWithPassword(email: email, password: pw).timeout(const Duration(seconds: 30));
      }
    } on AuthException catch (e) {
      if (_mode == _Mode.logIn && AuthRules.isUnconfirmed(e.message)) {
        await _resendSignup(email);
        if (mounted) _toCode(_Mode.verify, email, info: 'Your email isn\'t verified yet. We sent you a new code.');
      } else {
        setState(() => _error = friendlyAuthError(e.message));
      }
    } catch (e) {
      setState(() => _error = friendlyAuthError('$e'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resendSignup(String email) async {
    try {
      await Supabase.instance.client.auth.resend(type: OtpType.signup, email: email).timeout(const Duration(seconds: 30));
    } catch (_) {}
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (!AuthRules.validEmail(email)) {
      setState(() => _error = 'Enter your email first.');
      return;
    }
    // A reset code signs the account in, so it needs the box ticked like any other sign-in.
    if (!_ticked()) return;
    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth
          .resetPasswordForEmail(email, redirectTo: 'com.submac.agent://login-callback')
          .timeout(const Duration(seconds: 30));
    } on AuthException catch (e) {
      // Only a rate limit is shown; anything else stays generic so no one can test which emails have accounts.
      final msg = friendlyAuthError(e.message);
      if (msg.startsWith('Too many')) {
        if (mounted) setState(() => _error = msg);
        if (mounted) setState(() => _loading = false);
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loading = false);
    _toCode(_Mode.resetCode, email, info: 'If an account uses this email, we sent it a 6-digit code.');
  }

  Future<void> _resend() async {
    if (_wait > 0 || _pendingEmail.isEmpty) return;
    setState(() {
      _error = null;
      _info = null;
    });
    if (_mode == _Mode.resetCode) {
      try {
        await Supabase.instance.client.auth.resetPasswordForEmail(_pendingEmail, redirectTo: 'com.submac.agent://login-callback');
      } catch (_) {}
    } else {
      await _resendSignup(_pendingEmail);
    }
    if (!mounted) return;
    setState(() => _info = 'We sent a new code. Check your inbox and spam folder.');
    _startCooldown();
  }

  Future<void> _verify() async {
    final code = AuthRules.cleanCode(_code.text);
    if (!AuthRules.validCode(code)) {
      setState(() => _error = 'Enter the ${AuthRules.codeLength}-digit code from the email.');
      return;
    }
    final reset = _mode == _Mode.resetCode;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (reset) AuthFlow.pendingNewPassword = true;
    try {
      await Supabase.instance.client.auth
          .verifyOTP(type: reset ? OtpType.recovery : OtpType.signup, email: _pendingEmail, token: code)
          .timeout(const Duration(seconds: 30));
      // Signed in now: the app opens, and after a reset it asks for the new password.
    } on AuthException catch (e) {
      AuthFlow.pendingNewPassword = false;
      if (mounted) setState(() => _error = friendlyAuthError(e.message));
    } catch (e) {
      AuthFlow.pendingNewPassword = false;
      if (mounted) setState(() => _error = friendlyAuthError('$e'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _welcome(Palette p) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 24),
          child: Column(
            children: [
              const Spacer(),
              const AppLogo(size: 56),
              const SizedBox(height: 20),
              Text('SubMac', style: Brand.serif(size: 52, color: p.text)),
              const SizedBox(height: 6),
              Text(tr('Ask. Make. Get it done.'),
                  textAlign: TextAlign.center, style: TextStyle(fontSize: AppText.body, color: p.muted, height: 1.45)),
              const Spacer(),
              _consentTick(),
              const SizedBox(height: Space.x3),
              if (_google) ...[
                OutlinedButton(
                  onPressed: _loading || !_agree ? null : _signInWithGoogle,
                  child: Text(tr('Continue with Google')),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(onPressed: () => _go(_Mode.signUp), child: Text(tr('Create account'))),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => _go(_Mode.logIn), child: Text(tr('Log in'))),
              if (_error != null) ...[
                const SizedBox(height: Space.x3),
                Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.accent)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _confirmScreen(Palette p) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 48, 24, 24),
          children: [
            const Center(child: AppLogo(size: 48)),
            const SizedBox(height: Space.x5),
            Center(
              child: Text(tr('Before you start'),
                  textAlign: TextAlign.center, style: Brand.serif(size: AppText.displayLarge, color: p.text)),
            ),
            const SizedBox(height: Space.x3),
            Text(tr('SubMac is for people aged 18 and over. Please read and agree to our Terms of Use and Privacy Policy.'),
                textAlign: TextAlign.center, style: AppText.bodyStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x5),
            _consentTick(),
            if (_error != null) ...[
              const SizedBox(height: Space.x3),
              Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.accent)),
            ],
            const SizedBox(height: Space.x5),
            FilledButton(
              onPressed: _loading || !_agree ? null : _confirm,
              child: _loading
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.bg))
                  : Text(tr('Agree and continue')),
            ),
            const SizedBox(height: Space.x2),
            Center(
              child: TextButton(
                onPressed: _loading ? null : () => Supabase.instance.client.auth.signOut(),
                child: Text(tr('Sign out')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _codeScreen(Palette p) {
    final reset = _mode == _Mode.resetCode;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const SubIcon('back'), onPressed: () => _go(reset ? _Mode.logIn : _Mode.signUp)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: Space.x2),
            Center(
              child: Text(reset ? 'Reset your password' : 'Check your email',
                  textAlign: TextAlign.center, style: Brand.serif(size: AppText.displayLarge, color: p.text)),
            ),
            const SizedBox(height: Space.x3),
            Text(
              'Enter the ${AuthRules.codeLength}-digit code we sent to $_pendingEmail.',
              textAlign: TextAlign.center,
              style: AppText.bodyStyle.copyWith(color: p.muted),
            ),
            const SizedBox(height: Space.x6),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: AuthRules.codeLength,
              autofillHints: const [AutofillHints.oneTimeCode],
              style: AppText.titleStyle.copyWith(color: p.text, letterSpacing: Space.x3),
              decoration: const InputDecoration(hintText: '······', counterText: ''),
              onChanged: (v) {
                if (AuthRules.validCode(v) && !_loading) _verify();
              },
              onSubmitted: (_) => _verify(),
            ),
            if (_info != null) ...[
              const SizedBox(height: Space.x3),
              Text(_info!, textAlign: TextAlign.center, style: AppText.metaStyle.copyWith(color: p.muted)),
            ],
            if (_error != null) ...[
              const SizedBox(height: Space.x3),
              Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.accent)),
            ],
            const SizedBox(height: Space.x5),
            FilledButton(
              onPressed: _loading ? null : _verify,
              child: _loading
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.bg))
                  : Text(reset ? 'Continue' : 'Verify email'),
            ),
            const SizedBox(height: Space.x2),
            Center(
              child: TextButton(
                onPressed: _wait > 0 || _loading ? null : _resend,
                child: Text(_wait > 0 ? 'Send a new code in ${_wait}s' : 'Send a new code'),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => _go(reset ? _Mode.logIn : _Mode.signUp),
                child: const Text('Use a different email'),
              ),
            ),
            const SizedBox(height: Space.x2),
            Text('Can\'t find it? Check your spam folder.',
                textAlign: TextAlign.center, style: AppText.microStyle.copyWith(color: p.muted)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (_mode == _Mode.confirm) return _confirmScreen(p);
    if (_mode == _Mode.welcome) return _welcome(p);
    if (_mode == _Mode.verify || _mode == _Mode.resetCode) return _codeScreen(p);
    final isSignUp = _mode == _Mode.signUp;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const SubIcon('back'), onPressed: () => _go(_Mode.welcome)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 8),
            Center(child: Text(isSignUp ? 'Create your account' : 'Welcome back',
                style: Brand.serif(size: 38, color: p.text))),
            const SizedBox(height: 28),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(hintText: 'Email address'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Password',
                suffixIcon: IconButton(
                  icon: SubIcon(_obscure ? 'eye' : 'eye_off'),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (isSignUp) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _invite,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(hintText: 'Invite code (optional)'),
              ),
            ],
            const SizedBox(height: 4),
            _consentTick(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: p.accent)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _loading || !_agree ? null : _submit,
              child: _loading
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.bg))
                  : Text(tr('Continue')),
            ),
            if (isSignUp) ...[
              const SizedBox(height: Space.x2),
              Text('We\'ll email you a 6-digit code to confirm this address is yours.',
                  textAlign: TextAlign.center, style: AppText.microStyle.copyWith(color: p.muted)),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(isSignUp ? 'Already have an account?' : "Don't have an account?", style: TextStyle(color: p.muted)),
                TextButton(
                  onPressed: () => _go(isSignUp ? _Mode.logIn : _Mode.signUp),
                  child: Text(isSignUp ? 'Log in' : 'Sign up'),
                ),
              ],
            ),
            if (!isSignUp)
              Center(child: TextButton(onPressed: _loading || !_agree ? null : _forgot, child: Text(tr('Forgot password?')))),
          ],
        ),
      ),
    );
  }
}

/// Plain words for sign-in problems.
String friendlyAuthError(String raw) {
  final e = raw.toLowerCase();
  if (e.contains('invalid login') || e.contains('invalid credentials')) return 'That email and password don\'t match. Try again, or tap Forgot password.';
  if (e.contains('already registered') || e.contains('already exists')) return 'This email already has an account. Tap Log in instead.';
  if (e.contains('email not confirmed')) return 'Please verify your email first. We can send you a new code.';
  if (e.contains('token has expired') || e.contains('otp') || (e.contains('token') && e.contains('invalid'))) {
    return 'That code is wrong or has expired. Check it, or send a new code.';
  }
  if (e.contains('invalid') && e.contains('email')) return 'That email doesn\'t look right. Check it and try again.';
  if (e.contains('password') && (e.contains('weak') || e.contains('at least'))) return 'Choose a longer password, at least 6 characters.';
  if (e.contains('rate limit') || e.contains('too many') || e.contains('429')) return 'Too many tries. Wait a minute and try again.';
  if (e.contains('timeout')) return 'SubMac is slow to answer right now. Check your connection, then try again.';
  if (e.contains('socket') || e.contains('host lookup') || e.contains('network') || e.contains('connection')) return 'No internet connection. Check your data or Wi-Fi.';
  return 'Something went wrong. Please try again.';
}

/// Choose a new password after tapping the reset link.
Future<void> showNewPasswordSheet(BuildContext context) async {
  final ctl = TextEditingController();
  String? err;
  var busy = false;
  await showModalBottomSheet<void>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final p = Palette.of(ctx);
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(24, 20, 24, 24 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Choose a new password'), style: Brand.serif(size: 26, color: p.text)),
            const SizedBox(height: 14),
            TextField(controller: ctl, obscureText: true, autofocus: true, decoration: const InputDecoration(hintText: 'New password (6+ characters)')),
            if (err != null) ...[const SizedBox(height: 8), Text(err!, style: TextStyle(color: p.accent))],
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (ctl.text.length < 6) {
                          set(() => err = 'Use at least 6 characters.');
                          return;
                        }
                        set(() => busy = true);
                        try {
                          await Supabase.instance.client.auth.updateUser(UserAttributes(password: ctl.text));
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password changed. You\'re signed in.')));
                          }
                        } catch (e) {
                          set(() {
                            busy = false;
                            err = friendlyAuthError('$e');
                          });
                        }
                      },
                child: Text(busy ? 'Saving…' : 'Save password'),
              ),
            ),
          ]),
        );
      },
    ),
  );
  ctl.dispose();
}
