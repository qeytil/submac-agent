import 'dart:math' as m;

import 'package:flutter/material.dart';

import '../services/math_expr.dart';
import '../theme.dart';
import 'math_text.dart';
import 'motion.dart';
import 'output_cards.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';

/// Curve colours in the SubMac palette: brand red first, then ink, brass and slate.
List<Color> plotColors(Palette p) => [p.accent, p.text, const Color(0xFFB08D57), const Color(0xFF5B7083), const Color(0xFF7A5C8E)];

class GraphLine {
  final Plot plot;
  final String tex;
  GraphLine(this.plot, this.tex);
}

class GraphParam {
  final String name;
  final double min, max;
  double value;
  GraphParam(this.name, this.value, this.min, this.max);
}

/// A graph the model asked for: ```graph {"title","caption","plots":[...],"x":[a,b],"y":[a,b],"params":{"a":[1,0,5]}}
class GraphSpec {
  final String title;
  final String caption;
  final List<GraphLine> lines;
  final Rect? view; // x: left..right, y: top=ymax .. bottom=ymin stored as Rect.fromLTRB(xmin, ymin, xmax, ymax)
  final List<GraphParam> params;
  GraphSpec(this.title, this.caption, this.lines, this.view, this.params);

  static List<double>? _pair(dynamic v) {
    if (v is List && v.length >= 2) {
      final a = double.tryParse(v[0].toString()), b = double.tryParse(v[1].toString());
      if (a != null && b != null && b > a) return [a, b];
    }
    return null;
  }

  static GraphSpec? fromJson(dynamic input) {
    final Map<dynamic, dynamic> j;
    if (input is String) {
      j = <String, dynamic>{'plots': <dynamic>[input]};
    } else if (input is List) {
      j = <String, dynamic>{'plots': input};
    } else if (input is Map) {
      j = input;
    } else {
      return null;
    }
    final raw = j['plots'] ?? j['equations'] ?? j['functions'] ?? (j['expr'] != null ? [j] : (j['equation'] != null ? [j['equation']] : const []));
    final t = _pair(j['t']);
    final lines = <GraphLine>[];
    for (final r in (raw is List ? raw : [raw])) {
      try {
        if (r is Map) {
          final e = (r['expr'] ?? r['equation'] ?? r['y'] ?? '').toString();
          final x = r['x'], y = r['y'];
          Plot plot;
          final tt = _pair(r['t']) ?? t;
          if (x != null && y != null && r['expr'] == null) {
            plot = parsePlot('x=$x, y=$y', t0: tt?[0], t1: tt?[1]);
          } else {
            plot = parsePlot(e, t0: tt?[0], t1: tt?[1]);
          }
          lines.add(GraphLine(plot, (r['tex'] ?? r['latex'] ?? '').toString()));
        } else if (r != null) {
          final str = r.toString();
          // "y = sin(x), y = cos(x)" is two curves, unless it is a parametric "x = ..., y = ...".
          final isParam = RegExp(r'^\s*\(?\s*x\s*(\(t\))?\s*=').hasMatch(str) && str.contains('t');
          final parts = !isParam && '='.allMatches(str).length > 1 ? str.split(RegExp(r'[,;]\s*(?=[a-zA-Z]\s*(\(\w+\))?\s*=)')) : [str];
          for (final part in parts) {
            if (part.trim().isNotEmpty) lines.add(GraphLine(parsePlot(part, t0: t?[0], t1: t?[1]), ''));
          }
        }
      } catch (_) {}
    }
    if (lines.isEmpty) return null;
    final xr = _pair(j['x'] ?? j['xRange'] ?? j['x_range']);
    final yr = _pair(j['y'] ?? j['yRange'] ?? j['y_range']);
    final params = <GraphParam>[];
    final ps = j['params'] ?? j['sliders'];
    if (ps is Map) {
      ps.forEach((k, v) {
        if (v is List && v.length >= 3) {
          final val = double.tryParse(v[0].toString()) ?? 1, lo = double.tryParse(v[1].toString()) ?? -5, hi = double.tryParse(v[2].toString()) ?? 5;
          params.add(GraphParam(k.toString(), val, m.min(lo, hi), m.max(lo, hi)));
        } else if (v is num) {
          params.add(GraphParam(k.toString(), v.toDouble(), v.toDouble() - 5, v.toDouble() + 5));
        }
      });
    }
    // Any free letter that is not a variable becomes a slider so the graph still draws.
    const known = {'x', 'y', 't', 'theta', 'r', 'phi'};
    for (final l in lines) {
      for (final v in l.plot.vars) {
        if (!known.contains(v) && !params.any((p) => p.name == v)) params.add(GraphParam(v, 1, -5, 5));
      }
    }
    Rect? view;
    if (xr != null || yr != null) {
      view = Rect.fromLTRB(xr?[0] ?? -6, yr?[0] ?? -6, xr?[1] ?? 6, yr?[1] ?? 6);
    }
    return GraphSpec((j['title'] ?? '').toString(), (j['caption'] ?? j['note'] ?? '').toString(), lines, view, params);
  }

