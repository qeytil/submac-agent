import 'dart:async';

import 'person.dart';
import 'registry.dart';

/// The living layer behind bots (docs/digital-human.md).
///
/// Every bot gets a [DigitalPerson] — heartbeat, situational awareness, long-term memory, mood, energy — kept by the
/// [DigitalHumanRegistry] and persisted on the phone. This manager turns that inner life into one quiet line for the
/// bot's own prompt, so a bot is a person who notices and remembers, not only a prompt-answerer.
class BotMinds {
  BotMinds._();
  static final I = BotMinds._();

  /// Bot ids already hydrated (their saved mood/energy/memory restored and the roster saved), so it happens once.
  final Set<String> _hydrated = {};

  DigitalPerson ensure(String id, {String name = '', String role = ''}) =>
      DigitalHumanRegistry.I.ensure(id, name: name, role: role);

  /// Ensure the person exists, restore its saved state once, and keep it in the registry roster so the next launch
  /// (bootstrapFromPrefs + wakeAll) re-initialises it and its mood/energy/memory come back.
  DigitalPerson _touch(String id, {String name = '', String role = ''}) {
    final p = ensure(id, name: name, role: role);
    if (_hydrated.add(id)) unawaited(_hydrate(p));
    return p;
  }

  Future<void> _hydrate(DigitalPerson p) async {
    final prefs = DigitalHumanRegistry.I.prefs;
    if (prefs == null) return;
    try {
      await p.init(prefs); // restores dh_<id>_state (mood, energy, lastSpoke, memory)
      await DigitalHumanRegistry.I.save(); // keep the roster so wakeAll restores it next launch
    } catch (_) {}
  }

  /// A quiet, factual self-line for a bot's own system prompt. Never loud, never claimed as a system fact.
  String selfLine(String id, {String name = '', String role = ''}) {
    final p = _touch(id, name: name, role: role);
    final idle = p.heartbeat.idleTime.inMinutes;
    final seen = idle < 1
        ? 'just now'
        : idle < 60
            ? '${idle}m ago'
            : '${(idle / 60).floor()}h ago';
    final last = p.lastSpokeAt == null ? 'you have not spoken with the owner yet' : 'you last spoke $seen';
    return '# How you are right now\n'
        'You are ${p.heartbeat.isAlive ? 'awake' : 'resting'}; mood: ${p.mood.moodLabel} '
        '(${p.mood.intensity.toStringAsFixed(2)}); energy: ${(p.energy.level * 100).round()}%. '
        '$last. You remember ${p.memory.factCount} fact(s) and ${p.memory.episodeCount} earlier moment(s). '
        'Let this colour how you reply, but never announce it as a system line.';
  }

  /// The bot just said or did something (a turn, a wake, a reply).
  void spoke(String id, {String name = '', String role = ''}) => _touch(id, name: name, role: role).markSpoken();

  /// The bot noticed or learned something worth keeping (an echo of a turn into its memory).
  void remember(String id, String content, {String type = 'observation', String topic = ''}) =>
      _touch(id).memory.remember(type, content, topic: topic);

  /// Persist one bot's mind (mood, energy, memory), and the roster, on the phone.
  Future<void> save(String id) async {
    final prefs = DigitalHumanRegistry.I.prefs;
    if (prefs == null) return;
    try {
      await DigitalHumanRegistry.I.ensure(id).save(prefs);
      await DigitalHumanRegistry.I.save();
    } catch (_) {}
  }
}
