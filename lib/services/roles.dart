/// Plan 5.2 "Hire, don't build": pick a role, answer three short questions, and the new colleague does a real first
/// job right away. Everything here is plain data and pure functions (unit tested); the hire itself is in AppState.
library;

class RoleQuestion {
  const RoleQuestion(this.key, this.ask, {this.hint = '', this.chips = const [], this.fallback = ''});
  final String key;
  final String ask;
  final String hint;
  /// One-tap answers. The owner can always type their own.
  final List<String> chips;
  /// Used when the owner skips the question.
  final String fallback;
}

class BotRole {
  const BotRole({
    required this.id,
    required this.title,
    required this.name,
    required this.icon,
    required this.pitch,
    required this.persona,
    required this.questions,
    required this.firstTask,
    this.voice = '',
    this.routine = '',
    this.routineKind = 'message',
    this.routineDays = 'daily',
    this.scheduleKey = '',
    this.defaultTime = '08:00',
    this.proactivity = 'balanced',
    this.heartbeatHours = 0,
    this.mission = '',
  });

  final String id;
  /// The job title, e.g. "Researcher".
  final String title;
  /// The colleague's first name.
  final String name;
  final String icon;
  final String voice;
  /// One line on the role card.
  final String pitch;
  final String persona;
  final String mission;
  final List<RoleQuestion> questions;
  /// The first real job, with {key} placeholders for the answers.
  final String firstTask;
  /// The standing responsibility (a routine), with {key} placeholders. '' = none.
  final String routine;
  final String routineKind;
  /// Days of the routine when no answer says when (daily | weekdays | mon,thu ...).
  final String routineDays;
  /// Which answer says when the routine runs ('' = the role's own default time, daily).
  final String scheduleKey;
  final String defaultTime;
  final String proactivity;
  final int heartbeatHours;
}

