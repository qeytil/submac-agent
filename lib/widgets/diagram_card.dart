import 'dart:math' as m;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'output_cards.dart' show HarkSurface, openCardPreview;
import '../ui/tokens.dart';

part 'data_viz.dart';

/// ```diagram  Small, calm explainer graphics drawn on the phone in the SubMac style:
/// roadmap/timeline, steps/flow, cycle, bars, donut, line, tree, quadrant, stats, funnel/pyramid, versus.
/// JSON: {"type":"roadmap","title":"Launch plan","items":[...]} — see each builder for its fields.
Widget? diagramCardFrom(dynamic j) {
  if (j is! Map) return null;
  final type = (j['type'] ?? j['kind'] ?? 'steps').toString().toLowerCase().trim();
  final title = (j['title'] ?? '').toString();
  final note = (j['note'] ?? j['caption'] ?? '').toString();
  final items = _maps(j['items'] ?? j['steps'] ?? j['phases'] ?? j['data'] ?? j['points'] ?? j['nodes'] ?? const []);
  final dv = _dataViz(type, j, items);
  if (dv != null) {
    return dv.$2 == null ? null : _DiagramFrame(kicker: dv.$1, title: title, note: note, child: dv.$2!);
  }
  Widget? body;
  String kicker;
  switch (type) {
    case 'roadmap':
    case 'timeline':
    case 'plan':
    case 'milestones':
      kicker = type == 'timeline' ? 'Timeline' : 'Roadmap';
      body = items.isEmpty ? null : _Roadmap(items);
      break;
    case 'steps':
    case 'flow':
    case 'process':
    case 'flowchart':
      kicker = 'How it works';
      body = items.isEmpty ? null : _Steps(items);
      break;
    case 'cycle':
    case 'loop':
      kicker = 'Cycle';
      body = items.length < 2 ? null : _Cycle(items, (j['center'] ?? '').toString());
      break;
    case 'bars':
    case 'bar':
    case 'chart':
    case 'ranking':
      kicker = 'Chart';
      body = items.isEmpty ? null : _Bars(items, (j['unit'] ?? '').toString());
      break;
    case 'donut':
    case 'pie':
    case 'split':
    case 'breakdown':
      kicker = 'Breakdown';
      body = items.isEmpty ? null : _Donut(items, (j['center'] ?? '').toString(), (j['unit'] ?? '').toString());
      break;
    case 'line':
    case 'trend':
    case 'growth':
      kicker = 'Trend';
      if (j['series'] is List) {
        body = _Lines(j['labels'] is List ? [for (final l in j['labels']) l.toString()] : <String>[], _maps(j['series']), (j['unit'] ?? '').toString());
      } else {
        body = items.length < 2 ? null : _Line(items, (j['unit'] ?? '').toString());
      }
      break;
    case 'tree':
    case 'hierarchy':
    case 'mindmap':
    case 'org':
    case 'structure':
      kicker = 'Map';
      final root = j['root'] is Map ? Map<String, dynamic>.from(j['root']) : {'title': (j['root'] ?? title).toString(), 'children': j['children'] ?? j['items'] ?? const []};
      body = _Tree(root);
      break;
    case 'quadrant':
    case 'matrix':
    case 'priority':
      kicker = 'Priorities';
      final axes = j['axes'] is Map ? Map<String, dynamic>.from(j['axes']) : const <String, dynamic>{};
      body = items.isEmpty ? null : _Quadrant(items, axes, (j['quadrants'] is List) ? [for (final q in j['quadrants']) q.toString()] : const []);
      break;
    case 'stats':
    case 'metrics':
    case 'numbers':
    case 'kpi':
      kicker = 'At a glance';
      body = items.isEmpty ? null : _Stats(items);
      break;
    case 'funnel':
    case 'pyramid':
      kicker = type == 'pyramid' ? 'Pyramid' : 'Funnel';
      body = items.isEmpty ? null : _Funnel(items, pyramid: type == 'pyramid');
      break;
    case 'versus':
    case 'compare':
    case 'vs':
    case 'proscons':
      kicker = 'Side by side';
      final l = j['left'] is Map ? Map<String, dynamic>.from(j['left']) : (items.isNotEmpty ? items[0] : null);
      final r = j['right'] is Map ? Map<String, dynamic>.from(j['right']) : (items.length > 1 ? items[1] : null);
      body = (l == null || r == null) ? null : _Versus(l, r);
      break;
    default:
      kicker = 'Diagram';
      body = items.isEmpty ? null : _Steps(items);
  }
  if (body == null) return null;
  return _DiagramFrame(kicker: kicker, title: title, note: note, child: body);
}

