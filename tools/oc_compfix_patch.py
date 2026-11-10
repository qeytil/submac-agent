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

old = '''              // Ask or Autopilot (owner, 2026-11-03): a tiny switch under the field. Autopilot answers approval cards
              // and opencode's permission asks by itself; money and SubMac's own settings still ask.
              // The chat's model (BYOK, owner 2026-11-03) sits beside it, only when the user has models of their own.
              const Padding(
                padding: EdgeInsetsDirectional.only(top: Space.x2),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Wrap(spacing: Space.x2, runSpacing: Space.x1, crossAxisAlignment: WrapCrossAlignment.center, children: [PermissionPill(), ModelPill()]),
                ),
              ),'''

new = '''              // Ask or Autopilot (owner, 2026-11-03): a tiny switch under the field. Autopilot answers approval cards
              // and opencode's permission asks by itself; money and SubMac's own settings still ask.
              // The chat's model (BYOK, owner 2026-11-03) sits beside it, only when the user has models of their own.
              // These two are the OWNER's chat controls and never follow into a digital person's own chat: a bot has
              // its own permission and model in its profile, not under this composer (owner 2026-11-10).
              if (Bots.I.byConv(state.currentId) == null)
                const Padding(
                  padding: EdgeInsetsDirectional.only(top: Space.x2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(spacing: Space.x2, runSpacing: Space.x1, crossAxisAlignment: WrapCrossAlignment.center, children: [PermissionPill(), ModelPill()]),
                  ),
                ),'''

patch("lib/widgets/composer.dart", old, new)
