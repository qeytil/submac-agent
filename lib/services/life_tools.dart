import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'somali_knowledge.dart';

/// Everyday helpers for non-technical users: faith corner (prayer times, Hijri date, Quran, Qibla)
/// and a private money notebook kept on the phone.
class LifeTools {
  static const names = {
    'prayer_times', 'hijri_date', 'quran', 'qibla', 'money_add', 'money_report', 'money_delete',
    // The Somali knowledge library (always sent: see ToolScope.groupOf).
    'somali_knowledge', 'somali_knowledge_read',
  };

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static final List<Map<String, dynamic>> definitions = [
    ...SomaliKnowledge.definitions,
    _fn('prayer_times', 'Prayer times (Fajr, Dhuhr, Asr, Maghrib, Isha, plus sunrise) for a city or coordinates on a date, '
        'with the Hijri date. No login needed.', {
      'city': {'type': 'string', 'description': 'City name, e.g. Mogadishu'},
      'country': {'type': 'string', 'description': 'Country, e.g. Somalia'},
      'latitude': {'type': 'number'},
      'longitude': {'type': 'number'},
      'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
    }),
    _fn('hijri_date', 'Convert a Gregorian date to the Hijri (Islamic) date, with any holiday on that day.', {
      'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
    }),
    _fn('quran', 'Read Quran verses in Arabic with a translation (Somali by default, or English). '
        'Give a surah number and optionally a verse or a range.', {
      'surah': {'type': 'integer', 'description': '1-114'},
      'from_ayah': {'type': 'integer'},
      'to_ayah': {'type': 'integer'},
      'translation': {'type': 'string', 'enum': ['somali', 'english', 'arabic_only']},
    }, ['surah']),
    _fn('qibla', 'Direction of the Qibla (degrees from true north, clockwise) from coordinates.', {
      'latitude': {'type': 'number'},
      'longitude': {'type': 'number'},
    }, ['latitude', 'longitude']),
    _fn('money_add', 'Write an entry in the user\'s private money notebook (kept on the phone): money in (sales, salary) '
        'or money out (expenses, stock, rent), or a debt someone owes. Use whenever the user mentions earning, spending or lending.', {
      'type': {'type': 'string', 'enum': ['in', 'out', 'owed_to_me', 'i_owe']},
      'amount': {'type': 'number'},
      'currency': {'type': 'string', 'description': 'USD, SOS, KES, ETB... default USD'},
      'category': {'type': 'string', 'description': 'Short label: sales, food, transport, rent, stock, salary...'},
      'note': {'type': 'string', 'description': 'Who or what, e.g. "Ahmed, 2 bags of rice"'},
      'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
    }, ['type', 'amount']),
    _fn('money_report', 'Summarise the money notebook: totals in and out, profit, top categories, debts, and the latest entries.', {
      'period': {'type': 'string', 'enum': ['today', 'week', 'month', 'year', 'all']},
    }),
    _fn('money_delete', 'Remove a wrong money notebook entry by its id (from money_report).', {
      'id': {'type': 'string'},
    }, ['id']),
  ];

