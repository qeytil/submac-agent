part of 'diagram_card.dart';

// Data and analytics visuals in the Telesia style: gauge, rings, columns, multi-line/area, scatter,
// heatmap, radar, waterfall, sparklines, and a branded free-form canvas.

String _unitFmt(double v, String unit) =>
    unit.isEmpty ? _fmtNum(v) : (unit.length <= 2 && !RegExp(r'^[a-z%]').hasMatch(unit) ? '$unit${_fmtNum(v)}' : '${_fmtNum(v)}$unit');

/// Palette tokens only, so every drawing stays on brand.
Color? _token(Palette p, dynamic v) {
  switch ((v ?? '').toString().toLowerCase().trim()) {
    case '':
    case 'none':
    case 'transparent':
      return null;
    case 'accent':
    case 'red':
    case 'brand':
      return p.accent;
    case 'ink':
    case 'text':
    case 'black':
      return p.text;
    case 'muted':
    case 'grey':
    case 'gray':
      return p.muted;
    case 'wash':
    case 'accentwash':
    case 'pink':
      return p.accentWash;
    case 'paper':
    case 'sheet':
    case 'bg':
    case 'white':
      return p.sheet;
    case 'bubble':
    case 'soft':
      return p.bubble;
    case 'border':
    case 'line':
    case 'hairline':
      return p.border;
    case 'brass':
    case 'gold':
      return const Color(0xFFB08D57);
    case 'slate':
    case 'blue':
      return const Color(0xFF5B7083);
    case 'plum':
    case 'purple':
      return const Color(0xFF7A5C8E);
  }
  return p.text;
}

