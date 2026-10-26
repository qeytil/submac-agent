import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent/config.dart';
import 'package:agent/services/update_logic.dart';

// fix/app-updater: snooze, required vs optional, Range resume, why a download stopped, verify before install,
// "What's new" once, and the reported build version.

Release rel({int code = 175, DateTime? requiredAt, String notes = 'Faster answers'}) => Release(
      id: 'r$code',
      versionCode: code,
      versionName: '1.13.105',
      notes: notes,
      parts: const [ReleasePart('android/175/part-00.bin', 41943040), ReleasePart('android/175/part-01.bin', 30641955)],
      sizeBytes: 72584995,
      sha256: 'a' * 64,
      requiredAt: requiredAt,
    );

UpdateMachine machineFor(Release r) => UpdateMachine()..onRelease(r, 174);

void main() {
  final t0 = DateTime.utc(2026, 10, 26, 12);

  group('version compare', () {
    test('numbers, build after +, missing parts are 0', () {
      expect(compareVersions('1.13.104+174', '1.13.103+173'), 1);
      expect(compareVersions('1.13.9', '1.13.10'), -1);
      expect(compareVersions('1.13.104', '1.13.104+0'), 0);
      expect(compareVersions('1.13.104+174', '1.13.104+175'), -1);
      expect(compareVersions('2', '1.99.99+999'), 1);
    });
    test('a release is newer only by its build number', () {
      expect(rel(code: 175).newerThan(174), isTrue);
      expect(rel(code: 174).newerThan(174), isFalse);
      expect(rel().newerThan(null), isFalse);
    });
  });

  group('"Later" snoozes one version for 24 h', () {
    test('the snooze length is one constant (owner decision: zero = every start)', () {
      expect(snoozeLength, const Duration(hours: 24));
    });
    test('Later hides the window for that version until the time passes', () {
      final r = rel();
      final s = snoozeFor(r, t0, forced: false)!;
      expect(s.code, 175);
      expect(s.until, t0.add(snoozeLength));
      bool shows(DateTime now) => shouldShowWindow(release: r, currentCode: 174, forced: false, dismissed: false, snooze: s, now: now);
      expect(shows(t0.add(const Duration(hours: 1))), isFalse);
      expect(shows(t0.add(const Duration(hours: 23, minutes: 59))), isFalse);
      expect(shows(t0.add(snoozeLength)), isTrue);
    });
    test('the snooze survives a restart', () {
      final s = snoozeFor(rel(), t0, forced: false)!;
      final back = Snooze.fromJson(s.toJson())!;
      expect(back.code, s.code);
      expect(back.until, s.until);
      expect(Snooze.fromJson('junk'), isNull);
      expect(Snooze.fromJson({'code': 'x'}), isNull);
    });
    test('a newer version clears the snooze', () {
      final s = snoozeFor(rel(code: 175), t0, forced: false);
      expect(isSnoozed(s, release: rel(code: 176), now: t0, forced: false), isFalse);
      expect(shouldShowWindow(release: rel(code: 176), currentCode: 174, forced: false, dismissed: false, snooze: s, now: t0), isTrue);
    });
    test('Later in this run hides it even without a snooze (snoozeLength zero)', () {
      final s = snoozeFor(rel(), t0, forced: false, length: Duration.zero);
      expect(isSnoozed(s, release: rel(), now: t0, forced: false), isFalse);
      expect(shouldShowWindow(release: rel(), currentCode: 174, forced: false, dismissed: true, snooze: s, now: t0), isFalse);
      // Next start (dismissed cleared): shows again.
      expect(shouldShowWindow(release: rel(), currentCode: 174, forced: false, dismissed: false, snooze: s, now: t0), isTrue);
    });
  });

  group('required vs optional', () {
    test('a required time in the future is optional, a passed one is required', () {
      final r = rel(requiredAt: t0);
      expect(isForced(r.requiredAt, t0.subtract(const Duration(seconds: 1))), isFalse);
      expect(isForced(r.requiredAt, t0), isTrue);
    });
    test('a required update cannot be snoozed', () {
      final r = rel(requiredAt: t0);
      expect(snoozeFor(r, t0, forced: true), isNull);
    });
    test('an old snooze does not hide a required update', () {
      final r = rel(requiredAt: t0);
      final s = snoozeFor(r, t0.subtract(const Duration(hours: 1)), forced: false); // snoozed while still optional
      expect(isSnoozed(s, release: r, now: t0, forced: true), isFalse);
      expect(shouldShowWindow(release: r, currentCode: 174, forced: true, dismissed: true, snooze: s, now: t0), isTrue);
    });
    test('up to date: never shows', () {
      expect(shouldShowWindow(release: rel(), currentCode: 175, forced: true, dismissed: false), isFalse);
    });
  });

  group('resume with HTTP Range', () {
    test('finished parts are kept, a partial part continues from its bytes', () {
      final plan = planResume(expected: [100, 50], have: [100, 20]);
      expect(plan, [const PartPlan(0, 100, done: true), const PartPlan(1, 20)]);
    });
    test('nothing on the phone: every part from 0', () {
      expect(planResume(expected: [100, 50], have: const []), [const PartPlan(0, 0), const PartPlan(1, 0)]);
    });
    test('a part bigger than it should be starts over', () {
      expect(planResume(expected: [100], have: [120]), [const PartPlan(0, 0)]);
    });
    test('unknown size: kept when the downloader marked it finished, else continued', () {
      expect(planResume(expected: [0, 0], have: [80, 30], finished: [true, false]), [const PartPlan(0, 80, done: true), const PartPlan(1, 30)]);
    });
    test('what a ranged answer means', () {
      expect(rangeOutcome(status: 206, offset: 20), RangeOutcome.append);
      expect(rangeOutcome(status: 200, offset: 20), RangeOutcome.restart); // server ignored Range
      expect(rangeOutcome(status: 200, offset: 0), RangeOutcome.fresh);
      expect(rangeOutcome(status: 416, offset: 50, expected: 50), RangeOutcome.complete);
      expect(rangeOutcome(status: 416, offset: 20, expected: 50), RangeOutcome.restart);
      expect(rangeOutcome(status: 503, offset: 20), RangeOutcome.serverError);
      expect(rangeOutcome(status: 404, offset: 0), RangeOutcome.serverError);
    });
    test('a stop or failure keeps the bytes, so Download continues', () {
      final m = machineFor(rel())..start();
      m.onNative('running', bytes: 50000000, total: 72584995);
      expect(m.onNative('failed', bytes: 50000000, reason: 'network').bytes, 50000000);
      expect(m.state.phase, UpdatePhase.cancelled);
      m.start();
      expect(m.state.phase, UpdatePhase.downloading);
      expect(m.state.bytes, 50000000);
      expect(m.cancel().phase, UpdatePhase.cancelled);
      expect(m.state.bytes, 50000000);
    });
  });

  group('why a download stopped', () {
    test('native words', () {
      expect(stopReasonFrom('network'), StopReason.waitingNetwork);
      expect(stopReasonFrom('storage'), StopReason.lowStorage);
      expect(stopReasonFrom('server'), StopReason.server);
      expect(stopReasonFrom('unknown'), StopReason.unknown);
      expect(stopReasonFrom(null), StopReason.none);
      expect(stopReasonFrom('', http: 503), StopReason.server);
    });
    test("Android DownloadManager's reason codes", () {
      expect(stopReasonFrom(null, code: 1), StopReason.waitingNetwork);
      expect(stopReasonFrom(null, code: 2), StopReason.waitingNetwork);
      expect(stopReasonFrom(null, code: 3), StopReason.waitingNetwork);
      expect(stopReasonFrom(null, code: 1006), StopReason.lowStorage);
      expect(stopReasonFrom(null, code: 1007), StopReason.lowStorage);
      expect(stopReasonFrom(null, code: 1002), StopReason.server);
      expect(stopReasonFrom(null, code: 1004), StopReason.server);
      expect(stopReasonFrom(null, code: 500), StopReason.server);
      expect(stopReasonFrom(null, code: 1008), StopReason.unknown);
    });
    test('waiting for the network keeps downloading (it continues by itself)', () {
      final m = machineFor(rel())..start();
      final s = m.onNative('paused', bytes: 10, total: 100, reason: 'network');
      expect(s.phase, UpdatePhase.downloading);
      expect(s.reason, StopReason.waitingNetwork);
      expect(m.onNative('running', bytes: 20, total: 100).reason, StopReason.none);
    });
    test('failed with a reason shows that reason', () {
      final m = machineFor(rel())..start();
      final s = m.onNative('failed', bytes: 10, reason: 'server', http: 503);
      expect(s.issue, UpdateIssue.failed);
      expect(s.reason, StopReason.server);
      expect((machineFor(rel())..start()).onNative('failed').reason, StopReason.unknown);
    });
    test('about 2x the APK must be free; bytes already here count', () {
      expect(bytesNeeded(size: 100), 200);
      expect(bytesNeeded(size: 100, have: 60), 140);
      expect(bytesNeeded(size: 100, have: 300), 0);
      expect(hasRoomFor(size: 100, free: 199), isFalse);
      expect(hasRoomFor(size: 100, free: 200), isTrue);
      expect(hasRoomFor(size: 100, free: 150, have: 60), isTrue);
      expect(hasRoomFor(size: 100, free: -1), isTrue); // unknown never blocks
    });
    test('low storage before starting: stopped with that reason, nothing started', () {
      final m = machineFor(rel());
      final s = m.lowStorage();
      expect(s.phase, UpdatePhase.cancelled);
      expect(s.issue, UpdateIssue.failed);
      expect(s.reason, StopReason.lowStorage);
      expect(m.start().phase, UpdatePhase.downloading); // retry
    });
  });

  group('verify before installing', () {
    Map<String, dynamic> facts({String sha = 'aaaa', List<String>? apk, List<String>? hist, String pkg = 'com.submac.agent', bool unreadable = false}) => {
          'ready': true,
          'sha256': sha,
          'expected_sha256': 'aaaa',
          'package': pkg,
          'app_package': 'com.submac.agent',
          'app_signers': ['4D:6D:11:6E'],
          'apk_signers': apk ?? ['4d6d116e'],
          'apk_history': hist ?? const [],
          'apk_signers_unreadable': unreadable,
        };

    test('same sha256 and same signer: ok', () => expect(verifyVerdict(facts()), VerifyVerdict.ok));
    test('sha256 mismatch is caught first', () {
      expect(verifyVerdict(facts(sha: 'bbbb', apk: ['ffff'])), VerifyVerdict.badHash);
      expect(verifyVerdict(facts(), expectedSha: 'cccc'), VerifyVerdict.badHash);
    });
    test('another signing key is blocked', () {
      expect(verifyVerdict(facts(apk: ['ffff'])), VerifyVerdict.badSignature);
      expect(verifyVerdict(facts(apk: const [])), VerifyVerdict.badSignature);
      expect(verifyVerdict(facts(pkg: 'com.evil.app')), VerifyVerdict.badSignature);
    });
    test('a key rotated from ours is accepted', () {
      expect(verifyVerdict(facts(apk: ['eeee'], hist: ['4d6d116e', 'eeee'])), VerifyVerdict.ok);
    });
    test('signer unreadable on this Android: left to the installer', () {
      expect(verifyVerdict(facts(apk: const [], unreadable: true)), VerifyVerdict.ok);
    });
    test('no file: not ready', () {
      expect(verifyVerdict({'ready': false}), VerifyVerdict.notReady);
      expect(verifyVerdict(null), VerifyVerdict.notReady);
    });
    test('the machine: bad sha256 -> download again, bad signer -> blocked for good', () {
      UpdateMachine ready() => machineFor(rel())
        ..start()
        ..onNative('verifying')
        ..onNative('ready');
      final a = ready()..install();
      expect(a.state.phase, UpdatePhase.verifying);
      expect(a.onVerified(VerifyVerdict.badHash).issue, UpdateIssue.badFile);
      expect(a.start().phase, UpdatePhase.downloading);

      final b = ready()..install();
      final s = b.onVerified(VerifyVerdict.badSignature);
      expect(s.phase, UpdatePhase.cancelled);
      expect(s.issue, UpdateIssue.badSignature);
      expect(b.start().phase, UpdatePhase.cancelled); // the same file would come back: no download button
      expect(b.onNative('running', bytes: 1).issue, UpdateIssue.badSignature);
      expect((ready()..install()).onInstallResult('bad_signer').issue, UpdateIssue.badSignature);
    });
    test('native joins and checks the parts: verifying, then ready', () {
      final m = machineFor(rel())..start();
      expect(m.onNative('verifying', total: 100).phase, UpdatePhase.verifying);
      expect(m.onNative('ready', total: 100).phase, UpdatePhase.downloaded);
    });
  });

  group("What's new once after an update", () {
    test('first start on the new build: show it', () {
      final r = rel(code: 175);
      expect(whatsNewToShow(saved: r, currentCode: 175, lastRunCode: 174, shownCode: null), r);
    });
    test('first start with this feature (no last run) after an in-app update: show it', () {
      expect(whatsNewToShow(saved: rel(code: 175), currentCode: 175, lastRunCode: null, shownCode: null), isNotNull);
    });
    test('shown already, same build again, fresh install or no notes: nothing', () {
      expect(whatsNewToShow(saved: rel(code: 175), currentCode: 175, lastRunCode: 174, shownCode: 175), isNull);
      expect(whatsNewToShow(saved: rel(code: 175), currentCode: 175, lastRunCode: 175, shownCode: null), isNull);
      expect(whatsNewToShow(saved: null, currentCode: 175, lastRunCode: null, shownCode: null), isNull);
      expect(whatsNewToShow(saved: rel(code: 175, notes: '  '), currentCode: 175, lastRunCode: 174, shownCode: null), isNull);
      expect(whatsNewToShow(saved: rel(code: 176), currentCode: 175, lastRunCode: 174, shownCode: null), isNull); // not installed yet
    });
  });

  group('reported build version', () {
    test("Android's versionName wins over the fallback; the +build is dropped", () {
      expect(buildVersionName('1.13.104', '0.0.0'), '1.13.104');
      expect(buildVersionName('1.13.104+174', '0.0.0'), '1.13.104');
      expect(buildVersionName('', '1.13.1'), '1.13.1');
      expect(buildVersionName(null, '1.13.1'), '1.13.1');
    });
    test('AppConfig.version follows the build version once known', () {
      expect(AppConfig.version, AppConfig.pubspecVersion);
      AppConfig.buildVersion = '9.9.9+999';
      expect(AppConfig.version, '9.9.9');
      AppConfig.buildVersion = '';
      expect(AppConfig.version, AppConfig.pubspecVersion);
    });
    test('the fallback is in step with pubspec.yaml', () {
      final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
      final v = line.split(':').last.trim().split('+').first;
      expect(AppConfig.pubspecVersion, v, reason: 'Update AppConfig.pubspecVersion in lib/config.dart with the pubspec version');
    });
  });
}
