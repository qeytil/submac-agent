import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';
import 'package:http/http.dart' show ClientException;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../ui/i18n.dart' show AppLang;

/// In-app feedback (2026-10-26): the user writes a message, attaches up to 5 screenshots and sends it.
/// Screenshots go to the private bucket `feedback-screenshots` under `<uid>/<feedback id>/`, then one row goes into
/// `public.feedback` with the app and device details. The owner reads it in the admin dashboard's Feedback section.
/// Server: supabase/migrations/20261026_feedback.sql and supabase/functions/feedback-admin.

/// One attached picture.
class FeedbackShot {
  final String name;
  final String mime;
  final Uint8List bytes;
  FeedbackShot({required this.name, required this.mime, required this.bytes});

  int get size => bytes.length;
}

/// What the server accepts (the bucket and the table enforce the same limits).
class FeedbackLimits {
  FeedbackLimits._();
  static const maxShots = 5;
  static const maxShotBytes = 5 * 1024 * 1024;
  static const maxMessage = 5000;
  static const bucket = 'feedback-screenshots';
  static const mimes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'heic': 'image/heic',
    'heif': 'image/heif',
  };

  /// The picture type for a file name, or null when it is not a picture the server takes.
  static String? mimeFor(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    return mimes[name.substring(dot + 1).toLowerCase()];
  }

  static String extFor(String mime) => switch (mime) {
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'image/heic' => 'heic',
        'image/heif' => 'heif',
        _ => 'jpg',
      };
}

/// Why a send (or an attach) failed. The screen picks its words from this.
enum FeedbackProblem { empty, tooLong, offline, signedOut, tooMany, tooBig, badType, tooManyShots, server }

class FeedbackException implements Exception {
  final FeedbackProblem problem;
  final String detail;
  const FeedbackException(this.problem, [this.detail = '']);
  @override
  String toString() => 'FeedbackException(${problem.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// The app and device details sent with every feedback.
class FeedbackDevice {
  final String? appVersion;
  final String? buildNumber;
  final String? deviceModel;
  final String? osVersion;
  final String? locale;
  const FeedbackDevice({this.appVersion, this.buildNumber, this.deviceModel, this.osVersion, this.locale});

  static const _ch = MethodChannel('telesia/update');

  /// Reads the installed version and the phone model from Android (the update channel's `info`), with safe
  /// fallbacks off Android and in tests.
  static Future<FeedbackDevice> read() async {
    Map<String, dynamic>? info;
    try {
      info = await _ch.invokeMapMethod<String, dynamic>('info').timeout(const Duration(seconds: 3));
    } catch (_) {}
    String? s(Object? v) => v == null || '$v'.trim().isEmpty ? null : '$v'.trim();
    final maker = s(info?['manufacturer']);
    final model = s(info?['model']);
    final release = s(info?['release']);
    String? os;
    if (release != null) {
      os = 'Android $release${info?['sdk'] != null ? ' (SDK ${info!['sdk']})' : ''}';
    } else {
      try {
        os = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
      } catch (_) {}
    }
    final device = model == null
        ? null
        : (maker != null && !model.toLowerCase().startsWith(maker.toLowerCase()) ? '$maker $model' : model);
    return FeedbackDevice(
      appVersion: s(info?['name']) ?? AppConfig.version,
      buildNumber: s(info?['code']),
      deviceModel: device,
      osVersion: os,
      locale: localeTag(AppLang.I.code, PlatformDispatcher.instance.locale.toLanguageTag()),
    );
  }

  /// "so" for the app language plus the phone's own locale when it differs: "so (en-US)".
  static String localeTag(String app, String phone) {
    final t = phone.isEmpty || phone.toLowerCase().startsWith(app.toLowerCase()) ? app : '$app ($phone)';
    return t.length > 20 ? t.substring(0, 20) : t;
  }

  Map<String, dynamic> toRow() {
    String? cut(String? v, int n) => v == null ? null : (v.length > n ? v.substring(0, n) : v);
    return {
      'app_version': cut(appVersion, 40),
      'build_number': cut(buildNumber, 20),
      'device_model': cut(deviceModel, 120),
      'os_version': cut(osVersion, 120),
      'locale': cut(locale, 20),
    };
  }
}

/// Where feedback goes. The real one is Supabase; tests use a fake.
abstract class FeedbackBackend {
  String? get userId;
  Future<void> upload(String path, Uint8List bytes, String mime);
  Future<void> insert(Map<String, dynamic> row);
  Future<void> remove(List<String> paths);
}

class SupabaseFeedbackBackend implements FeedbackBackend {
  SupabaseClient get _c => Supabase.instance.client;
  static const _timeout = Duration(seconds: 60);

