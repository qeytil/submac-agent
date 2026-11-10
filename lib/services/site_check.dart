import 'dart:convert';
import 'dart:io';

import 'code_tools.dart';

/// The result of checking a page or site Telesia built.
class SiteReport {
  SiteReport(this.entry, {List<String>? problems, List<String>? notes, this.files = 0})
      : problems = problems ?? <String>[],
        notes = notes ?? <String>[];

  /// The page that was checked (as given).
  final String entry;

  /// What must be fixed before the work is delivered (broken, unfinished, unreadable on a phone).
  final List<String> problems;

  /// What is worth a look but does not block delivery (spots for the user to fill, external pictures, alt text).
  final List<String> notes;

  /// How many files were read.
  final int files;

  bool get ok => problems.isEmpty;

  /// A short plain report for the model.
  String get text {
    final sb = StringBuffer(ok ? 'Page check passed ($files files).' : 'Page check found ${problems.length} problems ($files files):');
    for (final p in problems.take(25)) {
      sb.write('\n- $p');
    }
    if (problems.length > 25) sb.write('\n- ...and ${problems.length - 25} more');
    if (notes.isNotEmpty) {
      sb.write('\nWorth a look:');
      for (final n in notes.take(12)) {
        sb.write('\n- $n');
      }
    }
    return sb.toString();
  }
}

/// Checks a web page Telesia built before it is delivered: complete files, no missing pictures, styles, scripts or
/// pages, in-page links that land, phone-ready head, no filler text. Static and offline (no browser needed), so it
/// runs on every page the agent wrote, right before its final reply (see [SiteGate]). Pure apart from file reads;
/// [checkHtml] and [checkCss] are pure and unit tested.
class SiteCheck {
  SiteCheck._();

  static final _lorem = RegExp(r'\blorem ipsum\b|\bdolor sit amet\b', caseSensitive: false);
  static final _cutMarker = RegExp(
      r'(\.\.\.\s*(rest|more|remaining|other)\b[^\n]{0,40}(here|code|sections?|content))|(<!--\s*(rest|more|remaining|continue)[^>]*-->)|'
      r'(/\*\s*(rest|more|remaining)\b[^*]*\*/)|(//\s*(rest|more|remaining) (of )?(the )?(code|logic|functions?))',
      caseSensitive: false);
  static final _spot = RegExp(r'\[(your|insert|add|put|enter)\b[^\]\n]{0,40}\]', caseSensitive: false);

