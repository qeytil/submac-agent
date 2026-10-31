import 'page_model.dart';

/// A site skill (playbook): the steps of a flow that worked once, replayed later with no model calls.
/// Targets are matched by signature (kind + visible label + href), never by coordinates — the page
/// can move between visits and the step still lands on the same control.

/// One recorded step.
class PlayStep {
  PlayStep({
    required this.act,
    this.kind = '',
    this.label = '',
    this.href = '',
    this.value = '',
    this.submit = false,
    this.nth = 0,
  });

  /// click | type | select | scroll | key | wait
  final String act;

  /// The snapshot kind of the target ("button", "link", "field(text)", "dropdown").
  final String kind;

  /// The visible label (what a person would read on the control).
  final String label;

  /// A link's target, when it is a link.
  final String href;

  /// Typed text, chosen option, key name or scroll direction.
  final String value;
  final bool submit;

  /// Which match among identical signatures (0 = the first).
  final int nth;

  Map<String, dynamic> toJson() => {
        'do': act,
        if (kind.isNotEmpty) 'k': kind,
        if (label.isNotEmpty) 't': label,
        if (href.isNotEmpty) 'h': href,
        if (value.isNotEmpty) 'v': value,
        if (submit) 's': true,
        if (nth > 0) 'n': nth,
      };

  static PlayStep? fromJson(Map j) {
    final a = '${j['do'] ?? ''}';
    if (a.isEmpty) return null;
    return PlayStep(
      act: a,
      kind: '${j['k'] ?? ''}',
      label: '${j['t'] ?? ''}',
      href: '${j['h'] ?? ''}',
      value: '${j['v'] ?? ''}',
      submit: j['s'] == true,
      nth: (j['n'] as num?)?.toInt() ?? 0,
    );
  }

  /// "click button "Place order"" — what the agent and the user read.
  String get line {
    final what = kind.isEmpty ? 'it' : kind.split('(').first;
    final lab = label.isEmpty ? '' : ' "$label"';
    final v = value.isEmpty ? '' : ' "${value.length > 40 ? '${value.substring(0, 40)}…' : value}"';
    return switch (act) {
      'type' => 'type into $what$lab:$v${submit ? ' then Enter' : ''}',
      'select' => 'choose$v in $what$lab',
      'scroll' => 'scroll $value',
      'key' => 'press $value',
      'wait' => 'wait ${value.isEmpty ? 'a moment' : value}',
      _ => '$act $what$lab',
    };
  }
}

/// The kind family a signature belongs to: a "field(password)" only matches fields, a link only links.
String kindFamily(String kind) {
  final s = kind.toLowerCase();
  if (s.startsWith('field') || s.startsWith('textbox') || s.startsWith('combobox')) return 'field';
  if (s.startsWith('dropdown')) return 'dropdown';
  if (s.startsWith('button')) return 'button';
  if (s.startsWith('link')) return 'link';
  if (s.startsWith('tab')) return 'tab';
  if (s.startsWith('checkbox') || s.startsWith('radio') || s.startsWith('switch')) return 'check';
  return 'any';
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'[.,;:!?…]+$'), '').trim();

/// The element a step means, on the page as it is now. Null = the page changed; the agent takes over.
PageElement? resolveStep(PlayStep step, List<PageElement> els) {
  final want = kindFamily(step.kind);
  bool kindOk(PageElement e) => want == 'any' || kindFamily(e.kind) == want;
  final lab = _norm(step.label);
  var c = <PageElement>[
    if (lab.isNotEmpty) for (final e in els) if (kindOk(e) && _norm(e.label) == lab) e,
  ];
  if (c.isEmpty && lab.isNotEmpty) c = [for (final e in els) if (kindOk(e) && _norm(e.label).contains(lab)) e];
  if (c.isEmpty && step.href.isNotEmpty) c = [for (final e in els) if (kindOk(e) && e.href == step.href) e];
  if (c.isEmpty && lab.isEmpty) c = [for (final e in els) if (kindOk(e)) e];
  if (c.isEmpty) return null;
  final k = step.nth.clamp(0, c.length - 1).toInt();
  return c[k];
}

/// The acts a playbook can replay.
const playActs = {'click', 'type', 'select', 'scroll', 'key', 'wait'};

