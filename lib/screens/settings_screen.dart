import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_state.dart';
import '../config.dart';
import '../services/cloud.dart';
import '../services/device_access.dart';
import '../services/notif_text.dart';
import '../services/oc_engine.dart';
import '../services/system_bridge.dart';
import '../services/full_access.dart';
import '../services/rewards.dart';
import '../services/tools.dart';
import '../services/wake_word.dart';
import '../widgets/logo.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../ui/embed.dart';
import '../ui/i18n.dart';
import '../ui/feedback_words.dart';
import 'files_screen.dart' show FilesScreen, FilesView;
import '../widgets/sidebar.dart';
import '../widgets/update_window.dart';
import 'billing/billing_widgets.dart';
import 'case_settings_screen.dart';
import 'connectors_screen.dart';
import 'feedback_screen.dart';
import 'home_screen.dart' show TodayUsage;
import 'inbox_screen.dart' show enterInviteCode;
import 'logins_screen.dart';
import 'memory_screen.dart';
import 'media_models_screen.dart';
import 'models_screen.dart';
import 'opencode_lab_screen.dart';
import 'system_screens.dart';
import '../ui/tokens.dart';

/// Settings (PLAN.md 3.2): the top level is a short list of sections and nothing else.
/// Each section opens its own page; no rows are exposed here.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Cloud.refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Coming back from Android's permission screen.
    if (s == AppLifecycleState.resumed) context.read<AppState>().refreshPhoneAccess();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget row(String title, Widget page) => _NavRow(title, () => _push(context, page));
    return Scaffold(
      appBar: AppBar(title: Text(tr('Settings'), style: Brand.serif(size: 28, color: p.text))),
      body: ListView(
        padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x6),
        children: [
          _Group([
            row('Account', const _AccountPage()),
            // Bring your own key (owner 2026-11-03): Telesia or the user's own providers.
            row('Models', const ModelsScreen()),
            // The user's own media providers (owner 2026-11-04): pictures, video, speech, music.
            row('Media models', const MediaModelsScreen()),
            row('Language', const _LanguagePage()),
            row('Voice', const _VoicePage()),
          ]),
          _Group([
            row('Phone access', const _PhonePage()),
            row('Investigation', const CaseSettingsScreen()),
            row('Privacy', const _PrivacyPage()),
            row('Notifications', const _NotificationsPage()),
          ]),
          _Group([
            row('Engine', const _EnginePage()),
            row('Advanced', const _AdvancedPage()),
            row('Help', const _HelpPage()),
          ]),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ shared helpers

/// Settings pages rebuild only when something they show changes, never on every chat update (a reply streaming in the
/// background used to rebuild the open page dozens of times a second, which made push, pop and switches stutter).
AppState _watchSettings(BuildContext context) {
  context.select<AppState, int>((s) => Object.hashAll([
        s.themeMode,
        s.replyLanguage,
        s.liveVoice,
        s.liveAvailable,
        s.phoneAccess,
        s.memoryEnabled,
        s.memory.facts.length,
        s.notifyWhenDone,
        s.approvalMode,
        s.agentEnabled,
        s.aboutYou,
        s.howToRespond,
        s.repo.email,
        s.conversations.length,
        s.conversations.where((c) => c.archived).length,
      ]));
  return context.read<AppState>();
}

void _push(BuildContext context, Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

Future<bool> _confirm(BuildContext context, String title, String body, String action, {bool danger = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: Text(action, style: TextStyle(color: danger ? Palette.of(context).accent : null)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// A settings page: a plain title and its groups, nothing else.
class _Page extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Page(this.title, this.children);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr(title))),
        body: ListView(padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x6), children: children),
      );
}

/// One top-level section row: its name and a chevron. No helper text.
class _NavRow extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  const _NavRow(this.title, this.onTap);

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(tr(title)),
        trailing: Icon(Icons.chevron_right_rounded, color: Palette.of(context).muted),
        onTap: onTap,
      );
}

// ------------------------------------------------------------------ Account

class _AccountPage extends StatelessWidget {
  const _AccountPage();