/// The ready roles shown first when hiring.
class BotRoles {
  static const all = <BotRole>[
    BotRole(
      id: 'researcher',
      title: 'Researcher',
      name: 'Nova',
      icon: 'travel_explore',
      voice: 'Aoede',
      pitch: 'Keeps an eye on any topic and briefs you with sources.',
      persona: 'You are a world-class research analyst: curious, rigorous and fast. You find primary sources, compare them, '
          'separate facts from claims, and always cite links. You track the topics your user cares about, notice what changed, '
          'and bring only what matters, with the "so what" for them.',
      questions: [
        RoleQuestion('topic', 'What should I keep an eye on?', hint: 'e.g. coffee prices in East Africa, my competitors', fallback: 'the news that matters to my work'),
        RoleQuestion('when', 'When do you want your brief?', chips: ['Every morning', 'Weekdays only', 'Once a week', 'Only when something big happens'], fallback: 'Every morning'),
        RoleQuestion('style', 'How do you like it?', chips: ['Short bullets', 'A full brief', 'Just the headline'], fallback: 'Short bullets'),
      ],
      firstTask: 'Make your first brief on: {topic}. Find what is new and important right now, with a source link for each point. '
          'Format: {style}.',
      routine: 'Check {topic} for anything new and important since your last brief. If something matters, send it ({style}, '
          'each point with a link). If nothing matters, stay silent.',
      scheduleKey: 'when',
      defaultTime: '08:00',
      heartbeatHours: 0,
    ),
    BotRole(
      id: 'writer',
      title: 'Social media writer',
      name: 'Idil',
      icon: 'edit',
      voice: 'Leda',
      pitch: 'Writes posts in your voice, ready to copy and share.',
      persona: 'You are a sharp social media writer. You write short, human posts that stop the scroll: a strong first line, '
          'one clear idea, a simple call to action. You match each platform\'s style and the owner\'s tone, and you never '
          'invent facts about their business.',
      questions: [
        RoleQuestion('what', 'What do you sell or promote?', hint: 'e.g. handmade perfumes, my coaching, a restaurant', fallback: 'my business'),
        RoleQuestion('where', 'Where do you post?', chips: ['Instagram', 'Facebook', 'TikTok', 'LinkedIn', 'WhatsApp status'], fallback: 'Instagram'),
        RoleQuestion('tone', 'What tone fits you?', chips: ['Friendly', 'Professional', 'Bold', 'Funny'], fallback: 'Friendly'),
      ],
      firstTask: 'Write 3 ready-to-post drafts for {where} about {what}, in a {tone} tone. Each with a hook line, the post and '
          'hashtags only if they fit. Number them so the owner can pick one.',
      routine: 'Suggest 3 fresh post ideas for {where} about {what} ({tone} tone), each with a draft first line.',
      defaultTime: '09:00',
      routineKind: 'message',
      routineDays: 'mon,thu',
    ),
    BotRole(
      id: 'seo',
      title: 'Website and SEO',
      name: 'Rank',
      icon: 'trending_up',
      voice: 'Puck',
      pitch: 'Checks your website and tells you the next three fixes.',
      persona: 'You are a senior SEO strategist. You think in search intent, technical health, content quality and links. You '
          'check the live site before you claim anything, and you give prioritised, concrete actions with the expected impact.',
      questions: [
        RoleQuestion('site', 'What is your website?', hint: 'e.g. myshop.com', fallback: 'my website (ask me for the address)'),
        RoleQuestion('goal', 'What matters most?', chips: ['More visitors', 'More leads', 'More sales'], fallback: 'More visitors'),
        RoleQuestion('market', 'Which country and language?', hint: 'e.g. Kenya, English', fallback: 'my country and language'),
      ],
      firstTask: 'Do a quick first check of {site} on the live site: title, description, headings, speed signals and anything '
          'clearly broken. Give the top 3 fixes for {goal} in {market}, most important first.',
      routine: 'Do the weekly check of {site}: new problems, changes you can see, and the top 3 actions this week for {goal}. '
          'Send it only if there is something worth acting on.',
      defaultTime: '10:00',
      routineKind: 'work',
      routineDays: 'mon',
    ),
    BotRole(
      id: 'tutor',
      title: 'Tutor',
      name: 'Ustad',
      icon: 'school',
      voice: 'Charon',
      pitch: 'Teaches you anything in small daily lessons.',
      persona: 'You are an inspiring, patient teacher who can teach any subject and language at any level. You teach in small '
          'pieces with examples, check understanding with quick questions, correct kindly, and review what was forgotten.',
      questions: [
        RoleQuestion('subject', 'What do you want to learn?', hint: 'e.g. English, Excel, the Quran, accounting', fallback: 'something new'),
        RoleQuestion('level', 'Where are you now?', chips: ['Beginner', 'Some basics', 'Intermediate', 'Advanced'], fallback: 'Beginner'),
        RoleQuestion('when', 'When are lessons best?', chips: ['Every morning', 'Every evening', 'Weekends', 'When I ask'], fallback: 'Every evening'),
      ],
      firstTask: 'Give the first 5-minute lesson on {subject} for a learner at level "{level}": one idea, a clear example, and '
          '3 quick questions to check understanding.',
      routine: 'Give today\'s short lesson on {subject} (level {level}): build on the last one, review one thing from before, '
          'end with 2 quick questions.',
      scheduleKey: 'when',
      defaultTime: '19:00',
    ),
    BotRole(
      id: 'legal',
      title: 'Legal helper',
      name: 'Amal',
      icon: 'gavel',
      voice: 'Kore',
      pitch: 'Explains your rights and checks documents in plain words.',
      persona: 'You are a careful, plain-spoken legal consultant. You explain rights and options in simple words, spot risks in '
          'documents clause by clause, and always say which country\'s law you assume. You give general legal information, not '
          'a lawyer-client relationship, and recommend a licensed local lawyer for high stakes. You never invent laws or cases.',
      questions: [
        RoleQuestion('country', 'Which country are you in?', hint: 'e.g. Somalia, Kenya, UAE', fallback: 'my country (ask me)'),
        RoleQuestion('area', 'What do you need help with?', chips: ['Contracts', 'Work and employment', 'My business', 'Rent and property'], fallback: 'Contracts'),
        RoleQuestion('now', 'Anything to look at right now?', hint: 'Optional: describe it in a line', fallback: ''),
      ],
      firstTask: 'Give a short, plain overview of the 5 most important things to know about {area} in {country}, each in one '
          'line, with what to watch out for. Then start on this if it is filled in: {now}',
      proactivity: 'quiet',
    ),
    BotRole(
      id: 'sales',
      title: 'Sales follow-up',
      name: 'Bashir',
      icon: 'payments',
      voice: 'Orus',
      pitch: 'Writes follow-ups that bring customers back.',
      persona: 'You are a friendly, persistent sales lead. You help the owner follow up with customers at the right time, '
          'with short messages that feel personal, and you track who is waiting for an answer.',
      questions: [
        RoleQuestion('what', 'What do you sell?', hint: 'e.g. phones, cleaning services, school fees', fallback: 'my products'),
        RoleQuestion('who', 'Who are your customers?', hint: 'e.g. families in Mogadishu, small shops', fallback: 'my customers'),
        RoleQuestion('channel', 'How do they reach you?', chips: ['WhatsApp', 'Phone calls', 'Email', 'In my shop'], fallback: 'WhatsApp'),
      ],
      firstTask: 'Write a simple follow-up kit for selling {what} to {who} over {channel}: 3 ready-to-send messages (first '
          'contact, a friendly reminder, a thank-you) and one idea to win back old customers.',
      routine: 'Look at your desk and memory for customers waiting on a follow-up and draft the messages for the owner to send.',
      defaultTime: '10:00',
      routineKind: 'work',
    ),
    BotRole(
      id: 'coach',
      title: 'Personal coach',
      name: 'Sagal',
      icon: 'fitness_center',
      voice: 'Fenrir',
      pitch: 'Checks in on your goal and keeps you going.',
      persona: 'You are a warm, practical coach. You turn a goal into small daily steps, check in briefly, celebrate progress '
          'and adjust the plan when life gets in the way.',
      questions: [
        RoleQuestion('goal', 'What is your goal?', hint: 'e.g. walk 8,000 steps, sleep by 11, save \$50 a week', fallback: 'a healthier routine'),
        RoleQuestion('when', 'When should I check in?', chips: ['Every morning', 'Every evening', 'Weekdays only'], fallback: 'Every morning'),
        RoleQuestion('style', 'How should I push you?', chips: ['Gentle', 'Balanced', 'Tough love'], fallback: 'Balanced'),
      ],
      firstTask: 'Make a simple 7-day starter plan for: {goal}. One small step per day, in a {style} coaching style. Keep it short.',
      routine: 'Check in on {goal}: one short, {style} message with today\'s small step.',
      scheduleKey: 'when',
      defaultTime: '07:30',
    ),
    BotRole(
      id: 'money',
      title: 'Money keeper',
      name: 'Faisal',
      icon: 'work',
      voice: 'Zephyr',
      pitch: 'Tracks spending or sales and sends a short summary.',
      persona: 'You are a calm, exact bookkeeper. You keep simple records of money in and out, spot what changed, and explain '
          'it in plain words without judgement.',
      questions: [
        RoleQuestion('what', 'What should I keep track of?', chips: ['My spending', 'My shop\'s sales', 'A savings goal'], fallback: 'My spending'),
        RoleQuestion('currency', 'Which currency?', chips: ['USD', 'KES', 'SOS', 'AED'], fallback: 'USD'),
        RoleQuestion('when', 'When do you want the summary?', chips: ['Every evening', 'Every Sunday', 'Once a week'], fallback: 'Every Sunday'),
      ],
      firstTask: 'Set up a simple tracker for {what} in {currency}: a small table with the right categories, ready to fill, and '
          '3 tips to start. Explain in one line how the owner can tell you new numbers.',
      routine: 'Send a short summary of {what} in {currency} from what the owner told you: totals, what changed, one tip.',
      scheduleKey: 'when',
      defaultTime: '19:00',
    ),
  ];

