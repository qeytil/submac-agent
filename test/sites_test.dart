import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/sites.dart';

void main() {
  test('free link status counts days and ends', () {
    final s = Site(id: 'sabc123', title: 'Cafe Amal', entryPath: '/w/pages/page_1.html');
    expect(s.statusLine, 'Not online yet');
    s
      ..host = SiteHost.free
      ..url = 'https://cafe-amal-x7k2.submac-sites.pages.dev'
      ..expiresAt = DateTime.now().add(const Duration(days: 6, hours: 2));
    expect(s.isLive, true);
    expect(s.statusLine, 'Free link · 7 days left');
    s.expiresAt = DateTime.now().add(const Duration(hours: 3));
    expect(s.statusLine, 'Free link · ends today');
    s.expiresAt = DateTime.now().subtract(const Duration(minutes: 1));
    expect(s.isExpired, true);
    expect(s.isLive, false);
    expect(s.statusLine.startsWith('Free link ended'), true);
  });

  test('vercel sites never expire', () {
    final s = Site(id: 's1', title: 'Shop', entryPath: '/x.html', host: SiteHost.vercel, url: 'https://shop-ab12.vercel.app');
    expect(s.isLive, true);
    expect(s.statusLine, 'On your Vercel');
  });

  test('vercel project name is safe and stable', () {
    final s = Site(id: 'slkq9z81', title: 'Amina\'s Bakery & Café!', entryPath: '/x.html');
    final n = Sites.projectName(s);
    expect(RegExp(r'^[a-z0-9-]+$').hasMatch(n), true);
    expect(n, Sites.projectName(s));
    expect(n.startsWith('amina-s-bakery-caf'), true);
    expect(Sites.projectName(Site(id: 's2', title: '!!!', entryPath: '/y.html')).startsWith('my-site-'), true);
  });

  test('picks the clean vercel address', () {
    const res = '{"url":"shop-ab12-k3j4h5g6f-team.vercel.app","alias":["shop-ab12.vercel.app"]}';
    expect(Sites.bestVercelUrl(res, 'shop-ab12'), 'https://shop-ab12.vercel.app');
    expect(Sites.bestVercelUrl('no address here', 'x'), null);
  });

  test('site survives a save round trip', () {
    final s = Site(id: 's9', title: 'T', entryPath: '/p.html', host: SiteHost.free, url: 'https://t.submac-sites.pages.dev', publishCount: 2);
    final back = Site.fromJson(s.toJson());
    expect(back.url, s.url);
    expect(back.publishCount, 2);
    expect(back.host, SiteHost.free);
  });
}
