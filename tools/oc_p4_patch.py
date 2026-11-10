import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

P = "lib/widgets/model_picker.dart"
patch(P,
"""            ListTile(
              key: const ValueKey('model-submac'),
              leading: const AppLogo(size: 32),
              title: const Text('SubMac'),
              subtitle: Text(tr('Included in your plan'), style: AppText.microStyle.copyWith(color: p.muted)),
              trailing: check(forBot ? (!onDefault && picked == null) : picked == null),
              onTap: () => Navigator.pop(context, ByokRef.submac),
            ),
""",
"")
patch(P, "  return 'SubMac';\n}", "  return BotModelWords.defaultLabel;\n}")
patch(P, "  static const defaultLabel = 'Default (same as SubMac)';", "  static const defaultLabel = 'Default';")

S = "lib/screens/models_screen.dart"
patch(S,
"                  title: Text(chat == null ? 'SubMac' : chat.model.label, maxLines: 1, overflow: TextOverflow.ellipsis),",
"                  title: Text(chat == null ? tr('Connect a model') : chat.model.label, maxLines: 1, overflow: TextOverflow.ellipsis),")
patch(S,
"                  subtitle: Text(chat == null ? tr('Included in your plan') : '${chat.provider.label} · ${tr('your key')}',",
"                  subtitle: Text(chat == null ? tr('Tap to add your provider') : '${chat.provider.label} · ${tr('your key')}',")

B = "lib/services/byok.dart"
patch(B,
"""    final pick = resolve(setting);
    if (pick == null) return 'SubMac';""",
"""    final pick = resolve(setting);
    if (pick == null) return 'Default';""")
