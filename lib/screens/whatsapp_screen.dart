import 'package:flutter/material.dart';

import '../services/system_bridge.dart';
import '../services/whatsapp.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../widgets/pill_kit.dart';
import '../ui/tokens.dart';
import '../widgets/surface.dart';

/// "WhatsApp on this phone": what Telesia needs (notification access + phone control), why, and the switches.
class WhatsAppScreen extends StatefulWidget {
  const WhatsAppScreen({super.key});

  @override
  State<WhatsAppScreen> createState() => _WhatsAppScreenState();
}

class _WhatsAppScreenState extends State<WhatsAppScreen> with WidgetsBindingObserver {
  Map<String, dynamic> _st = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from Android settings: show the new state.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    // Never a forever-loading page: a slow or failing phone check shows the page with what is known.
    var st = _st;
    try {
      await WhatsAppTools.init().timeout(const Duration(seconds: 8));
      st = await WhatsAppTools.status().timeout(const Duration(seconds: 8));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _st = st;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final personal = _st['personal'] == true;
    final business = _st['business'] == true;
    final notif = _st['notifRead'] == true;
    final a11y = _st['phoneControl'] == true;
    Widget note(String t) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 12),
          child: Text(t, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.45)),
        );
    Widget head(String t) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 8),
          child: Text(t, style: AppText.sectionStyle.copyWith(color: p.muted)),
        );
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        centerTitle: true,
        title: Text('WhatsApp'),
      ),
      body: _loading
          ? const SkeletonList(rows: 4)
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  note('Telesia reads and sends WhatsApp for you. You approve every message. Nothing leaves this phone.'),
                  if (_st.isEmpty) note('Not available on this device.'),
                  head('On this phone'),
                  CardRow(
                    title: personal || business
                        ? [if (personal) 'WhatsApp', if (business) 'WhatsApp Business'].join(' and ')
                        : 'WhatsApp is not installed',
                    subtitle: personal || business ? 'Installed' : 'Install WhatsApp or WhatsApp Business from the Play Store',
                    done: personal || business,
                  ),
                  head('What Telesia needs'),
                  CardRow(
                    title: 'Notification access',
                    subtitle: 'To see new WhatsApp messages, list who wrote, reply from the notification, and wake bots that watch a chat',
                    done: notif,
                    action: notif ? null : 'Allow',
                    onAction: notif ? null : () => SystemBridge.I.openPermission('notifRead'),
                    onTap: notif ? () => SystemBridge.I.openPermission('notifRead') : null,
                  ),
                  CardRow(
                    title: 'Phone control',
                    subtitle: 'To open a chat, press Send or Call, read a conversation and share files. Android shows this as '
                        'Accessibility > Telesia. It only acts when you or your bot asked',
                    done: a11y,
                    action: a11y ? null : 'Allow',
                    onAction: a11y ? null : () => SystemBridge.I.openPermission('accessibility'),
                    onTap: a11y ? () => SystemBridge.I.openPermission('accessibility') : null,
                  ),
                  if (_st['locked'] == true) note('The phone is locked: only replies from notifications work until it is unlocked.'),
                  if (personal && business) ...[
                    head('Use by default'),
                    SurfaceGroup(margin: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x3), children: [
                      for (final e in const {'personal': 'WhatsApp', 'business': 'WhatsApp Business'}.entries)
                        RadioListTile<String>(
                          value: e.key,
                          // RadioGroup would change this row's layout; keep the tile as it is for now.
                          // ignore: deprecated_member_use
                          groupValue: WhatsAppTools.defaultApp,
                          title: Text(e.value),
                          // ignore: deprecated_member_use
                          onChanged: (v) async {
                            await WhatsAppTools.setDefaultApp(v ?? 'personal');
                            if (mounted) setState(() {});
                          },
                        ),
                    ]),
                  ],
                  head('Privacy'),
                  SurfaceGroup(margin: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x3), children: [
                  SwitchListTile(
                    title: const Text('Keep new messages for Telesia'),
                    subtitle: Text('${_st['chats'] ?? 0} chats saved on this phone, newest 40 messages each, 7 days',
                        style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                    value: _st['capture'] != false,
                    onChanged: (v) async {
                      await SystemBridge.I.waCapture(v);
                      await _refresh();
                    },
                  ),
                  ]),
                  CardRow(
                    title: 'Clear saved WhatsApp messages',
                    subtitle: 'Removes them from Telesia on this phone. WhatsApp itself is not touched',
                    action: 'Clear',
                    onAction: () async {
                      await SystemBridge.I.waClear();
                      await _refresh();
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cleared.')));
                    },
                  ),
                ],
              ),
            ),
    );
  }
}
