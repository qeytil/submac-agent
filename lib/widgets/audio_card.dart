import 'dart:async';
import 'dart:io';
import 'dart:math' as m;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../services/media_store.dart';
import '../screens/preview_screen.dart';
import '../theme.dart';
import 'media_view.dart';
import 'output_cards.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// A decoded 16-bit PCM WAV.
class _Wav {
  final int rate, channels;
  final Int16List samples; // interleaved
  _Wav(this.rate, this.channels, this.samples);
  double get seconds => samples.length / channels / rate;

  static _Wav? parse(Uint8List b) {
    if (b.length < 44 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF') return null;
    final bd = ByteData.sublistView(b);
    var i = 12, rate = 44100, ch = 1, bits = 16;
    while (i + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(i, i + 4));
      final size = bd.getUint32(i + 4, Endian.little);
      if (id == 'fmt ') {
        ch = bd.getUint16(i + 10, Endian.little);
        rate = bd.getUint32(i + 12, Endian.little);
        bits = bd.getUint16(i + 22, Endian.little);
      } else if (id == 'data') {
        if (bits != 16) return null;
        final end = m.min(b.length, i + 8 + size);
        final start = i + 8;
        final n = (end - start) ~/ 2;
        final out = Int16List(n);
        for (var k = 0; k < n; k++) {
          out[k] = bd.getInt16(start + k * 2, Endian.little);
        }
        return _Wav(rate, ch, out);
      }
      i += 8 + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  /// Peak per bucket, 0..1, for the waveform.
  List<double> peaks(int buckets) {
    final frames = samples.length ~/ channels;
    if (frames == 0) return List.filled(buckets, 0);
    final per = m.max(1, frames ~/ buckets);
    final out = <double>[];
    for (var bI = 0; bI < buckets; bI++) {
      var pk = 0;
      final s = bI * per;
      for (var f = s; f < m.min(frames, s + per); f += 4) {
        final v = samples[f * channels].abs();
        if (v > pk) pk = v;
      }
      out.add(pk / 32768);
    }
    final mx = out.fold<double>(0.001, (a, b) => m.max(a, b));
    return [for (final v in out) v / mx];
  }
}

/// One sound plays at a time across the app.
class _Player {
  static _AudioCardState? current;
}

/// A sound Telesia made: a red-dot play button, a waveform that fills as it plays, Save and Share.
class AudioCard extends StatefulWidget {
  const AudioCard(this.path, {super.key});
  final String path;

  @override
  State<AudioCard> createState() => _AudioCardState();
}

class _AudioCardState extends State<AudioCard> with SingleTickerProviderStateMixin {
  _Wav? _wav;
  List<double> _peaks = const [];
  bool _playing = false;
  bool _failed = false;
  /// The file on this phone (after a download when it came from another phone).
  String? _local;
  final _clock = Stopwatch();
  Timer? _feeder;
  int _fed = 0; // frames fed
  late final Ticker _ticker = createTicker((_) {
    if (mounted && _playing) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // A sound made on another phone is fetched from the account first.
      final f = MediaStore.I.localNow(widget.path) ?? await MediaStore.I.resolve(widget.path);
      if (f == null) throw const FileSystemException('gone');
      unawaited(MediaStore.I.keep(f.path).catchError((_) => null));
      _local = f.path;
      final b = await f.readAsBytes();
      final w = _Wav.parse(b);
      if (!mounted) return;
      setState(() {
        _wav = w;
        _failed = w == null;
        _peaks = w?.peaks(56) ?? const [];
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  double get _pos {
    final w = _wav;
    if (w == null) return 0;
    return (_clock.elapsedMilliseconds / 1000 / w.seconds).clamp(0.0, 1.0);
  }

  Future<void> _toggle() async {
    if (_playing) return _stop();
    final w = _wav;
    if (w == null || _failed) {
      openPreview(context, _local ?? widget.path);
      return;
    }
    // Live owns the speaker during a call; open the full player instead.
    if (context.read<AppState>().liveCtl.active) {
      openPreview(context, _local ?? widget.path);
      return;
    }
    await _Player.current?._stop();
    _Player.current = this;
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
    await FlutterPcmSound.setup(sampleRate: w.rate, channelCount: w.channels);
    _fed = 0;
    // Leaving the chat while the player was still setting up used to start the clock and the feeder on a card that
    // was gone (setState after dispose).
    if (!mounted) return;
    _clock
      ..reset()
      ..start();
    setState(() => _playing = true);
    _ticker.start();
    _feed();
    _feeder = Timer.periodic(const Duration(milliseconds: 200), (_) => _feed());
  }

  void _feed() {
    final w = _wav!;
    final totalFrames = w.samples.length ~/ w.channels;
    final playedFrames = (_clock.elapsedMilliseconds / 1000 * w.rate).floor();
    if (playedFrames >= totalFrames) {
      _stop();
      return;
    }
    final ahead = w.rate; // keep about 1 s queued
    if (_fed - playedFrames > ahead ~/ 2 || _fed >= totalFrames) return;
    final n = m.min(totalFrames - _fed, ahead);
    // Copy the slice into its own buffer: the plugin sends `bytes.buffer` whole, so a view would
    // queue the entire song again on every feed and the sound turns into a garbled, radio-like mess.
    final slice = Int16List.fromList(Int16List.sublistView(w.samples, _fed * w.channels, (_fed + n) * w.channels));
    FlutterPcmSound.feed(PcmArrayInt16(bytes: slice.buffer.asByteData()));
    _fed += n;
  }

  Future<void> _stop() async {
    _feeder?.cancel();
    _feeder = null;
    _clock.stop();
    if (_ticker.isActive) _ticker.stop();
    if (_Player.current == this) _Player.current = null;
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
    if (mounted) setState(() => _playing = false);
    _clock.reset();
  }

  @override
  void dispose() {
    if (_playing) {
      _feeder?.cancel();
      FlutterPcmSound.release();
      if (_Player.current == this) _Player.current = null;
    }
    _ticker.dispose();
    super.dispose();
  }

  String _t(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = _wav;
    final name = widget.path.split('/').last.replaceAll(RegExp(r'_\d{10,}'), '').replaceAll(RegExp(r'\.\w+$'), '').replaceAll('-', ' ');
    final title = name.isEmpty ? 'Sound' : name[0].toUpperCase() + name.substring(1);
    // Compact: one slim row, like a voice note. Play, title over waveform, time, Save, Share.
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 4, 8),
      decoration: BoxDecoration(
        color: p.sheet,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: AnimatedContainer(
            duration: SubMotion.of(context, SubMotion.quick),
            curve: SubMotion.settle,
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.text,
              boxShadow: const [],
            ),
            child: _playing
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 3, height: 12, decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 4),
                    Container(width: 3, height: 12, decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(2))),
                  ])
                : Padding(padding: const EdgeInsetsDirectional.only(start: 2), child: SubIcon('play', color: p.bg, size: 16)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
              ),
              Text(
                w == null ? (_failed ? 'Tap to open' : '') : (_playing ? '${_t(_pos * w.seconds)} / ${_t(w.seconds)}' : _t(w.seconds)),
                style: Brand.mono(size: 10.5, color: p.muted),
              ),
            ]),
            const SizedBox(height: 4),
            SizedBox(
              height: 18,
              child: CustomPaint(size: Size.infinite, painter: _WavePainter(_peaks, _playing ? _pos : 0, p)),
            ),
          ]),
        ),
        const SizedBox(width: 2),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Save',
          onPressed: () => saveToPhone(context, widget.path),
          icon: Text(tr('Save'), style: TextStyle(color: p.muted, fontSize: AppText.micro, fontWeight: FontWeight.w600)),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Share',
          onPressed: () => withLocalFile(context, _local ?? widget.path, (f) => SharePlus.instance.share(ShareParams(files: [XFile(f.path)]))),
          icon: SubIcon('share', size: 18, color: p.muted),
        ),
      ]),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.peaks, this.pos, this.p);
  final List<double> peaks;
  final double pos;
  final Palette p;

  @override
  void paint(Canvas canvas, Size s) {
    if (peaks.isEmpty) {
      canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), Paint()..color = p.border);
      return;
    }
    final n = peaks.length;
    final step = s.width / n;
    final bw = m.max(1.5, step * 0.55);
    for (var i = 0; i < n; i++) {
      final hgt = m.max(2.0, peaks[i] * (s.height - 2));
      final x = i * step + step / 2;
      final played = (i + 0.5) / n <= pos;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, s.height / 2), width: bw, height: hgt), Radius.circular(bw / 2)),
        Paint()..color = played ? p.text : p.text.withValues(alpha: 0.28),
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) => o.pos != pos || o.peaks != peaks || o.p != p;
}