List<Map<String, dynamic>> _maps(dynamic v) {
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is Map) Map<String, dynamic>.from(e) else if (e != null) {'title': e.toString()}
  ];
}

String _s(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
  }
  return '';
}

double _n(dynamic v) {
  if (v is num) return v.toDouble();
  final s = v?.toString().replaceAll(RegExp(r'[^0-9.\-]'), '') ?? '';
  return double.tryParse(s) ?? 0;
}

String _fmtNum(double v) {
  if (v.abs() >= 1e9) return '${(v / 1e9).toStringAsFixed(v.abs() >= 1e10 ? 0 : 1)}B';
  if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(v.abs() >= 1e7 ? 0 : 1)}M';
  if (v.abs() >= 1e4) return '${(v / 1e3).toStringAsFixed(0)}k';
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}

List<Color> _tones(Palette p) => [p.accent, p.text, const Color(0xFFB08D57), const Color(0xFF5B7083), p.muted, const Color(0xFF7A5C8E)];

/// Plays a drawing once, 0 → 1. Instant when the phone asks for less motion.
class _DrawIn extends StatefulWidget {
  const _DrawIn({required this.builder, this.ms = 900});
  final Widget Function(BuildContext, double) builder;
  final int ms;
  @override
  State<_DrawIn> createState() => _DrawInState();
}

class _DrawInState extends State<_DrawIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: SubMotion.drawIn(widget.ms));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _c.value = 1;
    } else if (_c.value == 0 && !_c.isAnimating) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _c, builder: (c, _) => widget.builder(c, SubMotion.settle.transform(_c.value)));
}

class _DiagramFrame extends StatelessWidget {
  const _DiagramFrame({required this.kicker, required this.title, required this.note, required this.child, this.large = false});
  final String kicker, title, note;
  final Widget child;
  final bool large;

  /// A chart or diagram sits on the card fill; a tap opens it large in the shared preview (frosted chat behind,
  /// Close, its title). Hold keeps the card actions.
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (title.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x4),
          child: Text(title, style: Brand.serif(size: AppText.title, color: p.text, height: 1.2)),
        ),
      child,
      if (note.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Space.x4),
          child: Text(note, style: AppText.metaStyle.copyWith(color: p.muted)),
        ),
    ]);
    if (large) return body;
    return Semantics(
      container: true,
      button: true,
      label: 'Open preview of ${title.isEmpty ? kicker : title}',
      child: GestureDetector(
        onTap: () => openCardPreview(
          context,
          title: title.isEmpty ? kicker : title,
          child: _DiagramFrame(kicker: kicker, title: title, note: note, large: true, child: child),
        ),
        child: HarkSurface(child: body),
      ),
    );
  }
}

TextStyle _titleStyle(Palette p, {double size = 15}) => TextStyle(color: p.text, fontSize: size, fontWeight: FontWeight.w600, height: 1.3);
TextStyle _bodyStyle(Palette p) => TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.42);
TextStyle _tagStyle(Palette p, {Color? color}) =>
    Brand.mono(size: 10.5, color: color ?? p.muted).copyWith(letterSpacing: 0.8, fontWeight: FontWeight.w500);

