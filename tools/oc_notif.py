import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


# --- Android's notification permission, on our own terms -----------------------------------------------------------------
# Every notice (a finished task, a bot's message, a scheduled run) is dropped by Android with no error when
# POST_NOTIFICATIONS is off. The app only ever asked through Firebase (once, only if Firebase started), so on many
# phones it was never asked and everything went silent (owner 2026-11-25: "the app lost the notifications").
sub('lib/app_state.dart',
    "import 'package:http/http.dart' as http;",
    "import 'package:http/http.dart' as http;\nimport 'package:permission_handler/permission_handler.dart';")

sub('lib/state/system_phone.dart',
    "    await sideInits;\n    TelegramBridge.I.onMessage = _telegramAsk;",
    "    await sideInits;\n"
    "    // Ask for Android's notification permission once, on our own (not through Firebase, which may never start):\n"
    "    // every \"done\" notice is dropped silently without it.\n"
    "    unawaited(_ensureNotifPermission());\n"
    "    TelegramBridge.I.onMessage = _telegramAsk;")

sub('lib/state/system_phone.dart',
    "  Future<void> refreshPhoneAccess() async {",
    "  /// Asks for Android's notification permission once (Android 13+) when it is off but still askable, a moment after\n"
    "  /// the app opens. Without it Android drops every notification silently; this no longer depends on Firebase.\n"
    "  Future<void> _ensureNotifPermission() async {\n"
    "    try {\n"
    "      final st = await Permission.notification.status;\n"
    "      if (st.isGranted || st.isPermanentlyDenied) return;\n"
    "      if (local.prefs.getBool('notif_perm_asked_v1') == true) return;\n"
    "      await Future.delayed(const Duration(seconds: 3));\n"
    "      if (!appVisible) return;\n"
    "      await local.prefs.setBool('notif_perm_asked_v1', true);\n"
    "      await Permission.notification.request();\n"
    "    } catch (_) {}\n"
    "  }\n\n"
    "  Future<void> refreshPhoneAccess() async {")

# --- Settings > Notifications: show Android's own switch, let the owner fix it, and send a test --------------------------
sub('lib/screens/settings_screen.dart',
    "import 'package:url_launcher/url_launcher.dart';",
    "import 'package:url_launcher/url_launcher.dart';\nimport 'package:permission_handler/permission_handler.dart';")

sub('lib/screens/settings_screen.dart',
    "import '../services/device_access.dart';",
    "import '../services/device_access.dart';\nimport '../services/notif_text.dart';\nimport '../services/system_bridge.dart';")

sub('lib/screens/settings_screen.dart',
    "      ]),\n    ]);\n  }\n}\n\n// ------------------------------------------------------------------ Advanced",
    "      ]),\n"
    "      const _Group([_NotifHealth()]),\n"
    "    ]);\n  }\n}\n\n"
    "/// Shows whether Android itself allows Telesia's notifications (it decides whether any \"done\" notice is seen at\n"
    "/// all), lets the owner ask again, and sends a test so a silent phone can be checked.\n"
    "class _NotifHealth extends StatefulWidget {\n"
    "  const _NotifHealth();\n"
    "  @override\n"
    "  State<_NotifHealth> createState() => _NotifHealthState();\n"
    "}\n\n"
    "class _NotifHealthState extends State<_NotifHealth> {\n"
    "  PermissionStatus? _st;\n\n"
    "  @override\n"
    "  void initState() {\n"
    "    super.initState();\n"
    "    _load();\n"
    "  }\n\n"
    "  Future<void> _load() async {\n"
    "    try {\n"
    "      final s = await Permission.notification.status;\n"
    "      if (mounted) setState(() => _st = s);\n"
    "    } catch (_) {}\n"
    "  }\n\n"
    "  Future<PermissionStatus> _ask() async {\n"
    "    var s = _st ?? await Permission.notification.status;\n"
    "    if (!s.isGranted && !s.isPermanentlyDenied) s = await Permission.notification.request();\n"
    "    if (mounted) setState(() => _st = s);\n"
    "    return s;\n"
    "  }\n\n"
    "  Future<void> _test() async {\n"
    "    final s = await _ask();\n"
    "    if (!mounted) return;\n"
    "    if (!s.isGranted) {\n"
    "      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(\n"
    "          content: Text('Notifications are off for Telesia. Turn them on in your phone settings.')));\n"
    "      if (s.isPermanentlyDenied) await openAppSettings();\n"
    "      return;\n"
    "    }\n"
    "    await SystemBridge.I.notifyFrom(\n"
    "        id: 999001,\n"
    "        channel: NotifChannels.agent,\n"
    "        title: 'Telesia',\n"
    "        body: 'This is a test notification. Task notices will look like this.',\n"
    "        payload: '',\n"
    "        initial: '',\n"
    "        color: NotifFace.agentAccent);\n"
    "    if (mounted) {\n"
    "      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent a test notification.')));\n"
    "    }\n"
    "  }\n\n"
    "  @override\n"
    "  Widget build(BuildContext context) {\n"
    "    final s = _st;\n"
    "    final on = s?.isGranted ?? false;\n"
    "    final muted = Palette.of(context).muted;\n"
    "    return Column(mainAxisSize: MainAxisSize.min, children: [\n"
    "      ListTile(\n"
    "        title: const Text('Android notifications'),\n"
    "        subtitle: Text(s == null ? 'Checking...' : (on ? 'On' : 'Off - Telesia cannot show any notice while this is off')),\n"
    "        trailing: on\n"
    "            ? null\n"
    "            : TextButton(\n"
    "                onPressed: () async {\n"
    "                  final r = await _ask();\n"
    "                  if (!r.isGranted && r.isPermanentlyDenied) await openAppSettings();\n"
    "                },\n"
    "                child: const Text('Allow'),\n"
    "              ),\n"
    "      ),\n"
    "      ListTile(\n"
    "        title: const Text('Send a test notification'),\n"
    "        subtitle: const Text('Checks that notices reach your phone'),\n"
    "        trailing: Icon(Icons.notifications_active_outlined, color: muted),\n"
    "        onTap: _test,\n"
    "      ),\n"
    "    ]);\n"
    "  }\n"
    "}\n\n"
    "// ------------------------------------------------------------------ Advanced")

print('notifications: request the Android permission on our own + a status/test control in Settings')