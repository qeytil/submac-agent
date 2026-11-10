import 'dart:io';

import 'cloud.dart';

/// Turns a recording into text through Telesia Cloud (Somali, Arabic, English and more).
class MeetingNotes {
  /// Recordings up to about 18 MB (roughly 30 to 40 minutes) go in one piece.
  static const maxBytes = 18 * 1024 * 1024;

  static Future<String> transcribe(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    if (bytes.length > maxBytes) {
      throw 'This recording is too long to turn into text in one go. Record shorter parts (about 30 minutes each).';
    }
    try {
      final t = await Cloud.transcribe(bytes, mime: path.endsWith('.wav') ? 'audio/wav' : 'audio/mp4');
      if (t.isEmpty) throw 'No words were heard in the recording.';
      return t;
    } on CloudException catch (e) {
      throw e.message;
    }
  }
}
