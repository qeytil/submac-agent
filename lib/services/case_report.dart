import 'doc_maker.dart';
import 'cases.dart';

/// Builds a case's report as a real PDF, reusing DocMaker's exact look (docs/investigation.md §12).
///
/// The PDF lands in the workspace `Documents/` folder (the same place `make_document` writes) and is then copied
/// into the case folder as an exhibit, so it lives with the case. The evidence PDF bundles the image exhibits.
class CaseReport {
  CaseReport._();

  static const _imageExt = {'jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp', 'gif'};

  static bool _isImage(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExt.contains(path.substring(dot + 1).toLowerCase());
  }

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The report body in the simple markdown DocMaker understands.
  static String markdown(Case c) {
    final sb = StringBuffer()..writeln('# ${c.numberLabel}: ${c.title}');
    if (c.brief.isNotEmpty) {
      sb.writeln('## Brief');
      sb.writeln(c.brief);
    }
    if (c.client.isNotEmpty) sb.writeln('- Client: ${c.client}');
    if (c.reportedTo.isNotEmpty) sb.writeln('- Reported to: ${c.reportedTo}');
    sb.writeln('- Status: ${c.statusWord}');

    final findings = c.findings;
    if (findings.isNotEmpty) {
      sb.writeln('## Findings');
      for (final f in findings) {
        sb.writeln('- ${f.text} (${f.confidence} confidence, ${f.status})');
      }
    }
    final open = findings.where((f) => f.status == 'open').toList();
    if (open.isNotEmpty) {
      sb.writeln('## Open questions');
      for (final f in open) {
        sb.writeln('- ${f.text} (${f.confidence})');
      }
    }

    if (c.timeline.isNotEmpty) {
      final events = [...c.timeline]..sort((a, b) => a.at.compareTo(b.at));
      sb.writeln('## Timeline');
      for (final e in events) {
        sb.writeln('- ${_day(e.at)} — ${e.text}');
      }
    }

    if (c.persons.isNotEmpty) {
      sb.writeln('## Persons');
      for (final p in c.persons) {
        final extra = p.notes.isNotEmpty ? ' — ${p.notes}' : '';
        sb.writeln('- ${p.name} (${p.role})$extra');
      }
    }

    if (c.exhibits.isNotEmpty) {
      sb.writeln('## Evidence');
      for (final x in c.exhibits) {
        final note = x.note.isNotEmpty ? ' — ${x.note}' : '';
        sb.writeln('- ${x.name} (${x.kind}, ${_day(x.addedAt)})$note');
      }
    }
    return sb.toString();
  }

  /// One tap: the report PDF, saved into the case folder as an exhibit. Returns its path, or null on failure.
  static Future<String?> makeReport(Case c) async {
    final res = await DocMaker.execute('make_document', {
      'kind': 'pdf',
      'title': 'Case report ${c.numberLabel}',
      'subtitle': '${c.title} · ${c.statusWord} · ${_day(DateTime.now())}',
      'content': markdown(c),
    });
    return _adopt(c, res, kind: 'report', note: 'Case report');
  }

  /// The evidence PDF: every image exhibit, one page each, saved into the case folder.
  static Future<String?> makeEvidencePdf(Case c) async {
    final images = [for (final x in c.exhibits) if (_isImage(x.path)) x.path];
    if (images.isEmpty) return null;
    final res = await DocMaker.execute('images_to_pdf', {'paths': images, 'title': 'Evidence ${c.numberLabel}'});
    return _adopt(c, res, kind: 'dossier', note: 'Evidence PDF');
  }

  /// Copies the file DocMaker just wrote into the case folder (as an exhibit) and returns its new path.
  static Future<String?> _adopt(Case c, String res, {required String kind, required String note}) async {
    if (!res.startsWith('FILE_SAVED')) return null;
    final path = res.substring('FILE_SAVED'.length).trim().split('\n').first.trim();
    if (path.isEmpty) return null;
    final x = await Cases.I.addExhibit(c, path, kind: kind, note: note);
    return x?.path ?? path;
  }
}