// ───────────────────────────────── Roadmap / timeline
// items: [{"when":"Q1","title":"Research","text":"…","status":"done|now|next"}]
class _Roadmap extends StatelessWidget {
  const _Roadmap(this.items);
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(0, 12);
    return _DrawIn(
      ms: 400 + 120 * n,
      builder: (c, t) => Column(children: [
        for (var i = 0; i < n; i++)
          Builder(builder: (_) {
            final it = items[i];
            final status = _s(it, ['status', 'state']).toLowerCase();
            final done = status.startsWith('done') || status.startsWith('complete') || status == 'past';
            final now = status.startsWith('now') || status.startsWith('current') || status.contains('progress') || status == 'active';
            final local = ((t * n) - i).clamp(0.0, 1.0);
            final when = _s(it, ['when', 'date', 'time', 'phase']);
            final text = _s(it, ['text', 'note', 'detail', 'description']);
            return Opacity(
              opacity: local,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - local)),
                child: IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SizedBox(
                      width: 26,
                      child: CustomPaint(
                        painter: _RailPainter(p, done: done, now: now, first: i == 0, last: i == n - 1, nextDone: i + 1 < n && _isDone(items[i + 1])),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: i == n - 1 ? 0 : 18),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (when.isNotEmpty || now)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Row(children: [
                                if (when.isNotEmpty) Text(when.toUpperCase(), style: _tagStyle(p, color: now ? p.accent : p.muted)),
                                if (now) ...[
                                  if (when.isNotEmpty) const SizedBox(width: 8),
                                  Text('NOW', style: _tagStyle(p, color: p.accent)),
                                ],
                              ]),
                            ),
                          Text(_s(it, ['title', 'name', 'label']),
                              style: _titleStyle(p).copyWith(color: done ? p.text.withValues(alpha: 0.62) : p.text)),
                          if (text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(text, style: _bodyStyle(p))),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          }),
      ]),
    );
  }

  static bool _isDone(Map<String, dynamic> it) {
    final s = _s(it, ['status', 'state']).toLowerCase();
    return s.startsWith('done') || s.startsWith('complete') || s == 'past';
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter(this.p, {required this.done, required this.now, required this.first, required this.last, required this.nextDone});
  final Palette p;
  final bool done, now, first, last, nextDone;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    const cy = 9.0;
    if (!last) {
      final line = Paint()
        ..color = (done && nextDone) ? p.text.withValues(alpha: 0.55) : p.border
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(cx, cy + 7), Offset(cx, size.height + 2), line);
    }
    if (now) {
      canvas.drawCircle(Offset(cx, cy), 9, Paint()..color = p.accent.withValues(alpha: 0.16));
      canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = p.accent);
    } else if (done) {
      canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = p.text);
    } else {
      canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = p.sheet);
      canvas.drawCircle(
          Offset(cx, cy),
          5,
          Paint()
            ..color = p.muted
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
    }
  }

  @override
  bool shouldRepaint(_RailPainter o) => o.done != done || o.now != now || o.p != p;
}

// ───────────────────────────────── Steps / flow
// items: [{"title":"Sign up","text":"…"}]  Short labels (≤4) draw as one row with arrows.
class _Steps extends StatelessWidget {
  const _Steps(this.items);
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(0, 10);
    final compact = n <= 4 && items.take(n).every((e) => _s(e, ['title', 'label']).length <= 13 && _s(e, ['text', 'note']).isEmpty);
    if (compact) {
      return _DrawIn(
        builder: (c, t) => Row(children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0)
              Opacity(
                opacity: ((t * n) - i + 0.5).clamp(0.0, 1.0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: CustomPaint(size: const Size(16, 10), painter: _ArrowPainter(p.muted)),
                ),
              ),
            Expanded(
              child: Opacity(
                opacity: ((t * n) - i).clamp(0.0, 1.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                  decoration: BoxDecoration(
                    color: i == n - 1 ? p.accentWash : p.bubble,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: i == n - 1 ? p.accent.withValues(alpha: 0.35) : p.border, width: 0.8),
                  ),
                  child: Column(children: [
                    Text((i + 1).toString().padLeft(2, '0'), style: Brand.serif(size: 17, color: i == n - 1 ? p.accent : p.muted)),
                    const SizedBox(height: 2),
                    Text(_s(items[i], ['title', 'label']),
                        textAlign: TextAlign.center, maxLines: 2, style: _titleStyle(p, size: 13)),
                  ]),
                ),
              ),
            ),
          ],
        ]),
      );
    }
    return _DrawIn(
      ms: 400 + 110 * n,
      builder: (c, t) => Column(children: [
        for (var i = 0; i < n; i++)
          Opacity(
            opacity: ((t * n) - i).clamp(0.0, 1.0),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: 34,
                  child: Column(children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == 0 ? p.accent : p.sheet,
                        border: Border.all(color: i == 0 ? p.accent : p.border),
                      ),
                      child: Text('${i + 1}', style: Brand.serif(size: 16, color: i == 0 ? Colors.white : p.text)),
                    ),
                    if (i < n - 1) Expanded(child: Container(width: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: p.border)),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: 4, bottom: i == n - 1 ? 0 : 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_s(items[i], ['title', 'label', 'name']), style: _titleStyle(p)),
                      if (_s(items[i], ['text', 'note', 'detail']).isNotEmpty)
                        Padding(padding: const EdgeInsets.only(top: 2), child: Text(_s(items[i], ['text', 'note', 'detail']), style: _bodyStyle(p))),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.c);
  final Color c;
  @override
  void paint(Canvas canvas, Size s) {
    final pt = Paint()
      ..color = c
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), pt);
    canvas.drawLine(Offset(s.width - 4, s.height / 2 - 3.5), Offset(s.width, s.height / 2), pt);
    canvas.drawLine(Offset(s.width - 4, s.height / 2 + 3.5), Offset(s.width, s.height / 2), pt);
  }

  @override
  bool shouldRepaint(_ArrowPainter o) => o.c != c;
}

