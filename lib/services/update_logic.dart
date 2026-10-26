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

/// What the update window is doing. [verifying] = the file is being joined and checked (sha256, then the signing
/// certificate right before the installer opens).
enum UpdatePhase { idle, downloading, cancelled, downloaded, verifying, installing }

/// Why the last step did not go through (shown as one plain line). [badSignature] blocks the install for good: the
/// file is not signed with SubMac's key, so downloading it again would not help.
enum UpdateIssue { none, failed, badFile, needsPermission, badSignature }

/// Why a download stopped or waits, from the native downloader (or Android's DownloadManager codes).
enum StopReason { none, waitingNetwork, lowStorage, server, unknown }

/// Maps what the native side reports to a [StopReason].
/// [reason] is the native downloader's word ('network' | 'storage' | 'server' | 'unknown'); [code] is a numeric
/// DownloadManager COLUMN_REASON (PAUSED_* 1-4, ERROR_* 1000-1009, or an HTTP status) for downloads Android ran.
StopReason stopReasonFrom(dynamic reason, {int code = 0, int http = 0}) {
  switch ('${reason ?? ''}') {
    case 'network':
      return StopReason.waitingNetwork;
    case 'storage':
      return StopReason.lowStorage;
    case 'server':
      return StopReason.server;
    case 'unknown':
      return StopReason.unknown;
  }
  if (http >= 400) return StopReason.server;
  switch (code) {
    case 0:
      return StopReason.none;
    case 1: // PAUSED_WAITING_TO_RETRY
    case 2: // PAUSED_WAITING_FOR_NETWORK
    case 3: // PAUSED_QUEUED_FOR_WIFI
      return StopReason.waitingNetwork;
    case 1006: // ERROR_INSUFFICIENT_SPACE
    case 1007: // ERROR_DEVICE_NOT_FOUND (no external storage)
      return StopReason.lowStorage;
    case 1002: // ERROR_UNHANDLED_HTTP_CODE
    case 1004: // ERROR_HTTP_DATA_ERROR
    case 1005: // ERROR_TOO_MANY_REDIRECTS
      return StopReason.server;
  }
  if (code >= 400 && code <= 599) return StopReason.server;
  return StopReason.unknown;
}

// ---------------- storage ----------------

/// Bytes that must be free before a download starts: about twice the APK, because the parts and the joined file
/// sit side by side while joining. Bytes already on the phone (finished or partial parts) count as paid.
int bytesNeeded({required int size, int have = 0}) {
  final need = 2 * size - have;
  return need < 0 ? 0 : need;
}

/// True when [free] bytes are enough to start (or resume). Unknown free space (< 0) never blocks.
bool hasRoomFor({required int size, required int free, int have = 0}) => free < 0 || free >= bytesNeeded(size: size, have: have);

// ---------------- resume (HTTP Range per part) ----------------

/// Where one part starts when the download (re)starts: [done] parts are kept and skipped; otherwise the request
/// asks for `Range: bytes=<offset>-` (offset 0 = a normal request).
class PartPlan {
  final int index;
  final int offset;
  final bool done;
  const PartPlan(this.index, this.offset, {this.done = false});
  @override
  bool operator ==(Object o) => o is PartPlan && o.index == index && o.offset == offset && o.done == done;
  @override
  int get hashCode => Object.hash(index, offset, done);
  @override
  String toString() => 'PartPlan($index, $offset${done ? ', done' : ''})';
}

/// [expected] = each part's size from the release (0 = unknown); [have] = bytes of that part already on the phone;
/// [finished] = parts the downloader marked complete (needed when the size is unknown).
List<PartPlan> planResume({required List<int> expected, required List<int> have, List<bool> finished = const []}) {
  return [
    for (var i = 0; i < expected.length; i++)
      () {
        final want = expected[i];
        final got = i < have.length && have[i] > 0 ? have[i] : 0;
        final fin = i < finished.length && finished[i];
        if (want > 0 && got > want) return PartPlan(i, 0); // bigger than it should be: start that part over
        if (want > 0 && got == want) return PartPlan(i, got, done: true);
        if (want <= 0 && fin && got > 0) return PartPlan(i, got, done: true);
        return PartPlan(i, got);
      }(),
  ];
}

/// What to do with the answer to a (possibly ranged) request for one part.
enum RangeOutcome { append, restart, fresh, complete, serverError }

/// 206 to a ranged request appends; 200 means the server ignored Range, so the part starts over (the bytes on the
/// phone are dropped); 416 with the whole part already here is complete; other errors are the server's.
RangeOutcome rangeOutcome({required int status, required int offset, int expected = 0}) {
  if (status == 206 && offset > 0) return RangeOutcome.append;
  if (status == 200) return offset > 0 ? RangeOutcome.restart : RangeOutcome.fresh;
  if (status == 416 && offset > 0) return (expected <= 0 || offset == expected) ? RangeOutcome.complete : RangeOutcome.restart;
  return RangeOutcome.serverError;
}

