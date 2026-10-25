import 'dart:convert';

/// One interactive element from the page script's snapshot (browser-use v2).
///
/// Coordinates are fractions (0..1) of the VISUAL viewport, which is exactly what the screenshot shows, so the
/// numbers drawn on the picture, the positions the model reads and the point a finger taps all agree whatever the
/// zoom, device pixel ratio or scroll.
class PageElement {
  PageElement({
    required this.id,
    required this.kind,
    required this.label,
    this.href = '',
    this.cx = 0.5,
    this.cy = 0.5,
    this.box = const [0, 0, 0, 0],
    this.offscreen = false,
    this.disabled = false,
  });

  final int id;
  final String kind;
  final String label;
  final String href;

  /// Where a finger reaches this element (not covered by anything), as screen fractions.
  final double cx, cy;

  /// Left, top, width, height as screen fractions.
  final List<double> box;

  /// Listed but below the visible part: an action scrolls it in first.
  final bool offscreen;
  final bool disabled;

  bool get isField => kind.startsWith('field') || kind.startsWith('textbox') || kind.startsWith('combobox');

  static PageElement? fromJson(Map m) {
    final id = m['i'];
    if (id is! num) return null;
    List<double> nums(dynamic v, int n) {
      if (v is! List || v.length < n) return List<double>.filled(n, 0);
      return [for (final x in v.take(n)) x is num ? x.toDouble() : 0.0];
    }

    final c = nums(m['c'], 2);
    return PageElement(
      id: id.toInt(),
      kind: '${m['k'] ?? 'clickable'}',
      label: '${m['t'] ?? ''}',
      href: '${m['h'] ?? ''}',
      cx: c[0],
      cy: c[1],
      box: nums(m['b'], 4),
      offscreen: m['o'] == 1 || m['o'] == true,
      disabled: m['d'] == 1 || m['d'] == true,
    );
  }

  /// "[12] button "Add to cart" @64,71" — the line the model reads.
  String line({bool fresh = false}) {
    final at = offscreen ? ' (below, scrolls in)' : ' @${(cx * 100).round()},${(cy * 100).round()}';
    final lab = label.isEmpty ? '' : ' "$label"';
    final link = href.isEmpty ? '' : ' -> ${href.length > 90 ? '${href.substring(0, 90)}…' : href}';
    return '${fresh ? '*' : ''}[$id] $kind$lab$at${disabled ? ' (disabled)' : ''}$link';
  }
}

/// The page as the agent sees it after a step.
class PageSnapshot {
  PageSnapshot({
    required this.url,
    required this.title,
    required this.elements,
    this.text = '',
    this.password = false,
    this.cardFields = false,
    this.modal = false,
    this.more = false,
    this.scrolled = 0,
    this.favicon = '',
    this.banner,
    this.blockedFrames = const [],
    this.fingerprint = '',
    this.focus = '',
    this.zoom = 1,
    this.ready = 'complete',
  });

  final String url;
  final String title;
  final List<PageElement> elements;
  final String text;
  final bool password;

  /// A card number field (or a payment provider's frame) is on the page.
  final bool cardFields;
  final bool modal;
  final bool more;
  final int scrolled;
  final String favicon;

  /// A cookie / consent banner and the button that refuses (or accepts) it.
  final Map<String, dynamic>? banner;

  /// Frames the page script cannot read (other sites): hosts and boxes, for tap_at.
  final List<Map<String, dynamic>> blockedFrames;
  final String fingerprint;
  final String focus;
  final double zoom;
  final String ready;

  static final empty = PageSnapshot(url: '', title: '', elements: const []);

  String get host {
    final h = Uri.tryParse(url)?.host ?? '';
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  PageElement? byId(int id) {
    for (final e in elements) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// id -> label, for the approval cards ("Tap "Place order" on shop.com?").
  Map<int, String> get labels => {for (final e in elements) e.id: e.label};

  static PageSnapshot parse(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map) throw const FormatException('snapshot is not an object');
    return fromJson(j);
  }

  static PageSnapshot fromJson(Map j) {
    final els = <PageElement>[];
    for (final e in (j['els'] as List? ?? const [])) {
      if (e is Map) {
        final p = PageElement.fromJson(e);
        if (p != null) els.add(p);
      }
    }
    return PageSnapshot(
      url: '${j['url'] ?? ''}',
      title: '${j['title'] ?? ''}',
      elements: els,
      text: '${j['text'] ?? ''}'.trim(),
      password: j['pw'] == true,
      cardFields: j['card'] == true,
      modal: j['modal'] == true,
      more: j['more'] == true,
      scrolled: (j['sy'] as num?)?.toInt() ?? 0,
      favicon: '${j['fav'] ?? ''}',
      banner: j['banner'] is Map ? Map<String, dynamic>.from(j['banner'] as Map) : null,
      blockedFrames: [for (final f in (j['frames'] as List? ?? const [])) if (f is Map) Map<String, dynamic>.from(f)],
      fingerprint: '${j['fp'] ?? ''}',
      focus: '${j['focus'] ?? ''}',
      zoom: (j['zoom'] as num?)?.toDouble() ?? 1,
      ready: '${j['ready'] ?? 'complete'}',
    );
  }

  /// Is this a page where a press can spend money? (checkout, payment, card fields)
  bool get moneyPage => PageRisk.isMoneyPage(url, title, text, cardFields);

  /// What the model reads: page line, notices, the numbered elements (new ones starred), visible text.
  String describe({PageSnapshot? before, int maxChars = 9000}) {
    final sb = StringBuffer();
    sb.writeln('Page: ${title.isEmpty ? host : title} — $url');
    if (ready == 'loading') sb.writeln('(Still loading.)');
    if (banner != null) {
      sb.writeln('A cookie/consent banner is open: [${banner!['id']}] "${banner!['name']}" (${banner!['kind']}) closes it.');
    }
    if (modal) sb.writeln('A pop-up is open on top of the page: deal with it first (its close button, or key Escape).');
    if (password) {
      sb.writeln('This page has a password field: call browser_login (secure sheet for the user; you never see passwords).');
    }
    final known = before == null || before.url != url ? const <int>{} : {for (final e in before.elements) e.id};
    if (elements.isEmpty) {
      sb.writeln('No clickable elements found.');
    } else {
      sb.writeln('Elements (number, kind, label, @x,y = % of the screenshot; * = new since your last step):');
      for (final e in elements) {
        sb.writeln(e.line(fresh: known.isNotEmpty && !known.contains(e.id)));
      }
    }
    for (final f in blockedFrames) {
      final b = f['b'];
      if (b is List && b.length == 4) {
        final cx = (((b[0] as num) + (b[2] as num) / 2) * 100).round(), cy = (((b[1] as num) + (b[3] as num) / 2) * 100).round();
        sb.writeln('Embedded frame from ${f['host']} @$cx,$cy cannot be read: use browser_tap_at on the screenshot inside it.');
      }
    }
    if (text.isNotEmpty) sb.writeln('\nText in view:\n$text');
    sb.writeln('\nScrolled $scrolled%.${more ? ' More below.' : ''}${zoom > 1.05 ? ' Zoomed ${zoom.toStringAsFixed(1)}x.' : ''}');
    final out = sb.toString().trimRight();
    return out.length > maxChars ? '${out.substring(0, maxChars)}\n…' : out;
  }
}

/// What a step changed, from the page's state before and after (self-verification after every action).
class StepEffect {
  StepEffect({
    required this.urlChanged,
    required this.domChanged,
    required this.focusChanged,
    required this.scrolled,
    required this.pixelsChanged,
    this.newUrl = '',
  });