  /// Problems and notes for one HTML document. [exists] answers whether a local reference is in the site folder
  /// (null: references are not checked, e.g. a page shown inline in chat).
  static (List<String>, List<String>) checkHtml(String name, String html, {bool Function(String ref)? exists}) {
    final problems = <String>[];
    final notes = <String>[];
    final t = html.trim();
    if (t.isEmpty) return (['$name is empty'], notes);
    final low = t.toLowerCase();

    // Unfinished: the file stops halfway.
    if (!low.contains('</html>') && !low.contains('</body>')) {
      problems.add('$name stops before its end (no </body></html>): finish the file with append_file');
    }
    final lastLt = t.lastIndexOf('<'), lastGt = t.lastIndexOf('>');
    if (lastLt > lastGt) problems.add('$name ends in the middle of a tag');
    final scriptsOpen = RegExp(r'<script\b', caseSensitive: false).allMatches(t).length;
    final scriptsClosed = RegExp(r'</script>', caseSensitive: false).allMatches(t).length;
    if (scriptsOpen != scriptsClosed) problems.add('$name: a <script> is not closed');
    final stylesOpen = RegExp(r'<style\b', caseSensitive: false).allMatches(t).length;
    final stylesClosed = RegExp(r'</style>', caseSensitive: false).allMatches(t).length;
    if (stylesOpen != stylesClosed) problems.add('$name: a <style> is not closed');
    if (_cutMarker.hasMatch(t)) problems.add('$name has a "rest of the code here" style gap: write the missing part');

    // Structure and markup (shared with code_check), split into what blocks and what is only worth a look.
    for (final p in CodeTools.staticCheck(name.endsWith('.htm') ? name : (name.endsWith('.html') ? name : '$name.html'), t,
        exists: exists)) {
      if (p.contains('image without alt')) {
        notes.add('$name: ${p.replaceFirst('HTML: ', '')}');
      } else {
        problems.add('$name: ${p.replaceFirst('HTML: ', '')}');
      }
    }
    if (!RegExp(r'<title>\s*[^<\s][^<]*</title>', caseSensitive: false).hasMatch(t)) {
      problems.add('$name has no <title> (the tab, the share preview and Publish use it)');
    }
    if (!RegExp(r'<meta[^>]+charset', caseSensitive: false).hasMatch(t)) notes.add('$name: no <meta charset="utf-8">');
    if (!RegExp(r'<html[^>]*\blang=', caseSensitive: false).hasMatch(t)) notes.add('$name: no lang on <html>');

    // Content.
    if (_lorem.hasMatch(t)) problems.add('$name has lorem ipsum filler: write real content from the brief');
    final spots = {for (final m in _spot.allMatches(t)) m.group(0)!};
    if (spots.isNotEmpty) notes.add('$name: spots for the user to fill: ${spots.take(6).join(', ')} (list them in the final reply)');

    // In-page links land on something.
    final ids = {
      for (final m in RegExp(r'''\b(?:id|name)\s*=\s*["']([^"']+)["']''', caseSensitive: false).allMatches(t)) m.group(1)!,
    };
    final missingAnchors = <String>{};
    for (final m in RegExp(r'''href\s*=\s*["']#([^"']+)["']''', caseSensitive: false).allMatches(t)) {
      final id = m.group(1)!;
      if (!ids.contains(id)) missingAnchors.add('#$id');
    }
    if (missingAnchors.isNotEmpty) problems.add('$name: links to ${missingAnchors.take(8).join(', ')} go nowhere (no element with that id)');
    if (RegExp(r'''href\s*=\s*["']\s*["']''', caseSensitive: false).hasMatch(t)) problems.add('$name: a link has an empty href');

    // References the generic check does not see: srcset, poster, inline style url().
    if (exists != null) {
      final refs = <String>{};
      for (final m in RegExp(r'''srcset\s*=\s*["']([^"']+)["']''', caseSensitive: false).allMatches(t)) {
        for (final part in m.group(1)!.split(',')) {
          final u = part.trim().split(RegExp(r'\s+')).first;
          if (u.isNotEmpty) refs.add(u);
        }
      }
      for (final m in RegExp(r'''poster\s*=\s*["']([^"']+)["']''', caseSensitive: false).allMatches(t)) {
        refs.add(m.group(1)!);
      }
      refs.addAll(cssRefs(t));
      for (final r in refs) {
        if (_isLocal(r) && !exists(_clean(r))) problems.add('$name: missing file "${_clean(r)}"');
      }
    }
    final external = RegExp(r'''<img\b[^>]*\bsrc\s*=\s*["']https?://''', caseSensitive: false).allMatches(t).length;
    if (external > 0) notes.add('$name: $external pictures load from other sites; they break if those sites move them');
    final noSize = RegExp(r'<img\b(?![^>]*\b(width|height|style)=)[^>]*>', caseSensitive: false).allMatches(t).length;
    if (noSize > 0) notes.add('$name: $noSize pictures without width/height (the page jumps while they load)');

    // Phone width: a fixed width wider than a phone with no media query to adapt it.
    final css = [for (final m in RegExp(r'<style\b[^>]*>([\s\S]*?)</style>', caseSensitive: false).allMatches(t)) m.group(1)!].join('\n');
    for (final p in checkCss(name, css, hasMediaQuery: low.contains('@media'))) {
      (p.contains('braces') ? problems : notes).add(p);
    }
    return (problems, notes);
  }

  /// Notes and problems for a stylesheet. Brace mismatches are problems; layout risks are notes.
  static List<String> checkCss(String name, String css, {bool hasMediaQuery = false}) {
    final out = <String>[];
    if (css.trim().isEmpty) return out;
    final body = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    final o = '{'.allMatches(body).length, c = '}'.allMatches(body).length;
    if (o != c) out.add('$name: CSS braces do not match ($o "{" and $c "}"), a rule is cut off');
    final wide = RegExp(r'(?<![-\w])(?:min-)?width\s*:\s*(\d{3,4})px').allMatches(body).map((m) => int.parse(m.group(1)!)).where((w) => w > 420);
    if (wide.isNotEmpty && !hasMediaQuery && !body.contains('@media')) {
      out.add('$name: fixed width of ${wide.first}px and no @media rule: it will overflow a phone screen');
    }
    return out;
  }

  /// Local files a stylesheet or style attribute points at (url(...) and @import).
  static Set<String> cssRefs(String css) => {
        for (final m in RegExp(r'''url\(\s*["']?([^"')]+)["']?\s*\)''', caseSensitive: false).allMatches(css)) m.group(1)!.trim(),
        for (final m in RegExp(r'''@import\s+["']([^"']+)["']''', caseSensitive: false).allMatches(css)) m.group(1)!.trim(),
      };

  static bool _isLocal(String r) => r.isNotEmpty && !RegExp(r'^(https?:|//|mailto:|tel:|data:|javascript:|#|\{|blob:)').hasMatch(r);
  static String _clean(String r) => r.split('#').first.split('?').first;

