import '../services/agent_loop.dart';

// Pure helpers behind the chat screen's feel: incremental markdown, smooth text reveal,
// follow-up chips and the "How I did it" list. No Flutter imports, so they are cheap to test.

/// A card written on one line ("```file /path/a.pdf```") becomes a real fenced block, so it still draws as a card.
String fixInlineCards(String s) => s.replaceAllMapped(
    RegExp(r'```(file|images|photos|table|diagram|choices|links)[ \t]+([^\n`]+?)[ \t]*```'),
    (m) => '```${m.group(1)}\n${m.group(2)}\n```');

/// The key a page/file card is known by: the file's path for ```file (and a ```page holding a path),
/// the HTML itself for an inline ```page. Null for any other block.
String? pageCardKey(String lang, String body) {
  final b = body.trim();
  if (b.isEmpty) return null;
  if (lang == 'file') return b.split('\n').first.trim();
  if (lang == 'page') return b.startsWith('/') ? b.split('\n').first.trim() : 'html:${b.hashCode}';
  return null;
}

/// Drops every ```file / ```page card whose key is already in [seen] (an earlier card in this reply or this run),
/// and adds the keys it keeps to [seen]. A site preview then shows once, however often the model repeats its card.
String dropRepeatPageCards(String text, Set<String> seen) {
  final src = fixInlineCards(text);
  if (!src.contains('```file') && !src.contains('```page')) return text;
  final out = src.replaceAllMapped(RegExp(r'\n?[ \t]*```(file|page)[ \t]*\n([\s\S]*?)\n[ \t]*```[ \t]*(?=\n|$)'), (m) {
    final key = pageCardKey(m.group(1)!, m.group(2)!);
    if (key == null) return m.group(0)!;
    if (!seen.add(key)) return '';
    return m.group(0)!;
  });
  return out == src ? text : out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trimRight();
}

/// Splits markdown into blocks that render the same on their own as they do together, so a
/// streaming reply only re-renders its last block. A split happens only at a blank line outside
/// code fences and math blocks, when the next line starts a fresh block (not indented, not the
/// next item of the same list). Joining the result with blank lines gives back the same document.
List<String> splitMarkdownChunks(String text) {
  if (text.isEmpty) return const [];
  final lines = dropRepeatPageCards(text, <String>{}).split('\n');
  // (repeat page/file cards in one reply draw once)

  final out = <String>[];
  final cur = <String>[];
  String? fence; // ``` or ~~~ (with its length) while inside a fenced block
  var inMath = false;
  var pendingBlank = false;
  var lastWasList = false;

  bool isListItem(String l) => RegExp(r'^\s{0,3}([-*+]|\d{1,3}[.)])\s+').hasMatch(l);
  bool isIndented(String l) => l.startsWith(' ') || l.startsWith('\t');

  void flush() {
    while (cur.isNotEmpty && cur.last.trim().isEmpty) {
      cur.removeLast();
    }
    if (cur.isNotEmpty) out.add(cur.join('\n'));
    cur.clear();
  }

  for (final line in lines) {
    final t = line.trim();
    if (fence != null) {
      cur.add(line);
      if (t.startsWith(fence) && t.replaceAll(fence[0], '').trim().isEmpty) fence = null;
      continue;
    }
    if (inMath) {
      cur.add(line);
      if (t.endsWith(r'$$')) inMath = false;
      continue;
    }
    if (t.isEmpty) {
      if (cur.isNotEmpty) pendingBlank = true;
      cur.add(line);
      continue;
    }
    if (pendingBlank) {
      pendingBlank = false;
      final continuesList = lastWasList && (isListItem(line) || isIndented(line));
      if (!isIndented(line) && !continuesList) flush();
    }
    final open = RegExp(r'^\s{0,3}(```+|~~~+)').firstMatch(line);
    if (open != null) {
      fence = open.group(1)!;
      lastWasList = false;
    } else if (t.startsWith(r'$$') && !(t.length > 2 && t.endsWith(r'$$'))) {
      inMath = true;
      lastWasList = false;
    } else if (isListItem(line)) {
      lastWasList = true;
    } else if (!isIndented(line)) {
      lastWasList = false;
    }
    cur.add(line);
  }
  flush();
  return out;
}