// ---------------- verify before installing ----------------

/// The installed app's signing certificate digests must match the downloaded APK's: the same current signers, or the
/// APK's rotation history contains every signer the app has now (a key rotated from ours).
bool signersMatch({required List<String> app, required List<String> apk, List<String> apkHistory = const []}) {
  String n(String s) => s.toLowerCase().replaceAll(':', '').trim();
  final a = app.map(n).where((s) => s.isNotEmpty).toSet();
  final b = apk.map(n).where((s) => s.isNotEmpty).toSet();
  if (a.isEmpty || b.isEmpty) return false;
  if (a.length == b.length && a.containsAll(b)) return true;
  final h = apkHistory.map(n).toSet();
  return h.containsAll(a) && h.containsAll(b);
}

enum VerifyVerdict { ok, notReady, badHash, badSignature }

/// What the native `verify` call found, turned into one verdict: sha256 first, then package and signer.
VerifyVerdict verifyVerdict(dynamic facts, {String? expectedSha}) {
  if (facts is! Map || facts['ready'] != true) return VerifyVerdict.notReady;
  final got = '${facts['sha256'] ?? ''}'.toLowerCase();
  final want = (expectedSha ?? '${facts['expected_sha256'] ?? ''}').toLowerCase();
  if (got.isEmpty || want.isEmpty || got != want) return VerifyVerdict.badHash;
  if (facts['package'] != facts['app_package'] || facts['package'] == null) return VerifyVerdict.badSignature;
  List<String> l(dynamic v) => v is List ? [for (final x in v) '$x'] : const [];
  // Android could parse the file as our package but not read its signer here: its installer still refuses a
  // different key, so this is not treated as a mismatch.
  if (facts['apk_signers_unreadable'] == true && l(facts['apk_signers']).isEmpty && l(facts['app_signers']).isNotEmpty) return VerifyVerdict.ok;
  final ok = signersMatch(app: l(facts['app_signers']), apk: l(facts['apk_signers']), apkHistory: l(facts['apk_history']));
  return ok ? VerifyVerdict.ok : VerifyVerdict.badSignature;
}

// ---------------- "Later" ----------------

/// How long "Later" hides the window for one version. Owner decision point: the owner once asked for the window on
/// every start; set this to Duration.zero for that (Later then only hides it until SubMac is opened again).
const Duration snoozeLength = Duration(hours: 24);

/// "Later" for one version, until a time. A newer version is not covered.
class Snooze {
  final int code;
  final DateTime until;
  const Snooze(this.code, this.until);
  Map<String, dynamic> toJson() => {'code': code, 'until': until.toUtc().toIso8601String()};
  static Snooze? fromJson(dynamic j) {
    if (j is! Map) return null;
    final c = j['code'] is num ? (j['code'] as num).toInt() : null;
    final u = DateTime.tryParse('${j['until']}');
    return c == null || u == null ? null : Snooze(c, u.toUtc());
  }
}

/// The snooze "Later" leaves for [release] at [now]; null when it cannot be snoozed (required).
Snooze? snoozeFor(Release release, DateTime now, {required bool forced, Duration length = snoozeLength}) =>
    forced ? null : Snooze(release.versionCode, now.toUtc().add(length));

/// Still snoozed: same version, not required, and the time has not passed.
bool isSnoozed(Snooze? s, {required Release? release, required DateTime now, required bool forced}) {
  if (s == null || release == null || forced) return false;
  if (s.code != release.versionCode) return false; // a newer version clears the snooze
  return now.toUtc().isBefore(s.until);
}

// ---------------- "What's new" after an update ----------------

/// The release whose notes to show once on the first start after updating to it: the saved release is the version
/// now running, the previous start ran an older build (or is unknown: the first start with this feature, which an
/// in-app update to it implies), and that version was not shown yet. A fresh install has no saved release.
Release? whatsNewToShow({required Release? saved, required int? currentCode, required int? lastRunCode, required int? shownCode}) {
  if (saved == null || currentCode == null) return null;
  if (lastRunCode != null && currentCode <= lastRunCode) return null;
  if (saved.versionCode != currentCode) return null;
  if (shownCode != null && shownCode >= currentCode) return null;
  if (saved.notes.trim().isEmpty) return null;
  return saved;
}

class UpdateState {
  final UpdatePhase phase;
  final int releaseCode; // 0 = no release
  final int bytes;
  final int total;
  final UpdateIssue issue;

