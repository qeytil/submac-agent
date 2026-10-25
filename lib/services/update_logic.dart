/// Pure logic of in-app updates (no Flutter, no platform): version compare, forced vs optional by time,
/// the download state machine and when the update window shows. The controller is `updater.dart`.
library;

/// Compares "1.13.50+83" style versions: dot parts as numbers, then the build after '+'. Missing parts count as 0.
int compareVersions(String a, String b) {
  List<int> nums(String s) => s.split(RegExp(r'[.+]')).map((p) => int.tryParse(RegExp(r'\d+').stringMatch(p) ?? '') ?? 0).toList();
  String core(String s) => s.trim().split('+').first;
  String build(String s) => s.contains('+') ? s.split('+').last : '0';
  final x = nums(core(a)), y = nums(core(b));
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p < q ? -1 : 1;
  }
  final bx = int.tryParse(build(a)) ?? 0, by = int.tryParse(build(b)) ?? 0;
  return bx == by ? 0 : (bx < by ? -1 : 1);
}

/// Required when a deadline exists and has been reached.
bool isForced(DateTime? requiredAt, DateTime now) => requiredAt != null && !now.isBefore(requiredAt);

/// "Now" anchored on the server's clock at the last check, moved forward by the time since then, so changing the
/// phone's clock does not skip a required update. Time never runs backwards from the server's value.
DateTime effectiveNow({DateTime? serverNow, DateTime? fetchedAt, required DateTime deviceNow}) {
  if (serverNow == null || fetchedAt == null) return deviceNow;
  final elapsed = deviceNow.difference(fetchedAt);
  return serverNow.add(elapsed.isNegative ? Duration.zero : elapsed);
}

class ReleasePart {
  final String path;
  final int size;
  const ReleasePart(this.path, this.size);
  Map<String, dynamic> toJson() => {'path': path, 'size': size};
}

/// One published release, as `latest_release(p_current_code)` returns it.
class Release {
  final String id;
  final int versionCode;
  final String versionName;
  final String notes;
  final String bucket;

  /// 'r2' = one file at [fileUrl] (Cloudflare R2); 'supabase' = [parts] in the Supabase bucket, joined on the phone.
  final String storage;
  final String? fileUrl;
  final List<ReleasePart> parts;
  final int sizeBytes;
  final String sha256;
  final DateTime? requiredAt;
  final DateTime? serverNow;

  const Release({
    required this.id,
    required this.versionCode,
    required this.versionName,
    this.notes = '',
    this.bucket = 'app-updates',
    this.storage = 'supabase',
    this.fileUrl,
    this.parts = const [],
    this.sizeBytes = 0,
    required this.sha256,
    this.requiredAt,
    this.serverNow,
  });

  static DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toUtc();

  /// null when there is no update (or the answer is not usable).
  static Release? fromRpc(dynamic j) {
    if (j is! Map || j['update'] != true) return null;
    final code = j['version_code'] is num ? (j['version_code'] as num).toInt() : int.tryParse('${j['version_code']}');
    final sha = '${j['sha256'] ?? ''}'.toLowerCase();
    final parts = <ReleasePart>[
      for (final p in (j['parts'] is List ? j['parts'] as List : const []))
        if (p is Map && p['path'] is String) ReleasePart(p['path'] as String, p['size'] is num ? (p['size'] as num).toInt() : 0),
    ];
    final storage = '${j['storage'] ?? 'supabase'}';
    final rawUrl = j['file_url'];
    final fileUrl = rawUrl is String && rawUrl.startsWith('https://') ? rawUrl : null;
    if (code == null || code <= 0 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
    if (storage == 'r2' ? fileUrl == null : parts.isEmpty) return null;
    return Release(
      id: '${j['id'] ?? ''}',
      versionCode: code,
      versionName: '${j['version_name'] ?? ''}',
      notes: '${j['notes'] ?? ''}',
      bucket: '${j['bucket'] ?? 'app-updates'}',
      storage: storage == 'r2' ? 'r2' : 'supabase',
      fileUrl: storage == 'r2' ? fileUrl : null,
      parts: parts,
      sizeBytes: j['size_bytes'] is num ? (j['size_bytes'] as num).toInt() : parts.fold(0, (a, p) => a + p.size),
      sha256: sha,
      requiredAt: _date(j['required_at']),
      serverNow: _date(j['server_now']),
    );
  }

  Map<String, dynamic> toJson() => {
        'update': true,
        'id': id,
        'version_code': versionCode,
        'version_name': versionName,
        'notes': notes,
        'bucket': bucket,
        'storage': storage,
        'file_url': fileUrl,
        'parts': [for (final p in parts) p.toJson()],
        'size_bytes': sizeBytes,
        'sha256': sha256,
        'required_at': requiredAt?.toIso8601String(),
        'server_now': serverNow?.toIso8601String(),
      };

  /// True when the phone downloads one file (R2) instead of joining parts.
  bool get singleFile => storage == 'r2' && fileUrl != null;

  /// What to download, in order: the one R2 file, or the public address of every Supabase part.
  List<String> urls(String supabaseUrl) => singleFile
      ? [fileUrl!]
      : [
          for (final p in parts) '${supabaseUrl.replaceAll(RegExp(r'/+$'), '')}/storage/v1/object/public/$bucket/${p.path}',
        ];

  bool newerThan(int? currentCode) => currentCode != null && versionCode > currentCode;
}

/// What the update window is doing.
enum UpdatePhase { idle, downloading, cancelled, downloaded, installing }

/// Why the last step did not go through (shown as one plain line).
enum UpdateIssue { none, failed, badFile, needsPermission }

class UpdateState {
  final UpdatePhase phase;
  final int releaseCode; // 0 = no release
  final int bytes;
  final int total;
  final UpdateIssue issue;

