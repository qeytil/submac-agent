import 'dart:math' as m;

import 'math_expr.dart';

/// Exact answers on the phone: arithmetic with percentages, unit conversions and date maths.
/// Pure Dart (no plugins), so it is fast, works offline and is easy to test.
class Calc {
  /// Runs one or more lines (newline or ";" separated) and returns one answer per line.
  static String run(String input, {DateTime? now}) {
    final lines = input.split(RegExp(r'[\n;]')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return 'Error: nothing to calculate.';
    final out = <String>[];
    for (final l in lines.take(30)) {
      out.add(_one(l, now ?? DateTime.now()));
    }
    return out.join('\n');
  }

  static String _one(String raw, DateTime now) {
    try {
      final d = dateMath(raw, now);
      if (d != null) return '$raw → $d';
      final u = convert(raw);
      if (u != null) return '$raw → $u';
      final v = eval(raw);
      return '$raw = ${fmt(v)}';
    } on FormatException catch (e) {
      return '$raw → Error: ${e.message}';
    } catch (e) {
      return '$raw → Error: $e';
    }
  }

  // ---------------------------------------------------------------- arithmetic

  static final _fnWords = RegExp(
      r'^(sin|cos|tan|asin|acos|atan|sinh|cosh|tanh|sqrt|cbrt|abs|ln|log|log2|log10|exp|floor|ceil|round|sign|pi|e|tau)$');

  /// Turns everyday maths ("15% of 2,400", "1200 + 5%", "3 x 4", "2 to the power 8") into a plain expression.
  static String normalize(String s) {
    var t = s.toLowerCase().trim();
    t = t.replaceAll(RegExp(r'^(what is|what\x27s|calculate|compute|how much is)\s+'), '').replaceAll(RegExp(r'[?=]+$'), '').trim();
    // Currency marks and thousands separators.
    t = t.replaceAll(RegExp(r'[$€£¥₦₹]|\b(usd|eur|gbp|kes|sos|shillings?|dollars?)\b'), '');
    while (RegExp(r'\d,\d{3}(?!\d)').hasMatch(t)) {
      t = t.replaceAllMapped(RegExp(r'(\d),(\d{3})(?!\d)'), (x) => '${x[1]}${x[2]}');
    }
    t = t
        .replaceAll(RegExp(r'\bdivided by\b'), '/')
        .replaceAll(RegExp(r'\b(times|multiplied by)\b'), '*')
        .replaceAll(RegExp(r'\bplus\b'), '+')
        .replaceAll(RegExp(r'\bminus\b'), '-')
        .replaceAll(RegExp(r'\b(to the power of|to the power|power)\b'), '^')
        .replaceAll(RegExp(r'\bsquared\b'), '^2')
        .replaceAll(RegExp(r'\bcubed\b'), '^3')
        .replaceAll(RegExp(r'\bsquare root of\b'), 'sqrt')
        .replaceAll(RegExp(r'\bmod\b'), '%%');
    // Scientific notation: 2e5 -> 2E5 (the engine reads a lone e as Euler's number).
    t = t.replaceAllMapped(RegExp(r'(\d)e([+-]?\d)'), (x) => '${x[1]}E${x[2]}');
    // "3 x 4" -> 3 * 4
    t = t.replaceAllMapped(RegExp(r'(\d|\))\s*[x×]\s*(?=[\d(])'), (x) => '${x[1]}*');
    // Percentages.
    const n = r'(\d+(?:\.\d+)?)';
    t = t.replaceAllMapped(RegExp('$n\\s*%\\s*of\\s*$n'), (x) => '(${x[1]}/100*${x[2]})');
    t = t.replaceAllMapped(RegExp('$n\\s*([+-])\\s*$n\\s*%(?!%)'), (x) => '(${x[1]}*(1${x[2]}${x[3]}/100))');
    t = t.replaceAllMapped(RegExp('$n\\s*%(?!%)'), (x) => '(${x[1]}/100)');
    return t.trim();
  }

  static double eval(String s) {
    final t = normalize(s);
    if (t.isEmpty) throw const FormatException('nothing to calculate');
    for (final w in RegExp(r'[a-z_]+').allMatches(t).map((x) => x[0]!)) {
      if (!_fnWords.hasMatch(w)) throw FormatException('"$w" is not a number. Use numbers only, or a unit/date form');
    }
    final v = _evalMod(t);
    if (v.isNaN) throw const FormatException('not a valid number (check brackets or division by zero)');
    if (v.isInfinite) throw const FormatException('the result is infinite (division by zero?)');
    return v;
  }

  // "a %% b" is the remainder; everything else goes to the shared expression engine.
  static double _evalMod(String t) {
    final i = t.indexOf('%%');
    if (i < 0) return parseExpr(t).eval({});
    final a = _evalMod(t.substring(0, i).trim()), b = _evalMod(t.substring(i + 2).trim());
    return a % b;
  }

  /// A clean number: up to 10 significant digits, thousands separated, no trailing zeros.
  static String fmt(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return _group(v.round().toString());
    final a = v.abs();
    if (a != 0 && (a < 1e-6 || a >= 1e15)) return v.toStringAsExponential(6).replaceAll(RegExp(r'\.?0+e'), 'e');
    var s = v.toStringAsPrecision(10);
    if (s.contains('e')) s = v.toStringAsFixed(10);
    if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    final parts = s.split('.');
    return parts.length == 2 ? '${_group(parts[0])}.${parts[1]}' : _group(parts[0]);
  }

  static String _group(String s) {
    final neg = s.startsWith('-');
    final d = neg ? s.substring(1) : s;
    if (d.length < 5) return s;
    final b = StringBuffer();
    for (var i = 0; i < d.length; i++) {
      if (i > 0 && (d.length - i) % 3 == 0) b.write(',');
      b.write(d[i]);
    }
    return '${neg ? '-' : ''}$b';
  }

  // ---------------------------------------------------------------- units

  /// unit -> (dimension, factor to the base unit of that dimension).
  static final Map<String, (String, double)> _units = {
    // length (metre)
    'mm': ('length', 0.001), 'millimetre': ('length', 0.001), 'millimeter': ('length', 0.001),
    'cm': ('length', 0.01), 'centimetre': ('length', 0.01), 'centimeter': ('length', 0.01),
    'm': ('length', 1), 'metre': ('length', 1), 'meter': ('length', 1),
    'km': ('length', 1000), 'kilometre': ('length', 1000), 'kilometer': ('length', 1000),
    'in': ('length', 0.0254), 'inch': ('length', 0.0254), 'inches': ('length', 0.0254),
    'ft': ('length', 0.3048), 'foot': ('length', 0.3048), 'feet': ('length', 0.3048),
    'yd': ('length', 0.9144), 'yard': ('length', 0.9144),
    'mi': ('length', 1609.344), 'mile': ('length', 1609.344),
    'nmi': ('length', 1852), 'nautical mile': ('length', 1852),
    // mass (kilogram)
    'mg': ('mass', 1e-6), 'g': ('mass', 0.001), 'gram': ('mass', 0.001), 'kg': ('mass', 1), 'kilo': ('mass', 1), 'kilogram': ('mass', 1),
    't': ('mass', 1000), 'tonne': ('mass', 1000), 'ton': ('mass', 1000), 'metric ton': ('mass', 1000),
    'oz': ('mass', 0.028349523125), 'ounce': ('mass', 0.028349523125),
    'lb': ('mass', 0.45359237), 'lbs': ('mass', 0.45359237), 'pound': ('mass', 0.45359237),
    'st': ('mass', 6.35029318), 'stone': ('mass', 6.35029318),
    'quintal': ('mass', 100),
    // volume (litre)
    'ml': ('volume', 0.001), 'millilitre': ('volume', 0.001), 'milliliter': ('volume', 0.001),
    'cl': ('volume', 0.01), 'l': ('volume', 1), 'litre': ('volume', 1), 'liter': ('volume', 1), 'ltr': ('volume', 1),
    'm3': ('volume', 1000), 'cubic metre': ('volume', 1000), 'cubic meter': ('volume', 1000),
    'gal': ('volume', 3.785411784), 'gallon': ('volume', 3.785411784), 'us gallon': ('volume', 3.785411784),
    'uk gallon': ('volume', 4.54609), 'imperial gallon': ('volume', 4.54609),
    'qt': ('volume', 0.946352946), 'quart': ('volume', 0.946352946), 'pt': ('volume', 0.473176473), 'pint': ('volume', 0.473176473),
    'cup': ('volume', 0.2365882365), 'fl oz': ('volume', 0.0295735295625), 'floz': ('volume', 0.0295735295625),
    'tbsp': ('volume', 0.01478676478125), 'tablespoon': ('volume', 0.01478676478125),
    'tsp': ('volume', 0.00492892159375), 'teaspoon': ('volume', 0.00492892159375),
    'barrel': ('volume', 158.987294928),
    // area (square metre)
    'mm2': ('area', 1e-6), 'cm2': ('area', 1e-4), 'm2': ('area', 1), 'sqm': ('area', 1), 'square metre': ('area', 1), 'square meter': ('area', 1),
    'km2': ('area', 1e6), 'square kilometre': ('area', 1e6), 'square kilometer': ('area', 1e6),
    'ha': ('area', 1e4), 'hectare': ('area', 1e4), 'acre': ('area', 4046.8564224),
    'ft2': ('area', 0.09290304), 'sqft': ('area', 0.09290304), 'square foot': ('area', 0.09290304), 'square feet': ('area', 0.09290304),
    'in2': ('area', 0.00064516), 'yd2': ('area', 0.83612736), 'mi2': ('area', 2589988.110336), 'square mile': ('area', 2589988.110336),
    // speed (metre per second)
    'm/s': ('speed', 1), 'km/h': ('speed', 1 / 3.6), 'kmh': ('speed', 1 / 3.6), 'kph': ('speed', 1 / 3.6),
    'mph': ('speed', 0.44704), 'knot': ('speed', 1852 / 3600), 'kn': ('speed', 1852 / 3600),
    // time (second)
    'ms': ('time', 0.001), 's': ('time', 1), 'sec': ('time', 1), 'second': ('time', 1),
    'min': ('time', 60), 'minute': ('time', 60), 'h': ('time', 3600), 'hr': ('time', 3600), 'hour': ('time', 3600),
    'day': ('time', 86400), 'week': ('time', 604800), 'month': ('time', 2629746), 'year': ('time', 31556952),
    // data (byte)
    'bit': ('data', 0.125), 'byte': ('data', 1), 'kb': ('data', 1e3), 'mb': ('data', 1e6), 'gb': ('data', 1e9), 'tb': ('data', 1e12),
    'kib': ('data', 1024), 'mib': ('data', 1048576), 'gib': ('data', 1073741824),
    // energy (joule)
    'j': ('energy', 1), 'joule': ('energy', 1), 'kj': ('energy', 1000), 'cal': ('energy', 4.184), 'kcal': ('energy', 4184),
    'calorie': ('energy', 4184), 'wh': ('energy', 3600), 'kwh': ('energy', 3.6e6),
    // power (watt)
    'w': ('power', 1), 'watt': ('power', 1), 'kw': ('power', 1000), 'hp': ('power', 745.69987158227), 'horsepower': ('power', 745.69987158227),
    // pressure (pascal)
    'pa': ('pressure', 1), 'kpa': ('pressure', 1000), 'bar': ('pressure', 1e5), 'psi': ('pressure', 6894.757293168), 'atm': ('pressure', 101325),
    // fuel economy handled as plain units of distance per volume
    'km/l': ('economy', 1), 'mpg': ('economy', 0.425143707), 'uk mpg': ('economy', 0.354006189),
  };

  static const _temps = {
    'c': 'c', '°c': 'c', 'celsius': 'c', 'centigrade': 'c', 'degc': 'c',
    'f': 'f', '°f': 'f', 'fahrenheit': 'f', 'degf': 'f',
    'k': 'k', 'kelvin': 'k',
  };

  static String _unitKey(String u) {
    var k = u.toLowerCase().trim().replaceAll('²', '2').replaceAll('³', '3').replaceAll(RegExp(r'\s+'), ' ');
    final sq = RegExp(r'^(?:sq|square) (m|km|ft|in|yd|mi|cm|mm)$').firstMatch(k);
    if (sq != null) k = '${sq[1]}2';
    k = k.replaceFirst(RegExp(r'^degrees? '), '°');
    return k;
  }

  static (String, double)? _unit(String u) {
    final k = _unitKey(u);
    if (_units.containsKey(k)) return _units[k];
    if (k.endsWith('es') && _units.containsKey(k.substring(0, k.length - 2))) return _units[k.substring(0, k.length - 2)];
    if (k.endsWith('s') && _units.containsKey(k.substring(0, k.length - 1))) return _units[k.substring(0, k.length - 1)];
    return null;
  }

  static String? _temp(String u) {
    final k = _unitKey(u);
    return _temps[k] ?? _temps[k.replaceAll('°', '')];
  }

  /// "5 km to miles", "30 c in f", "2 acres to m2". Null when the line is not a conversion.
  static String? convert(String raw) {
    final mm = RegExp(r'^\s*(-?[\d.,]+(?:e-?\d+)?)\s*([a-zA-Z°µ²³/][a-zA-Z°µ²³/0-9 .]*?)\s+(?:to|in|into|->|=)\s+([a-zA-Z°µ²³/][a-zA-Z°µ²³/0-9 .]*?)\s*\??$',
            caseSensitive: false)
        .firstMatch(raw);
    if (mm == null) return null;
    final v = double.tryParse(mm[1]!.replaceAll(',', ''));
    if (v == null) return null;
    final from = mm[2]!.trim(), to = mm[3]!.trim();
    final tf = _temp(from), tt = _temp(to);
    if (tf != null && tt != null) {
      final c = switch (tf) { 'c' => v, 'f' => (v - 32) * 5 / 9, _ => v - 273.15 };
      final r = switch (tt) { 'c' => c, 'f' => c * 9 / 5 + 32, _ => c + 273.15 };
      return '${fmt(_round(r))} ${tt == 'k' ? 'K' : '°${tt.toUpperCase()}'}';
    }
    final a = _unit(from), b = _unit(to);
    if (a == null || b == null) {
      if (a == null && b == null) return null;
      throw FormatException('unknown unit "${a == null ? from : to}"');
    }
    if (a.$1 != b.$1) throw FormatException('cannot turn ${a.$1} ($from) into ${b.$1} ($to)');
    final r = v * a.$2 / b.$2;
    return '${fmt(_round(r))} $to';
  }

  static double _round(double v) {
    if (v == 0) return 0;
    final mag = (m.log(v.abs()) / m.ln10).floor();
    final p = m.pow(10, 9 - mag).toDouble();
    return (v * p).round() / p;
  }

  // ---------------------------------------------------------------- dates

  static const _wd = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const _mo = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  static const _d = r'(\d{4}-\d{1,2}-\d{1,2}|today|tomorrow|yesterday|now)';

  static DateTime _date(String s, DateTime now) {
    final t = DateTime(now.year, now.month, now.day);
    switch (s.toLowerCase()) {
      case 'today':
      case 'now':
        return t;
      case 'tomorrow':
        return t.add(const Duration(days: 1));
      case 'yesterday':
        return t.subtract(const Duration(days: 1));
    }
    final p = s.split('-').map(int.parse).toList();
    if (p[1] < 1 || p[1] > 12 || p[2] < 1 || p[2] > 31) throw FormatException('"$s" is not a real date');
    final d = DateTime(p[0], p[1], p[2]);
    if (d.month != p[1]) throw FormatException('"$s" is not a real date');
    return d;
  }

  static String day(DateTime d) => '${_wd[d.weekday - 1]} ${d.day} ${_mo[d.month - 1]} ${d.year}';

  static int _days(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  static DateTime _addMonths(DateTime d, int n) {
    final y = d.year + ((d.month - 1 + n) / 12).floor();
    final mth = (d.month - 1 + n) % 12 + 1;
    final last = DateTime(y, mth + 1, 0).day;
    return DateTime(y, mth, d.day > last ? last : d.day);
  }

  /// Whole years, months and days from [a] to [b] (b >= a).
  static (int, int, int) _ymd(DateTime a, DateTime b) {
    var months = (b.year - a.year) * 12 + b.month - a.month;
    if (_addMonths(a, months).isAfter(b)) months--;
    final rest = _days(_addMonths(a, months), b);
    return (months ~/ 12, months % 12, rest);
  }

  static String _span(int days) {
    final w = days.abs() ~/ 7, r = days.abs() % 7;
    return w == 0 ? '' : ' ($w week${w == 1 ? '' : 's'}${r == 0 ? '' : ' $r day${r == 1 ? '' : 's'}'})';
  }

  /// Date maths. Null when the line is not about dates.
  static String? dateMath(String raw, DateTime now) {
    final s = raw.toLowerCase().trim().replaceAll(RegExp(r'[?]$'), '');
    RegExpMatch? x;
    // days between two dates
    x = RegExp('^(?:how many )?(?:days|time)?\\s*(?:from|between)\\s+$_d\\s+(?:to|and|until|till)\\s+$_d\$').firstMatch(s);
    if (x != null) {
      final a = _date(x[1]!, now), b = _date(x[2]!, now);
      final n = _days(a, b);
      final (yy, mm, dd) = n >= 0 ? _ymd(a, b) : _ymd(b, a);
      final ymd = [if (yy > 0) '$yy year${yy == 1 ? '' : 's'}', if (mm > 0) '$mm month${mm == 1 ? '' : 's'}', if (dd > 0 || (yy == 0 && mm == 0)) '$dd day${dd == 1 ? '' : 's'}'];
      return '$n day${n.abs() == 1 ? '' : 's'}${_span(n)}; that is ${ymd.join(', ')} (${day(a)} → ${day(b)})';
    }
    // days until / since a date
    x = RegExp('^(?:how many )?days?\\s+(until|till|to|since|ago|from)\\s+$_d\$').firstMatch(s);
    if (x != null) {
      final t = _date('today', now), d = _date(x[2]!, now);
      final n = _days(t, d);
      return n >= 0 ? '$n day${n == 1 ? '' : 's'}${_span(n)} from today until ${day(d)}' : '${-n} day${n == -1 ? '' : 's'}${_span(n)} since ${day(d)}';
    }
    // date plus/minus a span
    x = RegExp('^$_d\\s*([+-]|plus|minus|after|before)\\s*(\\d+)\\s*(days?|weeks?|months?|years?)\$').firstMatch(s) ??
        RegExp('^(\\d+)\\s*(days?|weeks?|months?|years?)\\s+(after|before|from)\\s+$_d\$').firstMatch(s);
    if (x != null) {
      late DateTime base;
      late int n;
      late String unit;
      late bool minus;
      if (RegExp(r'^\d+$').hasMatch(x[1]!)) {
        n = int.parse(x[1]!);
        unit = x[2]!;
        minus = x[3] == 'before';
        base = _date(x[4]!, now);
      } else {
        base = _date(x[1]!, now);
        minus = x[2] == '-' || x[2] == 'minus' || x[2] == 'before';
        n = int.parse(x[3]!);
        unit = x[4]!;
      }
      if (minus) n = -n;
      final r = unit.startsWith('day')
          ? DateTime(base.year, base.month, base.day + n)
          : unit.startsWith('week')
              ? DateTime(base.year, base.month, base.day + 7 * n)
              : unit.startsWith('month')
                  ? _addMonths(base, n)
                  : _addMonths(base, 12 * n);
      return '${day(r)} (${r.year}-${_pad2(r.month)}-${_pad2(r.day)})';
    }
    // weekday of a date
    x = RegExp('^(?:weekday|day of week|what day(?: of the week)? is|which day is)\\s*(?:of\\s+)?$_d\$').firstMatch(s);
    if (x != null) return day(_date(x[1]!, now));
    // age from a birth date
    x = RegExp('^age\\s*(?:of|born|from)?\\s*$_d(?:\\s+(?:on|at)\\s+$_d)?\$').firstMatch(s);
    if (x != null) {
      final b = _date(x[1]!, now), at = x[2] == null ? _date('today', now) : _date(x[2]!, now);
      if (at.isBefore(b)) throw const FormatException('the birth date is after the other date');
      final (yy, mm, dd) = _ymd(b, at);
      return '$yy years, $mm months and $dd days old on ${day(at)}';
    }
    return null;
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}

/// The `calculate` agent tool: exact maths instead of guessing.
class CalcTools {
  static const names = {'calculate'};

  static final List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'calculate',
        'description': 'Exact maths on the phone; use it instead of mental maths for any number the user relies on. '
            'One item per line: "1250*12 - 15% of 3000", "2400 + 5%", "5 km to miles", "30 c to f", "2 acres to m2", '
            '"days from 2026-01-01 to 2026-03-15", "2026-10-20 + 90 days", "days until 2027-03-01", "weekday 2026-12-25", "age 1990-05-01". '
            'Dates as YYYY-MM-DD (or today).',
        'parameters': {
          'type': 'object',
          'properties': {
            'expression': {'type': 'string'},
          },
          'required': ['expression'],
        },
      },
    },
  ];

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    final e = '${a['expression'] ?? a['expr'] ?? a['input'] ?? ''}';
    return Calc.run(e);
  }
}