  @override
  String? get userId {
    try {
      return _c.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> upload(String path, Uint8List bytes, String mime) => _c.storage
      .from(FeedbackLimits.bucket)
      .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime, upsert: false))
      .timeout(_timeout);

  @override
  Future<void> insert(Map<String, dynamic> row) => _c.from('feedback').insert(row).timeout(const Duration(seconds: 30));

  @override
  Future<void> remove(List<String> paths) => _c.storage.from(FeedbackLimits.bucket).remove(paths).timeout(const Duration(seconds: 30));
}

/// Progress of one send: [done] of [total] steps (each screenshot, then the row).
class FeedbackProgress {
  final int done;
  final int total;
  final int shot; // 1-based screenshot being uploaded, 0 while saving the row
  const FeedbackProgress(this.done, this.total, this.shot);
  double get fraction => total == 0 ? 0 : done / total;
}

/// Sends feedback. One sender lives as long as the Feedback screen, so a retry after a failure does not upload the
/// screenshots that already made it.
class FeedbackSender {
  final FeedbackBackend backend;
  final Future<FeedbackDevice> Function() device;
  final String Function() newId;
  FeedbackSender({FeedbackBackend? backend, Future<FeedbackDevice> Function()? device, String Function()? newId})
      : backend = backend ?? SupabaseFeedbackBackend(),
        device = device ?? FeedbackDevice.read,
        newId = newId ?? (() => const Uuid().v4());

  String? _id;
  final Map<FeedbackShot, String> _uploaded = Map.identity();

  /// Checks one picture before it is attached.
  static void checkShot(FeedbackShot s, {int already = 0}) {
    if (already >= FeedbackLimits.maxShots) throw const FeedbackException(FeedbackProblem.tooManyShots);
    if (!FeedbackLimits.mimes.containsValue(s.mime)) throw const FeedbackException(FeedbackProblem.badType);
    if (s.size > FeedbackLimits.maxShotBytes) throw const FeedbackException(FeedbackProblem.tooBig);
  }

  /// Uploads the screenshots, then saves the row. Throws [FeedbackException]; on failure nothing is lost on the phone
  /// and a second call picks up where this one stopped.
  Future<void> send({
    required String message,
    String? category,
    List<FeedbackShot> shots = const [],
    void Function(FeedbackProgress p)? onProgress,
  }) async {
    final text = message.trim();
    if (text.isEmpty) throw const FeedbackException(FeedbackProblem.empty);
    if (text.length > FeedbackLimits.maxMessage) throw const FeedbackException(FeedbackProblem.tooLong);
    if (shots.length > FeedbackLimits.maxShots) throw const FeedbackException(FeedbackProblem.tooManyShots);
    for (final s in shots) {
      checkShot(s);
    }
    final uid = backend.userId;
    if (uid == null) throw const FeedbackException(FeedbackProblem.signedOut);
    final id = _id ??= newId();
    final total = shots.length + 1;
    var done = 0;
    try {
      for (var i = 0; i < shots.length; i++) {
        final s = shots[i];
        if (!_uploaded.containsKey(s)) {
          onProgress?.call(FeedbackProgress(done, total, i + 1));
          final path = '$uid/$id/${i + 1}-${DateTime.now().millisecondsSinceEpoch}.${FeedbackLimits.extFor(s.mime)}';
          await backend.upload(path, s.bytes, s.mime);
          _uploaded[s] = path;
        }
        done++;
      }
      onProgress?.call(FeedbackProgress(done, total, 0));
      final info = await device();
      await backend.insert({
        'user_id': uid,
        'message': text,
        if (category != null && category.isNotEmpty) 'category': category,
        ...info.toRow(),
        'screenshot_paths': [for (final s in shots) _uploaded[s]!],
      });
      onProgress?.call(FeedbackProgress(total, total, 0));
    } catch (e) {
      throw classify(e);
    }
    // Pictures uploaded on an earlier try and removed before this one: clean up, quietly.
    final stale = [
      for (final e in _uploaded.entries)
        if (!shots.any((s) => identical(s, e.key))) e.value
    ];
    _uploaded.clear();
    _id = null;
    if (stale.isNotEmpty) unawaited(backend.remove(stale).catchError((_) {}));
  }

