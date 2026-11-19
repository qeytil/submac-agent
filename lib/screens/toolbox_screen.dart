import 'package:flutter/material.dart';

import '../services/toolbox.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';

/// Settings -> Advanced -> Linux toolbox. Installs a proot Alpine rootfs so the agent can run real CLIs
/// (git, gh, node/npm, ffmpeg, python...) on the phone. Opt-in: nothing runs until the user installs it.
class ToolboxScreen extends StatefulWidget {
  const ToolboxScreen({super.key});

  @override
  State<ToolboxScreen> createState() => _ToolboxScreenState();
}

class _ToolboxScreenState extends State<ToolboxScreen> {
  final _cmd = TextEditingController();
  bool _busy = false;
  bool _installed = false;
  bool _ready = false;
  String _out = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _cmd.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = await Toolbox.status();
    if (!mounted) return;
    setState(() {
      _installed = s['installed'] == true;
      _ready = s['ready'] == true;
    });
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _out = tr('Downloading Linux... this takes a few minutes.');
    });
    final r = await Toolbox.install();
    await _refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _out = r;
    });
  }

  Future<void> _run() async {
    final c = _cmd.text.trim();
    if (c.isEmpty) return;
    setState(() {
      _busy = true;
      _out = '';
    });
    final r = await Toolbox.run(c);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _out = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final status = _ready
        ? const String('')
        : _installed
            ? const String('')
            : const String('');
  }
}