// ───────────────────────────────── Gauge
// {"type":"gauge","value":72,"min":0,"max":100,"label":"Health score","unit":"%","target":80}
class _Gauge extends StatelessWidget {
  const _Gauge(this.j);
  final Map j;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final v = _n(j['value']), lo = _n(j['min'] ?? 0), hi = j['max'] == null ? 100.0 : _n(j['max']);
    final frac = hi == lo ? 0.0 : ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    final target = j['target'] == null ? null : ((_n(j['target']) - lo) / (hi - lo)).clamp(0.0, 1.0);
    final unit = (j['unit'] ?? '').toString();
    final label = (j['label'] ?? j['name'] ?? '').toString();
    return _DrawIn(
      ms: 1200,
      builder: (c, t) => Center(
        child: SizedBox(
          width: 230,
          height: 150,
          child: Stack(alignment: Alignment.bottomCenter, children: [
            Positioned.fill(child: CustomPaint(painter: _GaugePainter(p, frac * t, target))),
            Positioned(
              bottom: 8,
              child: Column(children: [
                Text(_unitFmt(lo + (v - lo) * t, unit), style: Brand.serif(size: 38, color: p.text, height: 1)),
                if (label.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(label.toUpperCase(), style: _tagStyle(p))),
              ]),
            ),
            Positioned(left: 4, bottom: 0, child: Text(_fmtNum(lo), style: _tagStyle(p))),
            Positioned(right: 4, bottom: 0, child: Text(_fmtNum(hi), style: _tagStyle(p))),
          ]),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.p, this.f, this.target);
  final Palette p;
  final double f;
  final double? target;

  @override
  void paint(Canvas canvas, Size s) {
    final c = Offset(s.width / 2, s.height - 22);
    final r = m.min(s.width / 2 - 14, s.height - 34);
    final rect = Rect.fromCircle(center: c, radius: r);
    final base = Paint()
      ..color = p.bubble
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, m.pi, m.pi, false, base);
    // fine ticks
    final tick = Paint()
      ..color = p.border
      ..strokeWidth = 1;
    for (var i = 0; i <= 20; i++) {
      final a = m.pi + m.pi * i / 20;
      final o = c + Offset(m.cos(a), m.sin(a)) * (r - 14);
      final o2 = c + Offset(m.cos(a), m.sin(a)) * (r - (i % 5 == 0 ? 22 : 18));
      canvas.drawLine(o, o2, tick);
    }
    if (f > 0) {
      canvas.drawArc(rect, m.pi, m.pi * f, false, Paint()
        ..color = p.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round);
    }
    if (target != null) {
      final a = m.pi + m.pi * target!;
      canvas.drawLine(c + Offset(m.cos(a), m.sin(a)) * (r - 9), c + Offset(m.cos(a), m.sin(a)) * (r + 9), Paint()
        ..color = p.text
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round);
    }
    final a = m.pi + m.pi * f;
    final tip = c + Offset(m.cos(a), m.sin(a)) * r;
    canvas.drawCircle(tip, 8, Paint()..color = p.sheet);
    canvas.drawCircle(tip, 4, Paint()..color = p.accent);
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.f != f || o.p != p;
}

// ───────────────────────────────── Rings
// {"type":"rings","items":[{"label":"Move","value":82},{"label":"Sleep","value":64}]}  values are % (or value/max)
class _Rings extends StatelessWidget {
  const _Rings(this.items);
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(1, 4);
    final tones = _tones(p);
    return _DrawIn(
      ms: 1100,
      builder: (c, t) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        for (var i = 0; i < n; i++)
          Builder(builder: (_) {
            final it = items[i];
            final mx = it['max'] == null ? 100.0 : _n(it['max']);
            final f = mx == 0 ? 0.0 : (_n(it['value']) / mx).clamp(0.0, 1.0);
            return Column(children: [
              SizedBox(
                width: 76,
                height: 76,
                child: Stack(alignment: Alignment.center, children: [
                  CustomPaint(size: const Size(76, 76), painter: _RingPainter(p, f * t, tones[i % tones.length])),
                  Text('${(f * 100 * t).round()}%', style: Brand.serif(size: 19, color: p.text)),
                ]),
              ),
              const SizedBox(height: 8),
              Text(_s(it, ['label', 'title', 'name']).toUpperCase(), style: _tagStyle(p)),
            ]);
          }),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.p, this.f, this.c);
  final Palette p;
  final double f;
  final Color c;
  @override
  void paint(Canvas canvas, Size s) {
    final rect = Rect.fromCircle(center: s.center(Offset.zero), radius: s.width / 2 - 5);
    canvas.drawArc(rect, 0, 2 * m.pi, false, Paint()
      ..color = p.bubble
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6);
    if (f > 0) {
      canvas.drawArc(rect, -m.pi / 2, 2 * m.pi * f, false, Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.f != f || o.p != p;
}

// ───────────────────────────────── Columns (vertical bars), grouped when "series" is given
// {"type":"columns","items":[{"label":"Mon","value":4}]}  or  {"series":["2025","2026"],"items":[{"label":"Q1","values":[3,5]}]}
class _Columns extends StatelessWidget {
  const _Columns(this.items, this.series, this.unit);
  final List<Map<String, dynamic>> items;
  final List<String> series;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(1, 14);
    final tones = series.length > 1 ? _tones(p) : [p.text.withValues(alpha: 0.78)];
    List<double> vals(Map<String, dynamic> it) {
      final v = it['values'];
      if (v is List) return [for (final e in v) _n(e)];
      return [_n(it['value'] ?? it['amount'])];
    }

    final all = [for (var i = 0; i < n; i++) ...vals(items[i])];
    final mx = all.isEmpty ? 1.0 : all.reduce(m.max).clamp(1e-9, double.infinity);
    final single = series.length <= 1;
    final top = single && all.isNotEmpty ? all.indexOf(all.reduce(m.max)) : -1;
    return _DrawIn(
      builder: (c, t) => Column(children: [
        SizedBox(
          height: 150,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < n; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: n > 8 ? 2 : 5),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (var k = 0; k < vals(items[i]).length; k++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: single ? 0 : 1),
                          child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                            if (single && n <= 8)
                              Text(_unitFmt(vals(items[i])[k], unit),
                                  maxLines: 1, style: Brand.mono(size: 10, color: i == top || items[i]['highlight'] == true ? p.accent : p.muted)),
                            const SizedBox(height: 4),
                            Container(
                              height: 118 * (vals(items[i])[k].abs() / mx) * t + 1,
                              decoration: BoxDecoration(
                                color: single && (i == top || items[i]['highlight'] == true) ? p.accent : tones[k % tones.length],
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                              ),
                            ),
                          ]),
                        ),
                      ),
                  ]),
                ),
              ),
          ]),
        ),
        Container(height: 0.8, color: p.border),
        const SizedBox(height: 6),
        Row(children: [
          for (var i = 0; i < n; i++)
            Expanded(child: Text(_s(items[i], ['label', 'x', 'title']), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.clip, style: _tagStyle(p))),
        ]),
        if (!single) _Legend(series, tones),
      ]),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.names, this.tones);
  final List<String> names;
  final List<Color> tones;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(spacing: 14, runSpacing: 6, children: [
        for (var i = 0; i < names.length; i++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 12, height: 3, decoration: BoxDecoration(color: tones[i % tones.length], borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 6),
            Text(names[i], style: TextStyle(color: p.muted, fontSize: AppText.micro)),
          ]),
      ]),
    );
  }
}

