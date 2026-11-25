import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


H = 'lib/screens/home_screen.dart'

# Every new message said "Queued - it will read this next" because `live` also covers `pending` (the message is still
# being saved). Only a message handed to a task that is already working is queued; a normal send starts the run itself
# and must not claim it is waiting behind something (owner 2026-11-25: "the text is misleading").
sub(H,
    "            if (live && turn.isNotEmpty && turn.last.role == 'user')",
    "            // Only a message handed to a task that is already working is \"queued\": a normal send starts the run\n"
    "            // itself, so it must not claim it is waiting behind one (owner 2026-11-25: misleading text).\n"
    "            if (turn.isNotEmpty && turn.last.role == 'user' && working.any((r) => r.steered.contains(turn.last.id)))")

print('chat: "Queued" only for a message steered into a task that was already running')
