import 'dart:convert';
import 'dart:io';

import 'biz_pdf.dart';
import 'doc_maker.dart';
import 'tools.dart';

/// SubMac's health toolkit for the Health bot (Caafimaad) and for health questions in the main chat.
/// It keeps a private family health book on the phone (Health/health.json in the workspace): people, medicines and
/// doses taken, readings (blood pressure, sugar, temperature, weight...), pregnancy, child vaccines and clinic visits.
/// It also runs a fixed danger-sign check (rules, not the model's guess) and safe health maths, and makes a summary
/// for the doctor as a PDF. It never makes up a diagnosis or a medicine dose.
class HealthTools {
  static const names = {
    'health_check', 'health_people', 'health_meds', 'health_log', 'health_pregnancy', 'health_child', 'health_visits',
    'health_calc', 'health_report',
  };

  /// Tests point these at a temp folder and a fixed day.
  static String? dirOverride;
  static DateTime Function() now = DateTime.now;

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static const _person = {'type': 'string', 'description': 'Who: a name or relation in the health book (default: the user, "Me")'};

  static final List<Map<String, dynamic>> definitions = [
    _fn('health_check', 'Danger-sign check. Run it FIRST whenever someone describes symptoms or an injury, before any advice. '
        'Pick every matching sign code (you understand Somali; map their words to codes) and add any numbers you have. '
        'It returns the level (EMERGENCY, URGENT today, SOON, or HOME CARE with watch-outs), why, what to do now, and emergency numbers. '
        'Follow it: never play down an EMERGENCY or URGENT result.', {
      'who': {'type': 'string', 'enum': ['adult', 'child', 'baby', 'newborn', 'pregnant', 'elderly'],
          'description': 'newborn = under 2 months, baby = 2-12 months, child = 1-12 years'},
      'age_months': {'type': 'number', 'description': 'For children: age in months'},
      'signs': {'type': 'array', 'items': {'type': 'string', 'enum': _signs.keys.toList()}},
      'temp_c': {'type': 'number'},
      'breaths_per_min': {'type': 'number'},
      'bp': {'type': 'string', 'description': 'e.g. 150/95'},
      'sugar': {'type': 'number'},
      'sugar_unit': {'type': 'string', 'enum': ['mg/dL', 'mmol/L']},
      'spo2': {'type': 'number', 'description': 'Oxygen %'},
      'muac_cm': {'type': 'number', 'description': 'Mid-upper arm circumference (children 6-59 months)'},
      'days': {'type': 'number', 'description': 'How many days the problem has lasted'},
      'person': _person,
    }),
    _fn('health_people', 'The family health book: the people the user looks after, with sex, birth date, blood group, allergies, '
        'long-term conditions and notes. list, add, update, show, remove.', {
      'action': {'type': 'string', 'enum': ['list', 'add', 'update', 'show', 'remove']},
      'name': {'type': 'string', 'description': 'Name, e.g. "Me", "Hooyo", "Amina"'},
      'relation': {'type': 'string', 'description': 'me, mother, father, wife, husband, son, daughter...'},
      'sex': {'type': 'string', 'enum': ['female', 'male']},
      'birth': {'type': 'string', 'description': 'YYYY-MM-DD (or YYYY when only the year is known)'},
      'blood_group': {'type': 'string'},
      'allergies': {'type': 'array', 'items': {'type': 'string'}},
      'conditions': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Long-term: diabetes, high blood pressure, asthma...'},
      'height_cm': {'type': 'number'},
      'notes': {'type': 'string'},
    }),
    _fn('health_meds', 'Medicines: add one exactly as the doctor, pharmacist or package says (never choose a dose yourself), list, stop, '
        'delete, mark a dose taken or missed, today (what is due now), and history. Gives the times to set reminders with schedule_task.', {
      'action': {'type': 'string', 'enum': ['add', 'list', 'update', 'stop', 'delete', 'taken', 'missed', 'today', 'history']},
      'person': _person,
      'name': {'type': 'string', 'description': 'Medicine name and strength, e.g. "Metformin 500 mg"'},
      'dose': {'type': 'string', 'description': 'As prescribed, e.g. "1 tablet"'},
      'times': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Times of day, 24h: ["08:00","20:00"]'},
      'with_food': {'type': 'string', 'description': 'before food, with food, after food, any'},
      'days': {'type': 'number', 'description': 'Course length in days; empty = ongoing'},
      'start': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
      'purpose': {'type': 'string'},
      'prescriber': {'type': 'string'},
      'id': {'type': 'string'},
    }),
    _fn('health_log', 'Readings and symptoms: add a reading (it says at once if it is normal, high, low or dangerous), list, trend '
        '(a ```diagram chart card to paste), delete. Kinds: bp (value "130/85"), sugar (with context fasting/random/after_meal), '
        'temp, weight, height, pulse, spo2, muac, symptom, note.', {
      'action': {'type': 'string', 'enum': ['add', 'list', 'trend', 'delete']},
      'person': _person,
      'kind': {'type': 'string', 'enum': ['bp', 'sugar', 'temp', 'weight', 'height', 'pulse', 'spo2', 'muac', 'symptom', 'note']},
      'value': {'type': 'string', 'description': 'e.g. "130/85", "7.2", "38.5", text for a symptom or note'},
      'unit': {'type': 'string', 'description': 'sugar: mg/dL or mmol/L; temp: C or F; weight: kg or lb'},
      'context': {'type': 'string', 'enum': ['fasting', 'random', 'after_meal', 'bedtime']},
      'at': {'type': 'string', 'description': 'YYYY-MM-DD HH:MM, default now'},
      'note': {'type': 'string'},
      'days': {'type': 'number', 'description': 'list/trend: how many days back (default 30)'},
      'id': {'type': 'string'},
    }),
    _fn('health_pregnancy', 'Pregnancy: set from the first day of the last period (lmp) or a scan (scan_date + weeks), then status '
        '(week, trimester, due date, next check-up), visits (the WHO 8 antenatal contacts with dates), danger_signs, or end it.', {
      'action': {'type': 'string', 'enum': ['set', 'status', 'visits', 'danger_signs', 'end']},
      'person': _person,
      'lmp': {'type': 'string', 'description': 'YYYY-MM-DD'},
      'scan_date': {'type': 'string'},
      'scan_weeks': {'type': 'number'},
      'scan_days': {'type': 'number'},
      'due': {'type': 'string', 'description': 'A due date the clinic gave'},
    }),
    _fn('health_child', 'Children: vaccines (the Somalia routine schedule from the birth date: done, due, overdue with dates), given '
        '(mark vaccines given), and muac (malnutrition check for 6-59 months).', {
      'action': {'type': 'string', 'enum': ['vaccines', 'given', 'muac']},
      'person': _person,
      'vaccines': {'type': 'array', 'items': {'type': 'string'}, 'description': 'For given: codes like BCG, OPV0, PENTA1, PCV1, ROTA1, IPV1, MCV1, or "all_due"'},
      'date': {'type': 'string', 'description': 'Date given, default today'},
      'muac_cm': {'type': 'number'},
    }),
    _fn('health_visits', 'Clinic and doctor visits: add (reason, what the doctor found, tests and results, advice, next visit), list, delete.', {
      'action': {'type': 'string', 'enum': ['add', 'list', 'delete']},
      'person': _person,
      'date': {'type': 'string'},
      'place': {'type': 'string'},
      'doctor': {'type': 'string'},
      'reason': {'type': 'string'},
      'diagnosis': {'type': 'string', 'description': 'Only what the doctor said'},
      'tests': {'type': 'string', 'description': 'Tests and results as written on the paper'},
      'advice': {'type': 'string'},
      'next': {'type': 'string', 'description': 'Next visit date YYYY-MM-DD'},
      'id': {'type': 'string'},
    }),
    _fn('health_calc', 'Health maths with working: bmi, due_date (from lmp), age, convert (sugar mg/dL<->mmol/L, temp C<->F, weight kg<->lb, '
        'height cm<->ft/in), ors (how to mix oral rehydration solution), water (daily fluid guide). No medicine doses.', {
      'mode': {'type': 'string', 'enum': ['bmi', 'due_date', 'age', 'convert', 'ors', 'water']},
      'weight_kg': {'type': 'number'},
      'height_cm': {'type': 'number'},
      'lmp': {'type': 'string'},
      'birth': {'type': 'string'},
      'value': {'type': 'number'},
      'from': {'type': 'string', 'description': 'convert: mg/dL, mmol/L, C, F, kg, lb, cm, in'},
    }),
    _fn('health_report', 'A health summary of one person for a doctor or for the family: profile, allergies, conditions, medicines, '
        'latest readings with charts, pregnancy, vaccines, visits. format chat (text + ```diagram cards), pdf, or xlsx.', {
      'person': _person,
      'format': {'type': 'string', 'enum': ['chat', 'pdf', 'xlsx']},
      'days': {'type': 'number', 'description': 'Readings from the last N days (default 90)'},
      'language': {'type': 'string', 'enum': ['en', 'so']},
    }),
  ];

  // ------------------------------------------------------------------ danger signs