/// Turns the raw actions of a successful job into the shortest honest list of steps:
/// unresolvable actions and empty typed values are dropped, repeated scrolls collapse, the list is capped.
List<PlayStep> compressSteps(List<Map<String, dynamic>> rec, {int cap = 40}) {
  final out = <PlayStep>[];
  for (final r in rec) {
    final s = PlayStep.fromJson(r);
    if (s == null || !playActs.contains(s.act)) continue;
    if (s.kind.contains('password')) continue; // a saved skill never carries a password
    if (s.act == 'type' && s.value.trim().isEmpty) continue;
    if (s.act == 'select' && s.value.trim().isEmpty) continue;
    if ((s.act == 'click' || s.act == 'type' || s.act == 'select') && s.label.isEmpty && s.href.isEmpty) continue;
    final last = out.isEmpty ? null : out.last;
    if (s.act == 'scroll' && last != null && last.act == 'scroll' && last.value == s.value) continue;
    out.add(s);
    if (out.length >= cap) break;
  }
  return out;
}

/// One saved site skill.
class Playbook {
  Playbook({
    required this.id,
    required this.name,
    required this.site,
    this.goal = '',
    required this.steps,
    this.runs = 0,
    this.wins = 0,
    this.at = '',
  });

  final String id;
  final String name;

  /// The host it was recorded on ("shop.test"); a subdomain matches too.
  final String site;
  final String goal;
  final List<PlayStep> steps;
  final int runs;
  final int wins;
  final String at;

  String get line => '$id: $name — $site, ${steps.length} steps${runs > 0 ? ' ($runs runs, $wins worked)' : ''}';

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        'name': name,
        'site': site,
        'goal': goal,
        'steps': [for (final s in steps) s.toJson()],
        'runs': runs,
        'wins': wins,
        'at': at,
      };

  static Playbook? fromJson(Map j) {
    final id = '${j['id'] ?? ''}';
    final steps = [
      for (final s in (j['steps'] as List? ?? const []))
        if (s is Map) PlayStep.fromJson(s),
    ].whereType<PlayStep>().toList();
    if (id.isEmpty || steps.isEmpty) return null;
    return Playbook(
      id: id,
      name: '${j['name'] ?? id}',
      site: '${j['site'] ?? ''}',
      goal: '${j['goal'] ?? ''}',
      steps: steps,
      runs: (j['runs'] as num?)?.toInt() ?? 0,
      wins: (j['wins'] as num?)?.toInt() ?? 0,
      at: '${j['at'] ?? ''}',
    );
  }

  /// A readable body for "Your own skills" (the machine format stays in the playbook file).
  String get readable {
    final sb = StringBuffer('# $name\n')
      ..writeln('Site: $site${goal.isEmpty ? '' : ' — $goal'}')
      ..writeln('A saved browser flow. The agent replays it with no thinking per step; it stops and takes over the moment a step no longer matches the page.')
      ..writeln('');
    for (var i = 0; i < steps.length; i++) {
      sb.writeln('${i + 1}. ${steps[i].line}');
    }
    return sb.toString().trim();
  }

  Playbook copyWith({int? runs, int? wins, String? at}) => Playbook(
        id: id,
        name: name,
        site: site,
        goal: goal,
        steps: steps,
        runs: runs ?? this.runs,
        wins: wins ?? this.wins,
        at: at ?? this.at,
      );
}

/// A clean id from a name ("Book a flight!" -> "book-a-flight").
String playbookId(String name) {
  final s = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'-{2,}'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? 'flow' : (s.length > 40 ? s.substring(0, 40) : s);
}

/// Values the user (or the agent) supplies for a replay: by field label ("Email") or by step number
/// ("2", 1-based). Steps without an override keep what was recorded.
List<PlayStep> withValues(List<PlayStep> steps, Map<String, String> values) {
  if (values.isEmpty) return steps;
  final byLabel = {for (final e in values.entries) _norm(e.key): e.value};
  final out = <PlayStep>[];
  for (var i = 0; i < steps.length; i++) {
    final s = steps[i];
    final v = byLabel[_norm(s.label)] ?? values['${i + 1}'];
    if (v == null || s.act != 'type') {
      out.add(s);
      continue;
    }
    out.add(PlayStep(act: s.act, kind: s.kind, label: s.label, href: s.href, value: v, submit: s.submit, nth: s.nth));
  }
  return out;
}