  /// Turns whatever the network or the server threw into a [FeedbackProblem].
  static FeedbackException classify(Object e) {
    if (e is FeedbackException) return e;
    if (e is SocketException || e is TimeoutException || e is HandshakeException || e is ClientException) {
      return FeedbackException(FeedbackProblem.offline, '$e');
    }
    final s = '$e';
    final low = s.toLowerCase();
    if (low.contains('failed host lookup') || low.contains('connection refused') || low.contains('network is unreachable') ||
        low.contains('connection closed') || low.contains('socketexception') || low.contains('connection reset')) {
      return FeedbackException(FeedbackProblem.offline, s);
    }
    if (e is StorageException) {
      final code = e.statusCode ?? '';
      if (code == '413' || low.contains('exceeded the maximum allowed size') || low.contains('too large')) {
        return FeedbackException(FeedbackProblem.tooBig, s);
      }
      if (code == '415' || low.contains('mime type')) return FeedbackException(FeedbackProblem.badType, s);
      if (code == '401' || low.contains('jwt')) return FeedbackException(FeedbackProblem.signedOut, s);
      if (low.contains('row-level security') || code == '403') return FeedbackException(FeedbackProblem.tooMany, s);
      return FeedbackException(FeedbackProblem.server, s);
    }
    if (e is PostgrestException) {
      if (e.code == 'PGRST301' || e.code == 'PGRST303' || low.contains('jwt')) return FeedbackException(FeedbackProblem.signedOut, s);
      // The insert policy refuses more than 20 a day (and anything not the sender's own).
      if (e.code == '42501' || low.contains('row-level security')) return FeedbackException(FeedbackProblem.tooMany, s);
      return FeedbackException(FeedbackProblem.server, s);
    }
    if (e is AuthException) return FeedbackException(FeedbackProblem.signedOut, s);
    return FeedbackException(FeedbackProblem.server, s);
  }
}

/// The unsent draft, kept on the phone so nothing is lost offline or when the screen closes.
class FeedbackDraft {
  final String message;
  final String? category;
  final List<FeedbackShot> shots;
  const FeedbackDraft({this.message = '', this.category, this.shots = const []});
  bool get isEmpty => message.trim().isEmpty && shots.isEmpty;
}

abstract class FeedbackDraftStore {
  Future<FeedbackDraft?> load();
  Future<void> save(FeedbackDraft d);
  Future<void> clear();
}

/// Draft in the app's private files: draft.json plus one file per picture.
class FileFeedbackDraftStore implements FeedbackDraftStore {
  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/feedback_draft');
  }

  @override
  Future<FeedbackDraft?> load() async {
    try {
      final d = await _dir();
      final f = File('${d.path}/draft.json');
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final shots = <FeedbackShot>[];
      for (final s in (j['shots'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(s as Map);
        final file = File('${d.path}/${m['file']}');
        if (await file.exists()) shots.add(FeedbackShot(name: '${m['name']}', mime: '${m['mime']}', bytes: await file.readAsBytes()));
      }
      return FeedbackDraft(message: '${j['message'] ?? ''}', category: j['category'] as String?, shots: shots);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(FeedbackDraft draft) async {
    try {
      if (draft.isEmpty) {
        await clear();
        return;
      }
      final d = await _dir();
      if (await d.exists()) await d.delete(recursive: true);
      await d.create(recursive: true);
      final shots = <Map<String, String>>[];
      for (var i = 0; i < draft.shots.length; i++) {
        final s = draft.shots[i];
        final name = 'shot_$i.${FeedbackLimits.extFor(s.mime)}';
        await File('${d.path}/$name').writeAsBytes(s.bytes, flush: true);
        shots.add({'name': s.name, 'mime': s.mime, 'file': name});
      }
      await File('${d.path}/draft.json')
          .writeAsString(jsonEncode({'message': draft.message, 'category': draft.category, 'shots': shots}), flush: true);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      final d = await _dir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}