// ───────────────────────────────── Multi-series line / area
// {"type":"lines","labels":["Jan","Feb","Mar"],"series":[{"name":"2026","values":[3,5,8]},{"name":"2025","values":[2,4,5]}],"unit":"k"}
class _Lines extends StatelessWidget {
  const _Lines(this.labels, this.series, this.unit, {this.area = false});
  final List<String> labels;
  final List<Map<String, dynamic>> series;
  final String unit;
  final bool area;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final tones = _tones(p);
    final data = [
      for (final s in series.take(5)) [for (final v in (s['values'] is List ? s['values'] as List : const [])) _n(v)]
    ].where((l) => l.length >= 2).toList();
    if (data.isEmpty) return const SizedBox.shrink();
    final names = [for (final s in series.take(5)) _s(s, ['name', 'label', 'title'])];
    return _DrawIn(
      ms: 1200,
      builder: (c, t) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: 150, child: CustomPaint(painter: _LinesPainter(data, tones, p, t, unit, area))),
        const SizedBox(height: 6),
        if (labels.isNotEmpty)
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(labels.first, style: _tagStyle(p)),
            if (labels.length > 2) Text(labels[labels.length ~/ 2], style: _tagStyle(p)),
            Text(labels.last, style: _tagStyle(p)),
          ]),
        if (data.length > 1) _Legend(names, tones),
      ]),
    );
  }
}

class _LinesPainter extends CustomPainter {
  _LinesPainter(this.data, this.tones, this.p, this.t, this.unit, this.area);
  final List<List<double>> data;
  final List<Color> tones;
  final Palette p;
  final double t;
  final String unit;
  final bool area;

  @override
  void paint(Canvas canvas, Size size) {
    var lo = data.expand((e) => e).reduce(m.min), hi = data.expand((e) => e).reduce(m.max);
    if (area || lo > 0) lo = m.min(lo, 0);
    if ((hi - lo).abs() < 1e-9) hi = lo + 1;
    const left = 30.0;
    final w = size.width - left, h = size.height - 8;
    final grid = Paint()
      ..color = p.border.withValues(alpha: 0.6)
      ..strokeWidth = 0.6;
    for (var k = 0; k <= 3; k++) {
      final y = 4 + h * k / 3;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      final val = hi - (hi - lo) * k / 3;
      final tp = TextPainter(text: TextSpan(text: _fmtNum(val), style: Brand.mono(size: 9.5, color: p.muted)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(0, y - 6));
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, left + w * t + 2, size.height));
    for (var si = data.length - 1; si >= 0; si--) {
      final vals = data[si];
      Offset at(int i) => Offset(left + w * i / (vals.length - 1), 4 + h - (vals[i] - lo) / (hi - lo) * h);
      final path = Path()..moveTo(at(0).dx, at(0).dy);
      for (var i = 1; i < vals.length; i++) {
        final a = at(i - 1), b = at(i);
        final mid = (a.dx + b.dx) / 2;
        path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
      }
      final col = tones[si % tones.length];
      if (area || si == 0) {
        final fill = Path.from(path)
          ..lineTo(left + w, 4 + h)
          ..lineTo(left, 4 + h)
          ..close();
        canvas.drawPath(
            fill,
            Paint()
              ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
                col.withValues(alpha: area ? 0.22 : 0.14),
                col.withValues(alpha: 0),
              ]).createShader(Offset.zero & size));
      }
      canvas.drawPath(path, Paint()
        ..color = col
        ..style = PaintingStyle.stroke
        ..strokeWidth = si == 0 ? 2.2 : 1.6
        ..strokeCap = StrokeCap.round);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LinesPainter o) => o.t != t || o.p != p;
}