  /// code -> [level 3 emergency, 2 urgent today, 1 see a health worker soon], English, Somali.
  static const Map<String, List<dynamic>> _signs = {
    'unconscious': [3, 'Unconscious or cannot be woken', 'Miyir la\'aan / lama toosin karo'],
    'convulsions': [3, 'Fits or convulsions', 'Suuxdin / gariir'],
    'trouble_breathing': [3, 'Severe difficulty breathing', 'Neefsasho aad u adag'],
    'chest_indrawing': [3, 'Chest pulls in when breathing (child)', 'Laabta oo gudaha u galaysa marka uu neefsanayo'],
    'blue_lips': [3, 'Blue or grey lips', 'Bushimo buluug ama cirro ah'],
    'chest_pain': [3, 'Chest pain or pressure', 'Xanuun ama culays laabta ah'],
    'stroke_signs': [3, 'Face drooping, arm weak, speech slurred (stroke signs)', 'Weji dhinac u dhacay, gacan tabar la\'aan, hadal qalloocan'],
    'heavy_bleeding': [3, 'Heavy bleeding that does not stop', 'Dhiig bax badan oo aan istaagin'],
    'severe_dehydration': [3, 'Very dry, sunken eyes, no urine, very weak', 'Fuuqbax daran: indho godan, kaadi la\'aan, tabar darro'],
    'cannot_drink': [3, 'Child cannot drink or breastfeed', 'Ilmuhu ma cabbi karo / naaska ma nuugi karo'],
    'vomits_everything': [3, 'Vomits everything', 'Wax walba wuu soo mantagaa'],
    'very_sleepy': [3, 'Very sleepy, floppy or confused', 'Hurdo badan, jilicsanaan ama wareer'],
    'stiff_neck': [3, 'Stiff neck with fever', 'Qoorta oo adkaatay iyo qandho'],
    'severe_allergy': [3, 'Swelling of face or throat, hard to breathe after food, a sting or medicine', 'Weji ama cunaha oo bararay, neefsasho adag'],
    'poisoning': [3, 'Swallowed poison, chemicals or too many pills', 'Sun, kiimiko ama kiniinno badan ayuu liqay'],
    'snake_bite': [3, 'Snake bite', 'Mas qaniinay'],
    'big_burn': [3, 'Large or deep burn, or burn on face, hands or genitals', 'Gubasho weyn ama qoto dheer'],
    'head_injury': [3, 'Head injury with vomiting, sleepiness or fits', 'Dhaawac madaxa ah oo leh matag ama hurdo'],
    'suicidal': [3, 'Wants to end their life or harm themselves', 'Doonaya inuu naftiisa dilo ama is dhaawaco'],
    'pregnancy_bleeding': [3, 'Bleeding in pregnancy or after birth', 'Dhiig bax uurka ama dhalmada kadib'],
    'pregnancy_fits_headache': [3, 'Pregnant: severe headache, blurred vision or fits', 'Uur: madax xanuun daran, aragti cad ama suuxdin'],
    'labour_problem': [3, 'Labour over 12 hours, or baby\'s arm, cord or bottom comes first', 'Foosha 12 saac ka badan ama ilmaha oo si khaldan u imanaya'],
    'water_broke_no_labour': [2, 'Waters broke without labour, or before 37 weeks', 'Biyihii ayaa jabay foosha la\'aan'],
    'baby_not_moving': [2, 'Baby moves less or stopped moving (pregnancy)', 'Ilmaha caloosha ku jira oo dhaqdhaqaaqiisu yaraaday'],
    'newborn_danger': [3, 'Newborn: not feeding, cold, yellow palms or soles, or fast breathing', 'Ilmo dhashay: ma nuugo, qabow, jaalle, neef dhakhso ah'],
    'severe_belly_pain': [3, 'Sudden severe belly pain, hard belly', 'Calool xanuun daran oo kadis ah, calool adag'],
    'blood_vomit_stool': [3, 'Vomiting blood or black, tarry stool', 'Dhiig matag ama saxaro madow'],
    'cholera_like': [3, 'Sudden heavy watery diarrhoea like rice water', 'Shuban biyo badan oo kadis ah (sida biyaha bariiska)'],
    'fast_breathing': [2, 'Fast breathing', 'Neefsasho dhakhso ah'],
    'high_fever': [2, 'High fever (39 C or more)', 'Qandho sare (39 C ama ka badan)'],
    'fever_3_days': [2, 'Fever for 3 days or more', 'Qandho 3 maalmood ama ka badan'],
    'blood_in_stool': [2, 'Blood in the stool (dysentery)', 'Dhiig saxarada ku jira'],
    'diarrhoea_14_days': [2, 'Diarrhoea for 14 days or more', 'Shuban 14 maalmood ama ka badan'],
    'some_dehydration': [2, 'Thirsty, dry mouth, less urine', 'Harraad, af engegan, kaadi yar'],
    'painful_urination_fever': [2, 'Pain passing urine with fever or back pain', 'Kaadi xanuun iyo qandho ama dhabar xanuun'],
    'severe_pain': [2, 'Severe pain anywhere', 'Xanuun daran'],
    'eye_injury': [2, 'Eye injury, or sudden loss of vision', 'Dhaawac isha ah ama aragti lumay'],
    'swollen_red_hot': [2, 'Red, hot, swollen, painful skin spreading', 'Maqaar casaan, kulul, barar oo faafaya'],
    'dog_bite': [2, 'Animal bite (rabies risk)', 'Eey ama xayawaan qaniinay'],
    'measles_like': [2, 'Fever with rash and red eyes or cough', 'Qandho, finan iyo indho cas (jadeeco)'],
    'yellow_eyes': [2, 'Yellow eyes or skin', 'Indho ama maqaar jaalle ah'],
    'swelling_legs_breathless': [2, 'Swollen legs and short of breath', 'Lugo bararay iyo neef qabad'],
    'severe_malnutrition': [2, 'Very thin child or swollen feet (oedema)', 'Ilmo aad u caato ah ama cago bararay'],
    'cough_2_weeks': [1, 'Cough for 2 weeks or more (TB test)', 'Qufac 2 toddobaad ama ka badan (baaritaan TB)'],
    'weight_loss': [1, 'Losing weight without trying', 'Miisaan dhimis aan sabab lahayn'],
    'night_sweats': [1, 'Night sweats', 'Dhidid habeenkii'],
    'mild_fever': [1, 'Mild fever', 'Qandho yar'],
    'cough_cold': [1, 'Cough or cold', 'Qufac ama hargab'],
    'mild_diarrhoea': [1, 'Diarrhoea, drinking well', 'Shuban, si fiican wuu cabbaa'],
    'headache': [1, 'Headache', 'Madax xanuun'],
    'rash': [1, 'Rash or itching', 'Finan ama cuncun'],
    'low_mood': [1, 'Low mood, worry or poor sleep for weeks', 'Murugo, walwal ama hurdo la\'aan'],
    'tooth_pain': [1, 'Tooth pain', 'Ilig xanuun'],
  };

  static const _emergencyNumbers = 'Emergency numbers (checked Oct 2026): Mogadishu - Aamin Ambulance 999 (free, 24 hours). '
      'Across Somalia the official numbers are ambulance 999, police 888, fire 555, but they do not work everywhere: '
      'if a call fails, go straight to the nearest hospital and save its number in the phone.';

