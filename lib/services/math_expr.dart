import 'dart:math' as m;

/// A tiny, fast math expression engine for on-phone graphs.
/// Understands: + - * / ^, brackets, implicit multiplication (2x, 3sin(x), (x+1)(x-1), 2pi),
/// functions (sin cos tan asin acos atan sinh cosh tanh sqrt cbrt abs ln log log2 exp floor ceil round sign),
/// constants pi, e, tau, and any single-letter or named variable (x, y, t, r, theta/θ, a, b...).
typedef Env = Map<String, double>;

abstract class Expr {
  double eval(Env env);
}

class _Num extends Expr {
  final double v;
  _Num(this.v);
  @override
  double eval(Env env) => v;
}

class _Var extends Expr {
  final String name;
  _Var(this.name);
  @override
  double eval(Env env) => env[name] ?? double.nan;
}

class _Neg extends Expr {
  final Expr a;
  _Neg(this.a);
  @override
  double eval(Env env) => -a.eval(env);
}

class _Bin extends Expr {
  final String op;
  final Expr a, b;
  _Bin(this.op, this.a, this.b);
  @override
  double eval(Env env) {
    final x = a.eval(env), y = b.eval(env);
    switch (op) {
      case '+':
        return x + y;
      case '-':
        return x - y;
      case '*':
        return x * y;
      case '/':
        return x / y;
      default:
        // Real cube roots and friends for negative bases with odd-denominator exponents.
        if (x < 0 && y != y.roundToDouble()) {
          final inv = 1 / y;
          if ((inv - inv.round()).abs() < 1e-9 && inv.round().isOdd) return -m.pow(-x, y).toDouble();
        }
        return m.pow(x, y).toDouble();
    }
  }
}

class _Fn extends Expr {
  final String f;
  final Expr a;
  _Fn(this.f, this.a);
  @override
  double eval(Env env) {
    final x = a.eval(env);
    switch (f) {
      case 'sin':
        return m.sin(x);
      case 'cos':
        return m.cos(x);
      case 'tan':
        return m.tan(x);
      case 'cot':
        return 1 / m.tan(x);
      case 'sec':
        return 1 / m.cos(x);
      case 'csc':
        return 1 / m.sin(x);
      case 'asin':
      case 'arcsin':
        return m.asin(x);
      case 'acos':
      case 'arccos':
        return m.acos(x);
      case 'atan':
      case 'arctan':
        return m.atan(x);
      case 'sinh':
        return (m.exp(x) - m.exp(-x)) / 2;
      case 'cosh':
        return (m.exp(x) + m.exp(-x)) / 2;
      case 'tanh':
        final e2 = m.exp(2 * x);
        return (e2 - 1) / (e2 + 1);
      case 'sqrt':
        return m.sqrt(x);
      case 'cbrt':
        return x < 0 ? -m.pow(-x, 1 / 3).toDouble() : m.pow(x, 1 / 3).toDouble();
      case 'abs':
        return x.abs();
      case 'ln':
        return m.log(x);
      case 'log':
      case 'log10':
        return m.log(x) / m.ln10;
      case 'log2':
        return m.log(x) / m.ln2;
      case 'exp':
        return m.exp(x);
      case 'floor':
        return x.floorToDouble();
      case 'ceil':
        return x.ceilToDouble();
      case 'round':
        return x.roundToDouble();
      case 'sign':
      case 'sgn':
        return x.sign;
    }
    return double.nan;
  }
}

const _fns = {
  'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'asin', 'acos', 'atan', 'arcsin', 'arccos', 'arctan',
  'sinh', 'cosh', 'tanh', 'sqrt', 'cbrt', 'abs', 'ln', 'log', 'log10', 'log2', 'exp', 'floor', 'ceil', 'round', 'sign', 'sgn',
};
const _consts = {'pi': m.pi, 'e': m.e, 'tau': 2 * m.pi};
const _words = {'theta', 'phi', 'alpha', 'beta', 'pi', 'tau'};

class MathParseError implements Exception {
  final String msg;
  MathParseError(this.msg);
  @override
  String toString() => msg;
}

