import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:60])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


P = 'lib/widgets/hark_cards.dart'

# A page card in the chat used to mount a live web view (InAppWebView) for every page, eagerly, before the page was
# even opened; a chat with a few pages lagged badly. It now draws a still, browser-shaped thumbnail instead, and the
# live page opens on tap (openPreview).
sub(P,
    "? AbsorbPointer(child: WebPageView(fileUrl: 'file://$path', interactive: false))",
    "? _PageThumb(p)")

THUMB = '''

/// A page's card thumbnail: a still, browser-shaped tile drawn from the theme, with no web view \u2014 a chat full of
/// pages stays fast (owner 2026-11-24: a live view per card rendered before the page was even opened and lagged the
/// chat). Tapping the card opens the live page.
class _PageThumb extends StatelessWidget {
  const _PageThumb(this.p);
  final Palette p;

  @override
  Widget build(BuildContext context) {
    Widget line(double w) => Container(
          height: 7,
          width: w,
          decoration: BoxDecoration(color: p.muted.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
        );
    return DecoratedBox(
      decoration: BoxDecoration(color: p.sheet),
      child: Padding(
        padding: const EdgeInsets.all(Space.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              for (var i = 0; i < 3; i++) ...[
                Container(width: 6, height: 6, decoration: BoxDecoration(color: p.muted.withValues(alpha: 0.35), shape: BoxShape.circle)),
                const SizedBox(width: 4),
              ],
              const SizedBox(width: 2),
              Expanded(child: Container(height: 9, decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(5)))),
            ]),
            const SizedBox(height: Space.x4),
            line(double.infinity),
            const SizedBox(height: 7),
            line(double.infinity),
            const SizedBox(height: 7),
            line(120),
          ],
        ),
      ),
    );
  }
}
'''

with io.open(P, 'a', encoding='utf-8') as f:
    f.write(THUMB)

print('page preview: static thumbnail; no web view in the chat')
