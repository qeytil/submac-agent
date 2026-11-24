/// Built-in skills for the Investigation section (the private-detective environment).
///
/// These ship inside the app and are listed and readable offline, exactly like [ApkBuild] and [DesignSkills]
/// built-ins. Unlike those, the bodies are large Markdown files under `assets/skills/` (declared in
/// `pubspec.yaml`), so they are kept as files rather than Dart strings; [SkillLibrary.body] loads the asset
/// while [SkillLibrary.builtInBody] keeps its fast synchronous path for the in-Dart skills.
///
/// The OSINT investigator is the brain of a case: it holds the mindset, the operating rules, the toolkit,
/// the investigation playbooks, the confidence model, the geolocation and image/video/audio/document analysis
/// methods, the clue reasoning loop, Solo/Partner behaviour, the case-memory files and the report format.
class CaseSkills {
  CaseSkills._();

  /// The main investigator skill (the whole OSINT method).
  static const osintId = 'telesia-osint-investigator';

  /// The asset that holds the full body of each built-in case skill.
  static const _assets = {osintId: 'assets/skills/telesia-osint-investigator.md'};

  static const ids = {osintId};

  /// Library index lines (same shape as the shared library's `index.json` entries).
  static const skills = <Map<String, Object>>[
    {
      'id': osintId,
      'name': 'OSINT investigator',
      'cat': 'investigation',
      'sub': 'Investigation',
      'desc': 'Full cybersecurity, OSINT and technical investigation analyst. Given a name, email, phone number, username, '
          'domain, IP, place, country, case file or error, it investigates public sources, finds patterns, correlates '
          'evidence and produces a sourced, confidence-rated report. Image, video, audio and document analysis; '
          'geolocation by clue reasoning; Codespaces engine; the phone as the vault.',
      'tags': ['investigation', 'osint', 'detective', 'case', 'person', 'name', 'email', 'phone', 'username', 'domain',
        'ip', 'geolocation', 'image analysis', 'video analysis', 'audio analysis', 'document analysis', 'exif',
        'missing person', 'cyber', 'breach', 'whois', 'dns', 'report', 'case file'],
      'powers': <String>[],
      'level': 'pro',
      'v': 1,
    },
  ];

  /// The asset path for a built-in case skill, or null when [id] is not one.
  static String? assetOf(String id) => _assets[id];

  /// Whether [id] belongs to the Investigation section's built-ins.
  static bool isCase(String id) => _assets.containsKey(id);

  /// The house rule for the case prompt: the investigator reads this skill before working.
  static const promptRule = 'Investigation section: you are a private investigator and technical analyst. Before working a '
      'case, read skill_use $osintId and follow it (mindset, public sources only, confidence ratings, clue reasoning, '
      'report format). Track every claim with its source and confidence; report locations as probabilities, never a '
      'certain address.';
}