  static double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse('$v'.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), ''));
  }

  static (double, double)? _bp(dynamic v) {
    final m = RegExp(r'(\d{2,3})\s*[/\\-]\s*(\d{2,3})').firstMatch('${v ?? ''}');
    if (m == null) return null;
    return (double.parse(m[1]!), double.parse(m[2]!));
  }

  static String _f(double v) => v == v.roundToDouble() ? v.toInt().toString() : double.parse(v.toStringAsFixed(1)).toString();

  /// Reads that come from numbers: [level, reason]. level 0 = fine.
  static List<(int, String)> _numberFlags(Map<String, dynamic> a, {String who = 'adult', double? ageMonths}) {
    final out = <(int, String)>[];
    final t = _num(a['temp_c']);
    if (t != null) {
      if (ageMonths != null && ageMonths < 2 && (t >= 37.5 || t < 35.5)) {
        out.add((3, 'Temperature ${_f(t)} C in a baby under 2 months (WHO danger sign)'));
      } else if (ageMonths != null && ageMonths < 3 && t >= 38) {
        out.add((2, 'Fever ${_f(t)} C in a baby under 3 months'));
      } else if (t >= 40) {
        out.add((2, 'Very high fever ${_f(t)} C'));
      } else if (t >= 39) {
        out.add((2, 'High fever ${_f(t)} C'));
      } else if (t >= 38) {
        out.add((1, 'Fever ${_f(t)} C'));
      } else if (t < 35) {
        out.add((2, 'Low body temperature ${_f(t)} C'));
      }
    }
    final br = _num(a['breaths_per_min']);
    if (br != null && ageMonths != null && ageMonths < 60) {
      final limit = ageMonths < 2 ? 60 : ageMonths < 12 ? 50 : 40;
      if (br >= limit) out.add((ageMonths < 2 ? 3 : 2, 'Fast breathing: ${_f(br)} a minute (fast for this age is $limit or more)'));
    } else if (br != null && br >= 30) {
      out.add((2, 'Fast breathing for an adult: ${_f(br)} a minute'));
    }
    final bp = _bp(a['bp']);
    if (bp != null) {
      final (s, d) = bp;
      if (who == 'pregnant' && (s >= 160 || d >= 110)) {
        out.add((3, 'Blood pressure ${_f(s)}/${_f(d)} in pregnancy: severe'));
      } else if (who == 'pregnant' && (s >= 140 || d >= 90)) {
        out.add((2, 'Blood pressure ${_f(s)}/${_f(d)} in pregnancy: high (pre-eclampsia must be checked today)'));
      } else if (s >= 180 || d >= 120) {
        out.add((2, 'Blood pressure ${_f(s)}/${_f(d)}: very high. With chest pain, breathlessness, weakness, confusion or vision loss it is an emergency'));
      } else if (s < 90 && d < 60) {
        out.add((1, 'Low blood pressure ${_f(s)}/${_f(d)}'));
      }
    }
    final sg = _num(a['sugar']);
    if (sg != null) {
      final mg = _sugarMg(sg, '${a['sugar_unit'] ?? ''}');
      if (mg < 54) {
        out.add((3, 'Blood sugar ${_f(mg)} mg/dL: severe low'));
      } else if (mg < 70) {
        out.add((2, 'Blood sugar ${_f(mg)} mg/dL: low. Take 15 g of fast sugar now (3 teaspoons of sugar in water, or half a glass of juice), check again in 15 minutes'));
      } else if (mg >= 300) {
        out.add((2, 'Blood sugar ${_f(mg)} mg/dL: very high. With vomiting, deep fast breathing or drowsiness it is an emergency'));
      }
    }
    final o = _num(a['spo2']);
    if (o != null) {
      if (o < 90) {
        out.add((3, 'Oxygen ${_f(o)}%: dangerously low'));
      } else if (o < 94) {
        out.add((2, 'Oxygen ${_f(o)}%: low'));
      }
    }
    final mu = _num(a['muac_cm']);
    if (mu != null && (ageMonths == null || (ageMonths >= 6 && ageMonths < 60))) {
      if (mu < 11.5) {
        out.add((2, 'MUAC ${_f(mu)} cm: severe acute malnutrition (under 11.5 cm)'));
      } else if (mu < 12.5) {
        out.add((1, 'MUAC ${_f(mu)} cm: moderate malnutrition (11.5 to 12.4 cm)'));
      }
    }
    return out;
  }

  /// Sugar in mg/dL. Numbers under 35 with no unit are taken as mmol/L.
  static double _sugarMg(double v, String unit) {
    final u = unit.toLowerCase();
    if (u.contains('mmol') || (!u.contains('mg') && v < 35)) return double.parse((v * 18).toStringAsFixed(0));
    return v;
  }

  static String check(Map<String, dynamic> a) {
    final who = '${a['who'] ?? 'adult'}';
    var age = _num(a['age_months']);
    if (age == null && who == 'newborn') age = 1;
    final hits = <(int, String)>[];
    final signs = [for (final s in (a['signs'] is List ? a['signs'] as List : const [])) '$s'];
    for (final s in signs) {
      final d = _signs[s];
      if (d == null) continue;
      var lv = d[0] as int;
      // Young babies and pregnant women get less room.
      if ((who == 'newborn' || (age != null && age < 2)) && lv < 3 && const {'fast_breathing', 'high_fever', 'mild_fever', 'some_dehydration', 'mild_diarrhoea'}.contains(s)) {
        lv = 3;
      }
      if (who == 'pregnant' && lv == 1 && const {'headache', 'mild_fever', 'severe_pain'}.contains(s)) lv = 2;
      hits.add((lv, '${d[1]} / ${d[2]}'));
    }
    final days = _num(a['days']);
    if (days != null && days >= 14 && signs.contains('cough_cold')) hits.add((1, 'Cough for ${_f(days)} days: needs a TB test'));
    if (days != null && days >= 3 && signs.contains('mild_fever')) hits.add((2, 'Fever for ${_f(days)} days'));
    hits.addAll(_numberFlags(a, who: who, ageMonths: age));
    final level = hits.fold<int>(0, (m, h) => h.$1 > m ? h.$1 : m);
    final sb = StringBuffer();
    switch (level) {
      case 3:
        sb.writeln('LEVEL: EMERGENCY (DEGDEG). Go to a hospital now or call an ambulance. Do not wait to see if it gets better.');
        break;
      case 2:
        sb.writeln('LEVEL: URGENT. See a doctor or health centre TODAY (maanta).');
        break;
      case 1:
        sb.writeln('LEVEL: SOON. See a health worker in the next days if it does not improve; home care meanwhile.');
        break;
      default:
        sb.writeln('LEVEL: HOME CARE for now. No danger sign was given. Keep checking for the danger signs below.');
    }
    if (hits.isNotEmpty) {
      sb.writeln('Why:');
      for (final h in (hits..sort((x, y) => y.$1 - x.$1))) {
        sb.writeln('- ${h.$2}');
      }
    }
    if (level == 3) {
      sb.writeln('While going: keep them lying on the side if drowsy; nothing by mouth if unconscious; press firmly on bleeding with a clean cloth; '
          'a child with diarrhoea keeps sipping ORS or breastfeeding on the way; bring their medicines and any papers.');
      if (signs.contains('suicidal')) {
        sb.writeln('Stay with them, remove means of harm, and get help from family and a doctor now. Talk calmly and listen.');
      }
      if (signs.contains('snake_bite')) {
        sb.writeln('Snake bite: keep still, the bitten limb below the heart, remove rings; no cutting, sucking or tight tourniquet.');
      }
      if (signs.contains('big_burn')) sb.writeln('Burn: cool running water for 20 minutes, no butter, toothpaste or oil, cover with clean cloth.');
      sb.writeln(_emergencyNumbers);
    } else if (level == 2) {
      sb.writeln('If it gets worse on the way (breathing hard, fits, not waking, cannot drink), treat it as an emergency. $_emergencyNumbers');
    }
    sb.writeln('Danger signs to watch for: trouble breathing, fits, very sleepy, cannot drink, vomits everything, chest pain, heavy bleeding, '
        'stiff neck, blue lips. Any one of these = go to hospital at once.');
    sb.writeln('Tell the user plainly in their language. You are not a doctor and this is not a diagnosis.');
    return sb.toString().trim();
  }

  // ------------------------------------------------------------------ storage

  static Future<Directory> _dir() async {
    final ws = dirOverride ?? await AgentTools.workspaceDir();
    final d = Directory('$ws/Health');
    await d.create(recursive: true);
    return d;
  }

  static Future<Map<String, dynamic>> load() async {
    final f = File('${(await _dir()).path}/health.json');
    Map<String, dynamic> j = {};
    if (await f.exists()) {
      try {
        j = Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
      } catch (_) {
        j = {};
      }
    }
    for (final k in ['people', 'meds', 'logs', 'visits']) {
      j[k] = [for (final e in (j[k] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    }
    j['vaccines'] = Map<String, dynamic>.from((j['vaccines'] as Map?) ?? {});
    j['seq'] = (j['seq'] as num?)?.toInt() ?? 0;
    return j;
  }

  static Future<void> _save(Map<String, dynamic> j) async {
    final d = await _dir();
    final f = File('${d.path}/health.json');
    if (await f.exists()) await f.copy('${d.path}/health.prev.json');
    final tmp = File('${d.path}/health.tmp');
    await tmp.writeAsString(jsonEncode(j), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _lock = Future.value();
  static Future<T> _serial<T>(Future<T> Function() f) {
    final run = _lock.then((_) => f());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  static String _id(Map<String, dynamic> j, String prefix) {
    j['seq'] = (j['seq'] as int) + 1;
    return '$prefix${j['seq']}';
  }

  static String _s(Map<String, dynamic> a, String k) => '${a[k] ?? ''}'.trim();
  static List<String> _list(dynamic v) => v is List ? [for (final e in v) '$e'.trim()].where((e) => e.isNotEmpty).toList() : (v is String && v.trim().isNotEmpty ? [v.trim()] : <String>[]);
  static String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  /// Calendar days are kept in UTC so adding days never slips across a daylight-saving change.
  static DateTime _today() {
    final n = now();
    return DateTime.utc(n.year, n.month, n.day);
  }

  static DateTime? _date(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    if (RegExp(r'^\d{4}$').hasMatch(t)) return DateTime.utc(int.parse(t), 7, 1);
    final d = DateTime.tryParse(t.replaceAll('/', '-'));
    return d == null ? null : DateTime.utc(d.year, d.month, d.day);
  }

  /// Finds a person by name or relation; with none given, the user ("Me"), created on first use.
  static Map<String, dynamic> _who(Map<String, dynamic> j, String q, {bool create = true}) {
    final people = j['people'] as List<Map<String, dynamic>>;
    final n = q.trim().toLowerCase();
    if (n.isEmpty || const {'me', 'i', 'myself', 'aniga', 'user'}.contains(n)) {
      final me = people.where((p) => p['relation'] == 'me').firstOrNull ??
          (people.length == 1 && n.isEmpty ? people.first : null);
      if (me != null) return me;
      if (!create) throw 'No health record for you yet. Add one with health_people.';
      final p = <String, dynamic>{'id': _id(j, 'P'), 'name': 'Me', 'relation': 'me'};
      people.add(p);
      return p;
    }
    final hit = people.where((p) => '${p['name']}'.toLowerCase() == n || '${p['id']}'.toLowerCase() == n).firstOrNull ??
        people.where((p) => '${p['relation']}'.toLowerCase() == n).firstOrNull ??
        people.where((p) => '${p['name']}'.toLowerCase().contains(n)).firstOrNull;
    if (hit != null) return hit;
    if (!create) throw 'No one called "$q" in the health book. People: ${people.map((p) => p['name']).join(', ')}';
    final p = <String, dynamic>{'id': _id(j, 'P'), 'name': q.trim(), 'relation': ''};
    people.add(p);
    return p;
  }

  static double? _ageMonths(Map<String, dynamic> p) {
    final b = _date('${p['birth'] ?? ''}');
    if (b == null) return null;
    return _today().difference(b).inDays / 30.4375;
  }

  static String _age(Map<String, dynamic> p) {
    final m = _ageMonths(p);
    if (m == null) return '';
    if (m < 1) return '${(m * 30.4375).round()} days';
    if (m < 24) return '${m.floor()} months';
    return '${(m / 12).floor()} years';
  }

  static Future<String> _out(String base, String ext, List<int> bytes) async {
    final ws = dirOverride ?? await AgentTools.workspaceDir();
    final dir = Directory('$ws/Documents');
    await dir.create(recursive: true);
    final path = await DocMaker.uniquePath(dir.path, DocMaker.fileName(base), ext);
    await File(path).writeAsBytes(bytes);
    return path;
  }

  static String _saved(String path) => 'FILE_SAVED $path\nShow it with a ```file card. Do not print the path in text.';

  // ------------------------------------------------------------------ dispatch

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      if (name == 'health_check') return check(a);
      if (name == 'health_calc') return calc(a);
      return await _serial(() async {
        final j = await load();
        final before = jsonEncode(j);
        final r = await _run(name, a, j);
        if (jsonEncode(j) != before) await _save(j);
        return r;
      });
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<String> _run(String name, Map<String, dynamic> a, Map<String, dynamic> j) async {
    switch (name) {
      case 'health_people':
        return _people(a, j);
      case 'health_meds':
        return _meds(a, j);
      case 'health_log':
        return _log(a, j);
      case 'health_pregnancy':
        return _pregnancy(a, j);
      case 'health_child':
        return _child(a, j);
      case 'health_visits':
        return _visits(a, j);
      case 'health_report':
        return _report(a, j);
    }
    return 'Error: unknown tool $name';
  }

  // ------------------------------------------------------------------ people

  static String _personLine(Map<String, dynamic> p) {
    final bits = [
      if ('${p['relation'] ?? ''}'.isNotEmpty && p['relation'] != 'me') '${p['relation']}',
      if ('${p['sex'] ?? ''}'.isNotEmpty) '${p['sex']}',
      if (_age(p).isNotEmpty) _age(p),
      if ('${p['blood_group'] ?? ''}'.isNotEmpty) 'blood ${p['blood_group']}',
      if (_list(p['allergies']).isNotEmpty) 'ALLERGIES: ${_list(p['allergies']).join(', ')}',
      if (_list(p['conditions']).isNotEmpty) 'conditions: ${_list(p['conditions']).join(', ')}',
      if (p['pregnancy'] is Map) 'pregnant (due ${(p['pregnancy'] as Map)['due']})',
    ];
    return '${p['name']} (${p['id']})${bits.isEmpty ? '' : ': ${bits.join('; ')}'}';
  }

  static String _people(Map<String, dynamic> a, Map<String, dynamic> j) {
    final action = _s(a, 'action').isEmpty ? 'list' : _s(a, 'action');
    final people = j['people'] as List<Map<String, dynamic>>;
    if (action == 'list') {
      if (people.isEmpty) return 'The health book is empty. Add people with health_people add (start with the user: name "Me", relation me).';
      return 'Health book (${people.length}):\n${people.map((p) => '- ${_personLine(p)}').join('\n')}';
    }
    final name = _s(a, 'name');
    if (action == 'add') {
      if (name.isEmpty) return 'Error: give a name';
      final rel = _s(a, 'relation').toLowerCase();
      final exists = people.where((p) => '${p['name']}'.toLowerCase() == name.toLowerCase()).firstOrNull;
      final p = exists ?? <String, dynamic>{'id': _id(j, 'P'), 'name': name};
      if (exists == null) people.add(p);
      if (rel.isNotEmpty) p['relation'] = rel;
      _setPerson(p, a);
      return '${exists == null ? 'Added' : 'Updated'} ${_personLine(p)}';
    }
    final p = _who(j, name, create: false);
    switch (action) {
      case 'update':
        if (_s(a, 'relation').isNotEmpty) p['relation'] = _s(a, 'relation').toLowerCase();
        _setPerson(p, a);
        return 'Updated ${_personLine(p)}';
      case 'show':
        final meds = (j['meds'] as List<Map<String, dynamic>>).where((m) => m['person'] == p['id'] && m['active'] != false).toList();
        return [
          _personLine(p),
          if ('${p['height_cm'] ?? ''}'.isNotEmpty) 'Height: ${p['height_cm']} cm',
          if ('${p['notes'] ?? ''}'.isNotEmpty) 'Notes: ${p['notes']}',
          'Medicines now: ${meds.isEmpty ? 'none recorded' : meds.map((m) => '${m['name']} ${m['dose'] ?? ''}'.trim()).join(', ')}',
        ].join('\n');
      case 'remove':
        people.remove(p);
        final id = p['id'];
        for (final k in ['meds', 'logs', 'visits']) {
          (j[k] as List<Map<String, dynamic>>).removeWhere((e) => e['person'] == id);
        }
        (j['vaccines'] as Map).remove(id);
        return 'Removed ${p['name']} and all their health records.';
    }
    return 'Error: unknown action $action';
  }

  static void _setPerson(Map<String, dynamic> p, Map<String, dynamic> a) {
    for (final k in ['sex', 'birth', 'blood_group', 'notes']) {
      if (_s(a, k).isNotEmpty) p[k] = _s(a, k);
    }
    if (_num(a['height_cm']) != null) p['height_cm'] = _num(a['height_cm']);
    for (final k in ['allergies', 'conditions']) {
      if (a[k] != null) {
        final old = _list(p[k]);
        for (final v in _list(a[k])) {
          if (!old.any((o) => o.toLowerCase() == v.toLowerCase())) old.add(v);
        }
        p[k] = old;
      }
    }
  }

  // ------------------------------------------------------------------ medicines

  static String _medLine(Map<String, dynamic> m) {
    final times = _list(m['times']);
    return '${m['name']}${'${m['dose'] ?? ''}'.isEmpty ? '' : ', ${m['dose']}'}'
        '${times.isEmpty ? '' : ' at ${times.join(', ')}'}${'${m['with_food'] ?? ''}'.isEmpty ? '' : ' (${m['with_food']})'}'
        '${'${m['end'] ?? ''}'.isEmpty ? ', ongoing' : ', until ${m['end']}'}${m['active'] == false ? ' [stopped]' : ''} (${m['id']})';
  }

  static String _meds(Map<String, dynamic> a, Map<String, dynamic> j) {
    final action = _s(a, 'action').isEmpty ? 'list' : _s(a, 'action');
    final meds = j['meds'] as List<Map<String, dynamic>>;
    final p = _who(j, _s(a, 'person'), create: action == 'add');
    final mine = meds.where((m) => m['person'] == p['id']).toList();
    Map<String, dynamic> find() {
      final id = _s(a, 'id').toLowerCase(), n = _s(a, 'name').toLowerCase();
      final m = mine.where((m) => '${m['id']}'.toLowerCase() == id && id.isNotEmpty).firstOrNull ??
          mine.where((m) => n.isNotEmpty && '${m['name']}'.toLowerCase().contains(n) && m['active'] != false).firstOrNull ??
          mine.where((m) => n.isNotEmpty && '${m['name']}'.toLowerCase().contains(n)).firstOrNull;
      if (m == null) throw 'No medicine "${_s(a, 'name')}${_s(a, 'id')}" for ${p['name']}. Medicines: ${mine.map((m) => m['name']).join(', ')}';
      return m;
    }

    switch (action) {
      case 'add':
        if (_s(a, 'name').isEmpty) return 'Error: give the medicine name';
        final start = _date(_s(a, 'start')) ?? _today();
        final days = _num(a['days']);
        final m = <String, dynamic>{
          'id': _id(j, 'M'),
          'person': p['id'],
          'name': _s(a, 'name'),
          'dose': _s(a, 'dose'),
          'times': [for (final t in _list(a['times'])) _hm(t)].whereType<String>().toList(),
          'with_food': _s(a, 'with_food'),
          'start': _day(start),
          if (days != null && days > 0) 'end': _day(start.add(Duration(days: days.round() - 1))),
          'purpose': _s(a, 'purpose'),
          'prescriber': _s(a, 'prescriber'),
          'active': true,
          'log': <Map<String, dynamic>>[],
        };
        meds.add(m);
        final allergy = _list(p['allergies']).where((x) => m['name'].toString().toLowerCase().contains(x.toLowerCase())).toList();
        final times = m['times'] as List;
        return [
          'Added for ${p['name']}: ${_medLine(m)}.',
          if (allergy.isNotEmpty) 'WARNING: ${p['name']} is recorded as allergic to ${allergy.join(', ')}. Tell them not to take it and to ask the doctor or pharmacist now.',
          if ('${m['dose']}'.isEmpty) 'No dose recorded: ask what the prescription or package says. Never choose a dose yourself.',
          if (times.isNotEmpty)
            'Reminders: offer one schedule_task per time, repeat daily${m['end'] != null ? ' until ${m['end']} (cancel it then)' : ''}: '
                '${times.map((t) => '"${_day(start)}T$t"').join(', ')}, task "Remind ${p['relation'] == 'me' ? 'me' : p['name']} to take ${m['name']} ${m['dose']}".',
        ].join('\n');
      case 'list':
        final active = mine.where((m) => m['active'] != false && !_ended(m)).toList();
        final past = mine.where((m) => m['active'] == false || _ended(m)).toList();
        if (mine.isEmpty) return 'No medicines recorded for ${p['name']}.';
        return [
          'Medicines for ${p['name']} now (${active.length}):',
          for (final m in active) '- ${_medLine(m)}',
          if (past.isNotEmpty) 'Finished or stopped: ${past.map((m) => m['name']).join(', ')}',
        ].join('\n');
      case 'update':
        final m = find();
        for (final k in ['dose', 'with_food', 'purpose', 'prescriber']) {
          if (_s(a, k).isNotEmpty) m[k] = _s(a, k);
        }
        if (a['times'] != null) m['times'] = [for (final t in _list(a['times'])) _hm(t)].whereType<String>().toList();
        if (_num(a['days']) != null) {
          final st = _date('${m['start']}') ?? _today();
          m['end'] = _day(st.add(Duration(days: _num(a['days'])!.round() - 1)));
        }
        return 'Updated: ${_medLine(m)}. If the times changed, change the reminders too.';
      case 'stop':
        final m = find();
        m['active'] = false;
        m['end'] = _day(_today());
        return 'Stopped ${m['name']} for ${p['name']} today. Cancel its reminders (list_scheduled, cancel_scheduled).';
      case 'delete':
        final m = find();
        meds.remove(m);
        return 'Deleted ${m['name']} from ${p['name']}\'s medicines.';
      case 'taken':
      case 'missed':
        final m = find();
        final log = (m['log'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        final n = now();
        log.add({'at': '${_day(n)} ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}', 'status': action});
        m['log'] = log.length > 400 ? log.sublist(log.length - 400) : log;
        return action == 'taken'
            ? 'Noted: ${p['name']} took ${m['name']} at ${log.last['at']}.'
            : 'Noted as missed: ${m['name']}. Do not take a double dose to catch up unless the doctor or the leaflet says so.';
      case 'today':
        final today = _day(_today());
        final active = mine.where((m) => m['active'] != false && !_ended(m)).toList();
        if (active.isEmpty) return 'No medicines due today for ${p['name']}.';
        final lines = <String>[];
        for (final m in active) {
          final taken = (m['log'] as List? ?? []).where((e) => '${(e as Map)['at']}'.startsWith(today) && e['status'] == 'taken').length;
          final times = _list(m['times']);
          lines.add('- ${m['name']} ${m['dose']}: ${times.isEmpty ? 'as needed' : times.join(', ')}; taken $taken of ${times.isEmpty ? '?' : times.length} today');
        }
        return 'Today for ${p['name']}:\n${lines.join('\n')}';
      case 'history':
        final m = find();
        final log = (m['log'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        if (log.isEmpty) return 'No doses logged for ${m['name']} yet.';
        final taken = log.where((e) => e['status'] == 'taken').length;
        return '${m['name']} for ${p['name']}: $taken taken, ${log.length - taken} missed.\n'
            '${log.reversed.take(20).map((e) => '- ${e['at']} ${e['status']}').join('\n')}';
    }
    return 'Error: unknown action $action';
  }

  static bool _ended(Map<String, dynamic> m) {
    final e = _date('${m['end'] ?? ''}');
    return e != null && e.isBefore(_today());
  }

  static String? _hm(String t) {
    final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$', caseSensitive: false).firstMatch(t.trim());
    if (m == null) return null;
    var h = int.parse(m[1]!);
    final mi = int.tryParse(m[2] ?? '0') ?? 0;
    final ap = (m[3] ?? '').toLowerCase();
    if (ap == 'pm' && h < 12) h += 12;
    if (ap == 'am' && h == 12) h = 0;
    if (h > 23 || mi > 59) return null;
    return '${h.toString().padLeft(2, '0')}:${mi.toString().padLeft(2, '0')}';
  }

  // ------------------------------------------------------------------ readings

  /// What a reading means: [level 0 fine, 1 watch, 2 see doctor soon/today, 3 emergency], words.
  static (int, String) interpret(String kind, Map<String, dynamic> e, {Map<String, dynamic>? person}) {
    final pregnant = person?['pregnancy'] is Map;
    final ageM = person == null ? null : _ageMonths(person);
    switch (kind) {
      case 'bp':
        final s = (e['sys'] as num).toDouble(), d = (e['dia'] as num).toDouble();
        if (pregnant && (s >= 160 || d >= 110)) return (3, 'severe for pregnancy: go to hospital now');
        if (pregnant && (s >= 140 || d >= 90)) return (2, 'high for pregnancy: see the clinic today (pre-eclampsia check)');
        if (s >= 180 || d >= 120) {
          return (2, 'very high: rest 5 minutes and measure again. If still this high, see a doctor today; with chest pain, breathlessness, weakness, confusion or vision loss go to hospital now');
        }
        if (s >= 160 || d >= 100) return (2, 'high (stage 2 range): see a doctor soon');
        if (s >= 140 || d >= 90) return (1, 'high (hypertension range, WHO 140/90): check on other days; if it stays high see a doctor');
        if (s >= 120 || d >= 80) return (1, 'a little raised: less salt, more walking, recheck');
        if (s < 90 && d < 60) return (1, 'low: fine if no symptoms; with dizziness or fainting see a doctor');
        return (0, 'normal');
      case 'sugar':
        final mg = (e['mg'] as num).toDouble();
        final ctx = '${e['context'] ?? ''}';
        if (mg < 54) return (3, 'severe low: give fast sugar now if they can swallow; if confused or not waking, hospital now');
        if (mg < 70) return (2, 'low: 15 g fast sugar now (3 teaspoons of sugar in water or half a glass of juice), recheck in 15 minutes');
        if (mg >= 300) return (2, 'very high: see a doctor today; with vomiting, deep fast breathing or drowsiness go to hospital now');
        if (ctx == 'fasting') {
          if (mg >= 126) return (1, 'high fasting sugar (diabetes range if repeated, 126 mg/dL or more)');
          if (mg >= 100) return (1, 'a little high fasting sugar (prediabetes range 100-125)');
          return (0, 'normal fasting');
        }
        if (ctx == 'after_meal') {
          if (mg >= 200) return (1, 'high after a meal (200 or more)');
          if (mg >= 140) return (1, 'a little high 2 hours after a meal (140-199)');
          return (0, 'normal after a meal');
        }
        if (mg >= 200) return (1, 'high (200 or more at any time)');
        return (0, 'in range for a random reading');
      case 'temp':
        final t = (e['c'] as num).toDouble();
        if (ageM != null && ageM < 2 && (t >= 37.5 || t < 35.5)) return (3, 'danger in a baby under 2 months: hospital now');
        if (ageM != null && ageM < 3 && t >= 38) return (2, 'fever in a baby under 3 months: see a doctor today');
        if (t >= 40) return (2, 'very high fever: see a doctor today');
        if (t >= 39) return (2, 'high fever');
        if (t >= 38) return (1, 'fever');
        if (t >= 37.5) return (1, 'slightly warm');
        if (t < 35) return (2, 'too cold: warm them and see a doctor');
        return (0, 'normal');
      case 'spo2':
        final o = (e['n'] as num).toDouble();
        if (o < 90) return (3, 'dangerously low oxygen: hospital now');
        if (o < 94) return (2, 'low oxygen: see a doctor today');
        return (0, 'normal');
      case 'pulse':
        final p = (e['n'] as num).toDouble();
        if (ageM != null && ageM < 144) return (0, 'recorded (normal pulse in children depends on age)');
        if (p > 120) return (2, 'fast at rest: see a doctor today if it stays, at once with chest pain or fainting');
        if (p > 100) return (1, 'a bit fast (normal at rest is 60-100)');
        if (p < 50) return (1, 'slow: fine for some fit people; with dizziness see a doctor');
        return (0, 'normal (60-100)');
      case 'muac':
        final mu = (e['cm'] as num).toDouble();
        if (ageM != null && ageM >= 6 && ageM < 60) {
          if (mu < 11.5) return (2, 'severe acute malnutrition: nutrition centre or clinic now');
          if (mu < 12.5) return (1, 'moderate malnutrition: nutrition programme soon');
          return (0, 'normal for 6-59 months');
        }
        if (pregnant && mu < 23) return (1, 'under 23 cm in pregnancy: at risk of undernutrition, ask the clinic');
        return (0, 'recorded');
      case 'weight':
        final h = _num(person?['height_cm']);
        final kg = (e['kg'] as num).toDouble();
        if (h != null && h > 50 && (ageM == null || ageM >= 240)) {
          final bmi = kg / ((h / 100) * (h / 100));
          return (0, 'BMI ${bmi.toStringAsFixed(1)} (${_bmiWord(bmi)})');
        }
        return (0, 'recorded');
    }
    return (0, 'recorded');
  }

  static String _bmiWord(double b) => b < 18.5 ? 'underweight' : b < 25 ? 'healthy weight' : b < 30 ? 'overweight' : 'obesity';

  static String _show(Map<String, dynamic> e) {
    switch (e['kind']) {
      case 'bp':
        return '${_f((e['sys'] as num).toDouble())}/${_f((e['dia'] as num).toDouble())} mmHg';
      case 'sugar':
        final mg = (e['mg'] as num).toDouble();
        return '${_f(mg)} mg/dL (${(mg / 18).toStringAsFixed(1)} mmol/L)${'${e['context'] ?? ''}'.isEmpty ? '' : ', ${e['context']}'}';
      case 'temp':
        return '${_f((e['c'] as num).toDouble())} C';
      case 'weight':
        return '${_f((e['kg'] as num).toDouble())} kg';
      case 'height':
        return '${_f((e['cm'] as num).toDouble())} cm';
      case 'muac':
        return '${_f((e['cm'] as num).toDouble())} cm';
      case 'spo2':
        return '${_f((e['n'] as num).toDouble())}%';
      case 'pulse':
        return '${_f((e['n'] as num).toDouble())} a minute';
    }
    return '${e['text'] ?? ''}';
  }

  static String _log(Map<String, dynamic> a, Map<String, dynamic> j) {
    final action = _s(a, 'action').isEmpty ? 'add' : _s(a, 'action');
    final logs = j['logs'] as List<Map<String, dynamic>>;
    final p = _who(j, _s(a, 'person'), create: action == 'add');
    final kind = _s(a, 'kind');
    if (action == 'add') {
      final v = _s(a, 'value');
      if (kind.isEmpty || v.isEmpty) return 'Error: give kind and value';
      final unit = _s(a, 'unit').toLowerCase();
      final at = _s(a, 'at').isEmpty
          ? '${_day(now())} ${now().hour.toString().padLeft(2, '0')}:${now().minute.toString().padLeft(2, '0')}'
          : _s(a, 'at');
      final e = <String, dynamic>{'id': _id(j, 'L'), 'person': p['id'], 'kind': kind, 'at': at};
      if (_s(a, 'note').isNotEmpty) e['note'] = _s(a, 'note');
      final n = _num(v);
      switch (kind) {
        case 'bp':
          final bp = _bp(v);
          if (bp == null) return 'Error: blood pressure looks like "130/85"';
          e['sys'] = bp.$1;
          e['dia'] = bp.$2;
          break;
        case 'sugar':
          if (n == null) return 'Error: give the sugar number';
          e['mg'] = _sugarMg(n, unit);
          if (_s(a, 'context').isNotEmpty) e['context'] = _s(a, 'context');
          break;
        case 'temp':
          if (n == null) return 'Error: give the temperature';
          e['c'] = unit.startsWith('f') || n > 50 ? double.parse(((n - 32) * 5 / 9).toStringAsFixed(1)) : n;
          break;
        case 'weight':
          if (n == null) return 'Error: give the weight';
          e['kg'] = unit.startsWith('lb') ? double.parse((n * 0.45359237).toStringAsFixed(1)) : n;
          break;
        case 'height':
          if (n == null) return 'Error: give the height';
          e['cm'] = n;
          p['height_cm'] = n;
          break;
        case 'muac':
          if (n == null) return 'Error: give MUAC in cm';
          e['cm'] = n > 40 ? n / 10 : n;
          break;
        case 'pulse':
        case 'spo2':
          if (n == null) return 'Error: give the number';
          e['n'] = n;
          break;
        default:
          e['text'] = v;
      }
      logs.add(e);
      final (lvl, words) = interpret(kind, e, person: p);
      final tag = lvl == 3 ? 'EMERGENCY' : lvl == 2 ? 'SEE A DOCTOR' : lvl == 1 ? 'WATCH' : 'OK';
      return 'Saved for ${p['name']}: ${kind == 'symptom' || kind == 'note' ? '$kind "${e['text']}"' : '$kind ${_show(e)}'} at $at. '
          '${kind == 'symptom' || kind == 'note' ? '' : '[$tag] $words.'}'
          '${lvl == 3 ? '\n$_emergencyNumbers' : ''}';
    }
    final days = (_num(a['days']) ?? 30).round();
    final from = _today().subtract(Duration(days: days));
    final mine = logs
        .where((e) => e['person'] == p['id'] && (kind.isEmpty || e['kind'] == kind))
        .where((e) => !(_date('${e['at']}'.split(' ').first) ?? _today()).isBefore(from))
        .toList()
      ..sort((x, y) => '${x['at']}'.compareTo('${y['at']}'));
    switch (action) {
      case 'list':
        if (mine.isEmpty) return 'No ${kind.isEmpty ? 'readings' : kind} for ${p['name']} in the last $days days.';
        return '${p['name']}, last $days days (${mine.length}):\n${mine.reversed.take(40).map((e) {
          final (l, w) = interpret('${e['kind']}', e, person: p);
          return '- ${e['at']} ${e['kind']} ${_show(e)}${l > 0 ? ' ($w)' : ''} (${e['id']})';
        }).join('\n')}';
      case 'trend':
        if (kind.isEmpty) return 'Error: trend needs a kind (bp, sugar, weight, temp, pulse, spo2)';
        final pts = mine.where((e) => e['kind'] == kind && kind != 'symptom' && kind != 'note').toList();
        if (pts.length < 2) return 'Need at least 2 $kind readings for a trend; ${pts.length} in the last $days days.';
        return '${_trendText(kind, pts)}\n${_chart(kind, pts, p['name'] as String)}';
      case 'delete':
        final id = _s(a, 'id').toLowerCase();
        final e = logs.where((e) => '${e['id']}'.toLowerCase() == id).firstOrNull;
        if (e == null) return 'Error: no reading with id ${_s(a, 'id')}';
        logs.remove(e);
        return 'Deleted ${e['kind']} ${_show(e)} from ${e['at']}.';
    }
    return 'Error: unknown action $action';
  }

  static double _main(Map<String, dynamic> e) {
    switch (e['kind']) {
      case 'bp':
        return (e['sys'] as num).toDouble();
      case 'sugar':
        return (e['mg'] as num).toDouble();
      case 'temp':
        return (e['c'] as num).toDouble();
      case 'weight':
        return (e['kg'] as num).toDouble();
      case 'height':
      case 'muac':
        return (e['cm'] as num).toDouble();
      default:
        return (e['n'] as num?)?.toDouble() ?? 0;
    }
  }

  static String _trendText(String kind, List<Map<String, dynamic>> pts) {
    final vals = pts.map(_main).toList();
    final avg = vals.reduce((x, y) => x + y) / vals.length;
    final first = vals.first, last = vals.last;
    final hi = vals.reduce((x, y) => x > y ? x : y), lo = vals.reduce((x, y) => x < y ? x : y);
    final unit = const {'bp': 'mmHg (top number)', 'sugar': 'mg/dL', 'temp': 'C', 'weight': 'kg', 'pulse': '/min', 'spo2': '%'}[kind] ?? '';
    var extra = '';
    if (kind == 'bp') {
      final dia = pts.map((e) => (e['dia'] as num).toDouble()).toList();
      extra = ' Average ${_f(avg.roundToDouble())}/${_f((dia.reduce((x, y) => x + y) / dia.length).roundToDouble())}.';
    }
    return '${pts.length} $kind readings from ${'${pts.first['at']}'.split(' ').first} to ${'${pts.last['at']}'.split(' ').first}: '
        'first ${_f(first)}, latest ${_f(last)}, lowest ${_f(lo)}, highest ${_f(hi)}, average ${avg.toStringAsFixed(1)} $unit. '
        'Change ${last - first >= 0 ? '+' : ''}${(last - first).toStringAsFixed(1)}.$extra';
  }

  static String _chart(String kind, List<Map<String, dynamic>> pts, String name) {
    final use = pts.length > 40 ? pts.sublist(pts.length - 40) : pts;
    final labels = [for (final e in use) _shortDate('${e['at']}')];
    Map<String, dynamic> c;
    if (kind == 'bp') {
      c = {
        'type': 'line',
        'title': 'Blood pressure, $name',
        'unit': 'mmHg',
        'labels': labels,
        'series': [
          {'name': 'Top (systolic)', 'values': [for (final e in use) e['sys']]},
          {'name': 'Bottom (diastolic)', 'values': [for (final e in use) e['dia']]},
        ],
      };
    } else {
      final unit = const {'sugar': 'mg/dL', 'temp': 'C', 'weight': 'kg', 'pulse': '/min', 'spo2': '%', 'muac': 'cm', 'height': 'cm'}[kind] ?? '';
      final title = const {'sugar': 'Blood sugar', 'temp': 'Temperature', 'weight': 'Weight', 'pulse': 'Pulse', 'spo2': 'Oxygen', 'muac': 'MUAC', 'height': 'Height'}[kind] ?? kind;
      c = {
        'type': 'line',
        'title': '$title, $name',
        'unit': unit,
        'items': [for (var i = 0; i < use.length; i++) {'label': labels[i], 'value': _main(use[i])}],
      };
    }
    return '```diagram\n${jsonEncode(c)}\n```';
  }

  static String _shortDate(String at) {
    final d = DateTime.tryParse(at.replaceFirst(' ', 'T'));
    if (d == null) return at;
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]}';
  }

  // ------------------------------------------------------------------ pregnancy

  static const _ancWeeks = [12, 20, 26, 30, 34, 36, 38, 40];

  static String _pregnancy(Map<String, dynamic> a, Map<String, dynamic> j) {
    final action = _s(a, 'action').isEmpty ? 'status' : _s(a, 'action');
    if (action == 'danger_signs') return _pregDanger;
    final p = _who(j, _s(a, 'person'), create: action == 'set');
    if (action == 'set') {
      if ('${p['sex'] ?? ''}' == 'male') return 'Error: ${p['name']} is recorded as male.';
      final lmpIn = _date(_s(a, 'lmp'));
      final dueIn = _date(_s(a, 'due'));
      final scan = _date(_s(a, 'scan_date'));
      final sw = _num(a['scan_weeks']);
      final DateTime lmp;
      final String how;
      if (dueIn != null) {
        lmp = dueIn.subtract(const Duration(days: 280));
        how = 'the due date the clinic gave';
      } else if (scan != null && sw != null) {
        final sd = _num(a['scan_days']);
        lmp = scan.subtract(Duration(days: (sw * 7 + (sd ?? 0)).round()));
        how = 'the scan on ${_day(scan)} (${_f(sw)} weeks${sd != null ? ' ${_f(sd)} days' : ''})';
      } else if (lmpIn != null) {
        lmp = lmpIn;
        how = 'the first day of the last period, ${_day(lmpIn)} (LMP + 280 days)';
      } else {
        return 'Error: give lmp (first day of the last period), a scan date with weeks, or the due date the clinic gave';
      }
      final due = dueIn ?? lmp.add(const Duration(days: 280));
      if (lmp.isAfter(_today())) return 'Error: that date is in the future';
      if (_today().difference(lmp).inDays > 44 * 7) return 'Error: that is more than 44 weeks ago. Check the date.';
      p['pregnancy'] = <String, dynamic>{'lmp': _day(lmp), 'due': _day(due), 'how': how};
      p['sex'] = 'female';
      return 'Pregnancy saved for ${p['name']}, from $how.\n${_pregStatus(p)}';
    }
    if (p['pregnancy'] is! Map) return '${p['name']} has no pregnancy recorded. Use health_pregnancy set.';
    switch (action) {
      case 'status':
        return _pregStatus(p);
      case 'visits':
        final lmp = _date('${(p['pregnancy'] as Map)['lmp']}')!;
        final today = _today();
        final lines = <String>[];
        for (var i = 0; i < _ancWeeks.length; i++) {
          final w = _ancWeeks[i];
          final d = lmp.add(Duration(days: w * 7));
          final state = d.isBefore(today.subtract(const Duration(days: 7))) ? 'past' : (d.difference(today).inDays <= 14 ? 'DUE SOON' : 'coming');
          lines.add('${i + 1}. Week ${i == 0 ? 'up to 12' : '$w'}: around ${_day(d)} ($state)');
        }
        return 'Antenatal check-ups for ${p['name']} (WHO: at least 8 contacts):\n${lines.join('\n')}\n'
            'At each: blood pressure, weight, urine, the baby\'s growth and heartbeat; first visit also blood tests (blood group, anaemia, HIV, syphilis, hepatitis B), '
            'iron and folic acid, and tetanus (Td) vaccine as the clinic advises. A scan before 24 weeks if possible.';
      case 'end':
        final old = p.remove('pregnancy');
        p['last_pregnancy'] = old;
        return 'Pregnancy ended in the record for ${p['name']}. If the baby was born, add the baby with health_people (birth date) to track vaccines; '
            'the mother needs postnatal checks within 24 hours, at day 3, at 1-2 weeks and at 6 weeks (WHO).';
    }
    return 'Error: unknown action $action';
  }

  static String _pregStatus(Map<String, dynamic> p) {
    final pr = p['pregnancy'] as Map;
    final lmp = _date('${pr['lmp']}')!;
    final due = _date('${pr['due']}')!;
    final days = _today().difference(lmp).inDays;
    final w = days ~/ 7, d = days % 7;
    final tri = w < 14 ? 'first trimester' : w < 28 ? 'second trimester' : 'third trimester';
    final left = due.difference(_today()).inDays;
    final next = _ancWeeks.map((x) => lmp.add(Duration(days: x * 7))).where((x) => !x.isBefore(_today())).firstOrNull;
    return '${p['name']}: $w weeks $d days pregnant ($tri). Due date ${_day(due)}'
        '${left >= 0 ? ' ($left days to go)' : ' (${-left} days past the due date: she should be seen at the clinic now)'}.'
        '${next != null ? ' Next antenatal check-up around ${_day(next)}.' : ''}'
        '${w >= 37 && left >= 0 ? ' Full term: have the birth plan ready (which hospital, transport, money, a blood donor).' : ''}'
        '${w >= 42 ? ' Over 42 weeks: go to the clinic today.' : ''}';
  }

  static const _pregDanger = 'Pregnancy danger signs: go to hospital NOW for any of these:\n'
      '- Bleeding from the vagina (dhiig bax)\n- Severe headache, blurred vision, fits (madax xanuun daran, aragti cad, suuxdin)\n'
      '- Swollen face and hands with headache\n- Fever, very weak, cannot get out of bed\n- Severe belly pain\n'
      '- Fast or difficult breathing\n- Baby moves less or stops moving\n- Waters break before labour starts\n'
      '- Labour for more than 12 hours\nAfter birth: heavy bleeding (more than one pad soaked in 5 minutes), fever, smelly discharge, '
      'fits, or severe headache are emergencies too.';

  // ------------------------------------------------------------------ children

  /// Somalia routine schedule (Ministry of Health EPI policy, WHO; PCV and rotavirus added April 2025).
  static const _vaccines = [
    ['BCG', 0, 'BCG (TB)'],
    ['OPV0', 0, 'Polio drops 0'],
    ['PENTA1', 42, 'Penta 1 (DTP-HepB-Hib)'],
    ['OPV1', 42, 'Polio drops 1'],
    ['PCV1', 42, 'Pneumococcal 1'],
    ['ROTA1', 42, 'Rotavirus 1'],
    ['PENTA2', 70, 'Penta 2'],
    ['OPV2', 70, 'Polio drops 2'],
    ['PCV2', 70, 'Pneumococcal 2'],
    ['ROTA2', 70, 'Rotavirus 2'],
    ['PENTA3', 98, 'Penta 3'],
    ['OPV3', 98, 'Polio drops 3'],
    ['PCV3', 98, 'Pneumococcal 3'],
    ['IPV1', 98, 'Polio injection 1'],
    ['MCV1', 274, 'Measles 1'],
    ['IPV2', 274, 'Polio injection 2'],
    ['MCV2', 457, 'Measles 2'],
  ];

  static String _child(Map<String, dynamic> a, Map<String, dynamic> j) {
    final action = _s(a, 'action').isEmpty ? 'vaccines' : _s(a, 'action');
    final p = _who(j, _s(a, 'person'), create: false);
    if (action == 'muac') {
      final mu = _num(a['muac_cm']);
      if (mu == null) return 'Error: give muac_cm';
      final e = <String, dynamic>{'id': _id(j, 'L'), 'person': p['id'], 'kind': 'muac', 'cm': mu, 'at': '${_day(now())} 12:00'};
      (j['logs'] as List<Map<String, dynamic>>).add(e);
      final (l, w) = interpret('muac', e, person: p);
      return 'MUAC ${_f(mu)} cm for ${p['name']}${_age(p).isEmpty ? '' : ' (${_age(p)})'}: $w.${l >= 2 ? ' Take the child to a nutrition centre or clinic today.' : ''}'
          '${_ageMonths(p) == null ? ' (No birth date recorded: the MUAC cut-offs are for 6-59 months.)' : ''}';
    }
    final birth = _date('${p['birth'] ?? ''}');
    if (birth == null) return 'Error: ${p['name']} needs a birth date (health_people update birth).';
    final given = Map<String, dynamic>.from((j['vaccines'] as Map)[p['id']] as Map? ?? {});
    final today = _today();
    if (action == 'given') {
      final when = _s(a, 'date').isEmpty ? _day(today) : _s(a, 'date');
      final asked = [for (final v in _list(a['vaccines'])) v.toUpperCase().replaceAll(' ', '').replaceAll('-', '')];
      final codes = asked.contains('ALL_DUE') || asked.contains('ALLDUE')
          ? [for (final v in _vaccines) if (!given.containsKey(v[0]) && !birth.add(Duration(days: v[1] as int)).isAfter(today)) v[0] as String]
          : asked;
      final known = {for (final v in _vaccines) v[0] as String};
      final bad = codes.where((c) => !known.contains(c)).toList();
      for (final c in codes.where(known.contains)) {
        given[c] = when;
      }
      (j['vaccines'] as Map)[p['id']] = given;
      return 'Marked given on $when for ${p['name']}: ${codes.where(known.contains).join(', ')}.'
          '${bad.isEmpty ? '' : ' Unknown codes: ${bad.join(', ')} (use ${known.join(', ')}).'}';
    }
    final lines = <String>[];
    var overdue = 0, due = 0;
    for (final v in _vaccines) {
      final at = birth.add(Duration(days: v[1] as int));
      final code = v[0] as String;
      String state;
      if (given.containsKey(code)) {
        state = 'given ${given[code]}';
      } else if (at.isAfter(today)) {
        state = 'due ${_day(at)}';
      } else if (today.difference(at).inDays > 28) {
        state = 'OVERDUE since ${_day(at)}';
        overdue++;
      } else {
        state = 'DUE NOW (from ${_day(at)})';
        due++;
      }
      lines.add('- ${v[2]} [$code]: $state');
    }
    return 'Vaccines for ${p['name']} (born ${_day(birth)}, ${_age(p)}), Somalia routine schedule:\n${lines.join('\n')}\n'
        '${overdue + due > 0 ? '${overdue + due} due or overdue: take the child and this list to the nearest health centre (free). Missed vaccines can still be given late; the clinic will catch up.\n' : ''}'
        'Source: Somalia Ministry of Health immunization policy (birth, 6, 10, 14 weeks, 9 and 15 months); pneumococcal and rotavirus vaccines were added in April 2025. '
        'The clinic\'s card is the final word.';
  }

  // ------------------------------------------------------------------ visits

  static String _visits(Map<String, dynamic> a, Map<String, dynamic> j) {
    final action = _s(a, 'action').isEmpty ? 'list' : _s(a, 'action');
    final visits = j['visits'] as List<Map<String, dynamic>>;
    final p = _who(j, _s(a, 'person'), create: action == 'add');
    switch (action) {
      case 'add':
        final v = <String, dynamic>{'id': _id(j, 'V'), 'person': p['id'], 'date': _s(a, 'date').isEmpty ? _day(_today()) : _s(a, 'date')};
        for (final k in ['place', 'doctor', 'reason', 'diagnosis', 'tests', 'advice', 'next']) {
          if (_s(a, k).isNotEmpty) v[k] = _s(a, k);
        }
        visits.add(v);
        return 'Visit saved for ${p['name']} on ${v['date']}.${v['next'] != null ? ' Next visit ${v['next']}: offer a reminder with schedule_task the day before.' : ''}';
      case 'list':
        final mine = visits.where((v) => v['person'] == p['id']).toList()..sort((x, y) => '${y['date']}'.compareTo('${x['date']}'));
        if (mine.isEmpty) return 'No visits recorded for ${p['name']}.';
        return 'Visits for ${p['name']}:\n${mine.take(20).map(_visitLine).join('\n')}';
      case 'delete':
        final v = visits.where((v) => '${v['id']}'.toLowerCase() == _s(a, 'id').toLowerCase()).firstOrNull;
        if (v == null) return 'Error: no visit with id ${_s(a, 'id')}';
        visits.remove(v);
        return 'Deleted the visit of ${v['date']}.';
    }
    return 'Error: unknown action $action';
  }

  static String _visitLine(Map<String, dynamic> v) => '- ${v['date']}${v['place'] != null ? ' at ${v['place']}' : ''}'
      '${v['doctor'] != null ? ' (${v['doctor']})' : ''}: ${v['reason'] ?? ''}'
      '${v['diagnosis'] != null ? '; found: ${v['diagnosis']}' : ''}${v['tests'] != null ? '; tests: ${v['tests']}' : ''}'
      '${v['advice'] != null ? '; advice: ${v['advice']}' : ''}${v['next'] != null ? '; next ${v['next']}' : ''} (${v['id']})';

  // ------------------------------------------------------------------ calculator

  static String calc(Map<String, dynamic> a) {
    final mode = _s(a, 'mode');
    switch (mode) {
      case 'bmi':
        final kg = _num(a['weight_kg']), cm = _num(a['height_cm']);
        if (kg == null || cm == null || cm <= 0) return 'Error: give weight_kg and height_cm';
        final m = cm / 100;
        final b = kg / (m * m);
        final lo = 18.5 * m * m, hi = 24.9 * m * m;
        return 'BMI = weight / height² = ${_f(kg)} / (${m.toStringAsFixed(2)} × ${m.toStringAsFixed(2)}) = ${b.toStringAsFixed(1)} (${_bmiWord(b)}, WHO adult bands: '
            'under 18.5 underweight, 18.5-24.9 healthy, 25-29.9 overweight, 30+ obesity). Healthy weight for ${_f(cm)} cm: '
            '${lo.toStringAsFixed(0)}-${hi.toStringAsFixed(0)} kg. Not for children, pregnancy or very muscular people.';
      case 'due_date':
        final lmp = _date(_s(a, 'lmp'));
        if (lmp == null) return 'Error: give lmp YYYY-MM-DD';
        final due = lmp.add(const Duration(days: 280));
        final days = _today().difference(lmp).inDays;
        return 'Due date = first day of last period + 280 days = ${_day(lmp)} + 280 = ${_day(due)}. '
            '${days >= 0 && days < 300 ? 'Today: ${days ~/ 7} weeks ${days % 7} days.' : ''} Only about 1 in 20 babies come on the exact day; '
            'a scan in the first 3 months gives a better date.';
      case 'age':
        final b = _date(_s(a, 'birth'));
        if (b == null) return 'Error: give birth YYYY-MM-DD';
        final days = _today().difference(b).inDays;
        return 'Age: $days days = ${(days / 7).floor()} weeks = ${(days / 30.4375).floor()} months = ${(days / 365.25).floor()} years.';
      case 'convert':
        final v = _num(a['value']);
        final from = _s(a, 'from').toLowerCase();
        if (v == null || from.isEmpty) return 'Error: give value and from';
        if (from.contains('mg')) return '${_f(v)} mg/dL ÷ 18 = ${(v / 18).toStringAsFixed(1)} mmol/L';
        if (from.contains('mmol')) return '${_f(v)} mmol/L × 18 = ${(v * 18).toStringAsFixed(0)} mg/dL';
        if (from == 'c') return '${_f(v)} C × 9/5 + 32 = ${(v * 9 / 5 + 32).toStringAsFixed(1)} F';
        if (from == 'f') return '(${_f(v)} F − 32) × 5/9 = ${((v - 32) * 5 / 9).toStringAsFixed(1)} C';
        if (from == 'kg') return '${_f(v)} kg × 2.2046 = ${(v * 2.20462).toStringAsFixed(1)} lb';
        if (from == 'lb') return '${_f(v)} lb × 0.4536 = ${(v * 0.45359237).toStringAsFixed(1)} kg';
        if (from == 'cm') {
          final inch = v / 2.54;
          return '${_f(v)} cm ÷ 2.54 = ${inch.toStringAsFixed(1)} in = ${(inch / 12).floor()} ft ${(inch % 12).toStringAsFixed(0)} in';
        }
        if (from == 'in') return '${_f(v)} in × 2.54 = ${(v * 2.54).toStringAsFixed(1)} cm';
        return 'Error: from must be mg/dL, mmol/L, C, F, kg, lb, cm or in';
      case 'ors':
        return 'ORS (oral rehydration solution, sonkor iyo cusbo):\n'
            '- Best: a WHO ORS packet from the pharmacy or clinic, mixed in the exact amount of clean water written on the packet (usually 1 litre).\n'
            '- If there is no packet, home mix (WHO/UNICEF): 1 litre of clean boiled and cooled water + 6 level teaspoons of sugar + half a level teaspoon of salt. '
            'Stir until dissolved. Too much salt is harmful, so measure carefully.\n'
            '- Give small sips often (a spoon every 1-2 minutes for small children); after each loose stool give about 50-100 ml (a quarter to half cup) '
            'for under 2 years, 100-200 ml for 2-10 years, as much as wanted for older children and adults.\n'
            '- Keep breastfeeding and feeding. Make fresh ORS every day.\n'
            '- Children with diarrhoea also need zinc for 10-14 days: ask the health worker or pharmacist for the right tablets.\n'
            '- Go to the clinic at once if there is blood in the stool, the child cannot drink, vomits everything, is very sleepy, or the eyes look sunken.';
      case 'water':
        final kg = _num(a['weight_kg']);
        return 'Daily fluid guide for a healthy adult: about 2 litres for women and 2.5 litres for men from drinks (more in heat, when working outdoors, '
            'or breastfeeding)${kg != null ? '; a common rule of thumb is 30-35 ml per kg = ${(kg * 0.03).toStringAsFixed(1)}-${(kg * 0.035).toStringAsFixed(1)} litres for ${_f(kg)} kg' : ''}. '
            'Pale yellow urine means enough. People with heart or kidney disease must follow their doctor\'s fluid limit.';
      case 'dose':
        return 'Medicine doses are not calculated here. Use the dose on the prescription or package, or ask the pharmacist or doctor.';
    }
    return 'Error: mode must be bmi, due_date, age, convert, ors or water';
  }

  // ------------------------------------------------------------------ report

  static Future<String> _report(Map<String, dynamic> a, Map<String, dynamic> j) async {
    final p = _who(j, _s(a, 'person'), create: false);
    final fmt = _s(a, 'format').isEmpty ? 'chat' : _s(a, 'format');
    final days = (_num(a['days']) ?? 90).round();
    final from = _today().subtract(Duration(days: days));
    final meds = (j['meds'] as List<Map<String, dynamic>>).where((m) => m['person'] == p['id'] && m['active'] != false && !_ended(m)).toList();
    final logs = (j['logs'] as List<Map<String, dynamic>>)
        .where((e) => e['person'] == p['id'])
        .where((e) => !(_date('${e['at']}'.split(' ').first) ?? _today()).isBefore(from))
        .toList()
      ..sort((x, y) => '${x['at']}'.compareTo('${y['at']}'));
    final visits = (j['visits'] as List<Map<String, dynamic>>).where((v) => v['person'] == p['id']).toList()
      ..sort((x, y) => '${y['date']}'.compareTo('${x['date']}'));
    final kinds = ['bp', 'sugar', 'weight', 'temp', 'pulse', 'spo2', 'muac'];
    final latest = <String, Map<String, dynamic>>{};
    for (final e in logs) {
      if (kinds.contains(e['kind'])) latest['${e['kind']}'] = e;
    }
    final symptoms = logs.where((e) => e['kind'] == 'symptom' || e['kind'] == 'note').toList();
    final allergies = _list(p['allergies']);
    final conditions = _list(p['conditions']);
    final preg = p['pregnancy'] is Map ? _pregStatus(p) : '';

    if (fmt == 'chat') {
      final sb = StringBuffer('Health summary: ${p['name']}${_age(p).isEmpty ? '' : ', ${_age(p)}'}\n')
        ..writeln('Allergies: ${allergies.isEmpty ? 'none recorded' : allergies.join(', ')}')
        ..writeln('Conditions: ${conditions.isEmpty ? 'none recorded' : conditions.join(', ')}')
        ..writeln('Medicines now: ${meds.isEmpty ? 'none recorded' : meds.map((m) => '${m['name']} ${m['dose']}'.trim()).join('; ')}');
      if (preg.isNotEmpty) sb.writeln(preg);
      if (latest.isNotEmpty) {
        sb.writeln('Latest readings (last $days days):');
        for (final e in latest.values) {
          final w = interpret('${e['kind']}', e, person: p).$2;
          sb.writeln('- ${e['kind']}: ${_show(e)} on ${'${e['at']}'.split(' ').first} ($w)');
        }
      }
      if (symptoms.isNotEmpty) sb.writeln('Recent notes: ${symptoms.reversed.take(5).map((e) => '${'${e['at']}'.split(' ').first} ${e['text']}').join('; ')}');
      if (visits.isNotEmpty) sb.writeln('Last visit: ${_visitLine(visits.first).substring(2)}');
      for (final k in ['bp', 'sugar', 'weight']) {
        final pts = logs.where((e) => e['kind'] == k).toList();
        if (pts.length >= 2) sb.writeln(_chart(k, pts, p['name'] as String));
      }
      return sb.toString().trim();
    }

    final medRows = [for (final m in meds) [m['name'], m['dose'] ?? '', _list(m['times']).join(', '), m['with_food'] ?? '', m['purpose'] ?? '', m['start'] ?? '']];
    final readRows = [
      for (final e in logs.reversed.where((e) => kinds.contains(e['kind'])).take(60))
        [e['at'], e['kind'], _show(e), interpret('${e['kind']}', e, person: p).$2],
    ];
    final visitRows = [for (final v in visits.take(15)) [v['date'], v['place'] ?? '', v['reason'] ?? '', v['diagnosis'] ?? '', v['tests'] ?? '', v['advice'] ?? '']];

    if (fmt == 'xlsx') {
      final rows = <List<dynamic>>[
        ['Name', p['name'], '', ''],
        ['Age', _age(p), '', ''],
        ['Allergies', allergies.join(', '), '', ''],
        ['Conditions', conditions.join(', '), '', ''],
        ['', '', '', ''],
        ['Date', 'Kind', 'Reading', 'Meaning'],
        ...readRows,
      ];
      return _saved(await _out('Health ${p['name']}', 'xlsx', DocMaker.xlsxBytes('Health', ['Item', 'Value', '', ''], rows)));
    }

    final parts = <ReportPart>[
      ReportPart.figures([
        ['Age', _age(p).isEmpty ? '-' : _age(p)],
        ['Blood group', '${p['blood_group'] ?? '-'}'],
        ['Medicines', '${meds.length}'],
      ]),
      ReportPart.heading('Allergies and conditions'),
      ReportPart.text('Allergies: ${allergies.isEmpty ? 'none recorded' : allergies.join(', ')}'),
      ReportPart.text('Long-term conditions: ${conditions.isEmpty ? 'none recorded' : conditions.join(', ')}'),
      if (preg.isNotEmpty) ...[ReportPart.heading('Pregnancy'), ReportPart.text(preg)],
      ReportPart.heading('Medicines now'),
      if (medRows.isEmpty) ReportPart.text('None recorded.') else ReportPart.table('', ['Medicine', 'Dose', 'Times', 'Food', 'For', 'Since'], medRows),
      if (latest.isNotEmpty) ...[
        ReportPart.heading('Latest readings'),
        ReportPart.table('', ['Kind', 'Reading', 'Date', 'Meaning'], [
          for (final e in latest.values) [e['kind'], _show(e), '${e['at']}'.split(' ').first, interpret('${e['kind']}', e, person: p).$2],
        ]),
      ],
      for (final k in ['bp', 'sugar', 'weight'])
        if (logs.where((e) => e['kind'] == k).length >= 2)
          ReportPart.columnsChart(
              const {'bp': 'Blood pressure (top number), mmHg', 'sugar': 'Blood sugar, mg/dL', 'weight': 'Weight, kg'}[k]!,
              [for (final e in logs.where((e) => e['kind'] == k).toList().reversed.take(14).toList().reversed) MapEntry(_shortDate('${e['at']}'), _main(e))]),
      if (readRows.isNotEmpty) ...[ReportPart.heading('All readings, last $days days'), ReportPart.table('', ['When', 'Kind', 'Reading', 'Meaning'], readRows)],
      if (symptoms.isNotEmpty) ...[
        ReportPart.heading('Symptoms and notes'),
        ReportPart.table('', ['When', 'Note'], [for (final e in symptoms.reversed.take(20)) [e['at'], e['text']]]),
      ],
      if (visitRows.isNotEmpty) ...[ReportPart.heading('Visits'), ReportPart.table('', ['Date', 'Place', 'Reason', 'Found', 'Tests', 'Advice'], visitRows)],
      ReportPart.text('Made with Telesia from what the family recorded. It is not a medical record or a diagnosis; the doctor\'s own notes come first.'),
    ];
    final bytes = await BizPdf.report('Health summary: ${p['name']}', 'Prepared ${_day(_today())}', parts);
    return _saved(await _out('Health summary ${p['name']}', 'pdf', bytes));
  }
}