  Future<void> _invite(BuildContext context) async {
    final link = await Rewards.I.inviteLink();
    final code = Rewards.I.myCode;
    if (!context.mounted) return;
    if (link == null || code == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You need the internet for this.')));
      return;
    }
    await SharePlus.instance.share(ShareParams(text: Rewards.inviteText(link, code), subject: 'Join me on Telesia'));
  }

  Future<void> _deleteAccount(BuildContext context, AppState state) async {
    final p = Palette.of(context);
    final typed = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: const Text('Delete your account?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Your account, chats, memory, bots and backups are deleted for good.'),
            const SizedBox(height: Space.x3),
            const Text('Type DELETE to confirm.'),
            const SizedBox(height: Space.x2),
            TextField(controller: typed, autofocus: true, onChanged: (_) => setD(() {}), textCapitalization: TextCapitalization.characters),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
            TextButton(
              onPressed: typed.text.trim().toUpperCase() == 'DELETE' ? () => Navigator.pop(d, true) : null,
              child: Text('Delete forever', style: TextStyle(color: typed.text.trim().toUpperCase() == 'DELETE' ? p.accent : p.muted)),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(content: Row(children: [
        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: Space.x4),
        Expanded(child: Text('Deleting…')),
      ])),
    );
    final err = await state.deleteAccount();
    if (!context.mounted) return;
    Navigator.of(context).pop();
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    Navigator.popUntil(context, (r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    final p = Palette.of(context);
    final email = state.repo.email ?? '';
    return _Page('Account', [
      _Group([
        ListTile(
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: p.bubble,
            child: Text(email.isEmpty ? '?' : email[0].toUpperCase(), style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
          ),
          title: Text(email.isEmpty ? 'Signed in' : email, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('Backed up'),
        ),
      ]),
      _Group(title: 'Theme', [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x3, Space.x3, Space.x3),
          child: Wrap(spacing: Space.x2, children: [
            for (final m in const [(ThemeMode.system, 'Auto'), (ThemeMode.light, 'Light'), (ThemeMode.dark, 'Dark')])
              ChoiceChip(label: Text(tr(m.$2)), selected: state.themeMode == m.$1, onSelected: (_) => state.setThemeMode(m.$1)),
          ]),
        ),
      ]),
      _Group([
        ListTile(title: Text(tr('Invite friends')), onTap: () => _invite(context)),
        ListTile(title: const Text("Enter a friend's code"), onTap: () => enterInviteCode(context)),
      ]),
      _Group([
        ListTile(
          title: Text(tr('Sign out')),
          onTap: () async {
            if (!await _confirm(context, 'Sign out?', 'Your chats come back when you sign in again.', 'Sign out')) return;
            if (!context.mounted) return;
            Navigator.popUntil(context, (r) => r.isFirst);
            await state.signOut();
          },
        ),
        ListTile(
          title: Text('Delete account', style: TextStyle(color: p.accent)),
          onTap: () => _deleteAccount(context, state),
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Plan & usage

/// Placeholder home for Dev 2's Plan & usage screen (PLAN.md 2.4): today's usage, and the billing entry while
/// billing is on. Dev 2 replaces the body.
// ignore: unused_element
class _PlanPage extends StatelessWidget {
  const _PlanPage();

  @override
  Widget build(BuildContext context) => const _Page('Plan & usage', [
        _Group([TodayUsage()]),
        BillingSettingsEntry(),
      ]);
}

// ------------------------------------------------------------------ Language

class _LanguagePage extends StatelessWidget {
  const _LanguagePage();

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    return _Page('Language', [
      // The app is English only (owner 2026-11-08).
      _Group(title: 'Reply language', [
        Padding(
          padding: const EdgeInsets.all(Space.x3),
          child: Wrap(spacing: Space.x2, runSpacing: Space.x2, children: [
            // Language names in their own language (PLAN.md 3.4). Values stay the stored keys.
            for (final l in const [('auto', 'Auto'), ('Somali', 'Soomaali'), ('Arabic', 'العربية'), ('English', 'English')])
              ChoiceChip(label: Text(l.$1 == 'auto' ? tr(l.$2) : l.$2), selected: state.replyLanguage == l.$1, onSelected: (_) => state.setReplyLanguage(l.$1)),
          ]),
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Voice

/// The Voice page (PLAN.md 5.4): Live voice and the "Hello Telesia" wake word in one place.
///
/// Public entry so deep links (the wake notification's "settings/wake") can land here directly.
class VoiceScreen extends StatelessWidget {
  const VoiceScreen({super.key});

  @override
  Widget build(BuildContext context) => const _VoicePage();
}

class _VoicePage extends StatelessWidget {
  const _VoicePage();

  Future<void> _pickVoice(BuildContext context, AppState state) async {
    final voices = Cloud.features.value.voices;
    await showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x5),
          child: Wrap(spacing: Space.x2, runSpacing: Space.x2, children: [
            for (final v in voices)
              ChoiceChip(
                label: Text(v),
                selected: state.liveVoice == v,
                onSelected: (_) {
                  state.setLiveVoice(v);
                  Navigator.pop(ctx);
                },
              ),
          ]),
        ),
      ),
    );
  }

  /// The "Hello Telesia" rows: one switch, the live status underneath, and the
  /// sensitivity slider once the voice pack is on the phone.
  List<Widget> _wakeRows(WakeWord w, Palette p) {
    String subtitle;
    if (!w.enabled && (w.setup == WakeSetup.off || w.setup == WakeSetup.ready)) {
      subtitle = tr('Say “Hello Telesia” and Telesia wakes up to listen');
    } else {
      subtitle = w.statusLine;
    }
    return [
      SwitchListTile(
        title: const Text('Hello Telesia'),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        value: w.enabled,
        onChanged: (v) => w.setEnabled(v),
      ),
      if (w.enabled && w.setup == WakeSetup.ready)
        ListTile(
          title: Text(tr('Sensitivity')),
          subtitle: Slider(
            value: w.sensitivity.clamp(0.1, 0.95).toDouble(),
            min: 0.1,
            max: 0.95,
            divisions: 8,
            label: '${(w.sensitivity * 100).round()}%',
            onChanged: (v) => w.setSensitivity(v),
          ),
        ),
      if (w.setup == WakeSetup.paused || w.setup == WakeSetup.error)
        ListTile(
          title: Text(tr('Resume the voice pack')),
          trailing: Icon(Icons.refresh_rounded, color: p.muted),
          onTap: () => w.download(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    return _Page('Voice', [
      _Group([
        ListTile(
          title: Text(tr('Live voice')),
          subtitle: Text(state.liveAvailable ? state.liveVoice : tr('Not available right now')),
          enabled: state.liveAvailable,
          onTap: () => _pickVoice(context, state),
        ),
      ]),
      _Group([
        ListenableBuilder(
          listenable: WakeWord.I,
          builder: (context, _) => Column(children: _wakeRows(WakeWord.I, Palette.of(context))),
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Phone access

/// The one place for phone permissions (PLAN.md 3.2).
class _PhonePage extends StatelessWidget {
  const _PhonePage();

  Future<void> _setFiles(BuildContext context, AppState state, bool on) async {
    if (!on) {
      if (await _confirm(context, 'Turn off phone files?', 'Switch off "All files access" in Android settings.', 'Open settings')) {
        DeviceAccess.openSettings();
      }
      return;
    }
    final granted = await state.requestPhoneAccess();
    if (!granted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allow "All files access", then come back.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    return _Page('Phone access', [
      _Group([
        SwitchListTile(
          title: const Text('Phone files'),
          value: state.phoneAccess,
          onChanged: (v) => _setFiles(context, state, v),
        ),
        ListTile(
          title: const Text('Calendar, contacts, SMS and screen'),
          trailing: Icon(Icons.chevron_right_rounded, color: Palette.of(context).muted),
          onTap: () => _push(context, const SystemPermissionsScreen()),
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Privacy

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    final p = Palette.of(context);
    return _Page('Privacy', [
      _Group([
        ListTile(
          title: const Text('What Telesia knows about you'),
          subtitle: Text(!state.memoryEnabled ? 'Off' : '${state.memory.facts.length} remembered'),
          onTap: () => _push(context, const MemoryScreen()),
        ),
        ListTile(title: Text(tr('About you')), onTap: () => _push(context, const CustomInstructionsScreen())),
        ListTile(title: Text(tr('Saved logins')), onTap: () => _push(context, const LoginsScreen())),
        if (Platform.isAndroid)
          ListTile(
              title: const Text('opencode test'),
              subtitle: const Text('Run the opencode engine on this phone'),
              onTap: () => _push(context, const OpenCodeLabScreen())),
      ]),
      _Group([
        ListTile(title: Text(tr('Archived chats')), onTap: () => _push(context, const ArchivedChatsScreen())),
        ListTile(title: Text(tr('Trash')), onTap: () => _push(context, const FilesScreen(view: FilesView.trash))),
        ListTile(title: Text(tr('How your data is kept')), onTap: () => _push(context, const PrivacyScreen())),
      ]),
      _Group([
        ListTile(
          title: Text('Delete all chats', style: TextStyle(color: p.accent)),
          onTap: () async {
            if (await _confirm(context, 'Delete all chats?', 'This phone and your backup. This cannot be undone.', 'Delete', danger: true)) {
              await state.deleteAllConversations();
            }
          },
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Notifications

class _NotificationsPage extends StatelessWidget {
  const _NotificationsPage();

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    return _Page('Notifications', [
      _Group([
        SwitchListTile(
          title: const Text('Tell me when a task is done'),
          value: state.notifyWhenDone,
          onChanged: state.setNotifyWhenDone,
        ),
      ]),
      const _Group([_NotifHealth()]),
    ]);
  }
}

/// Shows whether Android itself allows Telesia's notifications (it decides whether any "done" notice is seen at
/// all), lets the owner ask again, and sends a test so a silent phone can be checked.
class _NotifHealth extends StatefulWidget {
  const _NotifHealth();
  @override
  State<_NotifHealth> createState() => _NotifHealthState();
}

class _NotifHealthState extends State<_NotifHealth> {
  PermissionStatus? _st;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await Permission.notification.status;
      if (mounted) setState(() => _st = s);
    } catch (_) {}
  }

  Future<PermissionStatus> _ask() async {
    var s = _st ?? await Permission.notification.status;
    if (!s.isGranted && !s.isPermanentlyDenied) s = await Permission.notification.request();
    if (mounted) setState(() => _st = s);
    return s;
  }

  Future<void> _test() async {
    final s = await _ask();
    if (!mounted) return;
    if (!s.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Notifications are off for Telesia. Turn them on in your phone settings.')));
      if (s.isPermanentlyDenied) await openAppSettings();
      return;
    }
    await SystemBridge.I.notifyFrom(
        id: 999001,
        channel: NotifChannels.agent,
        title: 'Telesia',
        body: 'This is a test notification. Task notices will look like this.',
        payload: '',
        initial: '',
        color: NotifFace.agentAccent);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent a test notification.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _st;
    final on = s?.isGranted ?? false;
    final muted = Palette.of(context).muted;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(
        title: const Text('Android notifications'),
        subtitle: Text(s == null ? 'Checking...' : (on ? 'On' : 'Off - Telesia cannot show any notice while this is off')),
        trailing: on
            ? null
            : TextButton(
                onPressed: () async {
                  final r = await _ask();
                  if (!r.isGranted && r.isPermanentlyDenied) await openAppSettings();
                },
                child: const Text('Allow'),
              ),
      ),
      ListTile(
        title: const Text('Send a test notification'),
        subtitle: const Text('Checks that notices reach your phone'),
        trailing: Icon(Icons.notifications_active_outlined, color: muted),
        onTap: _test,
      ),
    ]);
  }
}

/// The opencode engine: which version Telesia runs, and how it is updated. The engine is a native binary that only
/// runs from inside the Telesia APK (Android runs no code from app data), so a newer engine arrives with a Telesia
/// update; this page checks what is out and points the owner at that update.
class _EnginePage extends StatefulWidget {
  const _EnginePage();
  @override
  State<_EnginePage> createState() => _EnginePageState();
}

class _EnginePageState extends State<_EnginePage> {
  String? _latest;
  bool _checking = false;
  bool _failed = false;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _failed = false;
    });
    final v = await OcEngine.latest();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _failed = v == null;
      if (v != null) _latest = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = Palette.of(context).muted;
    final newer = _latest != null && OcEngine.newer(_latest!, OcEngine.version);
    final sub = _checking
        ? 'Checking...'
        : _failed
            ? 'Could not check. Try again.'
            : _latest == null
                ? 'See if a newer engine is out'
                : newer
                    ? 'opencode $_latest is out'
                    : 'You have the newest engine';
    return _Page('Engine', [
      _Group([
        ListTile(
          title: const Text('opencode engine'),
          subtitle: Text('Version ${OcEngine.version} (built into Telesia)'),
        ),
        ListTile(
          title: const Text('Check for updates'),
          subtitle: Text(sub),
          trailing: _checking
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.refresh_rounded, color: muted),
          onTap: _checking ? null : _check,
        ),
      ]),
      if (newer)
        _Group([
          ListTile(
            title: const Text('Update Telesia'),
            subtitle: const Text('The engine ships inside Telesia, so the newest app carries the newest engine.'),
            trailing: Icon(Icons.system_update_alt_rounded, color: muted),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppUpdateScreen())),
          ),
          ListTile(
            title: const Text('What is new in opencode'),
            subtitle: Text('opencode $_latest release notes'),
            trailing: Icon(Icons.open_in_new_rounded, color: muted),
            onTap: () => launchUrl(Uri.parse('https://github.com/anomalyco/opencode/releases/tag/v$_latest'), mode: LaunchMode.externalApplication),
          ),
        ]),
    ]);
  }
}

// ------------------------------------------------------------------ Advanced

class _AdvancedPage extends StatelessWidget {
  const _AdvancedPage();

  Future<void> _pickTrust(BuildContext context, AppState state) async {
    final v = await showModalBottomSheet<String>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('Ask me first'),
            trailing: state.fullAccess ? null : const Icon(Icons.check_rounded),
            onTap: () => Navigator.pop(ctx, 'ask'),
          ),
          ListTile(
            title: const Text('Do routine work alone'),
            subtitle: const Text('Asks only before paying, sending or deleting.'),
            trailing: state.fullAccess ? const Icon(Icons.check_rounded) : null,
            onTap: () => Navigator.pop(ctx, 'full'),
          ),
        ]),
      ),
    );
    if (v == null || !context.mounted) return;
    if (v == 'ask') {
      state.setApprovalMode('ask');
      return;
    }
    if (await _confirm(context, 'Do routine work alone?', 'Telesia still asks before paying, sending, posting or deleting.', 'Turn on')) {
      state.setApprovalMode('full');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    final muted = Palette.of(context).muted;
    return _Page('Advanced', [
      const _Group([FullAccessTile()]),
      _Group([
        ListTile(
          title: Text(tr('Trust level')),
          subtitle: Text(state.fullAccess ? 'Do routine work alone' : 'Ask me first'),
          trailing: Icon(Icons.chevron_right_rounded, color: muted),
          onTap: () => _pickTrust(context, state),
        ),
        SwitchListTile(
          title: const Text('Use phone, apps and websites'),
          value: state.agentEnabled,
          onChanged: state.setAgentEnabled,
        ),
      ]),
      _Group([
        SwitchListTile(
          title: const Text('Always on'),
          subtitle: const Text('Your digital people stay active between tasks. Uses more battery.'),
          value: state.alwaysOn,
          onChanged: (v) => state.setAlwaysOn(v),
        ),
      ]),
      _Group([
        ListTile(
          title: const Text('API & tool servers'),
          trailing: Icon(Icons.chevron_right_rounded, color: muted),
          onTap: () => _push(context, const ConnectorsScreen(advanced: true)),
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Help

class _HelpPage extends StatelessWidget {
  const _HelpPage();

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    void open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return _Page('Help', [
      _Group([
        ListTile(
          title: Text(ft('Send feedback')),
          trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
          onTap: () => _push(context, const FeedbackScreen()),
        ),
        ListTile(
          title: Text(ft('Email us')),
          onTap: () => open('mailto:${AppConfig.supportEmail}?subject=Telesia%20Agent%20${AppConfig.version}'),
        ),
        ListTile(title: Text(tr('Terms')), onTap: () => open(AppConfig.termsUrl)),
        ListTile(title: Text(tr('Privacy policy')), onTap: () => open(AppConfig.privacyUrl)),
      ]),
      _Group(title: 'About', [AppUpdateTile()]),
      const SizedBox(height: Space.x3),
      Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const AppLogo(size: 18),
          const SizedBox(width: Space.x2),
          Text('${AppConfig.appName} · ${AppConfig.version}', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        ]),
      ),
    ]);
  }
}

/// Plain-words privacy summary inside the app.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget h(String t) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 6),
          child: Text(t, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
        );
    Widget b(String t) => Text(t, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.45));
    return Scaffold(
      appBar: AppBar(title: Text(tr('Privacy'))),
      body: ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 32), children: [
        h('Your chats'),
        b('Chats live on this phone. A backup is kept in your Telesia account so they come back on a new phone. '
            'You can delete any chat, all chats, or your whole account at any time.'),
        h('When Telesia thinks'),
        b('To answer you, only your message and the context it needs are sent securely through Telesia\'s server to an AI partner that works on our behalf. '
            'A fair daily allowance is counted per account.'),
        h('Your data is yours'),
        b('Telesia never sells your data and never gives it to third parties for their own use. '
            'Your chats are not used for advertising.'),
        h('Your logins'),
        b('Logins you save for websites, and the sign-ins for apps you connect, are encrypted and stay on this phone. '
            'The AI never sees your saved passwords.'),
        h('Payments'),
        b('If you buy a package or pay as you go, a licensed payment partner takes the payment. Telesia never sees your mobile money PIN or card details.'),
        h('Phone access'),
        b('Telesia only uses the permissions you turn on (files, screen control, SMS, notifications), and asks before anything that pays, sends or deletes.'),
        h('Questions'),
        b('Write to ${AppConfig.supportEmail}.'),
        const SizedBox(height: 18),
        Wrap(spacing: 10, runSpacing: 8, children: [
          OutlinedButton(
            onPressed: () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication),
            child: const Text('Full privacy policy'),
          ),
          OutlinedButton(
            onPressed: () => launchUrl(Uri.parse(AppConfig.termsUrl), mode: LaunchMode.externalApplication),
            child: const Text('Terms of use'),
          ),
        ]),
      ]),
    );
  }
}


/// A group of rows on a soft fill. No border and no lines between rows (PLAN.md 3.1).
class _Group extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _Group(this.children, {this.title});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x4, Space.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: Space.x1, bottom: Space.x2),
              child: Text(tr(title!), style: AppText.sectionStyle.copyWith(color: p.muted)),
            ),
          Container(
            decoration: BoxDecoration(color: p.sheet, borderRadius: Radii.rowAll),
            clipBehavior: Clip.antiAlias,
            child: Material(color: Colors.transparent, child: Column(children: children)),
          ),
        ],
      ),
    );
  }
}

/// Files Telesia moved to its Trash, with one-tap restore.
class TrashScreen extends StatefulWidget {
  final bool embedded;
  const TrashScreen({super.key, this.embedded = false});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<FileSystemEntity> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = Directory(await AgentTools.trashDir());
    final all = await dir.list().toList();
    final items = all.where((e) => !e.path.endsWith('.origin')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  String _name(FileSystemEntity e) {
    final n = e.path.split('/').last;
    final i = n.indexOf('__');
    return i >= 0 ? n.substring(i + 2) : n;
  }

  Future<void> _restore(FileSystemEntity e) async {
    final origin = File('${e.path}.origin');
    if (!await origin.exists()) return;
    final target = (await origin.readAsString()).trim();
    try {
      await Directory(target.substring(0, target.lastIndexOf('/'))).create(recursive: true);
      try {
        await e.rename(target);
      } catch (_) {
        final r = await Process.run('/system/bin/sh', ['-c', 'cp -r "${e.path}" "$target" && rm -rf "${e.path}"']);
        if (r.exitCode != 0) throw Exception(r.stderr);
      }
      await origin.delete();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restored ${_name(e)}')));
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('That file could not be put back. It may have been moved or the phone is low on space.')));
    }
    _load();
  }

  Future<void> _empty() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Empty the Trash?'),
        content: const Text('These files will be gone for good.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text('Empty', style: TextStyle(color: Palette.of(context).accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final dir = Directory(await AgentTools.trashDir());
    await dir.delete(recursive: true);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return maybeScaffold(
      embedded: widget.embedded,
      appBar: AppBar(
        title: Text(tr('Trash'), style: Brand.serif(size: 28, color: p.text)),
        actions: [if (_items.isNotEmpty) TextButton(onPressed: _empty, child: const Text('Empty'))],
      ),
      body: _loading
          ? const Center(child: RedDot(size: 10, animate: true))
          : _items.isEmpty
              ? const Center(child: EmptyHint(text: 'The Trash is empty.'))
              : ListView(
                  children: [
                    // Embedded in Files there is no app bar, so Empty sits at the top of the list.
                    if (widget.embedded)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton(onPressed: _empty, child: const Text('Empty')),
                      ),
                    for (final e in _items)
                      ListTile(
                        title: Text(_name(e), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(e is Directory ? 'Folder' : 'File'),
                        trailing: TextButton(onPressed: () => _restore(e), child: Text(tr('Restore'))),
                      ),
                  ],
                ),
    );
  }
}

class CustomInstructionsScreen extends StatefulWidget {
  const CustomInstructionsScreen({super.key});

  @override
  State<CustomInstructionsScreen> createState() => _CustomInstructionsScreenState();
}

class _CustomInstructionsScreenState extends State<CustomInstructionsScreen> {
  late final AppState _state = context.read<AppState>();
  late final _about = TextEditingController(text: _state.aboutYou);
  late final _how = TextEditingController(text: _state.howToRespond);

  @override
  void dispose() {
    _about.dispose();
    _how.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('About you')),
        actions: [
          TextButton(
            onPressed: () async {
              await _state.saveCustomInstructions(_about.text, _how.text);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(tr('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('What should Telesia know about you?', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: _about, maxLines: 6, minLines: 4, maxLength: 1500),
          const SizedBox(height: 16),
          const Text('How should Telesia reply?', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: _how, maxLines: 6, minLines: 4, maxLength: 1500),
        ],
      ),
    );
  }
}

class ArchivedChatsScreen extends StatelessWidget {
  const ArchivedChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    final archived = state.conversations.where((c) => c.archived).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Archived chats'))),
      body: archived.isEmpty
          ? const Center(child: EmptyHint(text: 'No archived chats.'))
          : ListView(
              children: [
                for (final c in archived)
                  ListTile(
                    title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      state.openConversation(c.id);
                      Navigator.popUntil(context, (r) => r.isFirst);
                    },
                    onLongPress: () => showChatActions(context, c),
                    trailing: TextButton(
                      onPressed: () => state.setArchived(c.id, false),
                      child: Text(tr('Restore')),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Settings > Advanced > Full access (owner, 2026-10-24). Off by default. On: Telesia and your bots act without asking for
/// approval; payments and purchases still ask every time. Turning it on asks once, with the plain explanation.
class FullAccessTile extends StatelessWidget {
  const FullAccessTile({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: FullAccess.I,
      builder: (context, _) => SwitchListTile(
        key: const ValueKey('full-access'),
        title: Text(tr('Full access')),
        subtitle: Text(
          tr(FullAccess.I.on
              ? 'On: Telesia and your bots act without asking. Payments and purchases still ask every time.'
              : 'Off: Telesia and your bots ask before sending, deleting or changing things for you. Small, safe steps go ahead.'),
          style: AppText.microStyle.copyWith(color: p.muted),
        ),
        value: FullAccess.I.on,
        onChanged: (v) async {
          if (v &&
              !await _confirm(
                  context,
                  tr('Turn on Full access?'),
                  tr('Telesia and your bots will send, post, change and delete things for you without asking first. Payments and purchases still ask every time. You can turn this off anytime.'),
                  tr('Turn on'))) {
            return;
          }
          await FullAccess.I.set(v);
        },
      ),
    );
  }
}
