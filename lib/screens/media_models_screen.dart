import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/media_gen.dart';
import '../services/media_providers.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import '../widgets/brand_logo.dart';
import 'models_screen.dart' show ByokGroup, HeadersSheet;

/// Settings → Media models (owner 2026-11-04, docs/media-providers.md): the user's own providers for pictures, video,
/// speech and music, next to the chat models. One default per kind. Keys stay encrypted on this phone (or are borrowed
/// from a chat provider of the same vendor); the agent and bots use them through media_generate only when asked.
class MediaModelsScreen extends StatelessWidget {
  const MediaModelsScreen({super.key, this.store});

  /// Tests pass their own store; the app uses MediaProviderStore.I.
  final MediaProviderStore? store;

  @override
  Widget build(BuildContext context) {
    final s = store ?? MediaProviderStore.I;
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(tr('Media models'))),
        body: ListView(
          padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x8),
          children: [
            for (final k in MediaKind.values)
              ByokGroup(title: k.label, [
                for (final pr in s.of(k)) _MediaRow(pr, store: s),
                ListTile(
                  key: ValueKey('add-media-${k.id}'),
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.fieldAll),
                    child: Icon(Icons.add_rounded, color: p.text, size: IconSize.lg),
                  ),
                  title: Text('${tr('Add')} ${k.label.toLowerCase()} ${tr('provider')}'),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaPresetPickerScreen(kind: k, store: s))),
                ),
              ]),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2, Space.x5, 0),
              child: Text(
                tr('Your own providers for pictures, video, speech and music. SubMac and your bots use them when you ask '
                    '(“make a picture”, “use my fal key”). Keys stay encrypted on this phone, calls go straight to the '
                    'provider and are billed to your account there, not to your SubMac allowance.'),
                style: AppText.microStyle.copyWith(color: p.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaRow extends StatelessWidget {
  const _MediaRow(this.pr, {required this.store});
  final MediaProvider pr;
  final MediaProviderStore store;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final isDefault = store.defaultId(pr.kind) == pr.id;
    final parts = <String>[
      if (pr.model.isNotEmpty) pr.model,
      tr(store.keyLabel(pr)),
      if (isDefault) tr('default'),
      if (!pr.enabled) tr('off'),
    ];
    return ListTile(
      key: ValueKey('media-${pr.id}'),
      leading: Opacity(opacity: pr.enabled ? 1 : 0.45, child: BrandLogo(pr.logo, pr.label, size: 36)),
      title: Text(pr.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
      trailing: IconButton(
        key: ValueKey('media-default-${pr.id}'),
        tooltip: tr('Use by default'),
        icon: Icon(isDefault ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: isDefault ? p.text : p.muted),
        onPressed: () => store.setDefault(pr.kind, pr.id),
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaProviderEditScreen(provider: pr.copy(), store: store))),
    );
  }
}

/// Step one of adding a media provider: pick a ready-made one for this kind (or a compatible server).
class MediaPresetPickerScreen extends StatelessWidget {
  const MediaPresetPickerScreen({super.key, required this.kind, this.store});
  final MediaKind kind;
  final MediaProviderStore? store;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final presets = MediaPresets.of(kind);
    Widget row(MediaPreset x) => ListTile(
          key: ValueKey('media-preset-${x.id}'),
          leading: BrandLogo(x.logo, x.name, size: 36),
          title: Text(x.name),
          subtitle: Text(x.custom ? tr('Any base URL') : '${x.wire.label}${x.model.isEmpty ? '' : ' · ${x.model}'}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
          onTap: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => MediaProviderEditScreen(provider: MediaProvider.fromPreset(x), store: store, isNew: true)),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text('${tr('Add')} ${kind.label.toLowerCase()} ${tr('provider')}')),
      body: ListView(padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x8), children: [
        ByokGroup(title: 'Providers', [for (final x in presets) if (!x.custom) row(x)]),
        ByokGroup(title: 'Custom', [for (final x in presets) if (x.custom) row(x)]),
      ]),
    );
  }
}