// ───────────────────────────────── Cycle
// items: [{"title":"Plan"},{"title":"Build"},...], "center":"Ship weekly"
class _Cycle extends StatelessWidget {
  const _Cycle(this.items, this.center);
  final List<Map<String, dynamic>> items;
  final String center;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(2, 8);
    return LayoutBuilder(builder: (c, box) {
      final w = m.min(box.maxWidth, 320.0);
      final h = w * 0.86;
      final r = w * 0.31;
      final cx = box.maxWidth / 2, cy = h / 2;
      return _DrawIn(
        ms: 1100,
        builder: (c, t) => SizedBox(
          height: h,
          child: Stack(children: [
            Positioned.fill(child: CustomPaint(painter: _CyclePainter(p, n, r, Offset(cx, cy), t))),
            if (center.isNotEmpty)
              Positioned(
                left: cx - r * 0.62,
                top: cy - 30,
                width: r * 1.24,
                height: 60,
                child: Center(
                  child: Opacity(
                    opacity: t,
                    child: Text(center, textAlign: TextAlign.center, maxLines: 3, style: Brand.serif(size: 16, color: p.text, height: 1.15)),
                  ),
                ),
              ),
            for (var i = 0; i < n; i++)
              Builder(builder: (_) {
                final a = -m.pi / 2 + 2 * m.pi * i / n;
                final x = cx + r * m.cos(a), y = cy + r * m.sin(a);
                const bw = 104.0;
                return Positioned(
                  left: (x - bw / 2).clamp(0.0, box.maxWidth - bw),
                  top: y - 17,
                  width: bw,
                  child: Opacity(
                    opacity: ((t * n) - i).clamp(0.0, 1.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(
                        color: i == 0 ? p.accentWash : p.sheet,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: i == 0 ? p.accent.withValues(alpha: 0.4) : p.border, width: 0.8),
                      ),
                      child: Text(_s(items[i], ['title', 'label']),
                          textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: _titleStyle(p, size: 12.5)),
                    ),
                  ),
                );
              }),
          ]),
        ),
      );
    });
  }
}

class _CyclePainter extends CustomPainter {
  _CyclePainter(this.p, this.n, this.r, this.c, this.t);
  final Palette p;
  final int n;
  final double r, t;
  final Offset c;

  @override
  void paint(Canvas canvas, Size size) {
    final pt = Paint()
      ..color = p.muted.withValues(alpha: 0.7)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final gap = 0.42 * (6 / m.max(n, 3)) * 0.5;
    for (var i = 0; i < n; i++) {
      final a0 = -m.pi / 2 + 2 * m.pi * i / n + gap;
      final sweep = (2 * m.pi / n - 2 * gap) * ((t * n) - i).clamp(0.0, 1.0);
      if (sweep <= 0) continue;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a0, sweep, false, pt);
      if (sweep >= (2 * m.pi / n - 2 * gap) - 1e-3) {
        final a1 = a0 + sweep;
        final tip = c + Offset(m.cos(a1), m.sin(a1)) * r;
        final dir = Offset(-m.sin(a1), m.cos(a1)); // tangent
        final nrm = Offset(m.cos(a1), m.sin(a1));
        canvas.drawLine(tip, tip - dir * 6 + nrm * 4, pt);
        canvas.drawLine(tip, tip - dir * 6 - nrm * 4, pt);
      }
    }
    canvas.drawCircle(c, 3, Paint()..color = p.accent.withValues(alpha: t));
  }

  @override
  bool shouldRepaint(_CyclePainter o) => o.t != t || o.p != p;
}

