import 'package:flutter/material.dart';

import '../services/live_keys.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';

/// Settings -> Voice -> Live voice key. The user connects their own Gemini key for Live calls: with one set,
/// calls go straight to Google (no Telesia Cloud pass) and the daily call minutes do not apply.
class LiveKeyScreen extends StatefulWidget {
  const LiveKeyScreen({super.key});

  @override
  State<LiveKeyScreen> createState() => _LiveKeyScreenState();
}

class _LiveKeyScreenState extends State<LiveKeyScreen> {
  final _key = TextEditingController();
  final _model = TextEditingController(text: LiveKeys.defaultModel);
  bool _busy = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    LiveKeys.load().then((_) {
      if (!mounted) return;
      setState(() {
        _model.text = LiveKeys.model;
        _saved = LiveKeys.enabled;
      });
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final entered = _key.text.trim();
    final keep = LiveKeys.enabled && entered.isEmpty;
    final key = keep ? LiveKeys.key : entered;
    if (key.isEmpty) {
      setState(() => _error = tr('Paste your Gemini key first.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await LiveKeys.save(key, _model.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _saved = true;
      _key.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Saved. Calls use your key now.'))));
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    await LiveKeys.clear();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _saved = false;
      _model.text = LiveKeys.defaultModel;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Using Telesia for calls again.'))));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Live voice key'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.x5, Space.x3, Space.x5, Space.x8),
        children: [
          Text(
            tr('Use Telesia for calls, or connect your own Gemini key. With your own key, calls go straight to '
                'Google and the daily call minutes do not apply.'),
            style: AppText.metaStyle.copyWith(color: p.muted),
          ),
          const SizedBox(height: Space.x4),
          TextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: tr('Gemini API key'),
              hintText: _saved ? tr('Saved — paste a new key to replace it') : 'AIza…',
            ),
          ),
          const SizedBox(height: Space.x3),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('Model'),
              hintText: LiveKeys.defaultModel,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.x3),
            Text(_error!, style: AppText.metaStyle.copyWith(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: Space.x5),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? tr('Saving…') : tr('Save key')),
          ),
          if (_saved) ...[
            const SizedBox(height: Space.x2),
            TextButton(
              onPressed: _busy ? null : _clear,
              child: Text(tr('Use Telesia instead'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ],
      ),
    );
  }
}