/// Adding or editing one media provider: base URL, key (own or borrowed), model, voice, default, test and delete.
/// Changes are kept on this screen until Save.
class MediaProviderEditScreen extends StatefulWidget {
  const MediaProviderEditScreen({super.key, required this.provider, this.store, this.isNew = false, this.gen});
  final MediaProvider provider;
  final MediaProviderStore? store;
  final bool isNew;

  /// Tests pass a MediaGen with a fake HTTP client.
  final MediaGen? gen;

  @override
  State<MediaProviderEditScreen> createState() => _MediaProviderEditScreenState();
}

class _MediaProviderEditScreenState extends State<MediaProviderEditScreen> {
  late final MediaProvider pr = widget.provider;
  MediaProviderStore get store => widget.store ?? MediaProviderStore.I;
  MediaGen get gen => widget.gen ?? MediaGen.I;

  late final _name = TextEditingController(text: pr.name);
  late final _base = TextEditingController(text: pr.baseUrl);
  late final _model = TextEditingController(text: pr.model);
  late final _voice = TextEditingController(text: pr.voice);
  final _key = TextEditingController();

  late bool _makeDefault = widget.isNew ? store.defaultId(pr.kind) == null : store.defaultId(pr.kind) == pr.id;
  bool _busy = false;
  String? _status;
  bool _statusOk = false;