// ───────────────────────────────── Scatter
// {"type":"scatter","axes":{"x":"Price","y":"Rating"},"items":[{"x":12,"y":4.5,"label":"A","highlight":true}]}
class _Scatter extends StatelessWidget {
  const _Scatter(this.items, this.axes);
  final List<Map<String, dynamic>> items;
  final Map axes;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final pts = [for (final it in items.take(80)) Offset(_n(it['x']), _n(it['y']))];
    if (pts.isEmpty) return const SizedBox.shrink();
    return _DrawIn(
      builder: (c, t) => Column(children: [
        AspectRatio(aspectRatio: 1.5, child: CustomPaint(painter: _ScatterPainter(items, pts, p, t))),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('${(axes['y'] ?? '').toString()} ↑'.trim(), style: _tagStyle(p)),
          Text('${(axes['x'] ?? '').toString()} →'.trim(), style: _tagStyle(p)),
        ]),
      ]),
    );
  }
}

class _ScatterPainter extends CustomPainter {
  _ScatterPainter(this.items, this.pts, this.p, this.t);
  final List<Map<String, dynamic>> items;
  final List<Offset> pts;
  final Palette p;
  final double t;

  @override
  void paint(Canvas canvas, Size s) {
    var x0 = pts.map((e) => e.dx).reduce(m.min), x1 = pts.map((e) => e.dx).reduce(m.max);
    var y0 = pts.map((e) => e.dy).reduce(m.min), y1 = pts.map((e) => e.dy).reduce(m.max);
    if (x1 - x0 < 1e-9) x1 = x0 + 1;
    if (y1 - y0 < 1e-9) y1 = y0 + 1;
    final px = (x1 - x0) * 0.08, py = (y1 - y0) * 0.1;
    x0 -= px;
    x1 += px;
    y0 -= py;
    y1 += py;
    final grid = Paint()
      ..color = p.border.withValues(alpha: 0.6)
      ..strokeWidth = 0.6;
    for (var k = 0; k <= 4; k++) {
      canvas.drawLine(Offset(s.width * k / 4, 0), Offset(s.width * k / 4, s.height), grid);
      canvas.drawLine(Offset(0, s.height * k / 4), Offset(s.width, s.height * k / 4), grid);
    }
    for (var i = 0; i < pts.length; i++) {
      final local = ((t * pts.length) - i * 0.6).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final o = Offset((pts[i].dx - x0) / (x1 - x0) * s.width, s.height - (pts[i].dy - y0) / (y1 - y0) * s.height);
      final hl = items[i]['highlight'] == true;
      canvas.drawCircle(o, (hl ? 6 : 4.5) * local, Paint()..color = (hl ? p.accent : p.text).withValues(alpha: hl ? 1 : 0.7));
      final label = _s(items[i], ['label', 'title', 'name']);
      if (label.isNotEmpty && pts.length <= 12) {
        final tp = TextPainter(
          text: TextSpan(text: label, style: TextStyle(color: hl ? p.accent : p.text, fontSize: AppText.caption, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 90);
        tp.paint(canvas, Offset((o.dx + 7).clamp(0.0, m.max(0.0, s.width - tp.width)), (o.dy - 15).clamp(0.0, s.height - 14)));
      }
    }
  }

  @override
  bool shouldRepaint(_ScatterPainter o) => o.t != t || o.p != p;
}

// ───────────────────────────────── Heatmap
// {"type":"heatmap","rows":["Mon","Tue"],"cols":["9am","12pm","3pm"],"values":[[1,4,2],[0,5,3]]}
class _Heatmap extends StatelessWidget {
  const _Heatmap(this.rows, this.cols, this.values);
  final List<String> rows, cols;
  final List<List<double>> values;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final flat = values.expand((e) => e).toList();
    if (flat.isEmpty) return const SizedBox.shrink();
    final lo = flat.reduce(m.min), hi = flat.reduce(m.max);
    final nc = values.map((r) => r.length).reduce(m.max).clamp(1, 24);
    return _DrawIn(
      builder: (c, t) => Column(children: [
        for (var r = 0; r < values.length && r < 14; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              if (rows.isNotEmpty) SizedBox(width: 40, child: Text(r < rows.length ? rows[r] : '', style: _tagStyle(p))),
              for (var k = 0; k < nc; k++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Builder(builder: (_) {
                        final v = k < values[r].length ? values[r][k] : lo;
                        final f = hi == lo ? 0.5 : (v - lo) / (hi - lo);
                        return Container(
                          decoration: BoxDecoration(
                            color: Color.lerp(p.bubble, p.accent, f * t),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
            ]),
          ),
        if (cols.isNotEmpty)
          Row(children: [
            if (rows.isNotEmpty) const SizedBox(width: 40),
            for (var k = 0; k < nc; k++)
              Expanded(child: Text(k < cols.length ? cols[k] : '', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.clip, style: _tagStyle(p))),
          ]),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Text('LESS', style: _tagStyle(p)),
            const SizedBox(width: 6),
            for (var i = 0; i < 5; i++)
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(color: Color.lerp(p.bubble, p.accent, i / 4), borderRadius: BorderRadius.circular(3)),
              ),
            const SizedBox(width: 6),
            Text('MORE', style: _tagStyle(p)),
          ]),
        ),
      ]),
    );
  }
}

