/// The Investigation section's abilities: the small, plain vocabulary that gates the many Telesia tools.
///
/// There is no raw tool list in the UI. A case carries a map of ability id -> level (off | ask | on); the
/// tool router turns a tool into its ability and reads the level (phase 4). The default set is broad, because
/// the owner wants the detective to use the phone's sensors, its location and everything the phone offers on
/// the user's behalf without ticking boxes each time. Phone records (contacts, SMS, call log) are opt-in.
class CaseAbilities {
  CaseAbilities._();

  static const off = 'off';
  static const ask = 'ask';
  static const on = 'on';

  static const all = <Ability>[
    Ability('case-files', 'Case files',
        'Read and write the case folder: briefs, evidence, notes and reports.'),
    Ability('photos-media', 'Photos, video and audio',
        'See images and video, hear audio, read EXIF and metadata, analyse and annotate exhibits.'),
    Ability('web-research', 'Web research',
        'Search the web, read pages, follow links and check public sources.'),
    Ability('sensors-location', 'Sensors and location',
        'Use the phone\'s sensors and location: GPS, camera, microphone, and place lookups and maps.'),
    Ability('phone-powers', 'Phone powers',
        'Use everything else the phone offers on your behalf: alarms, timers, calendar drafts, sharing, opening apps and links, reading notifications.'),
    Ability('social-check', 'Social cross-check',
        'Check public social profiles and connected apps, read-only.'),
    Ability('report-writing', 'Report writing',
        'Build the case report and dossier as real files.'),
    Ability('phone-records', 'Phone records (opt-in)',
        'Read contacts, text messages and the call log. Off by default; turn it on for a case that needs it.'),
  ];

  /// On by default (the broad set the owner asked for).
  static const defaultOn = {'case-files', 'photos-media', 'web-research', 'sensors-location', 'phone-powers', 'report-writing'};

  /// Never in the default set; turned on per case.
  static const optIn = {'phone-records'};

  /// The editable default set (Settings → Investigation). Seeded from [initialDefaults]; the store keeps changes.
  static Map<String, String> defaults = initialDefaults();

  /// The broad seed the owner asked for: the phone's sensors, location and everything it offers on their behalf.
  static Map<String, String> initialDefaults() => {for (final a in all) a.id: defaultOn.contains(a.id) ? on : off};

  static Ability? byId(String id) {
    for (final a in all) {
      if (a.id == id) return a;
    }
    return null;
  }

  static String label(String id) => byId(id)?.name ?? id;

  /// The level of an ability in a set of levels (defaults to off when absent).
  static String levelOf(Map<String, String> levels, String id) => levels[id] ?? off;

  static Map<String, String> defaultLevels() => Map.of(defaults);

  /// Fills in any abilities a stored case predates, so new abilities appear (off) instead of vanishing.
  static Map<String, String> missingDefaults(Object? existing) {
    final have = existing is Map ? existing.keys.map((e) => '$e').toSet() : <String>{};
    return {for (final a in all) if (!have.contains(a.id)) a.id: defaults[a.id] ?? off};
  }

  /// A stored ability map with any new abilities added (off), ready to keep on a [Case].
  static Map<String, String> merge(Object? existing) {
    final out = <String, String>{};
    if (existing is Map) {
      for (final e in existing.entries) {
        out['${e.key}'] = '${e.value}';
      }
    }
    out.addAll(missingDefaults(existing));
    return out;
  }

  /// One line for the case prompt: what the detective may use.
  static String promptLine(Map<String, String> levels) {
    final names = [for (final a in all) if (levelOf(levels, a.id) == on) a.name];
    final asks = [for (final a in all) if (levelOf(levels, a.id) == ask) a.name];
    if (names.isEmpty && asks.isEmpty) return 'Abilities: none on. Only what the user asks directly.';
    final sb = StringBuffer();
    if (names.isNotEmpty) sb.write('Abilities on: ${names.join(', ')}.');
    if (asks.isNotEmpty) sb.write('${names.isEmpty ? '' : ' '}Asks first: ${asks.join(', ')}.');
    return sb.toString();
  }
}

class Ability {
  final String id;
  final String name;
  final String blurb;
  const Ability(this.id, this.name, this.blurb);
}