  static String _today() => DateTime.now().toIso8601String().substring(0, 10);

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    if (SomaliKnowledge.names.contains(name)) return SomaliKnowledge.execute(name, a);
    try {
      switch (name) {
        case 'prayer_times':
          return await _prayer(a);
        case 'hijri_date':
          final d = _dmy((a['date'] ?? '').toString());
          final j = await _get('https://api.aladhan.com/v1/gToH/$d');
          final h = j['data']['hijri'];
          final hol = (h['holidays'] as List? ?? const []).join(', ');
          return 'Hijri: ${h['day']} ${h['month']['en']} ${h['year']} AH (${h['month']['ar']})${hol.isEmpty ? '' : '. Holiday: $hol'}';
        case 'quran':
          return await _quran(a);
        case 'qibla':
          final lat = (a['latitude'] as num).toDouble(), lng = (a['longitude'] as num).toDouble();
          final deg = _qibla(lat, lng);
          return 'Qibla is ${deg.toStringAsFixed(0)}° from true north (${_compass(deg)}). '
              'Face that way using a compass; phone compasses can be off near metal.';
        case 'money_add':
        case 'money_report':
        case 'money_delete':
          return await _money(name, a);
      }
      return 'Error: unknown tool $name';
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<Map<String, dynamic>> _get(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) throw 'the service answered ${r.statusCode}';
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  static String _dmy(String iso) {
    final d = DateTime.tryParse(iso.isEmpty ? _today() : iso) ?? DateTime.now();
    return '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
  }

  static Future<String> _prayer(Map<String, dynamic> a) async {
    final d = _dmy((a['date'] ?? '').toString());
    final lat = a['latitude'], lng = a['longitude'];
    final String url;
    if (lat is num && lng is num) {
      url = 'https://api.aladhan.com/v1/timings/$d?latitude=$lat&longitude=$lng&method=3';
    } else {
      final city = Uri.encodeComponent((a['city'] ?? 'Mogadishu').toString());
      final country = Uri.encodeComponent((a['country'] ?? '').toString());
      url = 'https://api.aladhan.com/v1/timingsByCity/$d?city=$city&country=$country&method=3';
    }
    final j = await _get(url);
    final t = j['data']['timings'] as Map;
    final h = j['data']['date']['hijri'];
    final where = lat is num ? 'those coordinates' : (a['city'] ?? 'Mogadishu').toString();
    return 'Prayer times for $where on ${j['data']['date']['readable']} '
        '(${h['day']} ${h['month']['en']} ${h['year']} AH):\n'
        'Fajr ${t['Fajr']}, Sunrise ${t['Sunrise']}, Dhuhr ${t['Dhuhr']}, Asr ${t['Asr']}, Maghrib ${t['Maghrib']}, Isha ${t['Isha']}.\n'
        '(Muslim World League method, local time.)';
  }

  static Future<String> _quran(Map<String, dynamic> a) async {
    final s = (a['surah'] as num).toInt();
    if (s < 1 || s > 114) return 'Error: surah must be 1 to 114.';
    final tr = (a['translation'] ?? 'somali').toString();
    final ed = tr == 'english' ? 'en.sahih' : 'so.abduh';
    final eds = tr == 'arabic_only' ? 'quran-uthmani' : 'quran-uthmani,$ed';
    final j = await _get('https://api.alquran.cloud/v1/surah/$s/editions/$eds');
    final data = j['data'] as List;
    final ar = data[0];
    final from = ((a['from_ayah'] as num?)?.toInt() ?? 1).clamp(1, 286);
    final to = ((a['to_ayah'] as num?)?.toInt() ?? (a['from_ayah'] != null ? from : 300)).clamp(from, 286);
    final sb = StringBuffer('Surah ${ar['englishName']} (${ar['name']}), ${ar['numberOfAyahs']} verses\n');
    var n = 0;
    for (var i = 0; i < (ar['ayahs'] as List).length; i++) {
      final k = ar['ayahs'][i]['numberInSurah'] as int;
      if (k < from || k > to) continue;
      sb.writeln('\n$k. ${ar['ayahs'][i]['text']}');
      if (data.length > 1) sb.writeln('   ${data[1]['ayahs'][i]['text']}');
      if (++n >= 40) {
        sb.writeln('\n(more verses: ask for the next range)');
        break;
      }
    }
    return sb.toString();
  }

  static double _qibla(double lat, double lng) {
    const kLat = 21.4225 * math.pi / 180, kLng = 39.8262 * math.pi / 180;
    final p = lat * math.pi / 180, l = lng * math.pi / 180;
    final y = math.sin(kLng - l);
    final x = math.cos(p) * math.tan(kLat) - math.sin(p) * math.cos(kLng - l);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static String _compass(double d) {
    const n = ['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'];
    return n[((d + 22.5) % 360 ~/ 45)];
  }

  // ---------------------------------------------------------------- money notebook

  static Future<List<Map<String, dynamic>>> _load(SharedPreferences p) async {
    try {
      return [for (final e in jsonDecode(p.getString('money_book') ?? '[]') as List) Map<String, dynamic>.from(e as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<String> _money(String name, Map<String, dynamic> a) async {
    final p = await SharedPreferences.getInstance();
    final book = await _load(p);
    if (name == 'money_add') {
      final amt = (a['amount'] as num?)?.toDouble();
      if (amt == null || amt <= 0) return 'Error: give a positive amount.';
      final e = {
        'id': 'm${DateTime.now().millisecondsSinceEpoch}',
        'type': (a['type'] ?? 'out').toString(),
        'amount': amt,
        'currency': (a['currency'] ?? 'USD').toString().toUpperCase(),
        'category': (a['category'] ?? '').toString(),
        'note': (a['note'] ?? '').toString(),
        'date': (a['date'] ?? _today()).toString(),
      };
      book.add(e);
      await p.setString('money_book', jsonEncode(book));
      return 'Saved ${e['id']}: ${e['type']} ${_f(amt)} ${e['currency']}${(e['category'] as String).isEmpty ? '' : ' · ${e['category']}'}'
          '${(e['note'] as String).isEmpty ? '' : ' · ${e['note']}'} on ${e['date']}.';
    }
    if (name == 'money_delete') {
      final before = book.length;
      book.removeWhere((e) => e['id'] == a['id']);
      await p.setString('money_book', jsonEncode(book));
      return before == book.length ? 'No entry with that id.' : 'Removed.';
    }
    // Report.
    final period = (a['period'] ?? 'month').toString();
    final now = DateTime.now();
    bool inPeriod(String d) {
      final t = DateTime.tryParse(d);
      if (t == null) return period == 'all';
      switch (period) {
        case 'today':
          return t.year == now.year && t.month == now.month && t.day == now.day;
        case 'week':
          return now.difference(t).inDays < 7;
        case 'month':
          return t.year == now.year && t.month == now.month;
        case 'year':
          return t.year == now.year;
      }
      return true;
    }

    final rows = book.where((e) => inPeriod('${e['date']}')).toList();
    if (book.isEmpty) return 'The money notebook is empty.';
    final byCur = <String, Map<String, double>>{};
    final cats = <String, double>{};
    for (final e in rows) {
      final c = byCur.putIfAbsent('${e['currency']}', () => {'in': 0, 'out': 0, 'owed_to_me': 0, 'i_owe': 0});
      c['${e['type']}'] = (c['${e['type']}'] ?? 0) + (e['amount'] as num).toDouble();
      if (e['type'] == 'out') cats['${e['category']}'] = (cats['${e['category']}'] ?? 0) + (e['amount'] as num).toDouble();
    }
    final sb = StringBuffer('Money notebook, $period (${rows.length} entries):\n');
    byCur.forEach((cur, c) {
      sb.writeln('$cur: in ${_f(c['in']!)}, out ${_f(c['out']!)}, balance ${_f(c['in']! - c['out']!)}'
          '${c['owed_to_me']! > 0 ? ', people owe you ${_f(c['owed_to_me']!)}' : ''}${c['i_owe']! > 0 ? ', you owe ${_f(c['i_owe']!)}' : ''}');
    });
    final top = cats.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
    if (top.isNotEmpty) {
      sb.writeln('Top spending: ${top.take(4).map((e) => '${e.key.isEmpty ? 'other' : e.key} ${_f(e.value)}').join(', ')}');
    }
    sb.writeln('Latest:');
    for (final e in rows.reversed.take(12)) {
      sb.writeln('${e['id']} · ${e['date']} · ${e['type']} ${_f((e['amount'] as num).toDouble())} ${e['currency']} · ${e['category']} ${e['note']}');
    }
    return sb.toString();
  }

  static String _f(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}