// ───────────────────────────────── Radar
// {"type":"radar","axes":["Speed","Price","Design","Battery","Camera"],"series":[{"name":"Phone A","values":[8,6,9,7,8]}],"max":10}
class _Radar extends StatelessWidget {
  const _Radar(this.axes, this.series, this.max);
  final List<String> axes;
  final List<Map<String, dynamic>> series;
  final double max;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final tones = _tones(p);
    final data = [for (final s in series.take(3)) [for (final v in (s['values'] is List ? s['values'] as List : const [])) _n(v)]];
    final mx = max > 0 ? max : data.expand((e) => e).fold<double>(1, (a, b) => m.max(a, b));
    return _DrawIn(
      ms: 1000,
      builder: (c, t) => Column(children: [
        AspectRatio(aspectRatio: 1.25, child: CustomPaint(painter: _RadarPainter(axes, data, mx, tones, p, t))),
        if (data.length > 1) _Legend([for (final s in series.take(3)) _s(s, ['name', 'label'])], tones),
      ]),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.axes, this.data, this.mx, this.tones, this.p, this.t);
  final List<String> axes;
  final List<List<double>> data;
  final double mx, t;
  final List<Color> tones;
  final Palette p;

  @override
  void paint(Canvas canvas, Size s) {
    final n = axes.length;
    if (n < 3) return;
    final c = s.center(Offset.zero);
    final r = m.min(s.width, s.height) / 2 - 26;
    Offset at(int i, double f) {
      final a = -m.pi / 2 + 2 * m.pi * i / n;
      return c + Offset(m.cos(a), m.sin(a)) * r * f;
    }

    final web = Paint()
      ..color = p.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    for (var k = 1; k <= 4; k++) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final o = at(i, k / 4);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path..close(), web);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(c, at(i, 1), web);
      final tp = TextPainter(text: TextSpan(text: axes[i].toUpperCase(), style: _tagStyle(p)), textDirection: TextDirection.ltr)..layout(maxWidth: 80);
      final o = at(i, 1.16);
      tp.paint(canvas, Offset(o.dx - tp.width / 2, o.dy - tp.height / 2));
    }
    for (var si = data.length - 1; si >= 0; si--) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final v = i < data[si].length ? data[si][i] : 0.0;
        final o = at(i, (v / mx).clamp(0.0, 1.0) * t);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = tones[si % tones.length].withValues(alpha: si == 0 ? 0.16 : 0.1));
      canvas.drawPath(path, Paint()
        ..color = tones[si % tones.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = si == 0 ? 2 : 1.4
        ..strokeJoin = StrokeJoin.round);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter o) => o.t != t || o.p != p;
}