  /// Why the download waits ([UpdatePhase.downloading]) or stopped ([UpdatePhase.cancelled] with [UpdateIssue.failed]).
  final StopReason reason;

  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.releaseCode = 0,
    this.bytes = 0,
    this.total = 0,
    this.issue = UpdateIssue.none,
    this.reason = StopReason.none,
  });

  double? get progress => total > 0 ? (bytes / total).clamp(0.0, 1.0) : null;

  /// Whole percent for the progress line (never 100 before the file is checked).
  int? get percent => progress == null ? null : (progress! * 100).floor().clamp(0, phase == UpdatePhase.downloading ? 99 : 100);

  UpdateState copyWith({UpdatePhase? phase, int? releaseCode, int? bytes, int? total, UpdateIssue? issue, StopReason? reason}) => UpdateState(
        phase: phase ?? this.phase,
        releaseCode: releaseCode ?? this.releaseCode,
        bytes: bytes ?? this.bytes,
        total: total ?? this.total,
        issue: issue ?? this.issue,
        reason: reason ?? this.reason,
      );

  Map<String, dynamic> toJson() =>
      {'phase': phase.name, 'code': releaseCode, 'bytes': bytes, 'total': total, 'issue': issue.name, 'reason': reason.name};

  static UpdateState fromJson(dynamic j) {
    if (j is! Map) return const UpdateState();
    T pick<T extends Enum>(List<T> all, dynamic v, T d) => all.firstWhere((e) => e.name == v, orElse: () => d);
    return UpdateState(
      phase: pick(UpdatePhase.values, j['phase'], UpdatePhase.idle),
      releaseCode: j['code'] is num ? (j['code'] as num).toInt() : 0,
      bytes: j['bytes'] is num ? (j['bytes'] as num).toInt() : 0,
      total: j['total'] is num ? (j['total'] as num).toInt() : 0,
      issue: pick(UpdateIssue.values, j['issue'], UpdateIssue.none),
      reason: pick(StopReason.values, j['reason'], StopReason.none),
    );
  }
}

