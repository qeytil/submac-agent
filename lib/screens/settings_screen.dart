import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../config.dart';
import '../services/cloud.dart';
import '../services/device_access.dart';
import '../services/full_access.dart';
import '../services/rewards.dart';
import '../services/tools.dart';
import '../widgets/logo.dart';
import '../widgets/lux_kit.dart';
import '../widgets/team_parts.dart' show BusyNote;
import '../widgets/motion.dart';
import '../theme.dart';
import '../ui/embed.dart';
import '../ui/i18n.dart';
import '../ui/feedback_words.dart';
import 'files_screen.dart' show FilesScreen, FilesView;
import '../widgets/sidebar.dart';
import '../widgets/update_window.dart';
import 'billing/billing_widgets.dart';
import 'connectors_screen.dart';
import 'feedback_screen.dart';
import 'home_screen.dart' show TodayUsage;
import 'inbox_screen.dart' show enterInviteCode;
import 'logins_screen.dart';
import 'memory_screen.dart';
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
            row('Plan & usage', const _PlanPage()),
            row('Language', const _LanguagePage()),
            row('Voice', const _VoicePage()),
          ]),
          _Group([
            row('Phone access', const _PhonePage()),
            row('Privacy', const _PrivacyPage()),
            row('Notifications', const _NotificationsPage()),
          ]),
          _Group([
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

Future<bool> _confirm(BuildContext context, String title, String body, String action, {bool danger = false}) =>
    luxConfirm(context, title: title, message: body, action: action, destructive: danger);

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
  Widget build(BuildContext context) => ListTile(title: Text(tr(title)), onTap: onTap);
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
    await SharePlus.instance.share(ShareParams(text: Rewards.inviteText(link, code), subject: 'Join me on SubMac'));
  }

  Future<void> _deleteAccount(BuildContext context, AppState state) async {
    final typed = TextEditingController();
    final ok = await showLuxDialog<bool>(
      context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => LuxDialogBody(
          title: tr('Delete your account?'),
          message: tr('Your account, chats, memory, bots and backups are deleted for good.'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Type DELETE to confirm.'), style: AppText.bodyStyle.copyWith(color: Palette.of(d).muted)),
            const SizedBox(height: Space.x2),
            TextField(controller: typed, autofocus: true, onChanged: (_) => setD(() {}), textCapitalization: TextCapitalization.characters),
          ]),
          actions: [
            LuxWordButton('Cancel', onPressed: () => Navigator.pop(d, false)),
            LuxWordButton('Delete forever', destructive: true, onPressed: typed.text.trim().toUpperCase() == 'DELETE' ? () => Navigator.pop(d, true) : null),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    showLuxDialog<void>(context, dismissible: false, builder: (_) => const BusyNote('Deleting…'));
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
    final email = state.repo.email ?? '';
    return _Page('Account', [
      _Group([
        ListTile(
          title: Text(email.isEmpty ? tr('Signed in') : email, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(tr('Backed up')),
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
        LuxRow(title: tr('Delete account'), destructive: true, onTap: () => _deleteAccount(context, state)),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Plan & usage

/// Placeholder home for Dev 2's Plan & usage screen (PLAN.md 2.4): today's usage, and the billing entry while
/// billing is on. Dev 2 replaces the body.
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
      // The app's own words (PLAN.md 3.4). Follows the phone unless picked here.
      _Group(title: 'App language', [
        Padding(
          padding: const EdgeInsets.all(Space.x3),
          child: ListenableBuilder(
            listenable: AppLang.I,
            builder: (context, _) => LuxWords([
              for (final c in const ['phone', 'so', 'ar', 'en'])
                LuxWord(c == 'phone' ? tr(AppLang.names[c]!) : AppLang.names[c]!, selected: AppLang.I.choice == c, onTap: () => AppLang.I.set(c)),
            ]),
          ),
        ),
      ]),
      _Group(title: 'Reply language', [
        Padding(
          padding: const EdgeInsets.all(Space.x3),
          child: LuxWords([
            // Language names in their own language (PLAN.md 3.4). Values stay the stored keys.
            for (final l in const [('auto', 'Auto'), ('Somali', 'Soomaali'), ('Arabic', 'العربية'), ('English', 'English')])
              LuxWord(l.$1 == 'auto' ? tr(l.$2) : l.$2, selected: state.replyLanguage == l.$1, onTap: () => state.setReplyLanguage(l.$1)),
          ]),
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------------------ Voice

class _VoicePage extends StatelessWidget {
  const _VoicePage();

  Future<void> _pickVoice(BuildContext context, AppState state) async {
    final voices = Cloud.features.value.voices;
    final v = await showLuxChoices<String>(context, title: 'Live voice', selected: state.liveVoice, choices: [for (final v in voices) LuxChoice(v, v)]);
    if (v != null) state.setLiveVoice(v);
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
          title: Text(tr('Calendar, contacts, SMS and screen')),
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
    return _Page('Privacy', [
      _Group([
        ListTile(
          title: const Text('What SubMac knows about you'),
          subtitle: Text(!state.memoryEnabled ? 'Off' : '${state.memory.facts.length} remembered'),
          onTap: () => _push(context, const MemoryScreen()),
        ),
        ListTile(title: Text(tr('About you')), onTap: () => _push(context, const CustomInstructionsScreen())),
        ListTile(title: Text(tr('Saved logins')), onTap: () => _push(context, const LoginsScreen())),
      ]),
      _Group([
        ListTile(title: Text(tr('Archived chats')), onTap: () => _push(context, const ArchivedChatsScreen())),
        ListTile(title: Text(tr('Trash')), onTap: () => _push(context, const FilesScreen(view: FilesView.trash))),
        ListTile(title: Text(tr('How your data is kept')), onTap: () => _push(context, const PrivacyScreen())),
      ]),
      _Group([
        LuxRow(
          title: tr('Delete all chats'),
          destructive: true,
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
    ]);
  }
}

// ------------------------------------------------------------------ Advanced

class _AdvancedPage extends StatelessWidget {
  const _AdvancedPage();

  Future<void> _pickTrust(BuildContext context, AppState state) async {
    final v = await showLuxChoices<String>(context, title: 'Trust level', selected: state.fullAccess ? 'full' : 'ask', choices: const [
      LuxChoice('ask', 'Ask me first'),
      LuxChoice('full', 'Do routine work alone', sub: 'Asks only before paying, sending or deleting.'),
    ]);
    if (v == null || !context.mounted) return;
    if (v == 'ask') {
      state.setApprovalMode('ask');
      return;
    }
    if (await _confirm(context, 'Do routine work alone?', 'SubMac still asks before paying, sending, posting or deleting.', 'Turn on')) {
      state.setApprovalMode('full');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _watchSettings(context);
    return _Page('Advanced', [
      const _Group([FullAccessTile()]),
      _Group([
        ListTile(
          title: Text(tr('Trust level')),
          subtitle: Text(tr(state.fullAccess ? 'Do routine work alone' : 'Ask me first')),
          onTap: () => _pickTrust(context, state),
        ),
        SwitchListTile(
          title: const Text('Use phone, apps and websites'),
          value: state.agentEnabled,
          onChanged: state.setAgentEnabled,
        ),
      ]),
      _Group([
        ListTile(
          title: Text(tr('API & tool servers')),
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
          onTap: () => _push(context, const FeedbackScreen()),
        ),
        ListTile(
          title: Text(ft('Email us')),
          onTap: () => open('mailto:${AppConfig.supportEmail}?subject=SubMac%20Agent%20${AppConfig.version}'),
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
        b('Chats live on this phone. A backup is kept in your SubMac account so they come back on a new phone. '
            'You can delete any chat, all chats, or your whole account at any time.'),
        h('When SubMac thinks'),
        b('To answer you, only your message and the context it needs are sent securely through SubMac\'s server to an AI partner that works on our behalf. '
            'A fair daily allowance is counted per account.'),
        h('Your data is yours'),
        b('SubMac never sells your data and never gives it to third parties for their own use. '
            'Your chats are not used for advertising.'),
        h('Your logins'),
        b('Logins you save for websites, and the sign-ins for apps you connect, are encrypted and stay on this phone. '
            'The AI never sees your saved passwords.'),
        h('Payments'),
        b('If you buy a package or pay as you go, a licensed payment partner takes the payment. SubMac never sees your mobile money PIN or card details.'),
        h('Phone access'),
        b('SubMac only uses the permissions you turn on (files, screen control, SMS, notifications), and asks before anything that pays, sends or deletes.'),
        h('Questions'),
        b('Write to ${AppConfig.supportEmail}.'),
        const SizedBox(height: 18),
        Wrap(children: [
          LuxWordButton('Full privacy policy', primary: true, onPressed: () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication)),
          LuxWordButton('Terms of use', primary: true, onPressed: () => launchUrl(Uri.parse(AppConfig.termsUrl), mode: LaunchMode.externalApplication)),
        ]),
      ]),
    );
  }
}


/// A group of rows straight on the page: a quiet label, then the rows. No fill, no border, no lines (fix/ui-restyle).
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
              child: Text(tr(title!), style: AppText.sectionStyle.copyWith(color: p.faint)),
            ),
          Material(type: MaterialType.transparency, child: Column(children: children)),
        ],
      ),
    );
  }
}

/// Files SubMac moved to its Trash, with one-tap restore.
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
    final ok = await luxConfirm(context, title: 'Empty the Trash?', message: 'These files will be gone for good.', action: 'Empty', destructive: true);
    if (!ok) return;
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
          const Text('What should SubMac know about you?', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: _about, maxLines: 6, minLines: 4, maxLength: 1500),
          const SizedBox(height: 16),
          const Text('How should SubMac reply?', style: TextStyle(fontWeight: FontWeight.w600)),
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

/// Settings > Advanced > Full access (owner, 2026-10-24). Off by default. On: SubMac and your bots act without asking for
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
              ? 'On: SubMac and your bots act without asking. Payments and purchases still ask every time.'
              : 'Off: SubMac and your bots ask before sending, deleting or changing things for you. Small, safe steps go ahead.'),
          style: AppText.microStyle.copyWith(color: p.muted),
        ),
        value: FullAccess.I.on,
        onChanged: (v) async {
          if (v &&
              !await _confirm(
                  context,
                  tr('Turn on Full access?'),
                  tr('SubMac and your bots will send, post, change and delete things for you without asking first. Payments and purchases still ask every time. You can turn this off anytime.'),
                  tr('Turn on'))) {
            return;
          }
          await FullAccess.I.set(v);
        },
      ),
    );
  }
}
