import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/byok.dart';
import '../services/byok_fetch.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import '../widgets/brand_logo.dart';
import '../widgets/logo.dart';
import '../widgets/model_picker.dart';

/// Settings → Models (BYOK, owner 2026-11-03, docs/byok.md): which model the chats use (SubMac or one of the user's
/// own providers), and the providers themselves. Keys stay encrypted on this phone; calls to a provider go straight
/// from the phone and are never billed by SubMac.
class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key, this.store});

  /// Tests pass their own store; the app uses ByokStore.I.
  final ByokStore? store;

  @override
  Widget build(BuildContext context) {
    final s = store ?? ByokStore.I;
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final chat = s.resolve(s.chatModel);
        return Scaffold(
          appBar: AppBar(title: Text(tr('Models'))),
          body: ListView(
            padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x8),
            children: [
              ByokGroup(title: 'Your chats use', [
                ListTile(
                  key: const ValueKey('chat-model'),
                  leading: chat == null ? const AppLogo(size: 36) : BrandLogo(chat.provider.logo, chat.provider.label, size: 36),
                  title: Text(chat == null ? 'SubMac' : chat.model.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(chat == null ? tr('Included in your plan') : '${chat.provider.label} · ${tr('your key')}',
                      style: AppText.microStyle.copyWith(color: p.muted)),
                  trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
                  onTap: () async {
                    final v = await showModelPicker(context, current: s.chatModel, title: 'Model for your chats');
                    if (v != null) await s.setChatModel(v);
                  },
                ),
              ]),
              ByokGroup(title: 'Your providers', [
                for (final pr in s.providers) _ProviderRow(pr, store: s),
                ListTile(
                  key: const ValueKey('add-provider'),
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.fieldAll),
                    child: Icon(Icons.add_rounded, color: p.text, size: IconSize.lg),
                  ),
                  title: Text(tr('Add a provider')),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PresetPickerScreen(store: s))),
                ),
              ]),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2, Space.x5, 0),
                child: Text(
                  tr('Bring your own key: use models from OpenAI, Anthropic, Google, OpenRouter and more with your own account. '
                      'Keys stay encrypted on this phone and are never sent to SubMac. Calls go straight to the provider, '
                      'so they do not use your SubMac allowance.'),
                  style: AppText.microStyle.copyWith(color: p.muted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow(this.pr, {required this.store});
  final ByokProvider pr;
  final ByokStore store;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = pr.enabledModels.length;
    final key = pr.active;
    final parts = <String>[
      n == 1 ? '1 model' : '$n models',
      if (pr.needsKey) key == null ? tr('no key') : ByokKey.mask(key.hint),
      if (!pr.enabled) tr('off'),
    ];
    return ListTile(
      key: ValueKey('provider-${pr.id}'),
      leading: Opacity(opacity: pr.enabled ? 1 : 0.45, child: BrandLogo(pr.logo, pr.label, size: 36)),
      title: Text(pr.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(parts.join(' · '), style: AppText.microStyle.copyWith(color: p.muted)),
      trailing: Switch(
        value: pr.enabled,
        onChanged: (v) async {
          final c = pr.copy()..enabled = v;
          await store.upsert(c);
        },
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProviderEditScreen(provider: pr.copy(), store: store))),
    );
  }
}

/// A group of rows on a soft fill, as in Settings (no lines between rows, PLAN.md 3.1).
class ByokGroup extends StatelessWidget {
  const ByokGroup(this.children, {super.key, this.title});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x4, Space.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
      ]),
    );
  }
}

/// Step one of adding a provider: pick a preset (or a custom OpenAI- or Anthropic-compatible server).
class PresetPickerScreen extends StatelessWidget {
  const PresetPickerScreen({super.key, this.store});
  final ByokStore? store;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final presets = [for (final x in ByokPresets.all) if (!x.custom) x];
    final custom = [for (final x in ByokPresets.all) if (x.custom) x];
    Widget row(ByokPreset x) => ListTile(
          key: ValueKey('preset-${x.id}'),
          leading: BrandLogo(x.logo, x.name, size: 36),
          title: Text(x.name),
          subtitle: Text(x.custom ? tr('Any base URL') : (x.needsKey ? x.kind.label : tr('On your network, no key')),
              style: AppText.microStyle.copyWith(color: p.muted)),
          onTap: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => ProviderEditScreen(provider: ByokProvider.fromPreset(x), store: store, isNew: true)),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Add a provider'))),
      body: ListView(padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x8), children: [
        ByokGroup(title: 'Providers', [for (final x in presets) row(x)]),
        ByokGroup(title: 'Custom', [for (final x in custom) row(x)]),
      ]),
    );
  }
}

