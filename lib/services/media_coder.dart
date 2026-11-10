import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/services.dart' show rootBundle;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'tools.dart';

/// Media by code: the agent writes JavaScript and Telesia runs it in a private, invisible browser
/// on the phone. Canvas drawings become PNGs, SVG becomes PNG (+ the .svg), Web Audio code becomes
/// a WAV, and canvas animations become a WebM video. No image model, no key, no cost.
class MediaCoder {
  static const names = {'code_media'};

  /// The audio cookbook, sent only when the chat is about sound or music (it is long, and most requests are pictures).
  static const audioGuide = 'HOW TO CODE GOOD AUDIO (follow this, or music sounds thin like a cheap radio):\n'
            '1. Use Web Audio nodes (OscillatorNode is alias-free), not raw synth() for music; raw naive saw/square aliases into hiss.\n'
            '2. Fill the spectrum: sub/bass 40-120 Hz (sine an octave under a filtered saw, notes octave 1-2), kick (sine sweeping 150→45 Hz in 0.1 s, fast decay), body 200-800 Hz (chords octave 3-4), presence 1-4 kHz (melody octave 4-5), air above 6 kHz (hats = highpassed noise, 30-80 ms). Nothing should sit only in the mids.\n'
            '3. Shape every note: an attack/decay envelope on a GainNode (exponentialRamp to 0.001, never cut to zero instantly, which clicks). Plucks and keys decay; pads swell slowly.\n'
            '4. Tame harsh waves: run saw/square through a BiquadFilter lowpass (bass 300-900 Hz, chords 1-3 kHz) and sweep the cutoff for movement; add 2-3 partials (sine x1, x2, x3 with falling gain) for piano/bell tones.\n'
            '5. Width: StereoPannerNode on every voice. Keep kick, bass, snare and lead centred; spread chords, hats and doubles left/right; detune paired oscillators by ±6-10 cents for a wide pad.\n'
            '6. Space: send chords, snare and melody to `rev`; keep bass and kick dry.\n'
            '7. Gain staging: no single voice above 0.5, chords 0.05-0.15 per voice, the bass and kick loudest. The master already balances loudness and limits peaks cleanly; never add your own DynamicsCompressor or WaveShaper distortion.\n'
            '8. Write music, not tones: pick a key and a 4-chord progression (e.g. Am-F-C-G at 90-110 bpm), bass on the roots, chords on every bar, a melody from the scale with rests and repetition, drums on a grid (kick 1 and 3, snare 2 and 4, hats on eighths), and change something every 4-8 bars (drop drums, add a layer). End with a fade.\n';

  /// The tool with the audio cookbook folded into its description.
  static List<Map<String, dynamic>> get withAudioGuide {
    final f = Map<String, dynamic>.from(definitions.first['function'] as Map);
    f['description'] = '${f['description']}\n$audioGuide';
    return [
      {'type': 'function', 'function': f}
    ];
  }