  Env env() => {for (final p in params) p.name: p.value};

  /// A sensible first view: given ranges, or one that frames the curves.
  Rect autoView() {
    if (view != null) {
      // If only x was given, frame y from the curves.
      return view!;
    }
    final env0 = env();
    var xmin = -6.0, xmax = 6.0;
    final ys = <double>[];
    final pts = <Offset>[];
    for (final l in lines) {
      final pl = l.plot;
      switch (pl.kind) {
        case PlotKind.explicit:
          for (var i = 0; i <= 200; i++) {
            final x = xmin + (xmax - xmin) * i / 200;
            final y = pl.f.eval({...env0, 'x': x});
            if (y.isFinite) ys.add(y);
          }
          break;
        case PlotKind.polar:
        case PlotKind.parametric:
          for (var i = 0; i <= 400; i++) {
            final t = pl.t0 + (pl.t1 - pl.t0) * i / 400;
            final e = {...env0, 't': t, 'theta': t};
            final o = _curvePoint(pl, e);
            if (o != null) pts.add(o);
          }
          break;
        default:
          break;
      }
    }
    if (pts.isNotEmpty) {
      var a = pts.first.dx, b = pts.first.dx, c = pts.first.dy, d = pts.first.dy;
      for (final o in pts) {
        a = m.min(a, o.dx);
        b = m.max(b, o.dx);
        c = m.min(c, o.dy);
        d = m.max(d, o.dy);
      }
      final half = m.max(m.max(b - a, d - c) / 2 * 1.2, 1.0);
      final cx = (a + b) / 2, cy = (c + d) / 2;
      return Rect.fromLTRB(cx - half, cy - half, cx + half, cy + half);
    }
    if (lines.every((l) => l.plot.kind == PlotKind.implicit)) return const Rect.fromLTRB(-7, -7, 7, 7);
    if (ys.isEmpty) return Rect.fromLTRB(xmin, -6, xmax, 6);
    ys.sort();
    var lo = ys[(ys.length * 0.05).floor()], hi = ys[(ys.length * 0.95).floor().clamp(0, ys.length - 1)];
    if (hi - lo < 1e-6) {
      lo -= 2;
      hi += 2;
    }
    final pad = (hi - lo) * 0.18;
    lo -= pad;
    hi += pad;
    if (lo > 0) lo = m.min(lo, -pad);
    if (hi < 0) hi = m.max(hi, pad);
    return Rect.fromLTRB(xmin, lo, xmax, hi);
  }
}

Offset? _curvePoint(Plot pl, Env e) {
  if (pl.kind == PlotKind.polar) {
    final th = e['theta'] ?? 0;
    final r = pl.f.eval(e);
    if (!r.isFinite) return null;
    return Offset(r * m.cos(th), r * m.sin(th));
  }
  final x = pl.f.eval(e), y = pl.g!.eval(e);
  if (!x.isFinite || !y.isFinite) return null;
  return Offset(x, y);
}

/// Draws the grid, axes and curves. [view] is in maths units: left=xmin, top=ymin, right=xmax, bottom=ymax.
class GraphPainter extends CustomPainter {
  final GraphSpec spec;
  final Rect view;
  final double progress;
  final bool mini;
  final Palette p;
  final Offset? trace; // maths point to mark
  GraphPainter(this.spec, this.view, this.p, {this.progress = 1, this.mini = false, this.trace});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    double sx(double x) => (x - view.left) / view.width * w;
    double sy(double y) => h - (y - view.top) / view.height * h;
    canvas.clipRect(Offset.zero & size);