  /// Checks the page at [entryPath] and every page, stylesheet and script next to it (its site folder; just the page
  /// when it sits alone in a shared folder).
  /// [alone]: the page sits in a shared folder (the workspace, Telesia's pages, Downloads), so Publish sends the page
  /// by itself and nothing it links to locally goes online with it.
  static Future<SiteReport> run(String entryPath, {bool alone = false}) async {
    final entry = File(entryPath);
    if (!await entry.exists()) return SiteReport(entryPath, problems: ['The page $entryPath does not exist (it was never written, or it moved)']);
    final dir = entry.parent;
    final shared = alone || RegExp(r'/(pages|Download|Downloads)$').hasMatch(dir.path);
    final files = <File>[entry];
    if (!shared) {
      try {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is! File || e.path == entry.path) continue;
          final rel = e.path.substring(dir.path.length + 1);
          if (rel.split('/').any((p) => p.startsWith('.'))) continue;
          if (RegExp(r'\.(html?|css|js|mjs)$', caseSensitive: false).hasMatch(rel)) files.add(e);
          if (files.length >= 40) break;
        }
      } catch (_) {}
    }
    final report = SiteReport(entryPath, files: files.length);
    for (final f in files) {
      final rel = f.path == entry.path ? f.path.split('/').last : f.path.substring(dir.path.length + 1);
      String text;
      try {
        if (await f.length() > 2 * 1024 * 1024) {
          report.notes.add('$rel is over 2 MB; make it smaller');
          continue;
        }
        text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
      } catch (_) {
        report.problems.add('$rel could not be read');
        continue;
      }
      final here = f.parent.path;
      bool exists(String ref) {
        if (shared) return false; // only the page itself goes online
        final full = ref.startsWith('/') ? '${dir.path}$ref' : '$here/$ref';
        return File(full).existsSync() || Directory(full).existsSync();
      }

      final low = rel.toLowerCase();
      if (low.endsWith('.html') || low.endsWith('.htm')) {
        final (p, n) = checkHtml(rel, text, exists: exists);
        report.problems.addAll(p);
        report.notes.addAll(n);
      } else if (low.endsWith('.css')) {
        final issues = checkCss(rel, text);
        report.problems.addAll(issues.where((e) => e.contains('braces')));
        report.notes.addAll(issues.where((e) => !e.contains('braces')));
        for (final r in cssRefs(text)) {
          if (_isLocal(r) && !exists(_clean(r))) report.problems.add('$rel: missing file "${_clean(r)}"');
        }
      } else {
        if (text.trim().isEmpty) report.problems.add('$rel is empty');
        if (_cutMarker.hasMatch(text)) report.problems.add('$rel has a "rest of the code here" style gap: write the missing part');
        final o = '{'.allMatches(text).length, c = '}'.allMatches(text).length;
        // Strings and regexes can hold braces, so only a big gap counts as a cut-off file.
        if ((o - c).abs() >= 3) report.problems.add('$rel looks cut off ($o "{" and $c "}")');
      }
    }
    if (shared && report.problems.any((p) => p.contains('missing file'))) {
      report.problems.add('This page sits alone in a shared folder, so only the page itself goes online: move the site into its own '
          'folder (sites/<short-name>/) with its pictures, styles and scripts, or put them inline');
    }
    return report;
  }

  /// Serious problems in a page shown inline in chat (a ```page card): only what makes it broken.
  static List<String> inlinePage(String html) {
    final (p, _) = checkHtml('the page', html);
    return [for (final x in p) if (!x.contains('<title>')) x];
  }
}

/// What the engine does with a page check before the final reply.
enum SiteStep { pass, fix, explain }

/// The engine guard (owner, 2026-10-24: "unfinished ugly broken websites"): a page written in this task cannot go out
/// in the final reply until its check passes. Up to [maxFixes] rounds of fixing; after that the final reply must say
/// plainly what still fails. Pure, unit tested.
class SiteGate {
  SiteGate._();

  static const maxFixes = 2;

  static SiteStep decide({required bool ok, required int fixes, required bool explained}) {
    if (ok) return SiteStep.pass;
    if (fixes < maxFixes) return SiteStep.fix;
    return explained ? SiteStep.pass : SiteStep.explain;
  }

  static String fixNote(SiteReport r) => '# Your page is not ready yet\n'
      'Telesia checked the page you built before your final reply. It is not delivered yet.\n${r.text}\n'
      'Fix every problem now with your tools (append_file to finish a file, edit_file for small fixes, write the missing files). '
      'Do not send the final reply until the page is complete. Keep the user\'s choices exactly as they asked.';

  static String explainNote(SiteReport r) => '# The page still has problems\n${r.text}\n'
      'Give your final reply now, and say plainly, in one or two lines, what still does not work and what you suggest. '
      'Never call it finished or perfect.';

  /// The ```page card in a final reply: the HTML inside the block, or null when there is none (or it is cut off).
  static String? pageBlock(String reply) {
    final m = RegExp(r'```(?:page|html)\s*\n([\s\S]*?)\n```').firstMatch(reply);
    return m?.group(1);
  }

  static String pageNote(List<String> problems) => '# The page in your reply is broken\n'
      '${problems.take(10).map((e) => '- $e').join('\n')}\n'
      'Send the reply again with the whole page fixed and complete. If it is long, build it as files in sites/<short-name>/ '
      'instead (write_file, then append_file in parts of about 150 lines) and show the ```file card.';
}
