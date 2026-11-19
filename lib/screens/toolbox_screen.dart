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
        ? tr('Installed and ready.')
        : _installed
            ? tr('The toolbox binary is in this build, but Linux is not installed yet.')
            : tr('This build does not include the toolbox binary.');
    return Scaffold(
      appBar: AppBar(title: Text(tr('Linux toolbox'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.x5, Space.x3, Space.x5, Space.x8),
        children: [
          Text(
            tr('A small Linux on your phone. Install it once and the agent can use git, gh, node, ffmpeg and other '
                'command-line tools. Your workspace is mounted at /work.'),
            style: AppText.metaStyle.copyWith(color: p.muted),
          ),
          const SizedBox(height: Space.x4),
          Text(status, style: AppText.bodyStyle),
          const SizedBox(height: Space.x3),
          FilledButton(
            onPressed: _busy || _ready ? null : _install,
            child: Text(_ready
                ? tr('Installed')
                : _busy
                    ? tr('Installing...')
                    : tr('Install Linux toolbox')),
          ),
          const SizedBox(height: Space.x6),
          TextField(
            controller: _cmd,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: tr('Run a command'),
              hintText: 'git --version',
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy || !_ready ? null : _run,
              child: Text(tr('Run')),
            ),
          ),
          if (_out.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.x3),
              decoration: BoxDecoration(color: p.code, borderRadius: Radii.fieldAll),
              child: SelectableText(
                _out,
                style: AppText.microStyle.copyWith(color: p.text, fontFamily: 'monospace'),
              ),
            ),
        ],
      ),
    );
  }
}