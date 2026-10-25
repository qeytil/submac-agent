import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/update_logic.dart';

Release rel({int code = 84, DateTime? requiredAt, DateTime? serverNow, String name = '1.13.51'}) => Release(
      id: 'r$code',
      versionCode: code,
      versionName: name,
      notes: 'Faster answers',
      parts: const [ReleasePart('android/84-abc/part-00.bin', 41943040), ReleasePart('android/84-abc/part-01.bin', 23550273)],
      sizeBytes: 65493313,
      sha256: '00f594e4cbe2c8c192b000cda730fb325daec59e42681ce090be6ee16e521396',
      requiredAt: requiredAt,
      serverNow: serverNow,
    );

void main() {
  group('version compare', () {
    test('numbers, not text', () {
      expect(compareVersions('1.13.50', '1.13.51'), -1);
      expect(compareVersions('1.13.100', '1.13.99'), 1);
      expect(compareVersions('1.14.0', '1.13.99'), 1);
      expect(compareVersions('1.13.50', '1.13.50'), 0);
      expect(compareVersions('2.0', '2.0.0'), 0);
    });
    test('build number after +', () {
      expect(compareVersions('1.13.50+83', '1.13.50+84'), -1);
      expect(compareVersions('1.13.51+84', '1.13.50+90'), 1);
      expect(compareVersions('1.13.50+83', '1.13.50'), 1);
    });
    test('newerThan uses the build number', () {
      expect(rel(code: 84).newerThan(83), isTrue);
      expect(rel(code: 84).newerThan(84), isFalse);
      expect(rel(code: 84).newerThan(90), isFalse);
      expect(rel(code: 84).newerThan(null), isFalse);
    });
  });

  group('forced vs optional by time', () {
    final t = DateTime.utc(2026, 10, 21, 12);
    test('never required', () => expect(isForced(null, t), isFalse));
    test('required in the future', () => expect(isForced(t.add(const Duration(minutes: 1)), t), isFalse));
    test('required now or in the past', () {
      expect(isForced(t, t), isTrue);
      expect(isForced(t.subtract(const Duration(days: 1)), t), isTrue);
    });
    test('server clock wins over a phone clock set back', () {
      final server = DateTime.utc(2026, 10, 21, 12);
      final fetched = DateTime.utc(2020, 1, 1); // phone thinks it is 2020
      final now = effectiveNow(serverNow: server, fetchedAt: fetched, deviceNow: fetched.add(const Duration(hours: 2)));
      expect(now, server.add(const Duration(hours: 2)));
      expect(isForced(server.add(const Duration(hours: 1)), now), isTrue);
    });
    test('time never runs backwards from the server', () {
      final server = DateTime.utc(2026, 10, 21, 12);
      final fetched = DateTime.utc(2026, 10, 21, 12);
      expect(effectiveNow(serverNow: server, fetchedAt: fetched, deviceNow: fetched.subtract(const Duration(days: 3))), server);
    });
    test('no server time: the phone clock', () {
      final d = DateTime.utc(2026, 1, 1);
      expect(effectiveNow(deviceNow: d), d);
    });
  });

  group('release from the server', () {
    test('parses latest_release', () {
      final r = Release.fromRpc({
        'update': true,
        'id': 'x',
        'version_code': 84,
        'version_name': '1.13.51',
        'notes': 'New',
        'bucket': 'app-updates',
        'parts': [
          {'path': 'android/84-a/part-00.bin', 'size': 10},
          {'path': 'android/84-a/part-01.bin', 'size': 5},
        ],
        'size_bytes': 15,
        'sha256': 'A' * 64,
        'required_at': '2026-10-25T10:00:00+00:00',
        'server_now': '2026-10-20T18:00:00Z',
      })!;
      expect(r.versionCode, 84);
      expect(r.sha256, 'a' * 64);
      expect(r.requiredAt, DateTime.utc(2026, 10, 25, 10));
      expect(r.urls('https://x.supabase.co/'), [
        'https://x.supabase.co/storage/v1/object/public/app-updates/android/84-a/part-00.bin',
        'https://x.supabase.co/storage/v1/object/public/app-updates/android/84-a/part-01.bin',
      ]);
      expect(Release.fromRpc(r.toJson())!.toJson(), r.toJson());
    });
    test('an R2 release downloads one file', () {
      final r = Release.fromRpc({
        'update': true,
        'id': 'r',
        'version_code': 85,
        'version_name': '1.13.52',
        'storage': 'r2',
        'file_url': 'https://pub-x.r2.dev/android/85-0a1b2c3d/SubMac-85.apk',
        'apk_path': 'android/85-0a1b2c3d/SubMac-85.apk',
        'parts': [],
        'size_bytes': 125829120,
        'sha256': 'b' * 64,
      })!;
      expect(r.storage, 'r2');
      expect(r.singleFile, isTrue);
      expect(r.sizeBytes, 125829120);
      expect(r.urls('https://x.supabase.co'), ['https://pub-x.r2.dev/android/85-0a1b2c3d/SubMac-85.apk']);
      final again = Release.fromRpc(r.toJson())!;
      expect(again.toJson(), r.toJson());
      expect(again.singleFile, isTrue);
    });
    test('an R2 release without a usable address is ignored', () {
      final base = {'update': true, 'version_code': 85, 'version_name': '1.13.52', 'storage': 'r2', 'sha256': 'c' * 64, 'parts': []};
      expect(Release.fromRpc(base), isNull);
      expect(Release.fromRpc({...base, 'file_url': 'http://insecure.example/a.apk'}), isNull);
    });
    test('old rows without storage still use the parts', () {
      final r = Release.fromRpc({
        'update': true,
        'version_code': 84,
        'version_name': '1.13.51',
        'parts': [
          {'path': 'android/84-a/part-00.bin', 'size': 10},
        ],
        'file_url': 'https://pub-x.r2.dev/ignored.apk',
        'sha256': 'd' * 64,
      })!;
      expect(r.storage, 'supabase');
      expect(r.singleFile, isFalse);
      expect(r.fileUrl, isNull);
      expect(r.urls('https://x.supabase.co'), ['https://x.supabase.co/storage/v1/object/public/app-updates/android/84-a/part-00.bin']);
    });
    test('no update or a broken answer is null', () {
      expect(Release.fromRpc({'update': false}), isNull);
      expect(Release.fromRpc(null), isNull);
      expect(Release.fromRpc({'update': true, 'version_code': 84, 'sha256': 'bad', 'parts': []}), isNull);
    });
  });

  group('state machine', () {
    UpdateMachine fresh() {
      final m = UpdateMachine();
      m.onRelease(rel(), 83);
      return m;
    }

    test('idle -> downloading -> downloaded -> installing', () {
      final m = fresh();
      expect(m.state.phase, UpdatePhase.idle);
      expect(m.start().phase, UpdatePhase.downloading);
      expect(m.onNative('running', bytes: 10, total: 100).progress, closeTo(0.1, 1e-9));
      expect(m.onNative('ready').phase, UpdatePhase.downloaded);
      expect(m.install().phase, UpdatePhase.installing);
      expect(m.onInstallResult('started').phase, UpdatePhase.installing);
    });
    test('cancel brings the window back to Download', () {
      final m = fresh()..start();
      expect(m.cancel().phase, UpdatePhase.cancelled);
      expect(m.start().phase, UpdatePhase.downloading); // can download again any time
    });
    test('a failed or removed download becomes cancelled with a reason', () {
      final m = fresh()..start();
      expect(m.onNative('failed').phase, UpdatePhase.cancelled);
      expect(m.state.issue, UpdateIssue.failed);
      m.start();
      expect(m.onNative('none').phase, UpdatePhase.cancelled);
    });
    test('a file that does not match its check is thrown away', () {
      final m = fresh()..start();
      expect(m.onNative('bad').phase, UpdatePhase.cancelled);
      expect(m.state.issue, UpdateIssue.badFile);
    });
    test('downloaded on a fresh start offers Install without downloading again', () {
      final m = fresh(); // state lost, but the file is already on the phone
      expect(m.onNative('ready').phase, UpdatePhase.downloaded);
    });
    test('installer closed without updating -> Install again', () {
      final m = fresh()
        ..start()
        ..onNative('ready')
        ..install();
      expect(m.onResumed().phase, UpdatePhase.downloaded);
    });
    test('install needs the "Install unknown apps" switch', () {
      final m = fresh()
        ..start()
        ..onNative('ready')
        ..install();
      final s = m.onInstallResult('needs_permission');
      expect(s.phase, UpdatePhase.downloaded);
      expect(s.issue, UpdateIssue.needsPermission);
      expect(m.onNative('ready').issue, UpdateIssue.needsPermission);
    });
    test('illegal moves keep the state', () {
      final m = fresh();
      expect(m.install().phase, UpdatePhase.idle);
      expect(m.cancel().phase, UpdatePhase.idle);
      m.start();
      expect(m.start().phase, UpdatePhase.downloading);
      expect(UpdateMachine().start().phase, UpdatePhase.idle); // no release
    });
    test('updated, unpublished or a newer release resets and asks to remove files', () {
      final m = fresh()
        ..start()
        ..onNative('ready');
      expect(m.onRelease(rel(code: 85), 83), isTrue);
      expect(m.state.phase, UpdatePhase.idle);
      expect(m.state.releaseCode, 85);
      m.start();
      expect(m.onRelease(rel(code: 85), 85), isTrue); // now on 85
      expect(m.state.releaseCode, 0);
      expect(m.onRelease(null, 85), isFalse);
    });
    test('state survives a restart', () {
      final m = fresh()
        ..start()
        ..onNative('running', bytes: 5, total: 10);
      final back = UpdateState.fromJson(m.state.toJson());
      expect(back.phase, UpdatePhase.downloading);
      expect(back.releaseCode, 84);
      expect(back.bytes, 5);
      expect(UpdateState.fromJson('junk').phase, UpdatePhase.idle);
    });
  });

  group('when the window shows', () {
    test('pending optional: shows until Later in this run', () {
      expect(shouldShowWindow(release: rel(), currentCode: 83, forced: false, dismissed: false), isTrue);
      expect(shouldShowWindow(release: rel(), currentCode: 83, forced: false, dismissed: true), isFalse);
    });
    test('required: always shows', () {
      expect(shouldShowWindow(release: rel(), currentCode: 83, forced: true, dismissed: true), isTrue);
    });
    test('up to date or no release: never', () {
      expect(shouldShowWindow(release: rel(), currentCode: 84, forced: true, dismissed: false), isFalse);
      expect(shouldShowWindow(release: null, currentCode: 83, forced: false, dismissed: false), isFalse);
    });
  });
}