// ───────────────────────────────── Bars
// items: [{"label":"Rent","value":1200,"highlight":true}], "unit":"$"
class _Bars extends StatelessWidget {
  const _Bars(this.items, this.unit);
  final List<Map<String, dynamic>> items;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(0, 12);
    final vals = [for (var i = 0; i < n; i++) _n(items[i]['value'] ?? items[i]['amount'] ?? items[i]['score'])];
    final mx = vals.isEmpty ? 1.0 : vals.reduce(m.max).abs().clamp(1e-9, double.infinity);
    final hi = items.take(n).any((e) => e['highlight'] == true) ? -1 : (vals.isEmpty ? -1 : vals.indexOf(vals.reduce(m.max)));
    String fmt(double v) => unit.isEmpty ? _fmtNum(v) : (unit.length <= 2 && !RegExp(r'^[a-z%]').hasMatch(unit) ? '$unit${_fmtNum(v)}' : '${_fmtNum(v)}$unit');
    return _DrawIn(
      builder: (c, t) => Column(children: [
        for (var i = 0; i < n; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == n - 1 ? 0 : 12),
            child: Builder(builder: (_) {
              final strong = items[i]['highlight'] == true || i == hi;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(_s(items[i], ['label', 'title', 'name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle(p, size: 13.5))),
                  Text(fmt(vals[i] * t), style: Brand.mono(size: 12.5, color: strong ? p.accent : p.muted)),
                ]),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (_, b) => Stack(children: [
                    Container(height: 6, decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(3))),
                    Container(
                      height: 6,
                      width: b.maxWidth * (vals[i].abs() / mx) * t,
                      decoration: BoxDecoration(color: strong ? p.accent : p.text.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(3)),
                    ),
                  ]),
                ),
              ]);
            }),
          ),
      ]),
    );
  }
}