/// The download state machine: idle -> downloading -> verifying -> downloaded -> verifying -> installing, with
/// cancelled as the way back. Bytes already on the phone are kept across a stop or failure (the next start resumes).
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
      final hadFiles = state.releaseCode != 0 && (state.phase != UpdatePhase.idle || state.bytes > 0);
      state = UpdateState(releaseCode: r.versionCode, total: r.sizeBytes);
      return hadFiles;
    }
    return false;
  }

  UpdateState start() {
    if (state.releaseCode == 0) return state;
    if (state.issue == UpdateIssue.badSignature) return state; // blocked: the same file would come back
    if (state.phase == UpdatePhase.idle || state.phase == UpdatePhase.cancelled) {
      state = state.copyWith(phase: UpdatePhase.downloading, issue: UpdateIssue.none, reason: StopReason.none);
    }
    return state;
  }

  /// The free-space check before starting failed: nothing was started.
  UpdateState lowStorage() {
    if (state.releaseCode == 0) return state;
    if (state.phase == UpdatePhase.idle || state.phase == UpdatePhase.cancelled || state.phase == UpdatePhase.downloading) {
      state = state.copyWith(phase: UpdatePhase.cancelled, issue: UpdateIssue.failed, reason: StopReason.lowStorage);
    }
    return state;
  }

  /// Cancel: stops the download. What arrived stays on the phone, so Download continues from there.
  UpdateState cancel() {
    if (state.phase == UpdatePhase.downloading) state = state.copyWith(phase: UpdatePhase.cancelled, issue: UpdateIssue.none, reason: StopReason.none);
    return state;
  }

  /// What the native downloader reports: none | running | paused | stopped | failed | verifying | bad | ready.
  /// [reason]/[code]/[http] say why it waits or stopped (see [stopReasonFrom]).
  UpdateState onNative(String native, {int bytes = 0, int total = 0, dynamic reason, int code = 0, int http = 0}) {
    if (state.releaseCode == 0) return state;
    final t = total > 0 ? total : state.total;
    final active = state.phase == UpdatePhase.idle || state.phase == UpdatePhase.downloading || state.phase == UpdatePhase.cancelled;
    switch (native) {
      case 'running':
        if (active && state.issue != UpdateIssue.badSignature) {
          state = state.copyWith(phase: UpdatePhase.downloading, bytes: bytes, total: t, issue: UpdateIssue.none, reason: StopReason.none);
        }
      case 'paused':
        // Waiting (usually for the network); the downloader goes on by itself when it can.
        if (active && state.issue != UpdateIssue.badSignature) {
          final r = stopReasonFrom(reason, code: code, http: http);
          state = state.copyWith(
              phase: UpdatePhase.downloading, bytes: bytes, total: t, issue: UpdateIssue.none, reason: r == StopReason.none ? StopReason.waitingNetwork : r);
        }
      case 'stopped':
        if (state.phase == UpdatePhase.downloading) state = state.copyWith(phase: UpdatePhase.cancelled, bytes: bytes, issue: UpdateIssue.none, reason: StopReason.none);
      case 'verifying':
        if (active || state.phase == UpdatePhase.verifying) {
          state = state.copyWith(phase: UpdatePhase.verifying, bytes: t, total: t, issue: UpdateIssue.none, reason: StopReason.none);
        }
      case 'ready':
        if (state.phase != UpdatePhase.installing && state.issue != UpdateIssue.badSignature) {
          state = state.copyWith(
              phase: UpdatePhase.downloaded,
              bytes: t,
              total: t,
              issue: state.issue == UpdateIssue.needsPermission ? state.issue : UpdateIssue.none,
              reason: StopReason.none);
        }
      case 'failed':
        if (state.phase == UpdatePhase.downloading || state.phase == UpdatePhase.verifying) {
          final r = stopReasonFrom(reason, code: code, http: http);
          state = state.copyWith(
              phase: UpdatePhase.cancelled, bytes: bytes, issue: UpdateIssue.failed, reason: r == StopReason.none ? StopReason.unknown : r);
        }
      case 'bad':
        state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.badFile, reason: StopReason.none);
      case 'none':
        // The files are gone (removed, or never started).
        if (state.phase == UpdatePhase.downloading || state.phase == UpdatePhase.verifying) {
          state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.failed, reason: StopReason.unknown);
        } else if (state.phase == UpdatePhase.downloaded || state.phase == UpdatePhase.installing) {
          state = state.copyWith(phase: UpdatePhase.idle, bytes: 0, issue: UpdateIssue.none, reason: StopReason.none);
        }
    }
    return state;
  }

  /// Install tapped: the file is checked again (sha256, signer) before the installer opens.
  UpdateState install() {
    if (state.phase == UpdatePhase.downloaded) state = state.copyWith(phase: UpdatePhase.verifying, issue: UpdateIssue.none);
    return state;
  }

  /// The check before installing: ok opens the installer; a wrong sha256 throws the file away (download again);
  /// a wrong signer blocks.
  UpdateState onVerified(VerifyVerdict v) {
    if (state.phase != UpdatePhase.verifying) return state;
    switch (v) {
      case VerifyVerdict.ok:
        state = state.copyWith(phase: UpdatePhase.installing);
      case VerifyVerdict.badHash:
        state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.badFile);
      case VerifyVerdict.badSignature:
        state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.badSignature);
      case VerifyVerdict.notReady:
        state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.failed, reason: StopReason.unknown);
    }
    return state;
  }

  /// What opening the installer returned: started | needs_permission | bad | bad_signer | not_ready.
  UpdateState onInstallResult(String r) {
    if (state.phase != UpdatePhase.installing && state.phase != UpdatePhase.verifying) return state;
    if (r == 'started') {
      state = state.copyWith(phase: UpdatePhase.installing);
    } else if (r == 'needs_permission') {
      state = state.copyWith(phase: UpdatePhase.downloaded, issue: UpdateIssue.needsPermission);
    } else if (r == 'bad') {
      state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.badFile);
    } else if (r == 'bad_signer') {
      state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.badSignature);
    } else {
      state = state.copyWith(phase: UpdatePhase.cancelled, bytes: 0, issue: UpdateIssue.failed, reason: StopReason.unknown);
    }
    return state;
  }

  /// Back in SubMac with the old version still running: the installer was closed, so Install is offered again.
  UpdateState onResumed() {
    if (state.phase == UpdatePhase.installing) state = state.copyWith(phase: UpdatePhase.downloaded);
    return state;
  }
}

/// The window shows while a newer release is pending, unless the user tapped Later in this run of the app or that
/// version is snoozed. A required update always shows (and cannot be dismissed or snoozed).
bool shouldShowWindow({
  required Release? release,
  required int? currentCode,
  required bool forced,
  required bool dismissed,
  Snooze? snooze,
  DateTime? now,
}) {
  if (release == null || !release.newerThan(currentCode)) return false;
  if (forced) return true;
  if (dismissed) return false;
  return !isSnoozed(snooze, release: release, now: now ?? DateTime.now().toUtc(), forced: forced);
}

/// The version string to report (touch_device, Settings, mails): the real build's name from Android, else [fallback].
String buildVersionName(dynamic native, String fallback) {
  final n = native is String ? native.trim() : '';
  return n.isNotEmpty ? n.split('+').first : fallback;
}