/// Turns LaTeX-ish or typed input into the plain form the parser reads.
String normalizeMath(String s) {
  var t = s.trim();
  t = t
      .replaceAll('\\left', '')
      .replaceAll('\\right', '')
      .replaceAll('\\cdot', '*')
      .replaceAll('\\times', '*')
      .replaceAll('·', '*')
      .replaceAll('×', '*')
      .replaceAll('−', '-')
      .replaceAll('÷', '/')
      .replaceAll('θ', 'theta')
      .replaceAll('\\theta', 'theta')
      .replaceAll('φ', 'phi')
      .replaceAll('\\phi', 'phi')
      .replaceAll('π', 'pi')
      .replaceAll('\\pi', 'pi')
      .replaceAll('²', '^2')
      .replaceAll('³', '^3')
      .replaceAll('√', 'sqrt');
  // \frac{a}{b} -> (a)/(b) ; \sqrt{a} -> sqrt(a)
  final frac = RegExp(r'\\frac\{([^{}]*)\}\{([^{}]*)\}');
  while (frac.hasMatch(t)) {
    t = t.replaceAllMapped(frac, (mm) => '(${mm.group(1)})/(${mm.group(2)})');
  }
  t = t.replaceAllMapped(RegExp(r'\\sqrt\{([^{}]*)\}'), (mm) => 'sqrt(${mm.group(1)})');
  t = t.replaceAll(RegExp(r'\\(?=[a-z])'), '');
  t = t.replaceAll('{', '(').replaceAll('}', ')');
  t = t.replaceAll('**', '^');
  return t;
}

class _P {
  final String s;
  int i = 0;
  _P(this.s);

  void ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
  }

  String? peek() {
    ws();
    return i < s.length ? s[i] : null;
  }

  Expr parse() {
    final e = expr();
    ws();
    if (i < s.length) throw MathParseError('Unexpected "${s[i]}"');
    return e;
  }

  Expr expr() {
    var a = term();
    while (true) {
      final c = peek();
      if (c == '+' || c == '-') {
        i++;
        a = _Bin(c!, a, term());
      } else {
        return a;
      }
    }
  }

  bool _startsFactor(String? c) =>
      c != null && (c == '(' || c == '[' || c == '|' || RegExp(r'[0-9.a-zA-Z_]').hasMatch(c));

  Expr term() {
    var a = unary();
    while (true) {
      final c = peek();
      if (c == '*' || c == '/') {
        i++;
        a = _Bin(c!, a, unary());
      } else if (_startsFactor(c) && c != '|') {
        a = _Bin('*', a, unary()); // implicit multiplication
      } else {
        return a;
      }
    }
  }

  Expr unary() {
    final c = peek();
    if (c == '-') {
      i++;
      return _Neg(unary());
    }
    if (c == '+') {
      i++;
      return unary();
    }
    return power();
  }

  Expr power() {
    final base = postfix();
    if (peek() == '^') {
      i++;
      return _Bin('^', base, unary()); // right-associative, allows 2^-x
    }
    return base;
  }

  /// sin(x)^2 means (sin x)^2, so a bracketed argument is just the bracket; sin x^2 means sin(x^2).
  Expr _fnArg() {
    final c = peek();
    if (c == '(' || c == '[') return atom();
    return power();
  }

  Expr postfix() {
    var a = atom();
    while (peek() == '!') {
      i++;
      final inner = a;
      a = _Fact(inner);
    }
    return a;
  }

  Expr atom() {
    final c = peek();
    if (c == null) throw MathParseError('Unexpected end');
    if (c == '(' || c == '[') {
      i++;
      final e = expr();
      final close = peek();
      if (close == ')' || close == ']') i++;
      return e;
    }
    if (c == '|') {
      i++;
      final e = expr();
      if (peek() == '|') i++;
      return _Fn('abs', e);
    }
    if (RegExp(r'[0-9.]').hasMatch(c)) {
      final st = i;
      while (i < s.length && RegExp(r'[0-9.]').hasMatch(s[i])) {
        i++;
      }
      if (i < s.length && (s[i] == 'E') && i + 1 < s.length && RegExp(r'[-+0-9]').hasMatch(s[i + 1])) {
        i += 2;
        while (i < s.length && RegExp(r'[0-9]').hasMatch(s[i])) {
          i++;
        }
      }
      return _Num(double.parse(s.substring(st, i)));
    }
    if (RegExp(r'[a-zA-Z_]').hasMatch(c)) {
      final st = i;
      while (i < s.length && RegExp(r'[a-zA-Z0-9]').hasMatch(s[i])) {
        i++;
      }
      final word = s.substring(st, i);
      // A function name at the start ("sin", "sinx", "log2")? Take the longest.
      String? fn;
      for (final f in _fns) {
        if (word.startsWith(f) && (fn == null || f.length > fn.length)) fn = f;
      }
      if (fn != null) {
        i = st + fn.length;
        if (fn == 'log' && peek() == '_') {
          i++;
          final base = atom();
          final arg = _fnArg();
          return _Bin('/', _Fn('ln', arg), _Fn('ln', base));
        }
        return _Fn(fn == 'log10' ? 'log' : fn, _fnArg());
      }
      // Named words: theta, phi, alpha, beta, pi, tau.
      String? w;
      for (final k in _words) {
        if (word.startsWith(k) && (w == null || k.length > w.length)) w = k;
      }
      if (w != null) {
        i = st + w.length;
        return _consts.containsKey(w) ? _Num(_consts[w]!) : _Var(w);
      }
      // Otherwise one letter is one variable; the rest multiplies ("xy" = x*y, "x2" = x*2).
      i = st + 1;
      final v = word[0];
      if (v == 'e') return _Num(m.e);
      return _Var(v);
    }
    throw MathParseError('Unexpected "$c"');
  }
}