  final bool urlChanged;
  final bool domChanged;
  final bool focusChanged;
  final bool scrolled;

  /// The screenshot changed visibly (null when one of the two pictures is missing).
  final bool? pixelsChanged;
  final String newUrl;

  bool get any => urlChanged || domChanged || focusChanged || scrolled || (pixelsChanged ?? false);

  /// From two `S.state()` maps (url, mut, fp, focus, sy).
  static StepEffect compare(Map before, Map after, {bool? pixels}) {
    final u1 = '${before['url'] ?? ''}', u2 = '${after['url'] ?? ''}';
    final m1 = (before['mut'] as num?) ?? 0, m2 = (after['mut'] as num?) ?? 0;
    return StepEffect(
      urlChanged: u1 != u2,
      newUrl: u2,
      domChanged: m2 != m1 || '${before['fp']}' != '${after['fp']}',
      focusChanged: '${before['focus'] ?? ''}' != '${after['focus'] ?? ''}',
      scrolled: '${before['sy']}' != '${after['sy']}',
      pixelsChanged: pixels,
    );
  }

  String describe() {
    if (urlChanged) return 'Effect: moved to $newUrl.';
    final parts = <String>[
      if (domChanged) 'the page changed',
      if (focusChanged) 'focus moved',
      if (scrolled) 'the view scrolled',
      if (pixelsChanged == true && !domChanged) 'the screen changed',
    ];
    if (parts.isEmpty) return 'Effect: NOTHING changed on the page (same screen, same content). The action probably missed.';
    return 'Effect: ${parts.join(', ')}.';
  }
}

/// Money and sending risk of a browser press (approval gating stays in the app's approval flow).
class PageRisk {
  static final _moneyUrl = RegExp(r'(checkout|payment|/pay\b|/pay/|billing|/order/confirm|placeorder|place-order|purchase|/buy\b|cart/confirm|donate)',
      caseSensitive: false);
  static final _moneyText = RegExp(
      r'\b(place (your )?order|pay now|pay \$|complete purchase|confirm (and|&) pay|buy now|order total|card number|payment method|billing address)\b',
      caseSensitive: false);
  static final _submitLabel = RegExp(
      r'\b(post|publish|send|submit|apply|pay|buy|order|checkout|check out|place|book|reserve|confirm|delete|remove|tweet|share|transfer|donate|subscribe|continue|next|proceed|finish|complete|save|sign up|register|upload)\b',
      caseSensitive: false);
  static final _risky = RegExp(
      r'\b(post|publish|send|submit|apply|pay|buy|order|checkout|check out|place order|place your order|book|reserve|confirm|delete|remove|tweet|share|transfer|donate|subscribe|purchase|upload)\b',
      caseSensitive: false);

  static bool isMoneyPage(String url, String title, String text, bool cardFields) =>
      cardFields || _moneyUrl.hasMatch(url) || _moneyText.hasMatch('$title ${text.length > 3000 ? text.substring(0, 3000) : text}');

  /// Does pressing an element with this [label] need the user's OK? Risky words always do; on a money page any
  /// button that moves the flow on ("Continue", "Next") does too, and so does an unlabeled icon button there.
  static bool pressNeedsOk(String label, {required bool moneyPage, String kind = ''}) {
    final l = label.trim();
    if (_risky.hasMatch(l)) return true;
    if (!moneyPage) return false;
    if (l.isEmpty) return !kind.startsWith('field') && !kind.startsWith('link');
    return _submitLabel.hasMatch(l);
  }

  /// Pressing Enter / submit in a field on a money page submits the payment form.
  static bool submitNeedsOk({required bool moneyPage}) => moneyPage;

  /// A page's own confirm() dialog that the app would otherwise accept by itself.
  static bool dialogNeedsOk(String message) => _risky.hasMatch(message) || _moneyText.hasMatch(message);
}