  static final definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'code_media',
        'description': 'Create an image, sound, music or short animation by writing JavaScript that Telesia runs on the phone (free and instant). '
            'Use it for drawings, posters, logos, patterns, charts-as-art, generative art, illustrations, icons, wallpapers, '
            'sound effects, melodies, beats and ambient audio. The result is shown to the user and saved to the Library. '
            'If it returns an error, fix the code and call again. Never redeclare the given names (canvas, ctx, out, W, H, helpers).\n'
            'kind=image: code draws on `canvas` with `ctx` (CanvasRenderingContext2D, size W x H; starts filled with paper colour unless the code mentions "transparent"). Top-level await works.\n'
            'kind=svg: code is SVG markup (not JS); it is rendered to PNG.\n'
            'kind=audio: code schedules Web Audio nodes on `ctx` (an OfflineAudioContext, `out` = a soft master bus with gentle limiting; connect to `out`). '
            'Or call `synth((t, ch) => sample)` to write raw samples (-1..1). Length = duration seconds.\n'
            'kind=audio also has `rev` (a stereo studio reverb bus: send a voice to it with a second connect, through a gain of 0.1-0.4).\n'
            'kind=video: define `function frame(t, ctx)` (t = seconds) that draws one frame; it is recorded at fps for duration seconds (WebM).\n'
            'Helpers: W, H, DUR, SR, rand() (seeded), rnd(a,b), noise(x,y) (smooth 2D noise 0..1), lerp(a,b,t), ease(t), hsl(h,s,l), '
            'note("A4")→Hz, midi(n)→Hz, env(param, t, {a,d,s,r,peak,hold}) ADSR, osc(type,freq,t,len,gain), noiseBuf(sec), '
            'C = Telesia colours {paper:"#f4f0e7", ink:"#17150f", red:"#c2361b", night:"#000000", wash:"#f6dfd6", brass:"#b08d57", slate:"#5b7083"}, '
            'font(px, "serif"|"sans"|"mono", weight?, italic?) → a CSS font string using Telesia fonts (Instrument Serif, Geist, Geist Mono),  await loadImage(url), await load(scriptUrl) for a library from a CDN, console.log for notes.',
        'parameters': {
          'type': 'object',
          'properties': {
            'kind': {'type': 'string', 'enum': ['image', 'svg', 'audio', 'video']},
            'code': {'type': 'string', 'description': 'JavaScript (or SVG markup for kind=svg).'},
            'width': {'type': 'integer', 'description': 'Pixels, default 1080 (image/svg/video). Max 2048.'},
            'height': {'type': 'integer', 'description': 'Pixels, default 1080. Max 2048.'},
            'duration': {'type': 'number', 'description': 'Seconds for audio (default 6, max 90) or video (default 5, max 20).'},
            'fps': {'type': 'integer', 'description': 'Video frames per second, default 30.'},
            'name': {'type': 'string', 'description': 'Short file name without extension, e.g. "sunset-poster".'},
            'images': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Phone/workspace image paths to use (e.g. a photo the user sent). They arrive ready to draw as IMAGES[0], IMAGES[1]… (image/video only).'
            },
          },
          'required': ['kind', 'code'],
        },
      },
    }
  ];

  static Future<String> execute(String name, Map<String, dynamic> args) async {
    final kind = (args['kind'] ?? 'image').toString();
    final code = (args['code'] ?? '').toString();
    if (code.trim().isEmpty) return 'Error: code is empty.';
    final w = _int(args['width'], 1080).clamp(16, 2048);
    final h = _int(args['height'], 1080).clamp(16, 2048);
    final dur = _num(args['duration'], kind == 'video' ? 5 : 6).clamp(0.2, kind == 'video' ? 20.0 : 90.0);
    final fps = _int(args['fps'], 30).clamp(5, 60);
    final base = _slug((args['name'] ?? '').toString(), kind);
    final ws = await AgentTools.workspaceDir();
    final dir = Directory('$ws/media');
    await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;

    final images = <String>[];
    for (final pth in (args['images'] is List ? args['images'] as List : const [])) {
      try {
        var path = '$pth';
        if (!path.startsWith('/')) path = '$ws/$path';
        final f = File(path);
        if (!await f.exists()) return 'Error: image not found: $pth';
        final low = path.toLowerCase();
        final mime = low.endsWith('.png') ? 'image/png' : low.endsWith('.webp') ? 'image/webp' : low.endsWith('.gif') ? 'image/gif' : 'image/jpeg';
        images.add('data:$mime;base64,${base64Encode(await f.readAsBytes())}');
      } catch (e) {
        return 'Error: could not read image $pth ($e)';
      }
    }
    final r = await _run(kind: kind, code: code, w: w, h: h, dur: dur.toDouble(), fps: fps, images: images);
    if (r.error != null) {
      return 'Error: the code failed: ${r.error}${r.logs.isEmpty ? '' : '\nconsole: ${r.logs.join(' | ')}'}\nFix the code and call code_media again.';
    }
    final bytes = r.bytes!;
    final ext = switch (kind) { 'audio' => 'wav', 'video' => 'webm', _ => 'png' };
    final f = File('${dir.path}/${base}_$stamp.$ext');
    await f.writeAsBytes(bytes, flush: true);
    if (kind == 'svg') {
      try {
        await File('${dir.path}/${base}_$stamp.svg').writeAsString(code);
      } catch (_) {}
    }
    final note = r.logs.isEmpty ? '' : '\nconsole: ${r.logs.take(10).join(' | ')}';
    switch (kind) {
      case 'audio':
        return 'AUDIO_SAVED ${f.path}\nThe sound (${dur.toStringAsFixed(1)} s) is shown to the user with a player and saved in their Library.$note';
      case 'video':
        return 'VIDEO_SAVED ${f.path}\nThe animation is shown to the user and saved in their Library.$note';
      default:
        return 'IMAGE_SAVED ${f.path}\nThe image ($w x $h) is shown to the user and saved in their Library. '
            'You cannot see it; describe what you drew briefly and offer one tweak.$note';
    }
  }

  static int _int(dynamic v, int d) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? d;
  static double _num(dynamic v, double d) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? d;
  static String _slug(String s, String kind) {
    final t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (t.isNotEmpty) return t.length > 40 ? t.substring(0, 40) : t;
    return switch (kind) { 'audio' => 'sound', 'video' => 'animation', _ => 'drawing' };
  }

  // One run at a time keeps memory low on phones.
  static Future<void> _queue = Future.value();

  static Future<_Result> _run({required String kind, required String code, required int w, required int h, required double dur, required int fps, List<String> images = const []}) {
    final c = Completer<_Result>();
    _queue = _queue.then((_) => _runNow(kind: kind, code: code, w: w, h: h, dur: dur, fps: fps, images: images).then(c.complete, onError: (e) => c.complete(_Result.err('$e'))));
    return c.future;
  }

  static Future<_Result> _runNow({required String kind, required String code, required int w, required int h, required double dur, required int fps, List<String> images = const []}) async {
    final done = Completer<_Result>();
    final chunks = <int, String>{};
    final logs = <String>[];
    HeadlessInAppWebView? view;
    var started = false;
    final timeout = Duration(seconds: switch (kind) { 'video' => (dur + 40).ceil(), 'audio' => 90, _ => 45 });

    view = HeadlessInAppWebView(
      initialSize: Size(w.toDouble().clamp(320.0, 1200.0), h.toDouble().clamp(320.0, 1200.0)),
      initialData: InAppWebViewInitialData(data: _harness, baseUrl: WebUri('https://telesia.local/'), mimeType: 'text/html', encoding: 'utf-8'),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        cacheEnabled: true,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
      ),
      onConsoleMessage: (_, msg) {
        if (logs.length < 30) logs.add(msg.message.length > 300 ? '${msg.message.substring(0, 300)}…' : msg.message);
      },
      onWebViewCreated: (ctl) {
        ctl.addJavaScriptHandler(
            handlerName: 'chunk',
            callback: (a) {
              if (a.length >= 2) chunks[(a[0] as num).toInt()] = a[1].toString();
              return true;
            });
        ctl.addJavaScriptHandler(
            handlerName: 'finish',
            callback: (a) {
              final n = a.isNotEmpty ? (a[0] as num).toInt() : chunks.length;
              final b64 = [for (var i = 0; i < n; i++) chunks[i] ?? ''].join();
              try {
                final data = b64.contains(',') ? b64.substring(b64.indexOf(',') + 1) : b64;
                if (!done.isCompleted) done.complete(_Result.ok(base64Decode(data), logs));
              } catch (e) {
                if (!done.isCompleted) done.complete(_Result.err('could not read the output ($e)', logs));
              }
              return true;
            });
        ctl.addJavaScriptHandler(
            handlerName: 'fail',
            callback: (a) {
              if (!done.isCompleted) done.complete(_Result.err(a.isNotEmpty ? a[0].toString() : 'unknown error', logs));
              return true;
            });
      },
      onLoadStop: (ctl, _) async {
        if (started) return;
        started = true;
        try {
          if (kind != 'audio') {
            await ctl.callAsyncJavaScript(functionBody: 'return window.__telesiaFonts(fonts);', arguments: {'fonts': await _fonts()});
          }
          await ctl.callAsyncJavaScript(
            functionBody: 'return window.__telesiaRun(kind, code, w, h, dur, fps, images);',
            arguments: {'kind': kind, 'code': code, 'w': w, 'h': h, 'dur': dur, 'fps': fps, 'images': images},
          );
        } catch (e) {
          if (!done.isCompleted) done.complete(_Result.err('$e', logs));
        }
      },
    );
    try {
      await view.run();
      return await done.future.timeout(timeout, onTimeout: () => _Result.err('timed out after ${timeout.inSeconds}s (make the code lighter)', logs));
    } finally {
      try {
        await view.dispose();
      } catch (_) {}
    }
  }

  static List<Map<String, String>>? _fontCache;

  /// Telesia's own fonts, handed to the page so drawings use Instrument Serif, Geist and Geist Mono.
  static Future<List<Map<String, String>>> _fonts() async {
    if (_fontCache != null) return _fontCache!;
    final out = <Map<String, String>>[];
    for (final f in const [
      ['Instrument Serif', 'InstrumentSerif-Regular.ttf', 'normal', '400'],
      ['Instrument Serif', 'InstrumentSerif-Italic.ttf', 'italic', '400'],
      ['Geist', 'Geist-Regular.ttf', 'normal', '400'],
      ['Geist', 'Geist-SemiBold.ttf', 'normal', '600'],
      ['Geist', 'Geist-Bold.ttf', 'normal', '700'],
      ['Geist Mono', 'GeistMono-Regular.ttf', 'normal', '400'],
    ]) {
      try {
        final b = await rootBundle.load('assets/fonts/${f[1]}');
        out.add({'family': f[0], 'b64': base64Encode(b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes)), 'style': f[2], 'weight': f[3]});
      } catch (_) {}
    }
    return _fontCache = out;
  }

  /// The tiny page that runs the code, with drawing and sound helpers.
  static const _harness = r'''<!doctype html><html><head><meta charset="utf-8">
<style>
@font-face{font-family:SubSerif;src:local("Instrument Serif"),local("Noto Serif"),local("serif");}
html,body{margin:0;background:transparent}
</style></head><body><script>
(function(){
const send = async (dataUrl) => {
  const size = 400000; const n = Math.ceil(dataUrl.length / size);
  for (let i = 0; i < n; i++) await window.flutter_inappwebview.callHandler('chunk', i, dataUrl.slice(i*size, (i+1)*size));
  await window.flutter_inappwebview.callHandler('finish', n);
};
const fail = (e) => window.flutter_inappwebview.callHandler('fail', String((e && (e.message || e)) || e) + (e && e.stack ? ' @ ' + String(e.stack).split('\n').slice(0,2).join(' ') : ''));
window.onerror = (m, s, l, c, e) => { fail(e || (m + ' (line ' + l + ')')); };
window.addEventListener('unhandledrejection', ev => fail(ev.reason));

let seed = 1234567;
const rand = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
const rnd = (a=0,b=1) => a + (b-a)*rand();
const lerp = (a,b,t) => a + (b-a)*t;
const ease = t => t<.5 ? 4*t*t*t : 1-Math.pow(-2*t+2,3)/2;
const hsl = (h,s,l) => `hsl(${h},${s}%,${l}%)`;
const perm = new Uint8Array(512); { const p=[...Array(256).keys()]; for(let i=255;i>0;i--){const j=Math.floor(rand()*(i+1));[p[i],p[j]]=[p[j],p[i]];} for(let i=0;i<512;i++)perm[i]=p[i&255]; }
const grad = (h,x,y) => ((h&1)?-x:x) + ((h&2)?-y:y);
const fade = t => t*t*t*(t*(t*6-15)+10);
const noise = (x,y=0) => { const X=Math.floor(x)&255, Y=Math.floor(y)&255; x-=Math.floor(x); y-=Math.floor(y); const u=fade(x), v=fade(y);
  const a=perm[X]+Y, b=perm[X+1]+Y; return (lerp(lerp(grad(perm[a],x,y),grad(perm[b],x-1,y),u), lerp(grad(perm[a+1],x,y-1),grad(perm[b+1],x-1,y-1),u), v)+1)/2; };
const C = {paper:'#f4f0e7', ink:'#17150f', red:'#c2361b', night:'#000000', wash:'#f6dfd6', brass:'#b08d57', slate:'#5b7083'};
const font = (px, kind='sans', weight=400, italic=false) => `${italic?'italic ':''}${weight} ${px}px ` + (kind==='serif' ? '"Instrument Serif","Noto Serif",Georgia,serif' : kind==='mono' ? '"Geist Mono","Roboto Mono",monospace' : '"Geist","Roboto",system-ui,sans-serif');
const loadImage = (url) => new Promise((ok, no) => { const i = new Image(); i.crossOrigin='anonymous'; i.onload=()=>ok(i); i.onerror=()=>no(new Error('image failed: '+url)); i.src=url; });
const load = (url) => new Promise((ok, no) => { const s=document.createElement('script'); s.src=url; s.onload=ok; s.onerror=()=>no(new Error('script failed: '+url)); document.head.appendChild(s); });
const NOTES = {C:0,'C#':1,Db:1,D:2,'D#':3,Eb:3,E:4,F:5,'F#':6,Gb:6,G:7,'G#':8,Ab:8,A:9,'A#':10,Bb:10,B:11};
const midi = n => 440*Math.pow(2,(n-69)/12);
const note = s => { const m = /^([A-G][#b]?)(-?\d)$/.exec(String(s).trim()); if(!m) return 440; return midi(12*(+m[2]+1)+NOTES[m[1]]); };

function wav(buf){
  const ch = buf.numberOfChannels, sr = buf.sampleRate, len = buf.length;
  const out = new DataView(new ArrayBuffer(44 + len*ch*2));
  const w = (o,s) => { for (let i=0;i<s.length;i++) out.setUint8(o+i, s.charCodeAt(i)); };
  w(0,'RIFF'); out.setUint32(4, 36+len*ch*2, true); w(8,'WAVE'); w(12,'fmt '); out.setUint32(16,16,true); out.setUint16(20,1,true);
  out.setUint16(22,ch,true); out.setUint32(24,sr,true); out.setUint32(28,sr*ch*2,true); out.setUint16(32,ch*2,true); out.setUint16(34,16,true);
  w(36,'data'); out.setUint32(40,len*ch*2,true);
  const data = []; for (let c=0;c<ch;c++) data.push(buf.getChannelData(c));
  // Clean offline mastering (no WebAudio compressors: in offline renders they can get stuck and squash
  // everything after the first loud hit into a thin, radio-like sound). Loudness-match first, then a
  // smooth look-ahead peak limiter, then a final peak trim.
  let sq = 0, cnt = 0; for (let c=0;c<ch;c++) for (let i=0;i<len;i+=4){ const v=data[c][i]; sq+=v*v; cnt++; }
  const rms = Math.sqrt(sq/Math.max(1,cnt));
  const pre = rms > 1e-5 ? Math.min(6, 0.2/rms) : 1;
  const thr = 0.9, look = Math.max(1, Math.floor(sr*0.005)), rel = Math.exp(-1/(sr*0.15));
  const gr = new Float32Array(len);
  for (let i=0;i<len;i++){ let pk=0; for (let c=0;c<ch;c++){ const v=Math.abs(data[c][i]*pre); if(v>pk) pk=v; } gr[i] = pk>thr ? thr/pk : 1; }
  for (let i=len-2;i>=0;i--){ const a = gr[i+1] + (1-gr[i+1])/look; if (a < gr[i]) gr[i] = a; }
  let gcur = 1; for (let i=0;i<len;i++){ const r = 1-(1-gcur)*rel; gcur = gr[i] < r ? gr[i] : r; gr[i] = gcur; }
  let peak = 0; for (let c=0;c<ch;c++) for (let i=0;i<len;i++) peak = Math.max(peak, Math.abs(data[c][i]*pre*gr[i]));
  const post = peak > 0.97 ? 0.97/peak : 1;
  let o = 44; for (let i=0;i<len;i++) for (let c=0;c<ch;c++){ const s=Math.max(-1,Math.min(1,data[c][i]*pre*gr[i]*post)); out.setInt16(o, s<0?s*0x8000:s*0x7fff, true); o+=2; }
  const bytes = new Uint8Array(out.buffer); let bin=''; const step=0x8000;
  for (let i=0;i<bytes.length;i+=step) bin += String.fromCharCode.apply(null, bytes.subarray(i,i+step));
  return 'data:audio/wav;base64,' + btoa(bin);
}

window.__telesiaFonts = async function(list){
  for (const f of (list || [])) {
    try { const bin = atob(f.b64); const u = new Uint8Array(bin.length); for (let i=0;i<bin.length;i++) u[i]=bin.charCodeAt(i);
      const face = new FontFace(f.family, u.buffer, {style: f.style, weight: f.weight}); await face.load(); document.fonts.add(face); } catch(e) {}
  }
};

const AsyncFn = Object.getPrototypeOf(async function(){}).constructor;
// The code runs in its own block, so `const out = ...` or `const ctx = ...` shadows the given name instead of
// failing with "Identifier 'out' has already been declared" (models did that three times in a row).
const inBlock = (code) => '{\n' + code + '\n}';

window.__telesiaRun = async function(kind, code, W, H, DUR, FPS, srcs){
  try {
    const IMAGES = [];
    for (const u of (srcs || [])) IMAGES.push(await loadImage(u));
    if (kind === 'svg') {
      const canvas = document.createElement('canvas'); canvas.width=W; canvas.height=H;
      const ctx = canvas.getContext('2d');
      let svg = code.trim(); if (!/xmlns=/.test(svg)) svg = svg.replace('<svg', '<svg xmlns="http://www.w3.org/2000/svg"');
      const img = await loadImage('data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg));
      ctx.drawImage(img, 0, 0, W, H);
      return await send(canvas.toDataURL('image/png'));
    }
    if (kind === 'image') {
      const canvas = document.createElement('canvas'); canvas.width=W; canvas.height=H;
      const ctx = canvas.getContext('2d');
      // A plain paper background unless the code wants transparency, so it never shows as a dark hole in chat.
      if (!/transparent|clearRect/.test(code)) { ctx.fillStyle = C.paper; ctx.fillRect(0, 0, W, H); }
      const fn = new AsyncFn('canvas','ctx','W','H','rand','rnd','noise','lerp','ease','hsl','C','font','loadImage','load','IMAGES', inBlock(code));
      await fn(canvas, ctx, W, H, rand, rnd, noise, lerp, ease, hsl, C, font, loadImage, load, IMAGES);
      return await send(canvas.toDataURL('image/png'));
    }
    if (kind === 'audio') {
      const SR = 44100;
      const ctx = new OfflineAudioContext(2, Math.ceil(SR*DUR), SR);
      // Clean master: warm EQ and a stereo reverb send. Loudness and peak limiting happen offline in wav().
      const lowShelf = ctx.createBiquadFilter(); lowShelf.type='lowshelf'; lowShelf.frequency.value=110; lowShelf.gain.value=3; lowShelf.connect(ctx.destination);
      const mud = ctx.createBiquadFilter(); mud.type='peaking'; mud.frequency.value=450; mud.Q.value=0.9; mud.gain.value=-2.5; mud.connect(lowShelf);
      const air = ctx.createBiquadFilter(); air.type='highshelf'; air.frequency.value=9000; air.gain.value=1.5; air.connect(mud);
      const hiss = ctx.createBiquadFilter(); hiss.type='lowpass'; hiss.frequency.value=16500; hiss.Q.value=0.5; hiss.connect(air);
      const out = ctx.createGain(); out.gain.value = 0.55; out.connect(hiss);
      const verb = ctx.createConvolver(); const irLen = Math.floor(SR*2.4); const ir = ctx.createBuffer(2, irLen, SR);
      for (let c=0;c<2;c++){ const d=ir.getChannelData(c); for(let i=0;i<irLen;i++){ const x=i/irLen; d[i]=(rand()*2-1)*Math.pow(1-x,3.2)*(i<SR*0.012?0:1); } }
      verb.buffer = ir; const verbHp = ctx.createBiquadFilter(); verbHp.type='highpass'; verbHp.frequency.value=280;
      const rev = ctx.createGain(); rev.gain.value = 0.32; rev.connect(verbHp); verbHp.connect(verb); verb.connect(hiss);
      const env = (param, t, o={}) => { const a=o.a??0.01, d=o.d??0.1, s=o.s??0.6, r=o.r??0.3, pk=o.peak??1, hold=o.hold??0.2;
        param.cancelScheduledValues(t); param.setValueAtTime(0.0001,t); param.linearRampToValueAtTime(pk,t+a);
        param.linearRampToValueAtTime(pk*s,t+a+d); param.setValueAtTime(pk*s,t+a+d+hold); param.linearRampToValueAtTime(0.0001,t+a+d+hold+r); return t+a+d+hold+r; };
      const osc = (type, freq, t, len=0.5, gain=0.3, dest=out) => { const o=ctx.createOscillator(); o.type=type; o.frequency.value=freq;
        const g=ctx.createGain(); g.gain.value=0; o.connect(g); g.connect(dest); env(g.gain, t, {a:0.01,d:0.08,s:0.7,hold:Math.max(0,len-0.1),r:0.15,peak:gain}); o.start(t); o.stop(t+len+0.3); return o; };
      const noiseBuf = (sec=1) => { const b=ctx.createBuffer(1, Math.ceil(SR*sec), SR); const d=b.getChannelData(0); for(let i=0;i<d.length;i++) d[i]=rand()*2-1; return b; };
      const synth = (f) => { const b=ctx.createBuffer(2, Math.ceil(SR*DUR), SR); for(let c=0;c<2;c++){ const d=b.getChannelData(c); for(let i=0;i<d.length;i++) d[i]=f(i/SR, c)||0; }
        const s=ctx.createBufferSource(); s.buffer=b; s.connect(out); s.start(0); return s; };
      const fn = new AsyncFn('ctx','out','SR','DUR','rand','rnd','noise','lerp','ease','note','midi','env','osc','noiseBuf','synth','load','rev', inBlock(code));
      await fn(ctx, out, SR, DUR, rand, rnd, noise, lerp, ease, note, midi, env, osc, noiseBuf, synth, load, rev);
      const buf = await ctx.startRendering();
      // A render where nothing reached the speakers used to be saved and shown as a finished (silent) track.
      let loudest = 0;
      for (let c=0;c<buf.numberOfChannels;c++){ const d=buf.getChannelData(c); for (let i=0;i<d.length;i+=16){ const v=Math.abs(d[i]); if (v>loudest) loudest=v; } }
      if (!(loudest > 1e-4)) throw new Error('the sound came out silent: nothing reached the output. Connect every source to `out` (the given master bus; do not make your own `out`), start it inside the duration, then call again');
      return await send(wav(buf));
    }
    if (kind === 'video') {
      const canvas = document.createElement('canvas'); canvas.width=W; canvas.height=H; document.body.appendChild(canvas);
      const ctx = canvas.getContext('2d');
      const fn = new AsyncFn('canvas','ctx','W','H','rand','rnd','noise','lerp','ease','hsl','C','font','loadImage','load','IMAGES', code + '\n;return typeof frame==="function"?frame:null;');
      const frame = await fn(canvas, ctx, W, H, rand, rnd, noise, lerp, ease, hsl, C, font, loadImage, load, IMAGES);
      if (!frame) throw new Error('define function frame(t, ctx) for kind=video');
      if (!window.MediaRecorder || !canvas.captureStream) throw new Error('this phone cannot record canvas video; make an image instead');
      const stream = canvas.captureStream(FPS);
      const type = ['video/webm;codecs=vp9','video/webm;codecs=vp8','video/webm'].find(t => MediaRecorder.isTypeSupported(t)) || 'video/webm';
      const rec = new MediaRecorder(stream, {mimeType: type, videoBitsPerSecond: 6000000});
      const parts = []; rec.ondataavailable = e => { if (e.data && e.data.size) parts.push(e.data); };
      const stopped = new Promise(ok => rec.onstop = ok);
      frame(0, ctx); rec.start(250);
      const t0 = performance.now();
      await new Promise((ok, no) => { const tick = () => { try { const t = (performance.now()-t0)/1000; if (t >= DUR) return ok(); frame(Math.min(t, DUR), ctx); setTimeout(tick, 1000/FPS); } catch(e){ no(e); } }; tick(); });
      rec.stop(); await stopped;
      const blob = new Blob(parts, {type: 'video/webm'});
      const url = await new Promise(ok => { const r = new FileReader(); r.onload = () => ok(r.result); r.readAsDataURL(blob); });
      return await send(url);
    }
    throw new Error('unknown kind ' + kind);
  } catch (e) { fail(e); }
};
})();
</script></body></html>''';
}

class _Result {
  final List<int>? bytes;
  final String? error;
  final List<String> logs;
  _Result.ok(this.bytes, [this.logs = const []]) : error = null;
  _Result.err(this.error, [this.logs = const []]) : bytes = null;
}
