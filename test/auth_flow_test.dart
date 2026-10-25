import 'package:agent/screens/auth_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('google', () {
    test('button shows only when Google sign-in is on', () {
      expect(AuthRules.googleEnabled('{"external":{"google":true,"email":true}}'), isTrue);
      expect(AuthRules.googleEnabled('{"external":{"google":false}}'), isFalse);
      expect(AuthRules.googleEnabled('not json'), isFalse);
    });
  });

  group('email and code', () {
    test('email shape', () {
      expect(AuthRules.validEmail('ali@example.so'), isTrue);
      expect(AuthRules.validEmail(' ali@example.com '), isTrue);
      expect(AuthRules.validEmail('ali@example'), isFalse);
      expect(AuthRules.validEmail('ali example.com'), isFalse);
      expect(AuthRules.validEmail(''), isFalse);
    });

    test('six-digit code, spaces and dashes ignored', () {
      expect(AuthRules.validCode('482913'), isTrue);
      expect(AuthRules.validCode('482 913'), isTrue);
      expect(AuthRules.validCode('482-91'), isFalse);
      expect(AuthRules.cleanCode('48-29 13'), '482913');
    });
  });

  group('verification gate', () {
    test('unverified email accounts are held back', () {
      expect(AuthRules.needsVerification(emailConfirmedAt: null, provider: 'email'), isTrue);
      expect(AuthRules.needsVerification(emailConfirmedAt: '', provider: null), isTrue);
    });

    test('verified and Google accounts go straight in', () {
      expect(AuthRules.needsVerification(emailConfirmedAt: '2026-10-22T10:00:00Z', provider: 'email'), isFalse);
      expect(AuthRules.needsVerification(emailConfirmedAt: null, provider: 'google'), isFalse);
    });

    test('unconfirmed sign-in error is recognised', () {
      expect(AuthRules.isUnconfirmed('Email not confirmed'), isTrue);
      expect(AuthRules.isUnconfirmed('Invalid login credentials'), isFalse);
    });

    test('a code reset is taken once', () {
      AuthFlow.pendingNewPassword = true;
      expect(AuthFlow.takePendingReset(), isTrue);
      expect(AuthFlow.takePendingReset(), isFalse);
    });
  });

  group('messages', () {
    test('wrong or expired code', () {
      expect(friendlyAuthError('Token has expired or is invalid'), startsWith('That code is wrong'));
    });

    test('unconfirmed email offers a new code', () {
      expect(friendlyAuthError('Email not confirmed'), contains('new code'));
    });
  });

  group('consent', () {
    test('needs 18+ and the current version', () {
      expect(AuthRules.hasConsent(null), isFalse);
      expect(AuthRules.hasConsent({}), isFalse);
      expect(AuthRules.hasConsent({'consent_v': AuthRules.consentVersion}), isFalse);
      expect(AuthRules.hasConsent({'consent_v': AuthRules.consentVersion, 'age_18': true}), isTrue);
      expect(AuthRules.hasConsent({'consent_v': '${AuthRules.consentVersion}', 'age_18': true}), isTrue);
      expect(AuthRules.hasConsent({'consent_v': AuthRules.consentVersion - 1, 'age_18': true}), isFalse);
    });

    test('saved data passes the check', () {
      final d = AuthRules.consentData(now: DateTime.utc(2026, 10, 22));
      expect(AuthRules.hasConsent(d), isTrue);
      expect(d['consent_at'], '2026-10-22T00:00:00.000Z');
    });
  });
}