  static BotRole? byId(String id) => all.where((r) => r.id == id).firstOrNull;

  /// Questions for a colleague the owner described in their own words.
  static const custom = [
    RoleQuestion('start', 'What should they start on today?', hint: 'One real task', fallback: 'whatever helps me most this week'),
    RoleQuestion('when', 'When should they check in?', chips: ['Every morning', 'Every evening', 'Once a week', 'Only when I ask'], fallback: 'Only when I ask'),
    RoleQuestion('rules', 'Anything they should always do or avoid?', hint: 'Optional', fallback: ''),
  ];
}

/// Turns a role and three answers into a ready colleague.
class RoleHire {
  /// "Every morning" / "Weekdays only" / "7:30" / "8pm" -> (HH:MM, days), or null when there is no fixed time
  /// ("Only when something big happens", "When I ask").
  static (String, String)? scheduleFrom(String answer, String defaultTime) {
    final a = answer.trim().toLowerCase();
    if (a.isEmpty) return (defaultTime, 'daily');
    if (RegExp(r'(when i ask|only when|big happens|never|no thanks)').hasMatch(a)) return null;
    var time = defaultTime;
    final m = RegExp(r'\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b').firstMatch(a);
    if (m != null && (m.group(2) != null || m.group(3) != null)) {
      var h = int.parse(m.group(1)!);
      final min = int.tryParse(m.group(2) ?? '0') ?? 0;
      if (m.group(3) == 'pm' && h < 12) h += 12;
      if (m.group(3) == 'am' && h == 12) h = 0;
      if (h <= 23 && min <= 59) time = '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
    } else if (a.contains('morning')) {
      time = defaultTime.compareTo('12:00') < 0 ? defaultTime : '08:00';
    } else if (a.contains('evening') || a.contains('night')) {
      time = defaultTime.compareTo('17:00') >= 0 ? defaultTime : '19:00';
    } else if (a.contains('midday') || a.contains('noon') || a.contains('lunch')) {
      time = '12:30';
    }
    var days = 'daily';
    if (a.contains('weekday')) {
      days = 'weekdays';
    } else if (a.contains('weekend')) {
      days = 'weekends';
    } else if (a.contains('sunday')) {
      days = 'sun';
    } else if (a.contains('friday')) {
      days = 'fri';
    } else if (a.contains('week')) {
      days = 'mon';
    }
    return (time, days);
  }