  const UpdateState({this.phase = UpdatePhase.idle, this.releaseCode = 0, this.bytes = 0, this.total = 0, this.issue = UpdateIssue.none});

  double? get progress => total > 0 ? (bytes / total).clamp(0.0, 1.0) : null;

  UpdateState copyWith({UpdatePhase? phase, int? releaseCode, int? bytes, int? total, UpdateIssue? issue}) => UpdateState(
        phase: phase ?? this.phase,
        releaseCode: releaseCode ?? this.releaseCode,
        bytes: bytes ?? this.bytes,
        total: total ?? this.total,
        issue: issue ?? this.issue,
      );

  Map<String, dynamic> toJson() => {'phase': phase.name, 'code': releaseCode, 'bytes': bytes, 'total': total, 'issue': issue.name};

  static UpdateState fromJson(dynamic j) {
    if (j is! Map) return const UpdateState();
    T pick<T extends Enum>(List<T> all, dynamic v, T d) => all.firstWhere((e) => e.name == v, orElse: () => d);
    return UpdateState(
      phase: pick(UpdatePhase.values, j['phase'], UpdatePhase.idle),
      releaseCode: j['code'] is num ? (j['code'] as num).toInt() : 0,
      bytes: j['bytes'] is num ? (j['bytes'] as num).toInt() : 0,
      total: j['total'] is num ? (j['total'] as num).toInt() : 0,
      issue: pick(UpdateIssue.values, j['issue'], UpdateIssue.none),
    );
  }
}

/// The download state machine: idle -> downloading -> downloaded -> installing, with cancelled as the way back.
/// Every method returns the next state; illegal moves return the state unchanged.
class UpdateMachine {
  UpdateState state;
  UpdateMachine([this.state = const UpdateState()]);

  /// A (new) answer from the server. Returns true when old update files must be removed.
  bool onRelease(Release? r, int? currentCode) {
    if (r == null || !r.newerThan(currentCode)) {
      final hadFiles = state.releaseCode != 0 || state.phase != UpdatePhase.idle;
      state = const UpdateState();
      return hadFiles;
    }
    if (r.versionCode != state.releaseCode) {
      final hadFiles = state.releaseCode != 0 && state.phase != UpdatePhase.idle;
      state = UpdateState(releaseCode: r.versionCode, total: r.sizeBytes);
      return hadFiles;
    }
    return false;
  }

  UpdateState start() {
    if (state.releaseCode == 0) return state;
    if (state.phase == UpdatePhase.idle || state.phase == UpdatePhase.cancelled) {
      state = state.copyWith(phase: UpdatePhase.downloading, bytes: 0, issue: UpdateIssue.none);
    }
    return state;
  }

  UpdateState cancel() {
    if (state.phase == UpdatePhase.downloading) state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.none);
    return state;
  }

  /// What Android's download reports: none | running | paused | failed | bad | ready.
  UpdateState onNative(String native, {int bytes = 0, int total = 0}) {
    if (state.releaseCode == 0) return state;
    final t = total > 0 ? total : state.total;
    switch (native) {
      case 'running':
      case 'paused':
        if (state.phase == UpdatePhase.idle || state.phase == UpdatePhase.downloading || state.phase == UpdatePhase.cancelled) {
          state = state.copyWith(phase: UpdatePhase.downloading, bytes: bytes, total: t, issue: UpdateIssue.none);
        }
      case 'ready':
        if (state.phase != UpdatePhase.installing) {
          state = state.copyWith(phase: UpdatePhase.downloaded, bytes: t, total: t, issue: state.issue == UpdateIssue.needsPermission ? state.issue : UpdateIssue.none);
        }
      case 'failed':
        if (state.phase == UpdatePhase.downloading) state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.failed);
      case 'bad':
        state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.badFile);
      case 'none':
        // The files are gone (removed from Android's Downloads list, or never started).
        if (state.phase == UpdatePhase.downloading) {
          state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.failed);
        } else if (state.phase == UpdatePhase.downloaded || state.phase == UpdatePhase.installing) {
          state = state.copyWith(phase: UpdatePhase.idle, bytes: 0, issue: UpdateIssue.none);
        }
    }
    return state;
  }

  UpdateState install() {
    if (state.phase == UpdatePhase.downloaded) state = state.copyWith(phase: UpdatePhase.installing, issue: UpdateIssue.none);
    return state;
  }

  /// What opening the installer returned: started | needs_permission | bad | not_ready.
  UpdateState onInstallResult(String r) {
    if (state.phase != UpdatePhase.installing) return state;
    if (r == 'started') return state;
    if (r == 'needs_permission') {
      state = state.copyWith(phase: UpdatePhase.downloaded, issue: UpdateIssue.needsPermission);
    } else if (r == 'bad') {
      state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.badFile);
    } else {
      state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.failed);
    }
    return state;
  }

  /// Back in SubMac with the old version still running: the installer was closed, so Install is offered again.
  UpdateState onResumed() {
    if (state.phase == UpdatePhase.installing) state = state.copyWith(phase: UpdatePhase.downloaded);
    return state;
  }
}

/// The window shows while a newer release is pending, unless the user tapped Later in this run of the app.
/// A required update always shows (and cannot be dismissed).
bool shouldShowWindow({required Release? release, required int? currentCode, required bool forced, required bool dismissed}) {
  if (release == null || !release.newerThan(currentCode)) return false;
  return forced || !dismissed;
}