// ───────────────────────────────── Donut
// items: [{"label":"Housing","value":40}], "center":"$3,200"
class _Donut extends StatelessWidget {
  const _Donut(this.items, this.center, this.unit);
  final List<Map<String, dynamic>> items;
  final String center, unit;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(0, 6);
    final vals = [for (var i = 0; i < n; i++) _n(items[i]['value'] ?? items[i]['share'] ?? items[i]['percent']).abs()];
    final total = vals.fold<double>(0, (a, b) => a + b);
    final tones = _tones(p);
    return _DrawIn(
      ms: 1000,
      builder: (c, t) => Row(children: [
        SizedBox(
          width: 128,
          height: 128,
          child: Stack(alignment: Alignment.center, children: [
            CustomPaint(size: const Size(128, 128), painter: _DonutPainter(vals, tones, p, t)),
            if (center.isNotEmpty)
              SizedBox(
                width: 76,
                child: Text(center, textAlign: TextAlign.center, maxLines: 2, style: Brand.serif(size: center.length > 6 ? 16 : 20, color: p.text, height: 1.1)),
              ),
          ]),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < n; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: tones[i % tones.length], shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_s(items[i], ['label', 'title', 'name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle(p, size: 13))),
                  Text(total > 0 ? '${(vals[i] / total * 100).round()}%' : '', style: Brand.mono(size: 12, color: p.muted)),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.vals, this.tones, this.p, this.t);
  final List<double> vals;
  final List<Color> tones;
  final Palette p;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final total = vals.fold<double>(0, (a, b) => a + b);
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - 8);
    canvas.drawArc(rect, 0, 2 * m.pi, false, Paint()
      ..color = p.bubble
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12);
    if (total <= 0) return;
    var a = -m.pi / 2;
    final limit = 2 * m.pi * t;
    var drawn = 0.0;
    for (var i = 0; i < vals.length; i++) {
      final sweep = 2 * m.pi * vals[i] / total;
      final s = m.min(sweep, limit - drawn);
      if (s <= 0) break;
      final gap = vals.length > 1 ? 0.035 : 0.0;
      canvas.drawArc(rect, a + gap / 2, m.max(s - gap, 0.001), false, Paint()
        ..color = tones[i % tones.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.butt);
      a += sweep;
      drawn += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter o) => o.t != t || o.p != p;
}

// ───────────────────────────────── Line
// items: [{"label":"Jan","value":12},...], "unit":"k"
class _Line extends StatelessWidget {
  const _Line(this.items, this.unit);
  final List<Map<String, dynamic>> items;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(2, 24);
    final vals = [for (var i = 0; i < n; i++) _n(items[i]['value'] ?? items[i]['y'] ?? items[i]['amount'])];
    final labels = [for (var i = 0; i < n; i++) _s(items[i], ['label', 'x', 'when', 'title'])];
    final last = vals.last, first = vals.first;
    final change = first == 0 ? null : (last - first) / first.abs() * 100;
    return _DrawIn(
      ms: 1100,
      builder: (c, t) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text('${_fmtNum(last)}$unit', style: Brand.serif(size: 30, color: p.text)),
          const SizedBox(width: 10),
          if (change != null)
            Text('${change >= 0 ? '▲' : '▼'} ${change.abs().toStringAsFixed(change.abs() >= 10 ? 0 : 1)}%',
                style: Brand.mono(size: 12, color: change >= 0 ? p.accent : p.muted)),
        ]),
        const SizedBox(height: 10),
        SizedBox(height: 120, child: CustomPaint(size: Size.infinite, painter: _LinePainter(vals, p, t))),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(labels.first, style: _tagStyle(p)),
          if (n > 2) Text(labels[n ~/ 2], style: _tagStyle(p)),
          Text(labels.last, style: _tagStyle(p)),
        ]),
      ]),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.vals, this.p, this.t);
  final List<double> vals;
  final Palette p;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = vals.reduce(m.min), hi = vals.reduce(m.max);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    Offset at(int i) => Offset(size.width * i / (vals.length - 1), size.height - 8 - (vals[i] - lo) / span * (size.height - 16));
    final grid = Paint()
      ..color = p.border.withValues(alpha: 0.6)
      ..strokeWidth = 0.6;
    for (var k = 0; k <= 3; k++) {
      final y = 8 + (size.height - 16) * k / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < vals.length; i++) {
      final a = at(i - 1), b = at(i);
      final mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * t + 2, size.height));
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [p.accent.withValues(alpha: 0.16), p.accent.withValues(alpha: 0.0)],
          ).createShader(Offset.zero & size));
    canvas.drawPath(
        path,
        Paint()
          ..color = p.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round);
    canvas.restore();
    if (t >= 0.98) {
      final e = at(vals.length - 1);
      canvas.drawCircle(e, 7, Paint()..color = p.accent.withValues(alpha: 0.18));
      canvas.drawCircle(e, 3.5, Paint()..color = p.accent);
    }
  }

  @override
  bool shouldRepaint(_LinePainter o) => o.t != t || o.p != p;
}

// ───────────────────────────────── Tree / hierarchy / mind map
// root: {"title":"SubMac","children":[{"title":"Chat","children":[{"title":"Cards"}]}]}
class _Tree extends StatelessWidget {
  const _Tree(this.root);
  final Map<String, dynamic> root;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final kids = _maps(root['children'] ?? root['items'] ?? const []);
    return _DrawIn(
      builder: (c, t) => Opacity(
        opacity: t,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: p.muted, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Flexible(child: Text(_s(root, ['title', 'label', 'name']), style: Brand.serif(size: 17, color: p.bg))),
            ]),
          ),
          for (var i = 0; i < kids.length && i < 10; i++) _branch(p, kids[i], i == kids.length - 1 || i == 9, 0),
        ]),
      ),
    );
  }

  Widget _branch(Palette p, Map<String, dynamic> node, bool last, int depth) {
    final kids = depth >= 2 ? const <Map<String, dynamic>>[] : _maps(node['children'] ?? node['items'] ?? const []);
    final text = _s(node, ['text', 'note']);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 22, child: CustomPaint(painter: _ElbowPainter(p.border, last))),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s(node, ['title', 'label', 'name']), style: _titleStyle(p, size: depth == 0 ? 15 : 13.5).copyWith(
                color: depth == 0 ? p.text : p.text.withValues(alpha: 0.85),
              )),
              if (text.isNotEmpty) Text(text, style: _bodyStyle(p)),
              for (var i = 0; i < kids.length && i < 8; i++) _branch(p, kids[i], i == kids.length - 1 || i == 7, depth + 1),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ElbowPainter extends CustomPainter {
  _ElbowPainter(this.c, this.last);
  final Color c;
  final bool last;
  @override
  void paint(Canvas canvas, Size s) {
    final pt = Paint()
      ..color = c
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const x = 8.0, y = 20.0;
    final path = Path()
      ..moveTo(x, 0)
      ..lineTo(x, y - 6)
      ..quadraticBezierTo(x, y, x + 6, y)
      ..lineTo(s.width, y);
    canvas.drawPath(path, pt);
    if (!last) canvas.drawLine(const Offset(x, y - 6), Offset(x, s.height), pt);
  }

  @override
  bool shouldRepaint(_ElbowPainter o) => o.last != last || o.c != c;
}