// ───────────────────────────────── Waterfall
// {"type":"waterfall","items":[{"label":"Start","value":1000,"total":true},{"label":"Sales","value":400},{"label":"Costs","value":-250},{"label":"End","total":true}]}
class _Waterfall extends StatelessWidget {
  const _Waterfall(this.items, this.unit);
  final List<Map<String, dynamic>> items;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = items.length.clamp(2, 10);
    final starts = <double>[], ends = <double>[];
    var run = 0.0;
    for (var i = 0; i < n; i++) {
      final it = items[i];
      if (it['total'] == true) {
        if (it['value'] != null) run = _n(it['value']);
        starts.add(0);
        ends.add(run);
      } else {
        starts.add(run);
        run += _n(it['value']);
        ends.add(run);
      }
    }
    final double lo = m.min([...starts, ...ends].reduce(m.min), 0.0);
    final double hi = [...starts, ...ends].reduce(m.max);
    final double span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    return _DrawIn(
      builder: (c, t) => Column(children: [
        SizedBox(
          height: 150,
          child: LayoutBuilder(
            builder: (_, b) => Stack(children: [
              for (var i = 0; i < n; i++)
                Builder(builder: (_) {
                  final colW = b.maxWidth / n;
                  final a = m.min(starts[i], ends[i]), z = m.max(starts[i], ends[i]);
                  final top = (hi - z) / span * 130 + 16;
                  final hgt = m.max((z - a) / span * 130 * t, 1.5);
                  final isTotal = items[i]['total'] == true;
                  final up = ends[i] >= starts[i];
                  final delta = ends[i] - starts[i];
                  return Positioned(
                    left: colW * i + colW * 0.16,
                    width: colW * 0.68,
                    top: top - 14,
                    child: Column(children: [
                      Text(isTotal ? _unitFmt(ends[i], unit) : '${up ? '+' : '−'}${_unitFmt(delta.abs(), unit)}',
                          maxLines: 1, style: Brand.mono(size: 9.5, color: isTotal ? p.text : (up ? p.text : p.accent))),
                      const SizedBox(height: 2),
                      Container(
                        height: hgt,
                        decoration: BoxDecoration(
                          color: isTotal ? p.text : (up ? p.text.withValues(alpha: 0.35) : p.accent),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ]),
                  );
                }),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          for (var i = 0; i < n; i++)
            Expanded(child: Text(_s(items[i], ['label', 'title']), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.clip, style: _tagStyle(p))),
        ]),
      ]),
    );
  }
}

// ───────────────────────────────── Sparkline (used inside stats tiles)
class _Spark extends StatelessWidget {
  const _Spark(this.vals, this.t);
  final List<double> vals;
  final double t;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SizedBox(height: 26, child: CustomPaint(size: Size.infinite, painter: _LinesPainterSpark(vals, p, t)));
  }
}

class _LinesPainterSpark extends CustomPainter {
  _LinesPainterSpark(this.vals, this.p, this.t);
  final List<double> vals;
  final Palette p;
  final double t;
  @override
  void paint(Canvas canvas, Size s) {
    if (vals.length < 2) return;
    final lo = vals.reduce(m.min), hi = vals.reduce(m.max);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    Offset at(int i) => Offset(s.width * i / (vals.length - 1), s.height - 2 - (vals[i] - lo) / span * (s.height - 4));
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < vals.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, s.width * t + 2, s.height));
    canvas.drawPath(path, Paint()
      ..color = p.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LinesPainterSpark o) => o.t != t || o.p != p;
}

// ───────────────────────────────── Canvas: free-form drawing with palette tokens only
// {"type":"canvas","width":320,"height":180,"shapes":[
//   {"type":"rect","x":10,"y":10,"w":120,"h":60,"r":12,"fill":"wash","stroke":"accent"},
//   {"type":"circle","cx":200,"cy":40,"r":20,"fill":"accent"},
//   {"type":"line","x1":130,"y1":40,"x2":180,"y2":40,"stroke":"muted","arrow":true,"dash":true},
//   {"type":"text","x":70,"y":40,"text":"Idea","size":15,"serif":true,"align":"center","color":"ink"},
//   {"type":"path","d":"M10 150 C80 100 160 190 300 120","stroke":"accent","width":2}]}
class _CanvasCard extends StatelessWidget {
  const _CanvasCard(this.j);
  final Map j;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = _n(j['width'] ?? 320).clamp(40.0, 2000.0), h = _n(j['height'] ?? 180).clamp(40.0, 2000.0);
    final shapes = _maps(j['shapes'] ?? j['elements'] ?? const []);
    return _DrawIn(
      ms: 900,
      builder: (c, t) => AspectRatio(
        aspectRatio: w / h,
        child: CustomPaint(painter: _FreePainter(shapes, Size(w, h), p, t)),
      ),
    );
  }
}

