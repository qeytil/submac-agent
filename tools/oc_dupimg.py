import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


TV = 'lib/services/turn_visuals.dart'

# The user's own attachment is staged in workspace/uploads so the agent can read it by path. The end-of-turn visual
# scan looked in every folder, found that file, and drew the same picture again as a card under the reply - the
# repeated image bubble (owner 2026-11-24). uploads/ is never a place a turn's own visuals live, so it is left out.
sub(TV,
    "  static const _skipDirs = {'node_modules', '.git', 'build', 'dist', '.dart_tool', 'media', '__pycache__', '.cache', 'venv', '.venv'};",
    "  static const _skipDirs = {'node_modules', '.git', 'build', 'dist', '.dart_tool', 'media', '__pycache__', '.cache', 'venv', '.venv', 'uploads'};")

sub(TV,
    "      final p = resolve(raw, workspace);\n      if (seen.contains(p) || out.contains(p) || !isVisual(p) || !has(p)) continue;",
    "      final p = resolve(raw, workspace);\n      // The user's own file (staged in uploads/) is never shown again as a card of the reply, even if the answer\n"
    "      // names it.\n      if (p.contains('/uploads/') || seen.contains(p) || out.contains(p) || !isVisual(p) || !has(p)) continue;")

print('duplicate image: uploads/ left out of the turn visual scan')
