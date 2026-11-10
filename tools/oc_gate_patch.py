import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n))
        sys.exit(1)
    p.write_text(s.replace(old, new))
    print("patched", path)

C = "lib/widgets/composer.dart"

patch(C, "import '../services/bots.dart';\n", "import '../services/bots.dart';\nimport '../services/byok.dart';\n")
patch(C, "import '../screens/skills_screen.dart';\n", "import '../screens/skills_screen.dart';\nimport '../screens/models_screen.dart';\n")

patch(
    C,
    """  void _send() {
    final state = context.read<AppState>();
""",
    """  void _send() {
    final state = context.read<AppState>();
    // BYOK only: with no model of the owner's own there is nothing to send to (SubMac's own model is going away).
    if (ByokStore.I.loaded && !ByokStore.I.hasChoices) {
      _openModels();
      return;
    }
""",
)

patch(
    C,
    """    state.send(text, atts);
  }

  @override
  Widget build(BuildContext context) {
""",
    """    state.send(text, atts);
  }

  /// BYOK only: the one place the owner adds a provider and picks a model.
  void _openModels() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ModelsScreen()));
  }

  @override
  Widget build(BuildContext context) {
""",
)

patch(
    C,
    """    final state = context.watch<AppState>();
    // A chat that changed while another screen covered this one""",
    """    final state = context.watch<AppState>();
    // BYOK only: no usable model of the owner's own yet, so the box leads to model setup (SubMac's model is going away).
    final needsModel = ByokStore.I.loaded && !ByokStore.I.hasChoices;
    // A chat that changed while another screen covered this one""",
)

patch(
    C,
    "    final canSend = _ctrl.text.trim().isNotEmpty || _attachments.isNotEmpty || skill != null;",
    "    final canSend = !needsModel && (_ctrl.text.trim().isNotEmpty || _attachments.isNotEmpty || skill != null);",
)

patch(
    C,
    """    final Widget trailing = canSend
        ? _SendButton(key: const ValueKey('send'), icon: 'send', onTap: _send)
        : _listening""",
    """    final Widget trailing = needsModel
        ? IconButton(
            key: const ValueKey('connect-model'),
            icon: const Icon(Icons.vpn_key_rounded),
            tooltip: tr('Connect a model'),
            onPressed: _openModels,
          )
        : canSend
        ? _SendButton(key: const ValueKey('send'), icon: 'send', onTap: _send)
        : _listening""",
)

patch(
    C,
    "                        hintText: _listening ? 'Speak now...' : (state.busy ? tr('Add to the task, or ask anything') : tr('Ask SubMac anything')),",
    "                        hintText: needsModel ? tr('Connect a model to start') : _listening ? 'Speak now...' : (state.busy ? tr('Add to the task, or ask anything') : tr('Ask SubMac anything')),",
)

patch(
    C,
    """                  child: Wrap(spacing: Space.x2, runSpacing: Space.x2, children: chips),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,""",
    """                  child: Wrap(spacing: Space.x2, runSpacing: Space.x2, children: chips),
                ),
              if (needsModel)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(Space.x2, 0, Space.x2, Space.x2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const ValueKey('connect-model-banner'),
                      onPressed: _openModels,
                      icon: const Icon(Icons.vpn_key_rounded, size: 16),
                      label: Text(tr('Connect a model to start chatting')),
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,""",
)

patch(
    C,
    "              if (Bots.I.byConv(state.currentId) == null)\n                const Padding(",
    "              if (!needsModel && Bots.I.byConv(state.currentId) == null)\n                const Padding(",
)