class _FreePainter extends CustomPainter {
  _FreePainter(this.shapes, this.view, this.p, this.t);
  final List<Map<String, dynamic>> shapes;
  final Size view;
  final Palette p;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / view.width;
    canvas.save();
    canvas.scale(k, k);
    canvas.clipRect(Offset.zero & view);
    final n = shapes.length.clamp(0, 200);
    for (var i = 0; i < n; i++) {
      final sh = shapes[i];
      final local = ((t * (n + 2)) - i).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final type = (sh['type'] ?? sh['shape'] ?? '').toString().toLowerCase();
      final fill = _token(p, sh['fill']);
      final stroke = _token(p, sh['stroke'] ?? (fill == null && type != 'text' ? 'ink' : null));
      final sw = sh['width'] != null && type != 'rect' ? _n(sh['width']) : _n(sh['strokeWidth'] ?? 1.4);
      Paint fp(Color c) => Paint()..color = c.withValues(alpha: c.a * local);
      Paint sp(Color c) => Paint()
        ..color = c.withValues(alpha: c.a * local)
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw <= 0 ? 1.4 : sw
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      switch (type) {
        case 'rect':
        case 'box':
          final rr = RRect.fromRectAndRadius(Rect.fromLTWH(_n(sh['x']), _n(sh['y']), _n(sh['w'] ?? sh['width']), _n(sh['h'] ?? sh['height'])), Radius.circular(_n(sh['r'] ?? 10)));
          if (fill != null) canvas.drawRRect(rr, fp(fill));
          if (stroke != null) canvas.drawRRect(rr, sp(stroke)..strokeWidth = _n(sh['strokeWidth'] ?? 1));
          break;
        case 'circle':
        case 'dot':
          final o = Offset(_n(sh['cx'] ?? sh['x']), _n(sh['cy'] ?? sh['y']));
          final r = _n(sh['r'] ?? 6);
          if (fill != null) canvas.drawCircle(o, r, fp(fill));
          if (stroke != null && sh['stroke'] != null) canvas.drawCircle(o, r, sp(stroke));
          if (fill == null && sh['stroke'] == null) canvas.drawCircle(o, r, fp(p.text));
          break;
        case 'line':
        case 'arrow':
          final a = Offset(_n(sh['x1']), _n(sh['y1'])), b = Offset(_n(sh['x2']), _n(sh['y2']));
          final e = Offset.lerp(a, b, local)!;
          final paint = sp(stroke ?? p.muted);
          if (sh['dash'] == true) {
            final len = (e - a).distance;
            final dir = len == 0 ? Offset.zero : (e - a) / len;
            for (var d = 0.0; d < len; d += 8) {
              canvas.drawLine(a + dir * d, a + dir * m.min(d + 4, len), paint);
            }
          } else {
            canvas.drawLine(a, e, paint);
          }
          if ((sh['arrow'] == true || type == 'arrow') && local >= 1) {
            final ang = (b - a).direction;
            canvas.drawLine(b, b - Offset.fromDirection(ang - 0.5, 8), paint);
            canvas.drawLine(b, b - Offset.fromDirection(ang + 0.5, 8), paint);
          }
          break;
        case 'text':
        case 'label':
          final color = _token(p, sh['color'] ?? 'ink') ?? p.text;
          final size0 = _n(sh['size'] ?? 13).clamp(6.0, 60.0);
          final style = sh['serif'] == true
              ? Brand.serif(size: size0 + 2, color: color.withValues(alpha: local))
              : (sh['mono'] == true
                  ? Brand.mono(size: size0 - 1, color: color.withValues(alpha: local)).copyWith(letterSpacing: 0.8)
                  : TextStyle(fontSize: size0, color: color.withValues(alpha: local), fontWeight: sh['bold'] == true ? FontWeight.w700 : FontWeight.w500));
          final tp = TextPainter(
            text: TextSpan(text: (sh['text'] ?? '').toString(), style: style),
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            maxLines: 3,
          )..layout(maxWidth: sh['maxWidth'] != null ? _n(sh['maxWidth']) : view.width);
          final align = (sh['align'] ?? 'left').toString();
          final dx = align == 'center' ? tp.width / 2 : (align == 'right' ? tp.width : 0);
          tp.paint(canvas, Offset(_n(sh['x']) - dx, _n(sh['y']) - tp.height / 2));
          break;
        case 'path':
          final path = _svgPath((sh['d'] ?? '').toString());
          if (fill != null) canvas.drawPath(path, fp(fill));
          if (stroke != null) {
            for (final metric in path.computeMetrics()) {
              canvas.drawPath(metric.extractPath(0, metric.length * local), sp(stroke));
            }
          }
          break;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FreePainter o) => o.t != t || o.p != p;
}

/// Minimal SVG path reader: M L H V C Q Z (absolute and relative).
Path _svgPath(String d) {
  final path = Path();
  final tokens = RegExp(r'[MLHVCQZmlhvcqz]|-?\d*\.?\d+(?:e-?\d+)?').allMatches(d).map((e) => e.group(0)!).toList();
  var i = 0;
  var cmd = 'M';
  var cx = 0.0, cy = 0.0;
  double num() => i < tokens.length ? (double.tryParse(tokens[i++]) ?? 0) : 0;
  bool isNum() => i < tokens.length && !RegExp(r'^[A-Za-z]$').hasMatch(tokens[i]);
  var guard = 0;
  while (i < tokens.length && guard++ < 5000) {
    if (!isNum()) cmd = tokens[i++];
    final rel = cmd == cmd.toLowerCase();
    switch (cmd.toUpperCase()) {
      case 'M':
        cx = num() + (rel ? cx : 0);
        cy = num() + (rel ? cy : 0);
        path.moveTo(cx, cy);
        cmd = rel ? 'l' : 'L';
        break;
      case 'L':
        cx = num() + (rel ? cx : 0);
        cy = num() + (rel ? cy : 0);
        path.lineTo(cx, cy);
        break;
      case 'H':
        cx = num() + (rel ? cx : 0);
        path.lineTo(cx, cy);
        break;
      case 'V':
        cy = num() + (rel ? cy : 0);
        path.lineTo(cx, cy);
        break;
      case 'C':
        final x1 = num() + (rel ? cx : 0), y1 = num() + (rel ? cy : 0);
        final x2 = num() + (rel ? cx : 0), y2 = num() + (rel ? cy : 0);
        final x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0);
        path.cubicTo(x1, y1, x2, y2, x, y);
        cx = x;
        cy = y;
        break;
      case 'Q':
        final x1 = num() + (rel ? cx : 0), y1 = num() + (rel ? cy : 0);
        final x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0);
        path.quadraticBezierTo(x1, y1, x, y);
        cx = x;
        cy = y;
        break;
      case 'Z':
        path.close();
        break;
      default:
        i++;
    }
  }
  return path;
}

