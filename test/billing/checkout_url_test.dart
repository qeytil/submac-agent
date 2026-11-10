import 'package:agent/services/billing/checkout_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const host = 'moeemacbvsueekuvfjbo.supabase.co';
  const pid = '11111111-2222-3333-4444-555555555555';
  CheckoutNavDecision d(String u, {bool main = true}) => decideCheckoutNav(Uri.parse(u), functionsHost: host, mainFrame: main);

  test('Sifalo pay hosts and our functions host load in the page', () {
    expect(d('https://pay.sifalo.net/checkout/?key=abc%253D%253D&token=t').kind, CheckoutNavKind.allow);
    expect(d('https://pay.sifalo.com/pay').kind, CheckoutNavKind.allow);
    expect(d('https://$host/functions/v1/something').kind, CheckoutNavKind.allow);
    expect(d('about:blank').kind, CheckoutNavKind.allow);
  });

  test('billing-return URL finishes, keeps the URL for the server, never trusts the status', () {
    final r = d('https://$host/functions/v1/billing-return?provider=sifalo&purchase=$pid&order_id=$pid&sid=SID_123&status=success');
    expect(r.kind, CheckoutNavKind.finish);
    expect(r.purchaseId, pid);
    expect(r.serverReturnUrl.toString(), contains('sid=SID_123'));
    expect(d('https://$host/functions/v1/billing-return/sifalo?order_id=$pid').purchaseId, pid);
    expect(d('https://${host.toUpperCase()}/functions/v1/billing-return?purchase=$pid').kind, CheckoutNavKind.finish);
    // A billing-return look-alike on another host is just an outside link.
    expect(d('https://evil.example/functions/v1/billing-return?purchase=$pid').kind, CheckoutNavKind.external);
    // In a frame it is blocked (only the whole page can finish).
    expect(d('https://$host/functions/v1/billing-return?purchase=$pid', main: false).kind, CheckoutNavKind.block);
  });

  test('telesia://pay finishes; other telesia links are blocked', () {
    final r = d('telesia://pay?status=paid&purchase=$pid&reason=x');
    expect(r.kind, CheckoutNavKind.finish);
    expect(r.purchaseId, pid);
    expect(r.status, 'paid');
    expect(r.serverReturnUrl, isNull);
    expect(d('telesia://pay?status=failed&purchase=not-a-uuid').purchaseId, isNull);
    expect(d('telesia://hire?bot=abc').kind, CheckoutNavKind.block);
  });

  test('everything else opens outside the app', () {
    expect(d('https://www.google.com/').kind, CheckoutNavKind.external);
    expect(d('https://sifalo.net/terms').kind, CheckoutNavKind.external); // not the pay host
    expect(d('https://pay.sifalo.net.evil.com/').kind, CheckoutNavKind.external);
    expect(d('http://example.com/').kind, CheckoutNavKind.external);
    expect(d('tel:+252612345678').kind, CheckoutNavKind.external);
    expect(d('mailto:help@sifalo.net').kind, CheckoutNavKind.external);
  });

  test('dangerous or plain-text payment pages are blocked', () {
    expect(d('http://pay.sifalo.net/checkout').kind, CheckoutNavKind.block);
    expect(d('javascript:alert(1)').kind, CheckoutNavKind.block);
    expect(d('file:///etc/passwd').kind, CheckoutNavKind.block);
    expect(d('data:text/html,hi').kind, CheckoutNavKind.block);
  });

  test('frames (3-D Secure) may load https pages and data/blob, never leave the app', () {
    expect(d('https://acs.bank.example/challenge', main: false).kind, CheckoutNavKind.allow);
    expect(d('blob:https://pay.sifalo.net/x', main: false).kind, CheckoutNavKind.allow);
    expect(d('tel:123', main: false).kind, CheckoutNavKind.block);
    expect(d('http://x.example/', main: false).kind, CheckoutNavKind.block);
  });

  test('deep link parser', () {
    expect(parsePayDeepLink(Uri.parse('telesia://pay?purchase=$pid&status=pending'))!.purchaseId, pid);
    expect(parsePayDeepLink(Uri.parse('telesia://invite?ref=X')), isNull);
    expect(isBillingReturnPath('/functions/v1/billing-return'), isTrue);
    expect(isBillingReturnPath('/functions/v1/billing-returned'), isFalse);
  });
}