/// How often a streaming reply lets out its next batch of words (each batch then fades in where it lands).
const revealEvery = Duration(milliseconds: 90);

/// How much of a streaming reply to show (owner 2026-10-24: fade in, not letter by letter): every whole word that
/// has arrived. While it streams, a word still being written (no space or line break after it yet) waits, so text
/// never appears half a word at a time; a finished reply shows everything. Never cuts a character in half.
int revealTarget(String full, {required bool streaming}) {
  if (!streaming || full.isEmpty) return full.length;
  var i = full.length;
  while (i > 0) {
    final ch = full.codeUnitAt(i - 1);
    if (ch == 0x20 || ch == 0x0A || ch == 0x09) return i;
    i--;
  }
  // One long first word (or no spaces at all, like some scripts): show it as it comes rather than nothing.
  var n = full.length;
  final cu = full.codeUnitAt(n - 1);
  if (cu >= 0xD800 && cu <= 0xDBFF) n -= 1;
  return n;
}

/// Up to five short replies the user can tap after an answer, worked out from the answer itself
/// (no extra request). Offers ("Want me to…?") get Yes / No; "A, B or C?" gets each choice.
List<String> suggestFollowUps(String reply, {int max = 5}) {
  final text = reply.trim();
  if (text.isEmpty) return const [];
  // Cards that already carry their own buttons speak for themselves.
  if (RegExp(r'```(choices|confirm|order|order_summary|receipt)\b').hasMatch(text)) return const [];
  final prose = text.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ').trim();
  final out = <String>[];
  final last = _lastSentence(prose);
  if (last.endsWith('?')) {
    final q = last.substring(0, last.length - 1).trim();
    final offer = RegExp(
            r'^(?:(?:so|ok|okay|also|and)[, ]+)?(want me to|would you like(?: me)? to|shall i|should i|do you want(?: me)? to|can i|may i|i can\b.*?\bif you (?:want|like)|would it help if i)\b',
            caseSensitive: false)
        .firstMatch(q);
    final choice = _choicePair(q);
    if (choice != null) {
      out.addAll(choice);
    } else if (offer != null) {
      out
        ..add('Yes, please')
        ..add('No, thanks');
    }
  }
  final words = prose.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  // Code (a plain or language fence) may need explaining; a card (table, file, summary…) does not.
  final fences = RegExp(r'^\s{0,3}```(\w*)', multiLine: true).allMatches(text).toList();
  var code = false;
  for (var i = 0; i < fences.length; i += 2) {
    if (!_cardFences.contains(fences[i].group(1)!.toLowerCase())) code = true;
  }
  if (out.isEmpty && code) out.add('Explain it simply');
  if (words > 220) out.add('Make it shorter');
  if (out.length > max) return out.sublist(0, max);
  return out;
}

const _cardFences = {
  'links', 'table', 'grid', 'images', 'photos', 'order', 'order_summary', 'plan', 'choices', 'receipt', 'confirm', 'page', 'file',
  'video', 'graph', 'list', 'sections', 'math', 'diagram', 'roadmap', 'timeline', 'flow', 'chart', 'summary', 'template', 'draft',
  'event', 'qr', 'browser',
};

String _lastSentence(String prose) {
  final lines = prose.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return '';
  var l = lines.last.replaceAll(RegExp(r'[*_`>#]'), '').trim();
  final parts = l.split(RegExp(r'(?<=[.!?])\s+'));
  return parts.isEmpty ? l : parts.last.trim();
}