  @override
  void dispose() {
    for (final c in [_name, _base, _model, _voice, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    pr.name = _name.text.trim();
    pr.baseUrl = _base.text.trim();
    pr.model = _model.text.trim();
    pr.voice = _voice.text.trim();
  }

  /// The key a test uses: the one typed now, else the saved or borrowed one.
  String? get _keyNow {
    final typed = _key.text.trim();
    return typed.isNotEmpty ? typed : store.secretFor(pr);
  }

  String? get _problem {
    if (pr.baseUrl.isEmpty) return tr('Add the base URL.');
    final u = Uri.tryParse(pr.apiBase);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) return tr('The base URL should start with https://');
    if (pr.model.isEmpty) return tr('Add a model id.');
    if (_key.text.trim().isEmpty && store.secretFor(pr) == null) return tr('Add a key.');
    return null;
  }

  Future<void> _test() async {
    _apply();
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      _status = await gen.test(pr, _keyNow);
      _statusOk = true;
    } on MediaGenError catch (e) {
      _status = e.message;
      _statusOk = false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    _apply();
    final problem = _problem;
    if (problem != null) {
      setState(() {
        _status = problem;
        _statusOk = false;
      });
      return;
    }
    if (_key.text.trim().isNotEmpty) await store.setKey(pr, _key.text);
    await store.upsert(pr);
    if (_makeDefault) await store.setDefault(pr.kind, pr.id);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${tr('Remove')} ${pr.label}?'),
        content: Text(tr('Its key is deleted from this phone unless another provider uses it.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr('Remove'), style: TextStyle(color: Theme.of(d).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.remove(pr.id);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _editHeaders() async {
    final res = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: SubMotion.sheet,
      builder: (ctx) => HeadersSheet(headers: pr.headers),
    );
    if (res != null && mounted) setState(() => pr.headers = res);
  }

  InputDecoration _field(String label, {String? hint, String? helper}) => InputDecoration(labelText: tr(label), hintText: hint, helperText: helper, helperMaxLines: 3);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final preset = pr.presetDef;
    final sources = store.keySources(pr);
    final suggestions = [for (final m in preset?.models ?? const <String>[]) m];
    final speech = pr.kind == MediaKind.speech;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          BrandLogo(pr.logo, pr.label, size: 28),
          const SizedBox(width: Space.x3),
          Flexible(child: Text(widget.isNew ? pr.label : tr('Edit provider'), overflow: TextOverflow.ellipsis)),
        ]),
        actions: [TextButton(key: const ValueKey('media-save'), onPressed: _busy ? null : _save, child: Text(tr('Save')))],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x8),
        children: [
          ByokGroup(title: 'Connection', [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, Space.x3),
              child: Column(children: [
                TextField(key: const ValueKey('media-name'), controller: _name, decoration: _field('Name')),
                const SizedBox(height: Space.x3),
                TextField(
                  key: const ValueKey('media-base'),
                  controller: _base,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: _field('Base URL', hint: 'https://api.example.com/v1', helper: pr.wire.label),
                ),
                const SizedBox(height: Space.x3),
                TextField(
                  key: const ValueKey('media-key'),
                  controller: _key,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: _field(pr.keyId.isEmpty ? 'API key' : 'Replace the key',
                          hint: preset?.keyHint.isNotEmpty == true ? preset!.keyHint : null,
                          helper: pr.keyId.isNotEmpty && pr.keyFrom.isEmpty ? '${tr('Saved')}: ${store.keyLabel(pr)}' : null)
                      .copyWith(
                    suffixIcon: IconButton(
                      tooltip: tr('Paste'),
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: () async {
                        final d = await Clipboard.getData(Clipboard.kTextPlain);
                        if (d?.text != null) setState(() => _key.text = d!.text!.trim());
                      },
                    ),
                  ),
                ),
                if ((preset?.note ?? '').isNotEmpty) ...[
                  const SizedBox(height: Space.x2),
                  Align(alignment: AlignmentDirectional.centerStart, child: Text(preset!.note, style: AppText.microStyle.copyWith(color: p.muted))),
                ],
              ]),
            ),
          ]),
          if (sources.isNotEmpty)
            ByokGroup(title: 'Or use a key you already added', [
              for (final (id, label) in sources)
                ListTile(
                  key: ValueKey('media-keyfrom-$id'),
                  leading: Icon(pr.keyFrom == id ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: p.text),
                  title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => setState(() {
                    pr.keyFrom = pr.keyFrom == id ? '' : id;
                    if (pr.keyFrom.isNotEmpty) _key.clear();
                  }),
                ),
            ]),
          ByokGroup(title: 'Model', [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, Space.x3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  key: const ValueKey('media-model'),
                  controller: _model,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  decoration: _field('Model id', helper: tr('Any model id the provider offers.')),
                ),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: Space.x2),
                  Wrap(spacing: Space.x2, runSpacing: Space.x2, children: [
                    for (final m in suggestions)
                      ChoiceChip(
                        key: ValueKey('media-model-$m'),
                        label: Text(m),
                        selected: _model.text.trim() == m,
                        onSelected: (_) => setState(() => _model.text = m),
                      ),
                  ]),
                ],
                if (speech) ...[
                  const SizedBox(height: Space.x3),
                  TextField(key: const ValueKey('media-voice'), controller: _voice, autocorrect: false, decoration: _field('Voice', hint: preset?.voice)),
                ],
              ]),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x1),
            child: OutlinedButton(
              key: const ValueKey('media-test'),
              onPressed: _busy ? null : _test,
              child: Text(tr('Test connection')),
            ),
          ),
          if (_busy) const Padding(padding: EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2), child: LinearProgressIndicator()),
          if (_status != null)
            Padding(
              key: const ValueKey('media-status'),
              padding: const EdgeInsets.fromLTRB(Space.x5, Space.x2, Space.x5, Space.x1),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_statusOk ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: IconSize.md, color: _statusOk ? p.ok : Theme.of(context).colorScheme.error),
                const SizedBox(width: Space.x2),
                Expanded(child: Text(_status!, style: AppText.metaStyle.copyWith(color: p.text))),
              ]),
            ),
          ByokGroup(title: 'Options', [
            SwitchListTile(
              key: const ValueKey('media-default'),
              title: Text('${tr('Default for')} ${pr.kind.label.toLowerCase()}'),
              subtitle: Text(tr('Used when you do not name a provider.'), style: AppText.microStyle.copyWith(color: p.muted)),
              value: _makeDefault,
              onChanged: (v) => setState(() => _makeDefault = v),
            ),
            SwitchListTile(title: Text(tr('Use this provider')), value: pr.enabled, onChanged: (v) => setState(() => pr.enabled = v)),
            ListTile(
              title: Text(tr('Extra headers')),
              subtitle: Text(pr.headers.isEmpty ? tr('None') : pr.headers.keys.join(', '), style: AppText.microStyle.copyWith(color: p.muted)),
              trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
              onTap: _editHeaders,
            ),
            if (!widget.isNew)
              ListTile(
                key: const ValueKey('media-delete'),
                title: Text(tr('Remove provider'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: _delete,
              ),
          ]),
        ],
      ),
    );
  }
}
