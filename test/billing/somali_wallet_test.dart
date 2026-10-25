import 'package:agent/services/billing/somali_wallet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes the ways people type Somali numbers', () {
    for (final s in ['+252 61 234 5678', '252612345678', '00252612345678', '0612345678', '612345678', '+252 0612345678', '61-234-5678']) {
      expect(normalizeSomaliMobile(s), '252612345678', reason: s);
    }
    expect(normalizeSomaliMobile('61234567'), isNull); // 8 digits
    expect(normalizeSomaliMobile('6123456789'), isNull); // 10 digits
    expect(normalizeSomaliMobile('512345678'), isNull); // not a mobile prefix
    expect(normalizeSomaliMobile('+1 415 555 0100'), isNull);
    expect(normalizeSomaliMobile('904123456'), '252904123456'); // Golis
  });

  test('operator prefixes', () {
    expect(walletForNumber('252612345678'), MobileWallet.evc);
    expect(walletForNumber('252771234567'), MobileWallet.evc);
    expect(walletForNumber('252631234567'), MobileWallet.zaad);
    expect(walletForNumber('252901234567'), MobileWallet.sahal);
    for (final p in ['62', '65', '66']) {
      expect(walletForNumber('252${p}1234567'), MobileWallet.edahab, reason: p);
    }
    expect(walletForNumber('252681234567'), isNull);
  });

  test('gateways match billing-checkout (edahab | waafi | pbwallet)', () {
    expect(MobileWallet.all.map((w) => w.gateway).toSet(), {'edahab', 'waafi', 'pbwallet'});
    expect(MobileWallet.evc.gateway, 'waafi');
    expect(MobileWallet.zaad.gateway, 'waafi');
    expect(MobileWallet.sahal.gateway, 'waafi');
  });

  test('check: format errors block, operator mismatch only hints', () {
    expect(checkWalletNumber('', MobileWallet.evc).error, isNotNull);
    expect(checkWalletNumber('61abc', MobileWallet.evc).error, contains('digits'));
    expect(checkWalletNumber('6123', MobileWallet.evc).error, contains('too short'));
    expect(checkWalletNumber('2526123456789', MobileWallet.evc).error, contains('too long'));
    expect(checkWalletNumber('512345678', MobileWallet.evc).error, contains('Somali mobile'));

    final ok = checkWalletNumber('61 234 5678', MobileWallet.evc);
    expect(ok.ok, isTrue);
    expect(ok.normalized, '252612345678');
    expect(ok.hint, isNull);

    // EVC chosen, ZAAD number: same Waafi gateway -> fine.
    expect(checkWalletNumber('631234567', MobileWallet.evc).hint, isNull);

    // EVC chosen, eDahab number: usable, but hint + suggestion.
    final mis = checkWalletNumber('621111111', MobileWallet.evc);
    expect(mis.ok, isTrue);
    expect(mis.hint, contains('eDahab'));
    expect(mis.suggested, MobileWallet.edahab);

    // Premier works on any number.
    expect(checkWalletNumber('621111111', MobileWallet.premier).hint, isNull);
    // Unknown operator prefix: no hint.
    expect(checkWalletNumber('681234567', MobileWallet.edahab).hint, isNull);
  });

  test('display helpers', () {
    expect(formatSomaliMobile('252612345678'), '+252 61 234 5678');
    expect(maskNumber('252612345678'), '****5678');
  });
}
