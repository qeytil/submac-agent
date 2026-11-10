import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/system_bridge.dart';
import '../services/system_tools.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// A calm card of rows, like the rest of Settings.
class _Card extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _Card({this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
            child: Text(title!, style: AppText.sectionStyle.copyWith(color: p.muted)),
          ),
        Container(
          decoration: BoxDecoration(
            color: p.sheet,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border, width: 0.8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: Column(children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: Space.x1),
                children[i],
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Re-reads permissions whenever the user comes back from an Android settings screen.
mixin _Refresh<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  Map<String, bool> perms = {};

  Future<void> refresh() async {
    await SystemTools.refreshPerms();
    if (mounted) setState(() => perms = Map.of(SystemTools.perms));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) refresh();
  }
}

// =====================================================================
// Advanced > System permissions
// =====================================================================

class SystemPermissionsScreen extends StatefulWidget {
  const SystemPermissionsScreen({super.key});

  @override
  State<SystemPermissionsScreen> createState() => _SystemPermissionsScreenState();
}

class _SystemPermissionsScreenState extends State<SystemPermissionsScreen> with WidgetsBindingObserver, _Refresh<SystemPermissionsScreen> {
  Widget _row(String key, String title, String what, Future<void> Function() allow) {
    final p = Palette.of(context);
    final on = perms[key] == true;
    final stalled = key == 'accessibility' && perms['accessibilityStalled'] == true;
    if (stalled) {
      return ListTile(
        title: Text(title),
        subtitle: const Text('Android paused it. Turn Telesia off and on once, and set battery use to Unrestricted so it stays on.'),
        trailing: TextButton(
            onPressed: () async {
              await SystemBridge.I.openPermission('accessibility');
              await refresh();
            },
            child: const Text('Fix')),
      );
    }
    return ListTile(
      title: Text(title),
      subtitle: Text(what),
      trailing: on
          ? Text('Allowed', style: TextStyle(color: p.muted, fontSize: AppText.meta))
          : TextButton(onPressed: () async {
              await allow();
              await refresh();
            }, child: Text(tr('Allow'))),
      onTap: on ? () => SystemBridge.I.openPermission(const {'sms', 'microphone', 'calendar', 'contacts'}.contains(key) ? 'app' : key) : null,
    );
  }

  Future<void> _a11y() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Let Telesia use your phone?'),
        content: const Text(
            'Telesia will be able to read the screen and tap, type and scroll for you, only when you ask. '
            'It asks first before anything that sends, pays or deletes.\n\n'
            'On the next screen open "Installed apps" (or "Downloaded apps"), pick "Telesia phone control" and switch it on.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Not now'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Continue'))),
        ],
      ),
    );
    if (ok == true) await SystemBridge.I.openPermission('accessibility');
  }

  Future<void> _runtimeAll(List<Permission> perms) async {
    final r = await perms.request();
    if (r.values.any((s) => s.isPermanentlyDenied)) await openAppSettings();
  }

  Future<void> _runtime(Permission perm) async {
    final s = await perm.request();
    if (s.isPermanentlyDenied) await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('System permissions')),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 0),
          child: Text('Each one is off until you allow it, and you can turn it off again here or in Android settings.',
              style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.45)),
        ),
        _Card(title: 'Phone', children: [
          _row('accessibility', 'Phone control (Accessibility)', 'Telesia can use your apps for you: read the screen, tap, type, scroll', _a11y),
          _row('sms', 'Read SMS', 'Find codes, bank and delivery messages when you ask', () => _runtime(Permission.sms)),
          _row('calendar', 'Calendar', 'See your events and add new ones (every account on this phone)', () => _runtimeAll([Permission.calendarFullAccess])),
          _row('contacts', 'Contacts', 'Find the right person when you ask to call, text or email someone', () => _runtime(Permission.contacts)),
          _row('notifRead', 'Read notifications', '“What did I miss?” Summaries of WhatsApp, bank and other alerts, kept on your phone',
              () => SystemBridge.I.openPermission('notifRead')),
          _row('overlay', 'Display over other apps', 'Floating Live', () => SystemBridge.I.openPermission('overlay')),
        ]),
        _Card(title: 'Background', children: [
          _row('notifications', 'Notifications', 'When a task finishes or a scheduled task runs', () => _runtime(Permission.notification)),
          _row('battery', 'Run in the background', 'Keeps tasks and schedules running', () => SystemBridge.I.openPermission('battery')),
          _row('microphone', 'Microphone', 'Live and voice typing', () => _runtime(Permission.microphone)),
        ]),
        // "Tell me when a task is done" lives only in Settings > Notifications (PLAN.md 3.2).
        const SizedBox(height: 24),
      ]),
    );
  }
}

// =====================================================================
// Scheduled tasks
// =====================================================================

class ScheduledScreen extends StatelessWidget {
  const ScheduledScreen({super.key});

  static String _when(DateTime n, String repeat, String Function(int) two) {
    final time = '${two(n.hour)}:${two(n.minute)}';
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    switch (repeat) {
      case 'daily':
        return 'Every day at $time';
      case 'weekdays':
        return 'Weekdays at $time';
      case 'weekly':
        return 'Every ${days[n.weekday - 1]} at $time';
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(n.year, n.month, n.day).difference(today).inDays;
    if (d == 0) return 'Today at $time';
    if (d == 1) return 'Tomorrow at $time';
    if (d > 1 && d < 7) return '${days[n.weekday - 1]} at $time';
    return '${n.day}/${n.month}/${n.year} at $time';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: Scheduler.I,
      builder: (context, _) {
        final list = Scheduler.I.tasks;
        String two(int n) => n.toString().padLeft(2, '0');
        return Scaffold(
          appBar: AppBar(title: const Text('Scheduled')),
          body: list.isEmpty
              ? Center(
                  child: EmptyHint(
                    text: 'Nothing scheduled yet.',
                    example: 'Every morning at 7, tell me the weather',
                    onExample: () {
                      final state = context.read<AppState>();
                      Navigator.of(context).popUntil((r) => r.isFirst);
                      state.newChat();
                      state.send('Every morning at 7, tell me the weather and my emails.', const []);
                    },
                  ),
                )
              : ListView(children: [
                  _Card(children: [
                    for (final t in list)
                      ListTile(
                        title: Text(t.task, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_when(t.next, t.repeat, two)),
                        trailing: TextButton(
                          onPressed: () => Scheduler.I.cancel(t.id),
                          child: Text(tr('Cancel'), style: TextStyle(color: p.muted)),
                        ),
                      ),
                  ]),
                ]),
        );
      },
    );
  }
}