class _Fact extends Expr {
  final Expr a;
  _Fact(this.a);
  @override
  double eval(Env env) {
    final n = a.eval(env);
    if (n < 0 || n > 170) return double.nan;
    var r = 1.0;
    for (var k = 2; k <= n.round(); k++) {
      r *= k;
    }
    return r;
  }
}

Expr parseExpr(String s) => _P(normalizeMath(s)).parse();

/// What kind of curve a line describes.
enum PlotKind { explicit, explicitX, implicit, polar, parametric, point }

class Plot {
  final PlotKind kind;
  final Expr f; // y=f(x) | x=f(y) | F(x,y) | r=f(θ) | x(t)
  final Expr? g; // y(t) for parametric
  final double t0, t1;
  final String label;
  Plot(this.kind, this.f, {this.g, this.t0 = 0, this.t1 = 2 * m.pi, this.label = ''});

  Set<String> get vars {
    final out = <String>{};
    void walk(Expr e) {
      if (e is _Var) out.add(e.name);
      if (e is _Neg) walk(e.a);
      if (e is _Bin) {
        walk(e.a);
        walk(e.b);
      }
      if (e is _Fn) walk(e.a);
      if (e is _Fact) walk(e.a);
    }

    walk(f);
    if (g != null) walk(g!);
    return out;
  }
}

/// Reads one plot line: "y = x^3 - 3x", "x^2 + y^2 = 25", "r = 4cos(4θ)", "x=cos(t), y=sin(t)", "sin(x)".
Plot parsePlot(String line, {double? t0, double? t1}) {
  final raw = normalizeMath(line);
  // Parametric "x = ..., y = ..."
  final pm = RegExp(r'^\s*\(?\s*x\s*(?:\(t\))?\s*=\s*(.+?)\s*[,;]\s*y\s*(?:\(t\))?\s*=\s*(.+?)\s*\)?\s*$').firstMatch(raw);
  if (pm != null) {
    return Plot(PlotKind.parametric, _P(pm.group(1)!).parse(), g: _P(pm.group(2)!).parse(), t0: t0 ?? 0, t1: t1 ?? 2 * m.pi, label: line);
  }
  final parts = raw.split('=');
  if (parts.length == 1) return Plot(PlotKind.explicit, _P(raw).parse(), label: line);
  final lhs = parts.first.trim();
  final rhs = parts.sublist(1).join('=').trim();
  if (RegExp(r'^(y|f\(x\)|[a-z]\(x\))$').hasMatch(lhs)) return Plot(PlotKind.explicit, _P(rhs).parse(), label: line);
  if (lhs == 'r' || lhs == 'r(theta)') {
    return Plot(PlotKind.polar, _P(rhs).parse(), t0: t0 ?? 0, t1: t1 ?? 2 * m.pi, label: line);
  }
  if (lhs == 'x' && !RegExp(r'(?<![a-z])x(?![a-z])').hasMatch(rhs)) return Plot(PlotKind.explicitX, _P(rhs).parse(), label: line);
  if (rhs == 'y' || RegExp(r'^[a-z]\(x\)$').hasMatch(rhs)) return Plot(PlotKind.explicit, _P(lhs).parse(), label: line);
  // Anything else with x and y is an implicit curve F(x, y) = 0.
  return Plot(PlotKind.implicit, _Bin('-', _P(lhs).parse(), _P(rhs).parse()), label: line);
}