  /// The answers with skipped ones filled in.
  static Map<String, String> filled(List<RoleQuestion> qs, Map<String, String> answers) => {
        for (final q in qs) q.key: (answers[q.key] ?? '').trim().isEmpty ? q.fallback : answers[q.key]!.trim(),
      };

  static String fill(String template, Map<String, String> answers) {
    var t = template;
    answers.forEach((k, v) => t = t.replaceAll('{$k}', v));
    // A placeholder with no answer, and a trailing "...: " left empty, read cleanly.
    t = t.replaceAll(RegExp(r'\{[a-z]+\}'), '').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    return t.replaceFirst(RegExp(r'(Then start on this if it is filled in:)\s*$'), '').trim();
  }

  /// Everything the new colleague is made of: the spec for Bots.create, plus `instructions`, `memory` (lines it knows
  /// about the owner from the answers) and `first_task` (the job it does right away).
  static Map<String, dynamic> spec(BotRole r, Map<String, String> answers) {
    final a = filled(r.questions, answers);
    final when = r.scheduleKey.isEmpty ? (r.defaultTime, r.routineDays) : scheduleFrom(a[r.scheduleKey] ?? '', r.defaultTime);
    final routines = <Map<String, dynamic>>[
      if (r.routine.isNotEmpty && when != null)
        {'time': when.$1, 'days': when.$2, 'kind': r.routineKind, 'do': fill(r.routine, a)},
    ];
    final memory = <String>[
      for (final q in r.questions)
        if ((answers[q.key] ?? '').trim().isNotEmpty) '${q.ask.replaceAll('?', '')}: ${answers[q.key]!.trim()}',
    ];
    return {
      'name': r.name,
      'role': r.title,
      'persona': r.persona,
      'mission': r.mission,
      'icon': r.icon,
      'proactivity': r.proactivity,
      'heartbeat_hours': r.heartbeatHours,
      'first_meeting': '',
      'routines': routines,
      'voice': r.voice,
      'instructions': [
        for (final q in r.questions)
          if ((a[q.key] ?? '').isNotEmpty) '- ${q.ask} ${a[q.key]}',
      ].join('\n'),
      'memory': memory,
      'first_task': fill(r.firstTask, a),
    };
  }

  /// A colleague the owner described: the three custom answers become its first job, check-in and rules.
  static Map<String, dynamic> customExtras(Map<String, String> answers, {String defaultTime = '08:00'}) {
    final a = filled(BotRoles.custom, answers);
    final when = scheduleFrom(a['when'] ?? '', defaultTime);
    return {
      'first_task': 'Start on this now: ${a['start']}.',
      'instructions': (a['rules'] ?? '').isEmpty ? '' : a['rules'],
      'memory': [if ((answers['start'] ?? '').trim().isNotEmpty) 'First thing they asked for: ${answers['start']!.trim()}'],
      'routines': [
        if (when != null) {'time': when.$1, 'days': when.$2, 'kind': 'message', 'do': 'Check in: progress on what you own, and the next useful step.'},
      ],
    };
  }

  /// A free first name for a new colleague ("Nova", then "Nova 2"...).
  static String freeName(String name, Iterable<String> taken) {
    final low = {for (final t in taken) t.toLowerCase()};
    if (!low.contains(name.toLowerCase())) return name;
    var n = 2;
    while (low.contains('$name $n'.toLowerCase())) {
      n++;
    }
    return '$name $n';
  }

  /// The instruction for the first wake: deliver a real result while the owner watches.
  static String firstJobPrompt(String task) =>
      'This is your first job, right now, while they watch: $task\n'
      'Say one warm line about who you are, then deliver the real result (use your tools; keep it tight, or make a document '
      'if it is long). End with one line on what you will do next for them. No questions before the result.';
}