/// Routes the analytics types; returns null when the type isn't one of them.
(String, Widget?)? _dataViz(String type, Map j, List<Map<String, dynamic>> items) {
  final unit = (j['unit'] ?? '').toString();
  switch (type) {
    case 'gauge':
    case 'meter':
    case 'score':
      return ('Gauge', j['value'] == null ? null : _Gauge(j));
    case 'rings':
    case 'progress':
    case 'ring':
      return ('Progress', items.isEmpty ? (j['value'] == null ? null : _Rings([Map<String, dynamic>.from(j)])) : _Rings(items));
    case 'columns':
    case 'column':
    case 'histogram':
    case 'grouped':
      final series = j['series'] is List ? [for (final s in j['series']) s is Map ? _s(Map<String, dynamic>.from(s), ['name', 'label']) : s.toString()] : <String>[];
      return ('Chart', items.isEmpty ? null : _Columns(items, series, unit));
    case 'lines':
    case 'area':
    case 'multiline':
      final series = _maps(j['series']);
      final labels = j['labels'] is List ? [for (final l in j['labels']) l.toString()] : <String>[];
      return ('Trend', series.isEmpty ? null : _Lines(labels, series, unit, area: type == 'area'));
    case 'scatter':
    case 'bubble':
      return ('Chart', items.isEmpty ? null : _Scatter(items, j['axes'] is Map ? j['axes'] as Map : const {}));
    case 'heatmap':
    case 'calendar':
      final vals = j['values'] is List
          ? [for (final r in j['values']) if (r is List) [for (final v in r) _n(v)]]
          : <List<double>>[];
      final rows = j['rows'] is List ? [for (final r in j['rows']) r.toString()] : <String>[];
      final cols = j['cols'] is List ? [for (final r in j['cols']) r.toString()] : (j['columns'] is List ? [for (final r in j['columns']) r.toString()] : <String>[]);
      return ('Heatmap', vals.isEmpty ? null : _Heatmap(rows, cols, vals));
    case 'radar':
    case 'spider':
      final axes = j['axes'] is List ? [for (final a in j['axes']) a.toString()] : <String>[];
      final series = _maps(j['series']);
      return ('Profile', axes.length < 3 || series.isEmpty ? null : _Radar(axes, series, j['max'] == null ? 0 : _n(j['max'])));
    case 'waterfall':
    case 'bridge':
      return ('Breakdown', items.length < 2 ? null : _Waterfall(items, unit));
    case 'canvas':
    case 'drawing':
    case 'illustration':
      return ('Sketch', _CanvasCard(j));
  }
  return null;
}
