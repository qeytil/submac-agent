import 'dart:convert';
import 'dart:io';

import 'package:agent/services/health_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('health');
    HealthTools.dirOverride = tmp.path;
    HealthTools.now = () => DateTime(2026, 10, 21, 9, 30);
  });
  tearDown(() async {
    HealthTools.dirOverride = null;
    HealthTools.now = DateTime.now;
    await tmp.delete(recursive: true);
  });

  Future<String> run(String name, Map<String, dynamic> a) => HealthTools.execute(name, a);

  group('Danger-sign check', () {
    test('a child who cannot drink is an emergency, with the ambulance number', () async {
      final r = await run('health_check', {'who': 'child', 'age_months': 18, 'signs': ['cannot_drink', 'mild_fever']});
      expect(r, startsWith('LEVEL: EMERGENCY'));
      expect(r, contains('999'));
    });
    test('fast breathing uses the WHO cut-off for the age', () async {
      expect(await run('health_check', {'who': 'baby', 'age_months': 8, 'breaths_per_min': 52}), startsWith('LEVEL: URGENT'));
      expect(await run('health_check', {'who': 'child', 'age_months': 30, 'breaths_per_min': 36}), startsWith('LEVEL: HOME CARE'));
    });
    test('any fever in a baby under 2 months is an emergency', () async {
      expect(await run('health_check', {'who': 'newborn', 'age_months': 1, 'temp_c': 37.8}), startsWith('LEVEL: EMERGENCY'));
    });
    test('high blood pressure in pregnancy is urgent; severe is an emergency', () async {
      expect(await run('health_check', {'who': 'pregnant', 'bp': '145/92'}), startsWith('LEVEL: URGENT'));
      expect(await run('health_check', {'who': 'pregnant', 'bp': '165/112'}), startsWith('LEVEL: EMERGENCY'));
    });
    test('low sugar in mmol/L is read correctly', () async {
      final r = await run('health_check', {'sugar': 3.5, 'sugar_unit': 'mmol/L'});
      expect(r, startsWith('LEVEL: URGENT'));
      expect(r, contains('63 mg/dL'));
    });
    test('a mild cold stays at home care level soon', () async {
      expect(await run('health_check', {'who': 'adult', 'signs': ['cough_cold']}), startsWith('LEVEL: SOON'));
    });
  });

  group('Family health book', () {
    test('people, a medicine with an allergy warning, reminders and doses', () async {
      expect(await run('health_people', {'action': 'add', 'name': 'Hooyo', 'relation': 'mother', 'sex': 'female', 'birth': '1962', 'allergies': ['Penicillin'], 'conditions': ['High blood pressure']}),
          contains('Added Hooyo'));
      final add = await run('health_meds', {'action': 'add', 'person': 'Hooyo', 'name': 'Amlodipine 5 mg', 'dose': '1 tablet', 'times': ['8am'], 'with_food': 'any'});
      expect(add, contains('Amlodipine 5 mg, 1 tablet at 08:00'));
      expect(add, contains('schedule_task'));
      expect(add, contains('2026-10-21T08:00'));
      final warn = await run('health_meds', {'action': 'add', 'person': 'mother', 'name': 'Penicillin V 250 mg', 'dose': '1 tablet', 'times': ['08:00', '20:00'], 'days': 7});
      expect(warn, contains('WARNING'));
      expect(warn, contains('until 2026-10-27'));
      expect(await run('health_meds', {'action': 'taken', 'person': 'Hooyo', 'name': 'amlodipine'}), contains('took Amlodipine'));
      expect(await run('health_meds', {'action': 'today', 'person': 'Hooyo'}), contains('taken 1 of 1 today'));
      final saved = jsonDecode(await File('${tmp.path}/Health/health.json').readAsString()) as Map;
      expect((saved['meds'] as List).length, 2);
    });

    test('readings are explained at once and trend gives a chart', () async {
      expect(await run('health_log', {'kind': 'bp', 'value': '150/95', 'at': '2026-10-19 08:00'}), contains('[WATCH]'));
      expect(await run('health_log', {'kind': 'bp', 'value': '185/122', 'at': '2026-10-20 08:00'}), contains('[SEE A DOCTOR]'));
      expect(await run('health_log', {'kind': 'bp', 'value': '128/82', 'at': '2026-10-21 08:00'}), contains('a little raised'));
      final trend = await run('health_log', {'action': 'trend', 'kind': 'bp'});
      expect(trend, contains('3 bp readings'));
      expect(trend, contains('```diagram'));
      expect(trend, contains('Top (systolic)'));
      expect(await run('health_log', {'kind': 'sugar', 'value': '7.4', 'unit': 'mmol/L', 'context': 'fasting'}), contains('133 mg/dL'));
      expect(await run('health_log', {'kind': 'temp', 'value': '101.3', 'unit': 'F'}), contains('38.5 C'));
    });

    test('pregnancy dates follow LMP + 280 days and the WHO visits', () async {
      await run('health_people', {'action': 'add', 'name': 'Amina', 'relation': 'wife', 'sex': 'female'});
      final r = await run('health_pregnancy', {'action': 'set', 'person': 'Amina', 'lmp': '2026-05-01'});
      expect(r, contains('Due date 2027-02-05'));
      expect(r, contains('24 weeks 5 days'));
      final v = await run('health_pregnancy', {'action': 'visits', 'person': 'Amina'});
      expect(v, contains('Week 26: around 2026-10-30 (DUE SOON)'));
      // A pregnant woman's blood pressure is judged by pregnancy limits.
      expect(await run('health_log', {'person': 'Amina', 'kind': 'bp', 'value': '142/91'}), contains('pre-eclampsia'));
    });

    test('child vaccines from the birth date, then marked given', () async {
      await run('health_people', {'action': 'add', 'name': 'Bilal', 'relation': 'son', 'sex': 'male', 'birth': '2026-08-01'});
      final v = await run('health_child', {'action': 'vaccines', 'person': 'Bilal'});
      expect(v, contains('BCG (TB) [BCG]: OVERDUE since 2026-08-01'));
      expect(v, contains('Penta 1 (DTP-HepB-Hib) [PENTA1]: OVERDUE since 2026-09-12'));
      expect(v, contains('Penta 2 [PENTA2]: DUE NOW (from 2026-10-10)'));
      expect(v, contains('Measles 1 [MCV1]: due 2027-05-02'));
      expect(await run('health_child', {'action': 'given', 'person': 'Bilal', 'vaccines': ['all_due'], 'date': '2026-10-21'}), contains('BCG'));
      final after = await run('health_child', {'action': 'vaccines', 'person': 'Bilal'});
      expect(after, contains('[BCG]: given 2026-10-21'));
      expect(after, contains('[PENTA2]: given 2026-10-21'));
      expect(after, contains('[PENTA3]: due 2026-11-07'));
    });

    test('a doctor summary PDF is made', () async {
      await run('health_people', {'action': 'add', 'name': 'Me', 'relation': 'me', 'birth': '1990-01-01', 'conditions': ['Type 2 diabetes']});
      await run('health_meds', {'action': 'add', 'name': 'Metformin 500 mg', 'dose': '1 tablet', 'times': ['08:00', '20:00']});
      for (final v in ['8.1', '7.6', '7.0']) {
        await run('health_log', {'kind': 'sugar', 'value': v, 'unit': 'mmol/L', 'context': 'fasting'});
      }
      final chat = await run('health_report', {'format': 'chat'});
      expect(chat, contains('Type 2 diabetes'));
      expect(chat, contains('```diagram'));
      final pdf = await run('health_report', {'format': 'pdf'});
      expect(pdf, startsWith('FILE_SAVED '));
      final path = pdf.split('\n').first.substring('FILE_SAVED '.length);
      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync().take(4), [0x25, 0x50, 0x44, 0x46]);
    });
  });

  group('Health maths', () {
    test('BMI, due date, conversions and no doses', () {
      expect(HealthTools.calc({'mode': 'bmi', 'weight_kg': 70, 'height_cm': 170}), contains('24.2 (healthy weight'));
      expect(HealthTools.calc({'mode': 'due_date', 'lmp': '2026-01-10'}), contains('2026-10-17'));
      expect(HealthTools.calc({'mode': 'convert', 'value': 180, 'from': 'mg/dL'}), contains('10.0 mmol/L'));
      expect(HealthTools.calc({'mode': 'ors'}), contains('6 level teaspoons of sugar'));
      expect(HealthTools.calc({'mode': 'dose'}), contains('not calculated'));
    });
  });
}
