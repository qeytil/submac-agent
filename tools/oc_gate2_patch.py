import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

C = "lib/widgets/composer.dart"
patch(C,
"""    final Widget trailing = needsModel
        ? IconButton(
            key: const ValueKey('connect-model'),
            icon: const Icon(Icons.vpn_key_rounded),
            tooltip: tr('Connect a model'),
            onPressed: _openModels,
          )
        : canSend""",
"""    final Widget trailing = needsModel
        ? _BareIcon(key: const ValueKey('connect-model'), icon: 'plus', tip: tr('Connect a model'), onTap: _openModels)
        : canSend""")
patch(C,
"""                    child: TextButton.icon(
                      key: const ValueKey('connect-model-banner'),
                      onPressed: _openModels,
                      icon: const Icon(Icons.vpn_key_rounded, size: 16),
                      label: Text(tr('Connect a model to start chatting')),
                    ),""",
"""                    child: TextButton(
                      key: const ValueKey('connect-model-banner'),
                      onPressed: _openModels,
                      child: Text(tr('Connect a model to start chatting')),
                    ),""")