    // Grid
    final step = _niceStep(view.width / (mini ? 4 : 8));
    final stepY = _niceStep(view.height / (mini ? 4 : 8));
    final grid = Paint()
      ..color = p.border.withValues(alpha: mini ? 0.45 : 0.55)
      ..strokeWidth = 0.6;
    for (var x = (view.left / step).ceil() * step; x <= view.right; x += step) {
      canvas.drawLine(Offset(sx(x), 0), Offset(sx(x), h), grid);
    }
    for (var y = (view.top / stepY).ceil() * stepY; y <= view.bottom; y += stepY) {
      canvas.drawLine(Offset(0, sy(y)), Offset(w, sy(y)), grid);
    }
    // Axes
    final axis = Paint()
      ..color = p.muted.withValues(alpha: 0.8)
      ..strokeWidth = mini ? 0.8 : 1.1;
    if (view.left <= 0 && view.right >= 0) canvas.drawLine(Offset(sx(0), 0), Offset(sx(0), h), axis);
    if (view.top <= 0 && view.bottom >= 0) canvas.drawLine(Offset(0, sy(0)), Offset(w, sy(0)), axis);

    // Tick labels (full view only)
    if (!mini) {
      final ax = (view.top <= 0 && view.bottom >= 0) ? sy(0) : h - 4;
      final ay = (view.left <= 0 && view.right >= 0) ? sx(0) : 4.0;
      for (var x = (view.left / step).ceil() * step; x <= view.right; x += step) {
        if (x.abs() < step / 2) continue;
        _label(canvas, _fmt(x), Offset(sx(x) + 3, (ax + 3).clamp(2.0, h - 16)));
      }
      for (var y = (view.top / stepY).ceil() * stepY; y <= view.bottom; y += stepY) {
        if (y.abs() < stepY / 2) continue;
        _label(canvas, _fmt(y), Offset((ay + 4).clamp(2.0, w - 36), sy(y) - 15));
      }
    }

