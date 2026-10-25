import 'package:flutter/foundation.dart';

import 'billing_copy.dart';

/// Somali mobile-money wallets the app charges directly (no web page). [gateway] is what billing-checkout expects
/// (`wallet: edahab | waafi | pbwallet`): EVC Plus, ZAAD and SAHAL all go through Waafi.
@immutable
class MobileWallet {
  final String id;
  final String label;
  final String gateway;
  final String operator;

  /// First two digits of the 9-digit national number this wallet usually lives on. Empty = any Somali mobile.
  final Set<String> prefixes;
  const MobileWallet(this.id, this.label, this.gateway, this.operator, this.prefixes);

  static const evc = MobileWallet('evc', 'EVC Plus', 'waafi', 'Hormuud', {'61', '77'});
  static const zaad = MobileWallet('zaad', 'ZAAD', 'waafi', 'Telesom', {'63'});
  static const sahal = MobileWallet('sahal', 'SAHAL', 'waafi', 'Golis', {'90'});
  static const edahab = MobileWallet('edahab', 'eDahab', 'edahab', 'Somtel', {'62', '65', '66'});
  static const premier = MobileWallet('premier', 'Premier Wallet', 'pbwallet', 'Premier Bank', {});

  static const all = [evc, zaad, sahal, edahab, premier];

  static MobileWallet? byId(String? id) {
    for (final w in all) {
      if (w.id == id) return w;
    }
    return null;
  }
}

/// The result of checking a wallet number as typed.
@immutable
class WalletNumberCheck {
  /// 2526XXXXXXXX (12 digits) when the number is a valid Somali mobile, else null.
  final String? normalized;

  /// Why it can't be used (shown under the field). null = OK.
  final String? error;

  /// A gentle hint, never blocking: "This looks like an eDahab number".
  final String? hint;

  /// The wallet the number most likely belongs to (null when unknown or already the chosen one).
  final MobileWallet? suggested;
  const WalletNumberCheck({this.normalized, this.error, this.hint, this.suggested});
  bool get ok => normalized != null && error == null;
}

/// Turns what people type (+252 61 234 5678, 0612345678, 612345678, 00252...) into 2526XXXXXXXX.
String? normalizeSomaliMobile(String input) {
  var d = input.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('00')) d = d.substring(2);
  if (d.startsWith('252')) {
    d = d.substring(3);
    if (d.startsWith('0')) d = d.substring(1); // +252 0612...
  } else if (d.startsWith('0')) {
    d = d.substring(1);
  }
  if (d.length != 9) return null;
  // Somali mobiles start with 6, 7 or 9 (Golis 90).
  if (!RegExp(r'^(6[1-9]|7[0-9]|9[0-9])[0-9]{7}$').hasMatch(d)) return null;
  return '252$d';
}

/// The wallet a number's prefix points to (null = no clear match).
MobileWallet? walletForNumber(String normalized) {
  if (normalized.length != 12) return null;
  final p = normalized.substring(3, 5);
  for (final w in MobileWallet.all) {
    if (w.prefixes.contains(p)) return w;
  }
  return null;
}

/// Checks [input] for [wallet]. A format problem blocks; an operator mismatch only hints (prefix lists change, numbers port).
WalletNumberCheck checkWalletNumber(String input, MobileWallet wallet) {
  final raw = input.trim();
  if (raw.isEmpty) return WalletNumberCheck(error: tr('Enter your wallet number.'));
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (RegExp(r'[A-Za-z]').hasMatch(raw)) return WalletNumberCheck(error: tr('Use digits only, like 61 234 5678.'));
  final n = normalizeSomaliMobile(raw);
  if (n == null) {
    final national = digits.startsWith('252') ? digits.substring(3) : digits.startsWith('0') ? digits.substring(1) : digits;
    if (national.length < 9) return WalletNumberCheck(error: tr('This number is too short.'));
    if (national.length > 9) return WalletNumberCheck(error: tr('This number is too long.'));
    return WalletNumberCheck(error: tr("This doesn't look like a Somali mobile number."));
  }
  final likely = walletForNumber(n);
  // Same gateway (EVC / ZAAD / SAHAL are all Waafi) or a wallet that works on any number: fine.
  if (wallet.prefixes.isEmpty || likely == null || likely.gateway == wallet.gateway) {
    return WalletNumberCheck(normalized: n);
  }
  return WalletNumberCheck(
    normalized: n,
    hint: tr('This looks like a {x} number. Make sure it has {y}.', {'x': '${likely.label} (${likely.operator})', 'y': wallet.label}),
    suggested: likely,
  );
}

/// "252 61 234 5678" for display.
String formatSomaliMobile(String normalized) {
  if (normalized.length != 12) return normalized;
  return '+252 ${normalized.substring(3, 5)} ${normalized.substring(5, 8)} ${normalized.substring(8)}';
}

/// "****5678", for logs and lists.
String maskNumber(String n) => n.length <= 4 ? n : '****${n.substring(n.length - 4)}';
