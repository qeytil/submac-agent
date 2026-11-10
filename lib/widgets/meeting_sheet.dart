import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/meeting_notes.dart';
import '../theme.dart';
import 'logo.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// Records a meeting or lecture, turns it into text, and asks Telesia for clean notes.
Future<void> showMeetingRecorder(BuildContext context) async {
  final mic = await Permission.microphone.request();
  if (!mic.isGranted || !context.mounted) return;
  await showModalBottomSheet<void>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => const _MeetingSheet(),
  );
}

class _MeetingSheet extends StatefulWidget {
  const _MeetingSheet();

  @override
  State<_MeetingSheet> createState() => _MeetingSheetState();
}

class _MeetingSheetState extends State<_MeetingSheet> {
  final _rec = AudioRecorder();
  Timer? _tick;
  final _sw = Stopwatch();
  String _phase = 'recording'; // recording | paused | working | error
  String _error = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/meeting_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 16000, numChannels: 1),
        path: path,
      );
      // The sheet can be closed while the microphone is still starting: never start the clock on a closed sheet.
      if (!mounted) return;
      _sw.start();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'error';
        _error = 'The microphone didn\'t start. Check Telesia may use it, then try again.';
      });
    }
  }

  Future<void> _pause() async {
    if (_phase == 'recording') {
      await _rec.pause();
      _sw.stop();
      if (!mounted) return;
      setState(() => _phase = 'paused');
    } else {
      await _rec.resume();
      _sw.start();
      if (!mounted) return;
      setState(() => _phase = 'recording');
    }
  }

  Future<void> _finish() async {
    _tick?.cancel();
    _sw.stop();
    final path = await _rec.stop();
    if (path == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    if (!mounted) return;
    setState(() => _phase = 'working');
    final state = context.read<AppState>();
    try {
      final text = await MeetingNotes.transcribe(path);
      if (!mounted) return;
      final mins = (_sw.elapsed.inSeconds / 60).ceil();
      final bytes = Uint8List.fromList(utf8.encode(text));
      Navigator.pop(context);
      state.send(
        'I recorded a meeting ($mins min). Write clear notes from the transcript: a short summary first, then decisions, '
        'action items with who does what and by when, and open questions. Offer to make it a Word document.',
        [Attachment(name: 'Meeting transcript.txt', mime: 'text/plain', bytes: bytes)],
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'error';
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _rec.dispose();
    super.dispose();
  }

  String get _time {
    final s = _sw.elapsed.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return '${h > 0 ? '$h:' : ''}${m.toString().padLeft(h > 0 ? 2 : 1, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 28, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          RedDot(size: 18, animate: _phase == 'recording' || _phase == 'working'),
          const SizedBox(height: 18),
          Text(
            switch (_phase) {
              'working' => 'Writing your notes',
              'paused' => 'Paused',
              'error' => 'That did not work',
              _ => 'Recording the meeting',
            },
            style: Brand.serif(size: 26, color: p.text),
          ),
          const SizedBox(height: 8),
          Text(
            _phase == 'error'
                ? _error
                : _phase == 'working'
                    ? 'Listening back and turning it into notes…'
                    : '$_time · keep the phone near the speakers',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4),
          ),
          const SizedBox(height: 24),
          if (_phase == 'recording' || _phase == 'paused')
            Row(children: [
              Expanded(
                child: OutlinedButton(onPressed: _pause, child: Text(_phase == 'paused' ? 'Resume' : 'Pause')),
              ),
              const SizedBox(width: 12),
              Expanded(child: FilledButton(onPressed: _finish, child: Text(tr('Done')))),
            ]),
          if (_phase == 'error')
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
            ),
          if (_phase == 'recording' || _phase == 'paused')
            TextButton(
              onPressed: () async {
                _tick?.cancel();
                await _rec.cancel();
                if (context.mounted) Navigator.pop(context);
              },
              child: Text('Discard', style: TextStyle(color: p.muted)),
            ),
        ]),
      ),
    );
  }
}