// ───────────────────────────────── Quadrant
// axes: {"x":"Effort","y":"Impact"}, quadrants: ["Quick wins","Big bets","Fill-ins","Skip"] (top-left, top-right, bottom-left, bottom-right)
// items: [{"title":"Dark mode","x":0.2,"y":0.8}]  x,y from 0 to 1 (or 0-10).
class _Quadrant extends StatelessWidget {
  const _Quadrant(this.items, this.axes, this.quads);
  final List<Map<String, dynamic>> items;
  final Map<String, dynamic> axes;
  final List<String> quads;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final ql = quads.length >= 4 ? quads : const ['', '', '', ''];
    return AspectRatio(
      aspectRatio: 1.05,
      child: LayoutBuilder(builder: (c, b) {
        final w = b.maxWidth - 16, h = b.maxHeight - 18;
        double nv(dynamic v) {
          final d = _n(v);
          return (d > 1 ? d / 10 : d).clamp(0.04, 0.96);
        }

        return _DrawIn(
          builder: (c, t) => Stack(children: [
            Positioned(
              left: 16,
              top: 0,
              width: w,
              height: h,
              child: CustomPaint(painter: _QuadPainter(p)),
            ),
            for (var q = 0; q < 4; q++)
              if (ql[q].isNotEmpty)
                Positioned(
                  left: 16 + (q % 2) * w / 2 + 8,
                  top: (q ~/ 2) * h / 2 + 6,
                  child: Text(ql[q].toUpperCase(), style: _tagStyle(p, color: q == 0 ? p.accent : p.muted)),
                ),
            Positioned(left: 16, right: 0, bottom: 0, child: Text('${(axes['x'] ?? '').toString()}  →', textAlign: TextAlign.center, style: _tagStyle(p))),
            Positioned(
              left: 0,
              top: 0,
              bottom: 18,
              child: RotatedBox(quarterTurns: 3, child: Center(child: Text('${(axes['y'] ?? '').toString()}  →', style: _tagStyle(p)))),
            ),
            for (var i = 0; i < items.length && i < 10; i++)
              Builder(builder: (_) {
                final x = 16 + nv(items[i]['x']) * w, y = (1 - nv(items[i]['y'])) * h;
                final local = ((t * items.length) - i).clamp(0.0, 1.0);
                return Positioned(
                  left: (x - 6).clamp(16.0, 16 + w - 90),
                  top: y - 6,
                  child: Opacity(
                    opacity: local,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 9, height: 9, decoration: BoxDecoration(color: items[i]['highlight'] == true ? p.accent : p.text, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 86),
                        child: Text(_s(items[i], ['title', 'label', 'name']),
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: _titleStyle(p, size: 11.5).copyWith(height: 1.15)),
                      ),
                    ]),
                  ),
                );
              }),
          ]),
        );
      }),
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.p);
  final Palette p;
  @override
  void paint(Canvas canvas, Size s) {
    final r = RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(14));
    canvas.drawRRect(r, Paint()..color = p.bubble.withValues(alpha: 0.6));
    canvas.drawRect(Rect.fromLTWH(0, 0, s.width / 2, s.height / 2).deflate(0.5), Paint()..color = p.accentWash.withValues(alpha: 0.55));
    final line = Paint()
      ..color = p.border
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(s.width / 2, 0), Offset(s.width / 2, s.height), line);
    canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), line);
    canvas.drawRRect(
        r,
        Paint()
          ..color = p.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8);
  }

  @override
  bool shouldRepaint(_QuadPainter o) => o.p != p;
}