/// Adding or editing one provider: connection, key(s), models (fetched, searched, picked, or typed), advanced
/// options, test and delete. Changes are kept on this screen until Save.
class ProviderEditScreen extends StatefulWidget {
  const ProviderEditScreen({super.key, required this.provider, this.store, this.isNew = false, this.fetch});
  final ByokProvider provider;
  final ByokStore? store;
  final bool isNew;

  /// Tests pass a fetcher with a fake HTTP client.
  final ByokFetch? fetch;

  @override
  State<ProviderEditScreen> createState() => _ProviderEditScreenState();
}

class _ProviderEditScreenState extends State<ProviderEditScreen> {
  late final ByokProvider pr = widget.provider;
  ByokStore get store => widget.store ?? ByokStore.I;
  ByokFetch get fetcher => widget.fetch ?? ByokFetch.I;

  late final _name = TextEditingController(text: pr.name);
  late final _base = TextEditingController(text: pr.baseUrl);
  late final _modelsUrl = TextEditingController(text: pr.modelsUrl);
  final _key = TextEditingController();
  final _search = TextEditingController();
  final _customModel = TextEditingController();

  /// Keys added on this screen (removed again if the screen is left without saving a new provider).
  final _newKeys = <ByokKey>[];

  /// Models the provider listed, not yet chosen (chosen ones live in pr.models).
  List<ByokModel> _listed = [];
  bool _busy = false;
  String? _status;
  bool _statusOk = false;
  bool _saved = false;
  bool _showAll = false;

