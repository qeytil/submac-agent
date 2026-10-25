import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'doc_text.dart';
import 'tools.dart';

/// Reading documents on the phone: text in photos (on-device OCR), PDFs, and office files (Word, Excel, PowerPoint,
/// OpenDocument, EPUB, web pages, text) through [DocText].
class DocTools {
  static const names = {'read_text_in_image', 'read_pdf', 'read_document'};

  static final List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'read_text_in_image',
        'description': 'Read the text in a photo or screenshot on the phone (on-device, works offline). '
            'Use for receipts, documents, signs, screenshots.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Image file path (attachments are in uploads/).'},
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'read_pdf',
        'description': 'Extract the text of a PDF file on the phone.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'first_page': {'type': 'integer', 'description': '1-based, default 1'},
            'last_page': {'type': 'integer', 'description': 'default: last page (max 60 pages per call)'},
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'read_document',
        'description': 'Read the text of any document on the phone: Word, Excel (every sheet), PowerPoint (slides and notes), '
            'OpenDocument, EPUB, RTF, HTML, CSV or text; PDFs and photos too. Long files come in parts: pass offset to read on.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'offset': {'type': 'integer', 'description': 'Character to start from (default 0).'},
          },
          'required': ['path'],
        },
      },
    },
  ];

  /// read_document hands back this many characters per call.
  static const docChars = 12000;

  static Future<String> _resolve(String p) async {
    if (p.startsWith('/')) return p;
    return '${await AgentTools.workspaceDir()}/$p';
  }

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      final path = await _resolve((a['path'] ?? '').toString());
      if (!await File(path).exists()) return 'Error: file not found: $path';
      if (name == 'read_text_in_image') {
        final t = await ocrFile(path);
        return t.trim().isEmpty ? 'No readable text found in the image.' : t;
      }
      if (name == 'read_pdf') {
        final bytes = await File(path).readAsBytes();
        return pdfText(bytes,
            first: (a['first_page'] as num?)?.toInt(), last: (a['last_page'] as num?)?.toInt(), maxChars: 12000);
      }
      if (name == 'read_document') return await readDocument(path, (a['offset'] as num?)?.toInt() ?? 0);
      return 'Error: unknown tool "$name"';
    } on FormatException catch (e) {
      return 'Error: ${e.message}';
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<String> readDocument(String path, int offset) async {
    final e = DocText.ext(path);
    String text;
    if (e == 'pdf') {
      text = pdfText(await File(path).readAsBytes(), maxChars: 200000);
    } else if (const {'jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp', 'gif'}.contains(e)) {
      text = await ocrFile(path);
      if (text.trim().isEmpty) return 'No readable text found in the image.';
    } else if (DocText.supports(path)) {
      text = DocText.extract(path, await File(path).readAsBytes()) ?? '';
    } else if (e == 'doc' || e == 'xls' || e == 'ppt') {
      return 'Error: this is an old .$e file. Ask the user to save it as .${e}x (File > Save as) or share it as PDF, then read that.';
    } else {
      // Unknown extension: read it as text when it looks like text.
      final bytes = await File(path).readAsBytes();
      final head = bytes.take(2000);
      if (head.where((b) => b == 0).length > 4) return 'Error: .$e files are not documents I can read as text.';
      text = utf8.decode(bytes, allowMalformed: true);
    }
    if (text.trim().isEmpty) return 'This document has no text (it may be only pictures).';
    return partOf(text, offset, docChars);
  }

  /// One part of [text] from [offset], with a pointer to the next part.
  static String partOf(String text, int offset, int size) {
    if (offset < 0) offset = 0;
    if (offset >= text.length) return '(Nothing more: the document has ${text.length} characters.)';
    final end = (offset + size).clamp(0, text.length);
    final head = offset > 0 ? '(characters $offset to $end of ${text.length})\n' : '';
    final more = end < text.length ? '\n…[${text.length - end} more characters: call again with offset $end]' : '';
    return '$head${text.substring(offset, end)}$more';
  }

  static Future<String> ocrFile(String path) async {
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final res = await rec.processImage(InputImage.fromFilePath(path));
      return res.text;
    } finally {
      await rec.close();
    }
  }

  /// Text of a PDF, with page markers. Returns a friendly note if the PDF is a scan.
  static String pdfText(Uint8List bytes, {int? first, int? last, int maxChars = 40000}) {
    final doc = PdfDocument(inputBytes: bytes);
    try {
      final count = doc.pages.count;
      final a = ((first ?? 1) - 1).clamp(0, count - 1);
      var b = ((last ?? count) - 1).clamp(a, count - 1);
      if (b - a > 59) b = a + 59;
      final ex = PdfTextExtractor(doc);
      final sb = StringBuffer('PDF with $count pages. Showing pages ${a + 1}-${b + 1}.\n');
      for (var i = a; i <= b; i++) {
        final t = ex.extractText(startPageIndex: i, endPageIndex: i).trim();
        sb.writeln('\n--- Page ${i + 1} ---\n$t');
        if (sb.length > maxChars) break;
      }
      var s = sb.toString();
      if (s.replaceAll(RegExp(r'--- Page \d+ ---|\s'), '').length < 40) {
        s += '\n(This PDF looks like a scanned image with no text layer.)';
      }
      return s.length > maxChars ? '${s.substring(0, maxChars)}\n…[truncated]' : s;
    } finally {
      doc.dispose();
    }
  }
}