// ───────────────────────────────── Stats
// items: [{"value":"2.4M","label":"Users","delta":"+12%"}]
class _Stats extends StatelessWidget {
  const _Stats(this.items);
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(1, 6);
    return LayoutBuilder(builder: (_, box) {
      final cols = n == 1 ? 1 : 2;
      final tileW = (box.maxWidth - 10 * (cols - 1)) / cols;
      return _DrawIn(
        builder: (c, t) => Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < n; i++)
              Builder(builder: (_) {
                final delta = _s(items[i], ['delta', 'change']);
                final up = !delta.startsWith('-') && !delta.startsWith('−');
                return Opacity(
                  opacity: ((t * n) - i).clamp(0.0, 1.0),
                  child: Container(
                    width: tileW,
                    padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: p.bubble,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: p.border, width: 0.8),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(_s(items[i], ['label', 'title', 'name']).toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: _tagStyle(p)),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(_s(items[i], ['value', 'number', 'amount']), style: Brand.serif(size: 28, color: i == 0 ? p.accent : p.text, height: 1.05)),
                      ),
                      if (items[i]['trend'] is List && (items[i]['trend'] as List).length > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: _Spark([for (final v in items[i]['trend'] as List) _n(v)], t),
                        ),
                      if (delta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('${up ? '▲' : '▼'} ${delta.replaceFirst(RegExp(r'^[+\-−]'), '')}', style: Brand.mono(size: 11.5, color: up ? p.text : p.muted)),
                        ),
                    ]),
                  ),
                );
              }),
          ],
        ),
      );
    });
  }
}

// ───────────────────────────────── Funnel / pyramid
// items: [{"title":"Visitors","value":"10,000"}] widest first (funnel) or top first (pyramid).
class _Funnel extends StatelessWidget {
  const _Funnel(this.items, {required this.pyramid});
  final List<Map<String, dynamic>> items;
  final bool pyramid;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(1, 7);
    return _DrawIn(
      builder: (c, t) => LayoutBuilder(
        builder: (_, b) => Column(children: [
          for (var i = 0; i < n; i++)
            Builder(builder: (_) {
              final frac = pyramid ? 0.36 + 0.64 * (i + 1) / n : 1 - 0.55 * i / m.max(n - 1, 1);
              final strong = pyramid ? i == 0 : i == n - 1;
              final value = _s(items[i], ['value', 'amount', 'number']);
              return Opacity(
                opacity: ((t * n) - i).clamp(0.0, 1.0),
                child: Container(
                  width: b.maxWidth * frac,
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: strong ? p.accent : p.text.withValues(alpha: 0.08 + 0.06 * (pyramid ? n - i : i)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Text(_s(items[i], ['title', 'label', 'name']),
                          maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: value.isEmpty ? TextAlign.center : TextAlign.start,
                          style: _titleStyle(p, size: 13.5).copyWith(color: strong ? Colors.white : p.text)),
                    ),
                    if (value.isNotEmpty) Text(value, style: Brand.mono(size: 12, color: strong ? Colors.white : p.muted)),
                  ]),
                ),
              );
            }),
        ]),
      ),
    );
  }
}

// ───────────────────────────────── Versus
// left/right: {"title":"Rent","points":["Flexible","No upkeep"]}
class _Versus extends StatelessWidget {
  const _Versus(this.l, this.r);
  final Map<String, dynamic> l, r;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget side(Map<String, dynamic> d, bool accent) {
      final pts = (d['points'] ?? d['items'] ?? d['pros'] ?? const []) as dynamic;
      final list = pts is List ? [for (final e in pts) e.toString()] : <String>[];
      return Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: accent ? p.accent : p.text, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(_s(d, ['title', 'label', 'name']), style: Brand.serif(size: 19, color: p.text))),
          ]),
          const SizedBox(height: 8),
          for (final s in list.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(s, style: _bodyStyle(p).copyWith(color: p.text.withValues(alpha: 0.82))),
            ),
        ]),
      );
    }

    return _DrawIn(
      builder: (c, t) => Opacity(
        opacity: t,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            side(l, true),
            Container(width: 0.8, margin: const EdgeInsets.symmetric(horizontal: 14), color: p.border),
            side(r, false),
          ]),
        ),
      ),
    );
  }
}