    final colors = plotColors(p);
    final env0 = spec.env();
    for (var li = 0; li < spec.lines.length; li++) {
      final pl = spec.lines[li].plot;
      final paint = Paint()
        ..color = colors[li % colors.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = mini ? 1.8 : 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      final path = Path();
      switch (pl.kind) {
        case PlotKind.explicit:
        case PlotKind.explicitX:
          final isX = pl.kind == PlotKind.explicitX;
          final n = (isX ? h : w * progress).clamp(2, 4000).toInt() * (mini ? 1 : 2);
          var pen = false;
          double? lastS;
          final span = isX ? view.height : view.width * progress;
          final start = isX ? view.top : view.left;
          for (var i = 0; i <= n; i++) {
            final u = start + span * i / n;
            final v = pl.f.eval({...env0, (isX ? 'y' : 'x'): u});
            if (!v.isFinite) {
              pen = false;
              continue;
            }
            final px = isX ? sx(v) : sx(u);
            final py = isX ? sy(u) : sy(v);
            final s = isX ? px : py;
            if (lastS != null && (s - lastS).abs() > (isX ? w : h) * 1.5) pen = false; // asymptote
            if (pen) {
              path.lineTo(px, py.clamp(-h * 4, h * 5));
            } else {
              path.moveTo(px, py.clamp(-h * 4, h * 5));
              pen = true;
            }
            lastS = s;
          }
          break;
        case PlotKind.polar:
        case PlotKind.parametric:
          final n = mini ? 500 : 1600;
          var pen = false;
          final t1 = pl.t0 + (pl.t1 - pl.t0) * progress;
          for (var i = 0; i <= n; i++) {
            final t = pl.t0 + (t1 - pl.t0) * i / n;
            final o = _curvePoint(pl, {...env0, 't': t, 'theta': t});
            if (o == null) {
              pen = false;
              continue;
            }
            if (pen) {
              path.lineTo(sx(o.dx), sy(o.dy));
            } else {
              path.moveTo(sx(o.dx), sy(o.dy));
              pen = true;
            }
          }
          break;
        case PlotKind.implicit:
          _marching(path, pl, env0, size, sx, sy);
          paint.color = paint.color.withValues(alpha: progress.clamp(0.0, 1.0));
          break;
        case PlotKind.point:
          break;
      }
      canvas.drawPath(path, paint);
    }

    if (trace != null && !mini) {
      final c = Offset(sx(trace!.dx), sy(trace!.dy));
      canvas.drawCircle(c, 9, Paint()..color = p.accent.withValues(alpha: 0.18));
      canvas.drawCircle(c, 4.5, Paint()..color = p.accent);
      final tp = TextPainter(
        text: TextSpan(
            text: '(${_fmt(trace!.dx, fine: true)}, ${_fmt(trace!.dy, fine: true)})',
            style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final box = Rect.fromLTWH((c.dx + 12).clamp(4.0, w - tp.width - 20), (c.dy - 34).clamp(4.0, h - 30), tp.width + 16, 26);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(13)), Paint()..color = p.sheet);
      canvas.drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(13)),
          Paint()
            ..color = p.border
            ..style = PaintingStyle.stroke);
      tp.paint(canvas, Offset(box.left + 8, box.top + 5));
    }
  }

  void _marching(Path path, Plot pl, Env env0, Size size, double Function(double) sx, double Function(double) sy) {
    final nx = mini ? 70 : 150, ny = (nx * size.height / size.width).round().clamp(20, 300);
    final dx = view.width / nx, dy = view.height / ny;
    final vals = List.generate(ny + 1, (j) {
      final y = view.top + j * dy;
      return List.generate(nx + 1, (i) => pl.f.eval({...env0, 'x': view.left + i * dx, 'y': y}));
    });
    Offset lerp(double x0, double y0, double v0, double x1, double y1, double v1) {
      final t = (v0 - v1).abs() < 1e-12 ? 0.5 : v0 / (v0 - v1);
      return Offset(sx(x0 + (x1 - x0) * t), sy(y0 + (y1 - y0) * t));
    }

    for (var j = 0; j < ny; j++) {
      for (var i = 0; i < nx; i++) {
        final x0 = view.left + i * dx, y0 = view.top + j * dy, x1 = x0 + dx, y1 = y0 + dy;
        final a = vals[j][i], b = vals[j][i + 1], c = vals[j + 1][i + 1], d = vals[j + 1][i];
        if (!a.isFinite || !b.isFinite || !c.isFinite || !d.isFinite) continue;
        final pts = <Offset>[];
        if ((a > 0) != (b > 0)) pts.add(lerp(x0, y0, a, x1, y0, b));
        if ((b > 0) != (c > 0)) pts.add(lerp(x1, y0, b, x1, y1, c));
        if ((c > 0) != (d > 0)) pts.add(lerp(x1, y1, c, x0, y1, d));
        if ((d > 0) != (a > 0)) pts.add(lerp(x0, y1, d, x0, y0, a));
        // Skip sign changes caused by poles (huge jumps), e.g. 1/x.
        final mx = [a.abs(), b.abs(), c.abs(), d.abs()].reduce(m.max);
        if (mx > 1e6) continue;
        for (var k = 0; k + 1 < pts.length; k += 2) {
          path.moveTo(pts[k].dx, pts[k].dy);
          path.lineTo(pts[k + 1].dx, pts[k + 1].dy);
        }
      }
    }
  }

  void _label(Canvas c, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: p.muted, fontSize: AppText.caption)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at);
  }

  static double _niceStep(double raw) {
    if (raw <= 0 || !raw.isFinite) return 1;
    final e = m.pow(10, (m.log(raw) / m.ln10).floor()).toDouble();
    final f = raw / e;
    final n = f < 1.5 ? 1 : (f < 3.5 ? 2 : (f < 7.5 ? 5 : 10));
    return n * e;
  }

  static String _fmt(double v, {bool fine = false}) {
    if (v.abs() < 1e-9) return '0';
    if (fine) {
      final s = v.toStringAsFixed(v.abs() >= 100 ? 1 : (v.abs() >= 10 ? 2 : 3));
      return s.contains('.') ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '') : s;
    }
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(v.abs() < 1 ? 2 : 1).replaceAll(RegExp(r'0+$'), '');
  }

  @override
  bool shouldRepaint(GraphPainter old) => true; // params change in place, so always repaint (cheap).
}

/// The small curve preview that draws itself once.
class MiniGraph extends StatefulWidget {
  const MiniGraph(this.spec, {super.key, this.size = 84});
  final GraphSpec spec;
  final double size;

  @override
  State<MiniGraph> createState() => _MiniGraphState();
}