/// "Do you want the short version or the full one" -> [Short version, Full one]; "Should I use Python, Dart or Go"
/// -> [Python, Dart, Go] (up to five). Only for short, clean choices; anything longer is left to the user to type.
/// Before v1.13.101 a list of three or more ("X, Y or Z?") fell through to the offer rule and got Yes / No.
List<String>? _choicePair(String q) {
  final m = RegExp(r'^(?:.*?\b(?:want|prefer|like|rather|go with|should i (?:use|make|do|pick)|is it))\s+(.+?)\s+or\s+(.+)$',
          caseSensitive: false)
      .firstMatch(q);
  if (m == null) return null;
  String clean(String s) {
    var x = s.trim().replaceAll(RegExp(r'^(me to|you to|i|me)\s+', caseSensitive: false), '');
    x = x.replaceAll(RegExp(r'^(the|a|an|to)\s+', caseSensitive: false), '');
    x = x.replaceAll(RegExp(r'[,;:]+$'), '').trim();
    if (x.isEmpty) return x;
    return x[0].toUpperCase() + x.substring(1);
  }
  final head = m.group(1)!.replaceAll(RegExp(r'[,\s]+$'), ''), last = m.group(2)!;
  final parts = [...head.split(RegExp(r',\s*')), last].map(clean).toList();
  int n(String s) => s.split(' ').length;
  if (parts.length > 5 || parts.any((p) => p.isEmpty || n(p) > 4 || p.contains(','))) return null;
  return parts;
}

/// One tool step of a finished turn, as shown under "How I did it".
class TurnStep {
  const TurnStep(this.name, this.arguments, this.result);
  final String name;
  final String arguments;
  final String? result;

  bool get failed => ToolRecovery.stepFailed(result ?? '');
}

/// Bookkeeping steps that mean nothing to a person (the checklist, a quick note to them).
const hiddenStepNames = {'todo', 'say', 'ask_user'};

/// Plain-words progress for a checklist: "2 of 5 done".
String checklistLine(int done, int total) {
  if (total <= 0) return '';
  if (done >= total) return 'All $total done';
  return '$done of $total done';
}

/// True when the user explicitly asks to see how the work is done ("show steps", "how did you do it", "what's your
/// plan"). Steps, plans and narration are hidden by default (owner 2026-10-24); a turn that asks shows them.
bool asksForSteps(String text) => _stepsAsk.hasMatch(text);

final _stepsAsk = RegExp(
    r"\b(show|see|list|give|tell)( me)? (your |the |all (the )?|all your )?(steps|plan|process|reasoning|workflow)\b"
    r"|\bshow (your )?work\b|\bhow (did|do) you (do|get|find|make|work out) (it|that|this)\b"
    r"|\bwhat('s| is) your plan\b|\bwhat steps\b"
    r"|\btallaabooyinka(ga)? (i )?tus\b|\bi tus tallaabooyinka\b",
    caseSensitive: false);

/// A long, structured answer reads like Hark (owner 2026-10-24): a short lead in the reply bubble, then the document
/// itself as a summary card (serif title, a faded preview, tap for the full reader). Returns (lead, document) when
/// [text] is such an answer: at least two headings, a document part of [minDoc]+ characters, and no code or card
/// fences inside it (those keep their own cards). Null for everything else, which renders as normal text.
(String, String)? longReplySplit(String text, {int minDoc = 700}) {
  final t = text.trim();
  if (t.length < minDoc || t.contains('```') || t.contains('~~~')) return null;
  final lines = t.split('\n');
  final heads = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^#{1,3}\s+\S').hasMatch(lines[i])) heads.add(i);
  }
  if (heads.length < 2) return null;
  final lead = lines.sublist(0, heads.first).join('\n').trim();
  var doc = lines.sublist(heads.first).join('\n').trim();
  if (doc.length < minDoc) return null;
  // A lead longer than a short paragraph or two is part of the answer, not an intro: keep it all as text.
  if (lead.length > 600) return null;
  // The card's title is the first heading; make it a top-level one so the card shows it in the serif.
  doc = doc.replaceFirst(RegExp(r'^#{1,3}\s+'), '# ');
  return (lead, doc);
}
