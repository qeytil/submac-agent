import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bots.dart';
import 'offices.dart';
import 'team_run.dart';

/// What the ring around a bot's or a team's head says (owner, 2026-10-24). Always shown, the colour is the state:
/// green while it works, yellow while it waits for the owner's OK, blue when it finished and the owner has not read the
/// result yet, grey when idle.
enum RingState { idle, working, waiting, done }

/// The live status of every bot and team, for the rings in the Bots workspace rail.
///
/// Keys are `b:<botId>` and `t:<officeId>`. Driven by the real run state: a bot works while one of its runs (or a team
/// job) is going ([Bots.presenceOf]); a team works while [TeamRun] runs it or one of its members works. Waiting comes
/// from the owner's pending asks ([Offices.pending]) and from a lead's plan waiting for a go-ahead. A bot that stops
/// working while its chat is not the one on screen has unread results until the owner opens that chat; a team also
/// counts its own unread posts ([Office.unread]).
///
/// Listeners are told only when a ring actually changes, never on every app update (a reply streaming in notifies the
/// app many times a second).
class BotStatus extends ChangeNotifier {
  BotStatus._();
  static final BotStatus I = BotStatus._();

  static const _prefsKey = 'bot_ring_unread';

  Map<String, RingState> _rings = const {};
  Set<String> _working = {};
  final Set<String> _unread = {};
  final List<Listenable> _sources = [];
  bool _loaded = false;

  /// Bots workspaces on the navigation stack now (CB-16: a bot notification tapped then opens the bot in place).
  int workspaces = 0;

  /// The chat on screen right now (`b:<id>` or `t:<id>`): finishing there is read at once.
  String? _viewing;
  String? get viewing => _viewing;

  /// The ring for [key].
  RingState of(String key) => _rings[key] ?? RingState.idle;

  static String botKey(String id) => 'b:$id';
  static String teamKey(String id) => 't:$id';

  /// Starts following [app] (the AppState) and the bot, team and team-run services. Safe to call more than once.
  void attach(Listenable app) {
    if (!_sources.contains(app)) {
      _sources.add(app);
      app.addListener(recompute);
    }
    for (final s in <Listenable>[Bots.I, Offices.I, TeamRun.I]) {
      if (_sources.contains(s)) continue;
      _sources.add(s);
      s.addListener(recompute);
    }
    if (!_loaded) {
      _loaded = true;
      SharedPreferences.getInstance().then((p) {
        _unread.addAll(p.getStringList(_prefsKey) ?? const []);
        recompute();
      }).catchError((_) {});
    }
    recompute();
  }

  /// The owner opened this chat: it is on screen, and whatever it finished is read now.
  void open(String? key) {
    _viewing = key;
    if (key == null) {
      recompute();
      return;
    }
    final changed = _unread.remove(key);
    if (key.startsWith('t:')) {
      final o = Offices.I.byId(key.substring(2));
      if (o != null && o.unread > 0) {
        o.unread = 0;
        Offices.I.saveSoon();
      }
    }
    if (changed) _save();
    recompute();
  }

  /// The chat [key] left the screen (the workspace closed or moved on).
  void leave(String key) {
    if (_viewing == key) _viewing = null;
  }

  bool _botWorking(Bot b) => Bots.I.presenceOf(b) == 'working';

  /// Works out every ring again and tells listeners only when one changed.
  void recompute() {
    final working = <String>{};
    final waiting = <String>{};
    for (final b in Bots.I.bots) {
      if (_botWorking(b)) working.add(botKey(b.id));
    }
    for (final o in Offices.I.offices) {
      if (TeamRun.I.busy(o) || o.members.any((id) => working.contains(botKey(id)))) working.add(teamKey(o.id));
      if (TeamRun.I.awaitingGo(o)) waiting.add(teamKey(o.id));
    }
    for (final a in Offices.I.pending) {
      if (a.officeId.isNotEmpty) waiting.add(teamKey(a.officeId));
      if (a.botId.isNotEmpty) waiting.add(botKey(a.botId));
    }
    // Finished while the owner was elsewhere: unread until that chat is opened.
    var saved = false;
    for (final k in _working.difference(working)) {
      if (k != _viewing && _unread.add(k)) saved = true;
    }
    _working = working;
    if (saved) _save();
    final next = <String, RingState>{};
    void put(String k, {bool teamUnread = false}) {
      final s = waiting.contains(k)
          ? RingState.waiting
          : working.contains(k)
              ? RingState.working
              : (_unread.contains(k) || teamUnread) && k != _viewing
                  ? RingState.done
                  : RingState.idle;
      if (s != RingState.idle) next[k] = s;
    }

    for (final b in Bots.I.bots) {
      put(botKey(b.id));
    }
    for (final o in Offices.I.offices) {
      put(teamKey(o.id), teamUnread: o.unread > 0);
    }
    if (!mapEquals(next, _rings)) {
      _rings = next;
      _tell();
    }
  }

  bool _telling = false;

  /// Tells the rings, never in the middle of building a frame (the app can notify while widgets build): then right
  /// after that frame, once.
  void _tell() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_telling) return;
    _telling = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _telling = false;
      notifyListeners();
    });
  }

  void _save() {
    final list = _unread.toList();
    SharedPreferences.getInstance().then((p) => p.setStringList(_prefsKey, list)).catchError((_) => false);
  }

  /// Tests: forget everything.
  @visibleForTesting
  void reset() {
    for (final s in _sources) {
      s.removeListener(recompute);
    }
    _sources.clear();
    _rings = const {};
    _working = {};
    _unread.clear();
    _viewing = null;
    workspaces = 0;
    _loaded = true;
    _telling = false;
  }
}