class _MiniGraphState extends State<MiniGraph> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: SubMotion.drawLong);
  late final Rect _view = widget.spec.autoView();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: p.sheet,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: GraphPainter(widget.spec, _view, p, mini: true, progress: SubMotion.settle.transform(_c.value)),
        ),
      ),
    );
  }
}

String _plainEq(GraphSpec s) => s.lines.map((l) => l.plot.label).join(',  ');
String _texEq(GraphSpec s) => s.lines.map((l) => l.tex.isNotEmpty ? l.tex : plainToTex(l.plot.label)).join(',\\; ');

/// The compact equation tile: live mini curve, typeset equation, expand button.
class GraphTile extends StatelessWidget {
  const GraphTile(this.spec, {super.key});
  final GraphSpec spec;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final tex = _texEq(spec);
    return Pressable(
      onTap: () => openGraph(context, spec),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: p.bubble,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border, width: 0.8),
        ),
        child: Row(children: [
          MiniGraph(spec),
          const SizedBox(width: 14),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: tex.isNotEmpty
                  ? MathText(tex, size: 19, color: p.text)
                  : Text(_plainEq(spec), style: Brand.serif(size: 19, color: p.text).copyWith(fontStyle: FontStyle.italic)),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.border)),
            child: SubIcon('expand', size: 17, color: p.text),
          ),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}

/// ```graph as a card of its own.
class GraphCard extends StatelessWidget {
  const GraphCard(this.spec, {super.key});
  final GraphSpec spec;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return cardShell(
      context,
      kicker: spec.title.isEmpty ? 'Graph' : spec.title,
      collapse: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GraphTile(spec),
        if (spec.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 10, start: 2),
            child: Text(spec.caption, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
          ),
      ]),
    );
  }
}

void openGraph(BuildContext context, GraphSpec spec) {
  Navigator.of(context).push(PageRouteBuilder(
    transitionDuration: SubMotion.page,
    reverseTransitionDuration: SubMotion.sheetOut,
    pageBuilder: (_, __, ___) => GraphScreen(spec: spec),
    transitionsBuilder: (ctx, a, __, child) {
      if (SubMotion.still(ctx)) return child;
      // A driven tween, not a new CurvedAnimation each rebuild (those pile up listeners on the route's animation).
      final c = a.drive(CurveTween(curve: SubMotion.settle));
      return FadeTransition(
        opacity: c,
        child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(c), child: child),
      );
    },
  ));
}

