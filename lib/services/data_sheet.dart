import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';

/// A table read from a CSV, Excel (.xlsx) or JSON file, with the analysis Telesia's data tools run on it:
/// describe, filter, computed columns, group and aggregate, pivot, sort and charts. Pure Dart, so it can be tested.
class SheetTable {
  SheetTable(this.columns, this.rows);
  final List<String> columns;
  final List<List<dynamic>> rows;

  int col(String name) {
    final n = name.trim().toLowerCase();
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].trim().toLowerCase() == n) return i;
    }
    // Excel letters (A, B, AA) as a fallback.
    if (RegExp(r'^[A-Za-z]{1,2}$').hasMatch(name.trim())) {
      final i = colIndex(name.trim().toUpperCase());
      if (i < columns.length) return i;
    }
    return -1;
  }

  static int colIndex(String letters) {
    var n = 0;
    for (final c in letters.codeUnits) {
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  // ------------------------------------------------------------------ reading

  static SheetTable fromCsv(String text) {
    final t = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final first = t.split('\n').first;
    final delim = [',', ';', '\t', '|'].reduce((a, b) => first.split(b).length > first.split(a).length ? b : a);
    final out = <List<dynamic>>[];
    var row = <dynamic>[];
    final cell = StringBuffer();
    var q = false;
    for (var i = 0; i < t.length; i++) {
      final c = t[i];
      if (q) {
        if (c == '"') {
          if (i + 1 < t.length && t[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            q = false;
          }
        } else {
          cell.write(c);
        }
      } else if (c == '"') {
        q = true;
      } else if (c == delim) {
        row.add(cell.toString());
        cell.clear();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < t.length && t[i + 1] == '\n') i++;
        row.add(cell.toString());
        cell.clear();
        if (row.any((e) => '$e'.isNotEmpty)) out.add(row);
        row = <dynamic>[];
      } else {
        cell.write(c);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      if (row.any((e) => '$e'.isNotEmpty)) out.add(row);
    }
    return _fromGrid(out);
  }

  static SheetTable fromJson(String text) {
    final j = jsonDecode(text);
    final list = j is List ? j : (j is Map && j['rows'] is List ? j['rows'] as List : const []);
    final cols = <String>[];
    for (final r in list) {
      if (r is Map) {
        for (final k in r.keys) {
          if (!cols.contains('$k')) cols.add('$k');
        }
      }
    }
    return SheetTable(cols, [
      for (final r in list)
        if (r is Map) [for (final c in cols) r[c]] else if (r is List) r,
    ]);
  }

  /// The sheets in an .xlsx file (name -> table). Reads values, not formatting; formula cells give their saved result.
  static Map<String, SheetTable> fromXlsx(List<int> bytes) {
    final z = ZipDecoder().decodeBytes(bytes);
    String? read(String name) {
      final f = z.findFile(name);
      if (f == null) return null;
      return utf8.decode(f.content as List<int>, allowMalformed: true);
    }

    final shared = <String>[];
    final ss = read('xl/sharedStrings.xml');
    if (ss != null) {
      for (final si in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(ss)) {
        shared.add(_unxml(RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(si.group(1)!).map((m) => m.group(1)!).join()));
      }
    }
    final rels = <String, String>{};
    final rx = read('xl/_rels/workbook.xml.rels') ?? '';
    for (final m in RegExp(r'<Relationship\b[^>]*>').allMatches(rx)) {
      final id = RegExp(r'Id="([^"]+)"').firstMatch(m.group(0)!)?.group(1);
      final target = RegExp(r'Target="([^"]+)"').firstMatch(m.group(0)!)?.group(1);
      if (id != null && target != null) rels[id] = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    }
    final out = <String, SheetTable>{};
    final wb = read('xl/workbook.xml') ?? '';
    final sheets = RegExp(r'<sheet\b[^>]*>').allMatches(wb).toList();
    var i = 0;
    for (final s in sheets) {
      i++;
      final tag = s.group(0)!;
      final name = _unxml(RegExp(r'name="([^"]*)"').firstMatch(tag)?.group(1) ?? 'Sheet$i');
      final rid = RegExp(r'r:id="([^"]+)"').firstMatch(tag)?.group(1);
      final path = rels[rid] ?? 'xl/worksheets/sheet$i.xml';
      final xml = read(path);
      if (xml == null) continue;
      out[name] = _fromGrid(_sheetGrid(xml, shared));
    }
    if (out.isEmpty) {
      final xml = read('xl/worksheets/sheet1.xml');
      if (xml != null) out['Sheet1'] = _fromGrid(_sheetGrid(xml, shared));
    }
    return out;
  }

  static List<List<dynamic>> _sheetGrid(String xml, List<String> shared) {
    final grid = <List<dynamic>>[];
    for (final rm in RegExp(r'<row\b[^>]*?(?:/>|>(.*?)</row>)', dotAll: true).allMatches(xml)) {
      final body = rm.group(1) ?? '';
      final row = <dynamic>[];
      var next = 0;
      for (final cm in RegExp(r'<c\b([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true).allMatches(body)) {
        final attrs = cm.group(1) ?? '';
        final inner = cm.group(2) ?? '';
        final ref = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(attrs)?.group(1);
        final idx = ref == null ? next : colIndex(ref);
        while (row.length < idx) {
          row.add('');
        }
        final t = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?.group(1) ?? 'n';
        final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(inner)?.group(1);
        dynamic val;
        if (t == 's') {
          final k = int.tryParse(v ?? '');
          val = k != null && k < shared.length ? shared[k] : '';
        } else if (t == 'inlineStr') {
          val = _unxml(RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(inner).map((m) => m.group(1)!).join());
        } else if (t == 'b') {
          val = v == '1' ? 'TRUE' : 'FALSE';
        } else if (t == 'str' || t == 'e') {
          val = _unxml(v ?? '');
        } else {
          val = v == null ? '' : (num.tryParse(v) ?? _unxml(v));
        }
        row.add(val);
        next = idx + 1;
      }
      grid.add(row);
    }
    return grid;
  }

  static String _unxml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// First non-empty row is the header; numbers in text become numbers.
  static SheetTable _fromGrid(List<List<dynamic>> g) {
    final rows = g.where((r) => r.any((c) => '${c ?? ''}'.trim().isNotEmpty)).toList();
    if (rows.isEmpty) return SheetTable([], []);
    final width = rows.map((r) => r.length).fold<int>(0, math.max);
    final head = [for (var i = 0; i < width; i++) i < rows.first.length && '${rows.first[i]}'.trim().isNotEmpty ? '${rows.first[i]}'.trim() : 'Column ${i + 1}'];
    return SheetTable(head, [
      for (final r in rows.skip(1)) [for (var i = 0; i < width; i++) i < r.length ? _value(r[i]) : ''],
    ]);
  }

  static dynamic _value(dynamic v) {
    if (v is num) return v;
    final s = '${v ?? ''}'.trim();
    final c = s.replaceAll(',', '').replaceAll(RegExp(r'^[\$€£]|\s*(USD|SOS|KES|ETB|\$)$'), '');
    if (RegExp(r'^-?\d+(\.\d+)?$').hasMatch(c)) return num.parse(c);
    return s;
  }

  static double? number(dynamic v) {
    if (v is num) return v.toDouble();
    final s = '${v ?? ''}'.replaceAll(',', '').replaceAll(RegExp(r'[^\d.\-]'), '');
    return s.isEmpty ? null : double.tryParse(s);
  }

  // ------------------------------------------------------------------ describing

  String describe({int preview = 8}) {
    final sb = StringBuffer('${rows.length} rows x ${columns.length} columns.\n');
    for (var i = 0; i < columns.length; i++) {
      final vals = rows.map((r) => i < r.length ? r[i] : '').where((v) => '$v'.trim().isNotEmpty).toList();
      final nums = vals.map(number).whereType<double>().toList();
      if (vals.isNotEmpty && nums.length >= vals.length * 0.8) {
        final sum = nums.fold(0.0, (a, b) => a + b);
        nums.sort();
        sb.writeln('- ${columns[i]} (number): sum ${_f(sum)}, average ${_f(sum / nums.length)}, min ${_f(nums.first)}, '
            'max ${_f(nums.last)}, median ${_f(_median(nums))}, ${rows.length - vals.length} empty');
      } else {
        final counts = <String, int>{};
        for (final v in vals) {
          counts['$v'] = (counts['$v'] ?? 0) + 1;
        }
        final top = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(4);
        sb.writeln('- ${columns[i]} (text): ${counts.length} different values${counts.isEmpty ? '' : ', most common ${top.map((e) => '"${e.key}" x${e.value}').join(', ')}'}'
            '${rows.length - vals.length > 0 ? ', ${rows.length - vals.length} empty' : ''}');
      }
    }
    if (rows.isNotEmpty) {
      sb.writeln('\nFirst ${math.min(preview, rows.length)} rows:');
      sb.write(markdown(limit: preview));
    }
    return sb.toString();
  }

  String markdown({int limit = 30}) {
    if (columns.isEmpty) return '(empty)';
    final sb = StringBuffer('| ${columns.join(' | ')} |\n|${List.filled(columns.length, '---').join('|')}|\n');
    for (final r in rows.take(limit)) {
      sb.writeln('| ${[for (var i = 0; i < columns.length; i++) _cell(i < r.length ? r[i] : '')].join(' | ')} |');
    }
    if (rows.length > limit) sb.writeln('(${rows.length - limit} more rows)');
    return sb.toString();
  }

  static String _cell(dynamic v) => v is num ? _f(v.toDouble()) : '$v'.replaceAll('|', '/').replaceAll('\n', ' ');

  static String _f(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }

  static double _median(List<double> sorted) {
    if (sorted.isEmpty) return 0;
    final m = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2;
  }

  // ------------------------------------------------------------------ transforming

  /// Keeps rows matching every filter: {column, op, value}. ops: = != > >= < <= contains not_contains starts_with
  /// in (value is a list) between (value is [low, high]) empty not_empty.
  SheetTable filter(List<Map<String, dynamic>> filters) {
    if (filters.isEmpty) return this;
    final idx = [for (final f in filters) col('${f['column']}')];
    final bad = [for (var i = 0; i < filters.length; i++) if (idx[i] < 0) '${filters[i]['column']}'];
    if (bad.isNotEmpty) throw 'no column called ${bad.join(', ')}. Columns: ${columns.join(', ')}';
    bool ok(List<dynamic> r) {
      for (var i = 0; i < filters.length; i++) {
        final v = idx[i] < r.length ? r[idx[i]] : '';
        final op = '${filters[i]['op'] ?? '='}'.toLowerCase();
        final want = filters[i]['value'];
        final a = number(v), b = number(want);
        final sv = '$v'.toLowerCase().trim(), sw = '${want ?? ''}'.toLowerCase().trim();
        bool pass;
        switch (op) {
          case '=':
          case '==':
          case 'eq':
            pass = a != null && b != null && v is num ? a == b : sv == sw;
            break;
          case '!=':
          case 'ne':
            pass = a != null && b != null && v is num ? a != b : sv != sw;
            break;
          case '>':
            pass = a != null && b != null ? a > b : sv.compareTo(sw) > 0;
            break;
          case '>=':
            pass = a != null && b != null ? a >= b : sv.compareTo(sw) >= 0;
            break;
          case '<':
            pass = a != null && b != null ? a < b : sv.compareTo(sw) < 0;
            break;
          case '<=':
            pass = a != null && b != null ? a <= b : sv.compareTo(sw) <= 0;
            break;
          case 'contains':
            pass = sv.contains(sw);
            break;
          case 'not_contains':
            pass = !sv.contains(sw);
            break;
          case 'starts_with':
            pass = sv.startsWith(sw);
            break;
          case 'in':
            pass = want is List && want.map((e) => '$e'.toLowerCase().trim()).contains(sv);
            break;
          case 'between':
            if (want is List && want.length == 2) {
              final lo = number(want[0]), hi = number(want[1]);
              pass = a != null && lo != null && hi != null ? a >= lo && a <= hi : sv.compareTo('${want[0]}'.toLowerCase()) >= 0 && sv.compareTo('${want[1]}'.toLowerCase()) <= 0;
            } else {
              pass = false;
            }
            break;
          case 'empty':
            pass = sv.isEmpty;
            break;
          case 'not_empty':
            pass = sv.isNotEmpty;
            break;
          default:
            throw 'unknown filter op $op';
        }
        if (!pass) return false;
      }
      return true;
    }

    return SheetTable(columns, rows.where(ok).toList());
  }

  /// Adds a column from a formula over other columns: "Price * Qty", "[Unit price] * [Qty] - Discount", "(Sales - Cost) / Sales * 100".
  SheetTable compute(String name, String formula) {
    final f = _Formula(formula, this);
    return SheetTable([...columns, name], [
      for (final r in rows) [...r, f.eval(r)],
    ]);
  }

  SheetTable select(List<String> names) {
    final idx = [for (final n in names) col(n)];
    final bad = [for (var i = 0; i < names.length; i++) if (idx[i] < 0) names[i]];
    if (bad.isNotEmpty) throw 'no column called ${bad.join(', ')}. Columns: ${columns.join(', ')}';
    return SheetTable([for (final i in idx) columns[i]], [
      for (final r in rows) [for (final i in idx) i < r.length ? r[i] : ''],
    ]);
  }

  SheetTable sort(String column, {bool desc = false}) {
    final i = col(column);
    if (i < 0) throw 'no column called $column. Columns: ${columns.join(', ')}';
    final out = [...rows];
    out.sort((x, y) {
      final a = i < x.length ? x[i] : '', b = i < y.length ? y[i] : '';
      final na = number(a), nb = number(b);
      final c = na != null && nb != null && (a is num || b is num) ? na.compareTo(nb) : '$a'.toLowerCase().compareTo('$b'.toLowerCase());
      return desc ? -c : c;
    });
    return SheetTable(columns, out);
  }

  SheetTable limit(int n) => SheetTable(columns, rows.take(n).toList());

  /// Group by columns and aggregate: [{column, fn}] with fn sum, avg, count, min, max, median, distinct.
  /// The result column is named like "sum of Amount" (or [as]).
  SheetTable group(List<String> by, List<Map<String, dynamic>> aggs) {
    final bi = [for (final b in by) col(b)];
    final bad = [for (var i = 0; i < by.length; i++) if (bi[i] < 0) by[i]];
    if (bad.isNotEmpty) throw 'no column called ${bad.join(', ')}. Columns: ${columns.join(', ')}';
    final ag = aggs.isEmpty ? [<String, dynamic>{'fn': 'count'}] : aggs;
    final ai = [for (final a in ag) a['column'] == null ? -1 : col('${a['column']}')];
    for (var i = 0; i < ag.length; i++) {
      if (ai[i] < 0 && '${ag[i]['fn']}' != 'count') throw 'no column called ${ag[i]['column']}. Columns: ${columns.join(', ')}';
    }
    final groups = <String, List<List<dynamic>>>{};
    final keys = <String, List<dynamic>>{};
    for (final r in rows) {
      final k = [for (final i in bi) i < r.length ? r[i] : ''];
      final ks = jsonEncode(k.map((e) => '$e').toList());
      groups.putIfAbsent(ks, () => []).add(r);
      keys[ks] = k;
    }
    final names = [
      for (var i = 0; i < ag.length; i++)
        '${ag[i]['as'] ?? ''}'.isNotEmpty ? '${ag[i]['as']}' : ('${ag[i]['fn']}' == 'count' && ai[i] < 0 ? 'count' : '${ag[i]['fn']} of ${columns[ai[i]]}')
    ];
    final out = <List<dynamic>>[];
    groups.forEach((ks, rs) {
      out.add([
        ...keys[ks]!,
        for (var i = 0; i < ag.length; i++) _agg('${ag[i]['fn'] ?? 'sum'}', ai[i], rs),
      ]);
    });
    return SheetTable([for (final i in bi) columns[i], ...names], out);
  }

  static dynamic _agg(String fn, int i, List<List<dynamic>> rs) {
    if (fn == 'count') return i < 0 ? rs.length : rs.where((r) => i < r.length && '${r[i]}'.trim().isNotEmpty).length;
    final vals = [for (final r in rs) if (i < r.length) r[i]];
    if (fn == 'distinct') return vals.map((e) => '$e').toSet().length;
    final nums = vals.map(number).whereType<double>().toList();
    if (nums.isEmpty) return 0;
    switch (fn) {
      case 'sum':
        return _r(nums.fold(0.0, (a, b) => a + b));
      case 'avg':
      case 'average':
      case 'mean':
        return _r(nums.fold(0.0, (a, b) => a + b) / nums.length);
      case 'min':
        return nums.reduce(math.min);
      case 'max':
        return nums.reduce(math.max);
      case 'median':
        nums.sort();
        return _r(_median(nums));
    }
    throw 'unknown aggregate $fn (use sum, avg, count, min, max, median, distinct)';
  }

  static double _r(double v) => double.parse(v.toStringAsFixed(4));

  /// Pivot: one row per [rowCol] value, one column per [colCol] value, cells = fn of [valueCol], with totals.
  SheetTable pivot(String rowCol, String colCol, String valueCol, {String fn = 'sum'}) {
    final ri = col(rowCol), ci = col(colCol), vi = col(valueCol);
    for (final (n, i) in [(rowCol, ri), (colCol, ci), (valueCol, vi)]) {
      if (i < 0) throw 'no column called $n. Columns: ${columns.join(', ')}';
    }
    final rk = <String>[], ck = <String>[];
    final cells = <String, List<List<dynamic>>>{};
    for (final r in rows) {
      final a = '${ri < r.length ? r[ri] : ''}', b = '${ci < r.length ? r[ci] : ''}';
      if (!rk.contains(a)) rk.add(a);
      if (!ck.contains(b)) ck.add(b);
      cells.putIfAbsent('$a\u0000$b', () => []).add(r);
    }
    ck.sort();
    final out = <List<dynamic>>[];
    for (final a in rk) {
      final line = <dynamic>[a];
      var total = 0.0;
      for (final b in ck) {
        final v = cells['$a\u0000$b'] == null ? 0 : _agg(fn, vi, cells['$a\u0000$b']!);
        line.add(v);
        total += (v as num).toDouble();
      }
      if (fn == 'sum' || fn == 'count') line.add(_r(total));
      out.add(line);
    }
    final head = [rowCol, ...ck, if (fn == 'sum' || fn == 'count') 'Total'];
    if (fn == 'sum' || fn == 'count') {
      final tot = <dynamic>['Total'];
      for (var j = 1; j < head.length; j++) {
        tot.add(_r(out.fold(0.0, (a, r) => a + (r[j] as num).toDouble())));
      }
      out.add(tot);
    }
    return SheetTable(head, out);
  }

  /// A chart card for the chat from a label column and a value column (first 20 rows).
  String chart(String labelCol, String valueCol, {String type = 'bars', String title = '', String unit = ''}) {
    final li = col(labelCol), vi = col(valueCol);
    if (li < 0 || vi < 0) throw 'chart needs columns that exist. Columns: ${columns.join(', ')}';
    final items = [
      for (final r in rows.take(type == 'line' ? 60 : 20))
        {'label': '${li < r.length ? r[li] : ''}', 'value': number(vi < r.length ? r[vi] : 0) ?? 0},
    ];
    final j = {'type': type, if (title.isNotEmpty) 'title': title, if (unit.isNotEmpty) 'unit': unit, 'items': items};
    return '```diagram\n${jsonEncode(j)}\n```';
  }
}

/// + - * / and brackets over numbers and column names ([Name with spaces] or a bare name).
class _Formula {
  _Formula(this.src, this.t) {
    _tokens = _lex(src);
    _pos = 0;
  }
  final String src;
  final SheetTable t;
  late List<String> _tokens;
  late int _pos;
  List<dynamic> _row = const [];

  static List<String> _lex(String s) {
    final out = <String>[];
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t') {
        i++;
      } else if ('+-*/()'.contains(c)) {
        out.add(c);
        i++;
      } else if (c == '[') {
        final e = s.indexOf(']', i);
        if (e < 0) throw 'formula: missing ]';
        out.add('@${s.substring(i + 1, e)}');
        i = e + 1;
      } else if (RegExp(r'[\d.]').hasMatch(c)) {
        final m = RegExp(r'[\d.]+').matchAsPrefix(s, i)!;
        out.add(m.group(0)!);
        i = m.end;
      } else {
        final m = RegExp(r'[^\s+\-*/()\[\]]+').matchAsPrefix(s, i)!;
        out.add('@${m.group(0)}');
        i = m.end;
      }
    }
    return out;
  }

  double eval(List<dynamic> row) {
    _row = row;
    _pos = 0;
    final v = _expr();
    if (_pos < _tokens.length) throw 'formula: unexpected "${_tokens[_pos]}"';
    return double.parse(v.toStringAsFixed(4));
  }

  double _expr() {
    var a = _term();
    while (_pos < _tokens.length && (_tokens[_pos] == '+' || _tokens[_pos] == '-')) {
      final op = _tokens[_pos++];
      final b = _term();
      a = op == '+' ? a + b : a - b;
    }
    return a;
  }

  double _term() {
    var a = _unary();
    while (_pos < _tokens.length && (_tokens[_pos] == '*' || _tokens[_pos] == '/')) {
      final op = _tokens[_pos++];
      final b = _unary();
      a = op == '*' ? a * b : (b == 0 ? 0 : a / b);
    }
    return a;
  }

  double _unary() {
    if (_pos < _tokens.length && _tokens[_pos] == '-') {
      _pos++;
      return -_unary();
    }
    return _atom();
  }

  double _atom() {
    if (_pos >= _tokens.length) throw 'formula ends too early';
    final tk = _tokens[_pos++];
    if (tk == '(') {
      final v = _expr();
      if (_pos >= _tokens.length || _tokens[_pos] != ')') throw 'formula: missing )';
      _pos++;
      return v;
    }
    if (tk.startsWith('@')) {
      final i = t.col(tk.substring(1));
      if (i < 0) throw 'formula: no column called ${tk.substring(1)}. Columns: ${t.columns.join(', ')}';
      return SheetTable.number(i < _row.length ? _row[i] : 0) ?? 0;
    }
    return double.tryParse(tk) ?? (throw 'formula: bad number $tk');
  }
}
