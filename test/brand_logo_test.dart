import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/calm.dart';
import 'package:agent/services/connector_catalog.dart';
import 'package:agent/services/mcp_oauth.dart';
import 'package:agent/widgets/brand_logo.dart';
import 'package:agent/widgets/motion.dart';

void main() {
  group('BrandLogo: real logos for the Apps screen', () {
    test('every logo the widget knows has its file', () {
      for (final id in BrandLogo.tint.keys) {
        expect(File('assets/logos/$id.svg').existsSync(), isTrue, reason: '$id.svg');
      }
      for (final id in BrandLogo.colourMarks) {
        expect(File('assets/logos/$id.svg').existsSync(), isTrue, reason: '$id.svg');
      }
      for (final id in BrandLogo.pictures) {
        expect(File('assets/logos/$id.png').existsSync(), isTrue, reason: '$id.png');
      }
    });

    test('every sign-in app has a logo', () {
      final missing = [for (final pr in McpOAuth.presets) if (!BrandLogo.has(pr.id)) pr.id];
      expect(missing, isEmpty);
    });

    test('every key app has a logo, except plain email', () {
      final missing = [for (final d in ConnectorCatalog.all) if (!BrandLogo.has(d.id) && d.id != 'mail') d.id];
      expect(missing, isEmpty);
    });

    test('a server link finds its app by whole name only', () {
      expect(BrandLogo.idFor('x', url: 'https://mcp.notion.com/mcp'), 'notion');
      expect(BrandLogo.idFor('x', url: 'https://mcp.supermemory.ai/mcp'), 'supermemory');
      expect(BrandLogo.idFor('x', url: 'https://search-mcp.parallel.ai/mcp'), 'parallel');
      expect(BrandLogo.idFor('myserver', url: 'https://example.com/mcp'), 'myserver');
    });

    test('a sign-in app a bot uses maps from its link', () {
      final notion = McpOAuth.presets.firstWhere((p) => p.id == 'notion');
      expect(BrandLogo.idForApp('mcp', notion.url, 'Notion'), 'notion');
      expect(BrandLogo.idForApp('connector', 'github', 'GitHub'), 'github');
    });

    test('pale brand colours are drawn in ink', () {
      expect(BrandLogo.readable(const Color(0xFFFFFFFF)), const Color(0xFF17150F));
      expect(BrandLogo.readable(const Color(0xFF0052CC)), const Color(0xFF0052CC));
    });

    testWidgets('an unknown app falls back to its letter tile', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: BrandLogo('nope', 'Nope'))));
      expect(find.text('N'), findsOneWidget);
    });
  });

  group('Plan 5.5 friendly failures', () {
    test('Calm.short never shows the raw error', () {
      const raw = 'SocketException: Failed host lookup: mcp.notion.com (OS Error: No address associated with hostname, errno = 7)';
      final s = Calm.short(raw, app: 'Notion');
      expect(s, contains('offline'));
      expect(s, isNot(contains('Socket')));
      expect(Calm.short('HTTP 429 Too Many Requests', app: 'Notion'), contains('resting'));
      expect(Calm.short('401 unauthorized', app: 'Notion'), contains('sign in again'));
      expect(Calm.short('TimeoutException after 0:00:25'), contains('slow'));
      expect(Calm.short('weird'), isNot(contains('weird')));
    });
  });

  group('Sign-in stress', () {
    test('cancel with nothing waiting is safe', () {
      expect(McpOAuth.waiting, isFalse);
      McpOAuth.cancel();
      expect(McpOAuth.waiting, isFalse);
    });
  });

  group('Plan 5.5 motion', () {
    testWidgets('a leaving card folds away', (t) async {
      Widget card(bool gone) => MaterialApp(
          home: Scaffold(body: Column(children: [Leaving(gone: gone, child: const SizedBox(height: 80, child: Text('ask')))])));
      await t.pumpWidget(card(false));
      expect(t.getSize(find.byType(Leaving)).height, 80);
      await t.pumpWidget(card(true));
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(Leaving)).height, 0);
    });

    testWidgets('skeleton, tick and empty hint build', (t) async {
      var tapped = false;
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ListView(children: [
        const SkeletonList(rows: 2),
        const DoneTick(),
        EmptyHint(text: 'Nothing yet.', example: 'Try this', onExample: () => tapped = true),
      ]))));
      await t.pump(const Duration(milliseconds: 600));
      await t.tap(find.text('Try this'));
      expect(tapped, isTrue);
    });
  });
}