/// Full-screen interactive graph: pinch to zoom, drag to pan, touch to read a point, sliders for values.
class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key, required this.spec});
  final GraphSpec spec;

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> with SingleTickerProviderStateMixin {
  late Rect _view = widget.spec.autoView();
  late Rect _startView;
  Offset _startFocal = Offset.zero;
  Offset? _trace;
  Size _size = Size.zero;
  late final AnimationController _draw = AnimationController(vsync: this, duration: SubMotion.draw)..forward();

  @override
  void initState() {
    super.initState();
    // Equal scale on both axes for circles and roses.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitAspect());
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  void _fitAspect() {
    if (_size == Size.zero) return;
    final wantsEqual = widget.spec.lines.any((l) => l.plot.kind != PlotKind.explicit && l.plot.kind != PlotKind.explicitX);
    final v = _view;
    if (wantsEqual) {
      final unitsPerPx = m.max(v.width / _size.width, v.height / _size.height);
      final cx = v.center.dx, cy = v.center.dy;
      setState(() => _view = Rect.fromCenter(center: Offset(cx, cy), width: unitsPerPx * _size.width, height: unitsPerPx * _size.height));
    } else if (widget.spec.view == null) {
      // Taller screen: show more y.
      final scale = (_size.height / _size.width) / (v.height / v.width);
      if (scale > 1) setState(() => _view = Rect.fromCenter(center: v.center, width: v.width, height: v.height * m.min(scale, 1.8)));
    }
  }

  Offset _toMath(Offset px) =>
      Offset(_view.left + px.dx / _size.width * _view.width, _view.bottom - px.dy / _size.height * _view.height);

  void _traceAt(Offset px) {
    final mp = _toMath(px);
    final env = widget.spec.env();
    Offset? best;
    var bestD = double.infinity;
    for (final l in widget.spec.lines) {
      final pl = l.plot;
      if (pl.kind == PlotKind.explicit) {
        final y = pl.f.eval({...env, 'x': mp.dx});
        if (y.isFinite) {
          final d = ((y - mp.dy) / _view.height * _size.height).abs();
          if (d < bestD) {
            bestD = d;
            best = Offset(mp.dx, y);
          }
        }
      } else if (pl.kind == PlotKind.polar || pl.kind == PlotKind.parametric) {
        for (var i = 0; i <= 1200; i++) {
          final t = pl.t0 + (pl.t1 - pl.t0) * i / 1200;
          final o = _curvePoint(pl, {...env, 't': t, 'theta': t});
          if (o == null) continue;
          final d = Offset((o.dx - mp.dx) / _view.width * _size.width, (o.dy - mp.dy) / _view.height * _size.height).distance;
          if (d < bestD) {
            bestD = d;
            best = o;
          }
        }
      }
    }
    if (best != null && bestD < 60) {
      setState(() => _trace = best);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final spec = widget.spec;
    final colors = plotColors(p);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(spec.title.isEmpty ? 'Graph' : spec.title, style: Brand.serif(size: 21, color: p.text)),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _view = spec.autoView();
                _trace = null;
              });
              WidgetsBinding.instance.addPostFrameCallback((_) => _fitAspect());
            },
            child: Text('Reset', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: Container(
              margin: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 8),
              decoration: BoxDecoration(
                color: p.sheet,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: p.border, width: 0.8),
              ),
              clipBehavior: Clip.antiAlias,
              child: LayoutBuilder(builder: (context, box) {
                final first = _size == Size.zero;
                _size = Size(box.maxWidth, box.maxHeight);
                if (first) WidgetsBinding.instance.addPostFrameCallback((_) => _fitAspect());
                return GestureDetector(
                  onScaleStart: (d) {
                    _startView = _view;
                    _startFocal = d.localFocalPoint;
                  },
                  onScaleUpdate: (d) {
                    final s = d.scale.clamp(0.05, 40.0);
                    final sv = _startView;
                    final fx = sv.left + _startFocal.dx / _size.width * sv.width;
                    final fy = sv.bottom - _startFocal.dy / _size.height * sv.height;
                    final nw = sv.width / s, nh = sv.height / s;
                    final left = fx - d.localFocalPoint.dx / _size.width * nw;
                    final bottom = fy + d.localFocalPoint.dy / _size.height * nh;
                    setState(() => _view = Rect.fromLTRB(left, bottom - nh, left + nw, bottom));
                  },
                  onLongPressStart: (d) => _traceAt(d.localPosition),
                  onLongPressMoveUpdate: (d) => _traceAt(d.localPosition),
                  onTapUp: (d) => _trace == null ? _traceAt(d.localPosition) : setState(() => _trace = null),
                  child: AnimatedBuilder(
                    animation: _draw,
                    builder: (_, __) => CustomPaint(
                      size: Size.infinite,
                      painter: GraphPainter(spec, _view, p, progress: SubMotion.settle.transform(_draw.value), trace: _trace),
                    ),
                  ),
                );
              }),
            ),
          ),
          // Legend
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              for (var i = 0; i < spec.lines.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Container(width: 14, height: 3, decoration: BoxDecoration(color: colors[i % colors.length], borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: MathText(spec.lines[i].tex.isNotEmpty ? spec.lines[i].tex : plainToTex(spec.lines[i].plot.label),
                            size: 17, color: p.text),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
          // Sliders
          for (final prm in spec.params)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 8, 0),
              child: Row(children: [
                SizedBox(width: 26, child: Text(prm.name, style: Brand.serif(size: 18, color: p.text).copyWith(fontStyle: FontStyle.italic))),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: p.accent,
                      inactiveTrackColor: p.border,
                      thumbColor: p.accent,
                      overlayColor: p.accent.withValues(alpha: 0.12),
                      trackHeight: 2.5,
                    ),
                    child: Slider(
                      value: prm.value.clamp(prm.min, prm.max),
                      min: prm.min,
                      max: prm.max,
                      onChanged: (v) => setState(() {
                        prm.value = v;
                        _trace = null;
                      }),
                    ),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(prm.value.toStringAsFixed(2), textAlign: TextAlign.end, style: TextStyle(color: p.muted, fontSize: AppText.meta)),
                ),
              ]),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 10),
            child: Text('Pinch to zoom, drag to move, touch the curve to read a point.',
                textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
          ),
        ]),
      ),
    );
  }
}
