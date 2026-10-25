import 'dart:convert';

import 'page_model.dart';

/// One action of a `browser_act` batch (browser-use style: several actions per step, run in order).
class BrowserAction {
  BrowserAction(this.kind, this.args);

  /// click | type | select | scroll | key | wait | find | clear | check
  final String kind;
  final Map<String, dynamic> args;

  static const kinds = {'click', 'type', 'select', 'scroll', 'key', 'wait', 'find', 'clear', 'check'};

  /// Actions that may move the page on: anything after them in a batch is skipped when the page changes.
  bool get mayChangePage =>
      kind == 'click' || kind == 'check' || (kind == 'type' && args['submit'] == true) || (kind == 'key' && '${args['key']}'.toLowerCase() == 'enter');

  int get id => _int(args['id']);

  static int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? -1;

  /// Parses and validates a batch. Returns the actions, or an error message for the model.
  static (List<BrowserAction>, String?) parseBatch(dynamic raw, {int max = 6}) {
    var list = raw;
    if (list is String) {
      try {
        list = jsonDecode(list);
      } catch (_) {
        return (const <BrowserAction>[], 'Error: actions must be a list like [{"do":"click","id":3}].');
      }
    }
    if (list is! List || list.isEmpty) return (const <BrowserAction>[], 'Error: give at least one action.');
    if (list.length > max) return (const <BrowserAction>[], 'Error: at most $max actions per step.');
    final out = <BrowserAction>[];
    for (var k = 0; k < list.length; k++) {
      final m = list[k];
      if (m is! Map) return (const <BrowserAction>[], 'Error: action ${k + 1} is not an object.');
      final a = Map<String, dynamic>.from(m);
      final kind = '${a.remove('do') ?? a.remove('action') ?? ''}'.trim().toLowerCase();
      if (!kinds.contains(kind)) return (const <BrowserAction>[], 'Error: action ${k + 1}: unknown "do":"$kind". Use one of ${kinds.join(', ')}.');
      final needsId = {'click', 'type', 'select', 'clear', 'check'}.contains(kind);
      if (needsId && _int(a['id']) < 0) return (const <BrowserAction>[], 'Error: action ${k + 1} ($kind) needs the element number "id".');
      if (kind == 'type' && a['text'] == null) return (const <BrowserAction>[], 'Error: action ${k + 1} (type) needs "text".');
      if (kind == 'select' && '${a['option'] ?? ''}'.isEmpty) return (const <BrowserAction>[], 'Error: action ${k + 1} (select) needs "option".');
      if (kind == 'key' && '${a['key'] ?? ''}'.isEmpty) return (const <BrowserAction>[], 'Error: action ${k + 1} (key) needs "key".');
      out.add(BrowserAction(kind, a));
    }
    return (out, null);
  }

  /// Short plain words for the status pill ("Typing", "Tapping "Search"").
  String describe(Map<int, String> labels) {
    final l = labels[id] ?? '';
    switch (kind) {
      case 'click':
      case 'check':
        return l.isEmpty ? 'Tapping' : 'Tapping "$l"';
      case 'type':
        return 'Typing';
      case 'select':
        return 'Choosing ${args['option']}';
      case 'scroll':
        return 'Scrolling';
      case 'wait':
        return 'Waiting';
      default:
        return 'Working';
    }
  }
}

/// Which browser calls need the user's OK, decided from the call and the page it acts on. This only DECIDES; the
/// asking always goes through the app's approval flow (cards, Full access rules, money always asks).
class BrowserGate {
  /// Returns (title, label) of the press that needs approval, or null.
  ///
  /// [labels] are the element labels from the task's latest view; [page] is that view.
  /// [readOnly]: the task only looks things up (PageRisk.readOnlyGoal), so plain flow buttons on a money page don't
  /// ask (CB-44). Card fields, money words and risky words still ask.
  static ({String title, String label})? check(String tool, Map<String, dynamic> args, Map<int, String> labels, PageSnapshot page,
      {bool readOnly = false}) {
    final about = '${args['about'] ?? ''}'.trim();
    final money = page.moneyPage;
    String lab(dynamic id) => (labels[BrowserAction._int(id)] ?? '').replaceAll('"', '');
    String kindOf(dynamic id) => page.byId(BrowserAction._int(id))?.kind ?? '';
    // A cookie / consent banner's own button (the one the page script found, or a consent button in a dialog).
    bool consentOf(dynamic id, String l) {
      final b = page.banner;
      if (b != null && BrowserAction._int(b['id']) == BrowserAction._int(id) && BrowserAction._int(id) >= 0) return true;
      if (b == null && !page.modal) return false;
      if (!PageRisk.isConsentPress(l)) return false;
      return !page.cardFields || RegExp(r'cookie|consent|gdpr|privacy', caseSensitive: false).hasMatch(l);
    }

    bool needs(dynamic id, String l) =>
        PageRisk.pressNeedsOk(l, moneyPage: money, kind: kindOf(id), consent: consentOf(id, l), readOnly: readOnly, cardFields: page.cardFields);
    switch (tool) {
      case 'browser_click':
        final l = lab(args['id']);
        if (about.isNotEmpty || needs(args['id'], l)) {
          return (title: about.isNotEmpty ? about : 'Tap "${l.isEmpty ? 'this button' : l}" on ${page.host.isEmpty ? 'this site' : page.host}?', label: l);
        }
        return null;
      case 'browser_type':
        if (args['submit'] == true && (about.isNotEmpty || PageRisk.submitNeedsOk(moneyPage: money))) {
          return (title: about.isNotEmpty ? about : 'Submit this form on ${page.host}?', label: lab(args['id']));
        }
        return null;
      case 'browser_press':
        if ('${args['key'] ?? ''}'.toLowerCase() == 'enter' && (about.isNotEmpty || PageRisk.submitNeedsOk(moneyPage: money))) {
          return (title: about.isNotEmpty ? about : 'Submit this form on ${page.host}?', label: 'Enter');
        }
        return null;
      case 'browser_tap_at':
      case 'browser_js':
        if (about.isNotEmpty) return (title: about, label: '');
        if (money) return (title: 'Tap on the payment page of ${page.host}?', label: '');
        return null;
      case 'browser_act':
        final (acts, err) = BrowserAction.parseBatch(args['actions']);
        if (err != null) return null; // the tool itself reports the error; nothing runs
        for (final a in acts) {
          if (a.kind == 'click' || a.kind == 'check') {
            final l = lab(a.id);
            if (about.isNotEmpty || needs(a.id, l)) {
              return (title: about.isNotEmpty ? about : 'Tap "${l.isEmpty ? 'this button' : l}" on ${page.host.isEmpty ? 'this site' : page.host}?', label: l);
            }
          }
          if ((a.kind == 'type' && a.args['submit'] == true) || (a.kind == 'key' && '${a.args['key']}'.toLowerCase() == 'enter')) {
            if (about.isNotEmpty || PageRisk.submitNeedsOk(moneyPage: money)) {
              return (title: about.isNotEmpty ? about : 'Submit this form on ${page.host}?', label: lab(a.id));
            }
          }
        }
        return null;
    }
    return null;
  }
}