  @override
  void dispose() {
    // Keys typed here are kept only when the provider is saved.
    if (!_saved) store.discardKeys(_newKeys);
    for (final c in [_name, _base, _modelsUrl, _key, _search, _customModel]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    pr.name = _name.text.trim();
    pr.baseUrl = _base.text.trim();
    pr.modelsUrl = _modelsUrl.text.trim();
  }

  /// The key used for fetch and test: the one typed now, else the active saved key.
  String? get _keyNow {
    final typed = _key.text.trim();
    if (typed.isNotEmpty) return typed;
    return store.activeSecret(pr);
  }

  Future<void> _addTypedKey() async {
    final typed = _key.text.trim();
    if (typed.isEmpty) return;
    final k = await store.addKey(pr, typed);
    _newKeys.add(k);
    _key.clear();
    if (mounted) setState(() {});
  }

  Future<void> _fetch() async {
    _apply();
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final list = await fetcher.models(pr, _keyNow);
      final have = {for (final m in pr.models) m.id};
      _listed = [for (final m in list) if (!have.contains(m.id)) m];
      // Known details refresh the chosen models too (context, output, flags), keeping the user's own names.
      for (final m in list) {
        final mine = pr.model(m.id);
        if (mine == null) continue;
        mine.context ??= m.context;
        mine.output ??= m.output;
        mine.vision ??= m.vision;
        mine.reasoning ??= m.reasoning;
        mine.tools ??= m.tools;
        if (mine.name.isEmpty) mine.name = m.name;
      }
      _statusOk = true;
      _status = list.isEmpty ? tr('The provider lists no chat models. Add one by its id below.') : '${list.length} ${tr('models found. Pick the ones you want.')}';
    } on ByokError catch (e) {
      _statusOk = false;
      _status = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    _apply();
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      _status = await fetcher.test(pr, _keyNow);
      _statusOk = true;
    } on ByokError catch (e) {
      _status = e.message;
      _statusOk = false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(ByokModel m, bool on) {
    setState(() {
      if (on) {
        _listed.remove(m);
        pr.models.add(m..enabled = true);
      } else {
        pr.models.remove(m);
        if (!m.custom) _listed.insert(0, m);
      }
    });
  }

  void _addCustomModel() {
    final id = _customModel.text.trim();
    if (id.isEmpty || pr.model(id) != null) return;
    setState(() {
      _listed.removeWhere((m) => m.id == id);
      pr.models.add(ByokModel(id: id, custom: true));
      _customModel.clear();
    });
  }

  String? get _problem {
    if (pr.baseUrl.isEmpty) return tr('Add the base URL.');
    final u = Uri.tryParse(pr.baseUrl);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) return tr('The base URL should start with https://');
    if (pr.needsKey && pr.keys.isEmpty) return tr('Add a key.');
    if (pr.models.isEmpty) return tr('Choose at least one model.');
    return null;
  }

  Future<void> _save() async {
    _apply();
    if (_key.text.trim().isNotEmpty) await _addTypedKey();
    final problem = _problem;
    if (problem != null) {
      setState(() {
        _status = problem;
        _statusOk = false;
      });
      return;
    }
    await store.upsert(pr);
    _saved = true;
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${tr('Remove')} ${pr.label}?'),
        content: Text(tr('Its keys are deleted from this phone. Chats and bots using its models go back to SubMac.')),
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
    _saved = true;
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _editModel(ByokModel m) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: SubMotion.sheet,
      builder: (ctx) => ModelOptionsSheet(model: m),
    );
    if (changed == true && mounted) setState(() {});
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
    final q = _search.text.trim().toLowerCase();
    bool match(ByokModel m) => q.isEmpty || m.id.toLowerCase().contains(q) || m.name.toLowerCase().contains(q);
    final chosen = [for (final m in pr.models) if (match(m)) m];
    final listed = [for (final m in _listed) if (match(m)) m];
    final shownListed = _showAll || q.isNotEmpty ? listed : listed.take(60).toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          BrandLogo(pr.logo, pr.label, size: 28),
          const SizedBox(width: Space.x3),
          Flexible(child: Text(widget.isNew ? pr.label : tr('Edit provider'), overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          TextButton(key: const ValueKey('provider-save'), onPressed: _busy ? null : _save, child: Text(tr('Save'))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: Space.x1, bottom: Space.x8),
        children: [
          ByokGroup(title: 'Connection', [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, Space.x3),
              child: Column(children: [
                TextField(key: const ValueKey('provider-name'), controller: _name, decoration: _field('Name')),
                const SizedBox(height: Space.x3),
                TextField(
                  key: const ValueKey('provider-base'),
                  controller: _base,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: _field('Base URL',
                      hint: pr.kind.isAnthropic ? 'https://api.example.com' : 'https://api.example.com/v1',
                      helper: '${pr.kind.label} API'),
                ),
                if (pr.needsKey) ...[
                  const SizedBox(height: Space.x3),
                  TextField(
                    key: const ValueKey('provider-key'),
                    controller: _key,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    decoration: _field(pr.keys.isEmpty ? 'API key' : 'Add another key', hint: preset?.keyHint.isNotEmpty == true ? preset!.keyHint : null).copyWith(
                      suffixIcon: IconButton(
                        tooltip: tr('Paste'),
                        icon: const Icon(Icons.content_paste_rounded),
                        onPressed: () async {
                          final d = await Clipboard.getData(Clipboard.kTextPlain);
                          if (d?.text != null) setState(() => _key.text = d!.text!.trim());
                        },
                      ),
                    ),
                    onSubmitted: (_) => _addTypedKey(),
                  ),
                ],
                if ((preset?.note ?? '').isNotEmpty) ...[
                  const SizedBox(height: Space.x2),
                  Align(alignment: AlignmentDirectional.centerStart, child: Text(preset!.note, style: AppText.microStyle.copyWith(color: p.muted))),
                ],
              ]),
            ),
          ]),
          if (pr.keys.isNotEmpty)
            ByokGroup(title: 'Keys', [
              for (final k in pr.keys)
                ListTile(
                  key: ValueKey('key-${k.id}'),
                  leading: Icon(k.id == pr.active?.id ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: p.text),
                  title: Text(k.name),
                  subtitle: Text(ByokKey.mask(k.hint), style: AppText.microStyle.copyWith(color: p.muted)),
                  trailing: IconButton(
                    tooltip: tr('Remove key'),
                    icon: Icon(Icons.close_rounded, color: p.muted),
                    onPressed: () async {
                      await store.removeKey(pr, k.id);
                      setState(() {});
                    },
                  ),
                  onTap: () => setState(() => pr.activeKey = k.id),
                ),
              if (pr.keys.length > 1)
                SwitchListTile(
                  title: Text(tr('Switch keys when one fails')),
                  subtitle: Text(tr('When a key is refused or out of quota, the next one takes over.'), style: AppText.microStyle.copyWith(color: p.muted)),
                  value: pr.rotate,
                  onChanged: (v) => setState(() => pr.rotate = v),
                ),
            ]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x1),
            child: Row(children: [
              Expanded(
                child: FilledButton.tonal(
                  key: const ValueKey('provider-fetch'),
                  onPressed: _busy ? null : _fetch,
                  child: Text(tr('Fetch models')),
                ),
              ),
              const SizedBox(width: Space.x3),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('provider-test'),
                  onPressed: _busy ? null : _test,
                  child: Text(tr('Test connection')),
                ),
              ),
            ]),
          ),
          if (_busy) const Padding(padding: EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2), child: LinearProgressIndicator()),
          if (_status != null)
            Padding(
              key: const ValueKey('provider-status'),
              padding: const EdgeInsets.fromLTRB(Space.x5, Space.x2, Space.x5, Space.x1),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_statusOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                    size: IconSize.md, color: _statusOk ? p.ok : Theme.of(context).colorScheme.error),
                const SizedBox(width: Space.x2),
                Expanded(child: Text(_status!, style: AppText.metaStyle.copyWith(color: p.text))),
              ]),
            ),
          if (pr.models.isNotEmpty || _listed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.x4, Space.x3, Space.x4, 0),
              child: TextField(
                key: const ValueKey('model-search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Search models'), isDense: true),
              ),
            ),
          ByokGroup(title: pr.models.isEmpty ? 'Models' : '${tr('Chosen models')} (${pr.models.length})', [
            for (final m in chosen)
              _ModelRow(
                m,
                chosen: true,
                onToggle: (v) => _toggle(m, v),
                onEdit: () => _editModel(m),
              ),
            if (pr.models.isEmpty)
              ListTile(title: Text(tr('Fetch the list, or add a model by its id.'), style: AppText.metaStyle.copyWith(color: p.muted))),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.x4, 0, Space.x2, Space.x2),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('custom-model'),
                    controller: _customModel,
                    autocorrect: false,
                    decoration: InputDecoration(hintText: tr('Add a model by id'), isDense: true),
                    onSubmitted: (_) => _addCustomModel(),
                  ),
                ),
                IconButton(key: const ValueKey('custom-model-add'), tooltip: tr('Add'), icon: const Icon(Icons.add_rounded), onPressed: _addCustomModel),
              ]),
            ),
          ]),
          if (listed.isNotEmpty)
            ByokGroup(title: '${tr('Available')} (${listed.length})', [
              for (final m in shownListed) _ModelRow(m, chosen: false, onToggle: (v) => _toggle(m, v)),
              if (shownListed.length < listed.length)
                ListTile(
                  title: Text('${tr('Show all')} ${listed.length}', style: AppText.metaStyle.copyWith(color: p.text)),
                  onTap: () => setState(() => _showAll = true),
                ),
            ]),
          ByokGroup(title: 'Advanced', [
            if (!(preset?.custom ?? true) || pr.modelsUrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, Space.x2),
                child: TextField(
                  controller: _modelsUrl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: _field('Model list URL', helper: tr('Leave empty to use the base URL + /models.')),
                ),
              ),
            ListTile(
              title: Text(tr('Extra headers')),
              subtitle: Text(pr.headers.isEmpty ? tr('None') : pr.headers.keys.join(', '), style: AppText.microStyle.copyWith(color: p.muted)),
              trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
              onTap: _editHeaders,
            ),
            SwitchListTile(
              title: Text(tr('Use this provider')),
              value: pr.enabled,
              onChanged: (v) => setState(() => pr.enabled = v),
            ),
            if (!widget.isNew)
              ListTile(
                key: const ValueKey('provider-delete'),
                title: Text(tr('Remove provider'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: _delete,
              ),
          ]),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow(this.m, {required this.chosen, required this.onToggle, this.onEdit});
  final ByokModel m;
  final bool chosen;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onEdit;

  static String _k(int n) => n >= 1000000 ? '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M' : '${(n / 1000).round()}K';

  static String facts(ByokModel m) => [
        if (m.label != m.id) m.id,
        if (m.context != null) '${_k(m.context!)} context',
        if (m.vision == true) 'vision',
        if (m.reasoning == true) 'reasoning',
        if (m.custom) 'added by you',
      ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final f = facts(m);
    return ListTile(
      key: ValueKey('${chosen ? 'chosen' : 'listed'}-${m.id}'),
      leading: Checkbox(value: chosen, onChanged: (v) => onToggle(v ?? false)),
      title: Text(m.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: f.isEmpty ? null : Text(f, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
      trailing: onEdit == null ? null : IconButton(tooltip: tr('Model options'), icon: Icon(Icons.tune_rounded, color: p.muted), onPressed: onEdit),
      onTap: () => onToggle(!chosen),
    );
  }
}

/// Per-model options: display name, context and output limits, and what the model can do.
class ModelOptionsSheet extends StatefulWidget {
  const ModelOptionsSheet({super.key, required this.model});
  final ByokModel model;

  @override
  State<ModelOptionsSheet> createState() => _ModelOptionsSheetState();
}

class _ModelOptionsSheetState extends State<ModelOptionsSheet> {
  ByokModel get m => widget.model;
  late final _name = TextEditingController(text: m.name);
  late final _ctx = TextEditingController(text: m.context?.toString() ?? '');
  late final _out = TextEditingController(text: m.output?.toString() ?? '');
  late bool _vision = m.vision ?? false;
  late bool _reasoning = m.reasoning ?? false;
  late bool _tools = m.tools ?? true;

  @override
  void dispose() {
    _name.dispose();
    _ctx.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.x5, 0, Space.x5, Space.x4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(m.id, style: AppText.titleStyle.copyWith(color: p.text)),
            const SizedBox(height: Space.x3),
            TextField(controller: _name, decoration: InputDecoration(labelText: tr('Display name'), hintText: m.id)),
            const SizedBox(height: Space.x3),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctx,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr('Context (tokens)'), hintText: '128000'),
                ),
              ),
              const SizedBox(width: Space.x3),
              Expanded(
                child: TextField(
                  controller: _out,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr('Max output'), hintText: '8192'),
                ),
              ),
            ]),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr('Uses tools')), value: _tools, onChanged: (v) => setState(() => _tools = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr('Sees images')), value: _vision, onChanged: (v) => setState(() => _vision = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(tr('Thinks before answering')), value: _reasoning, onChanged: (v) => setState(() => _reasoning = v)),
            const SizedBox(height: Space.x2),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  m.name = _name.text.trim();
                  m.context = int.tryParse(_ctx.text.trim());
                  m.output = int.tryParse(_out.text.trim());
                  m.tools = _tools;
                  m.vision = _vision;
                  m.reasoning = _reasoning;
                  Navigator.pop(context, true);
                },
                child: Text(tr('Done')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Extra HTTP headers sent with every call to a provider (one `Name: value` per line).
class HeadersSheet extends StatefulWidget {
  const HeadersSheet({super.key, required this.headers});
  final Map<String, String> headers;

  static Map<String, String> parse(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      if (RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(k) && v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  @override
  State<HeadersSheet> createState() => _HeadersSheetState();
}

class _HeadersSheetState extends State<HeadersSheet> {
  late final _c = TextEditingController(text: widget.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.x5, 0, Space.x5, Space.x4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Extra headers'), style: AppText.titleStyle.copyWith(color: p.text)),
            const SizedBox(height: Space.x2),
            Text(tr('One per line, like HTTP-Referer: https://example.com'), style: AppText.microStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x3),
            TextField(controller: _c, minLines: 3, maxLines: 8, autocorrect: false, decoration: const InputDecoration(hintText: 'Name: value')),
            const SizedBox(height: Space.x3),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(context, HeadersSheet.parse(_c.text)), child: Text(tr('Done'))),
            ),
          ]),
        ),
      ),
    );
  }
}
