// Visuals from the opencode chat (owner 2026-11-04: "there is no visual like image or video or graphics output
// ability, why?"). opencode makes visuals its own way (a written .svg/.html, a script's .png, `![x](path)`, a file
// named in its answer); the chat turns them into the cards it already draws, and generate_image is offered by name
// while the server can make pictures.
import 'dart:convert';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/services/mcp_routes.dart';
import 'package:agent/services/telesia_gateway.dart';
import 'package:agent/services/telesia_mcp.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/services/turn_visuals.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/markdown_view.dart';
import 'package:agent/widgets/visual_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 60"><rect width="100" height="60" fill="#f4f0e7"/></svg>';

Map<String, dynamic> fn(String n) => {
      'type': 'function',
      'function': {'name': n, 'description': n, 'parameters': {'type': 'object', 'properties': {}}},
    };

Widget _host(Widget child) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('TurnVisuals: finding what a turn made', () {
    test('visual files only', () {
      for (final p in ['a.png', 'b.JPG', 'c.svg', 'd.html', 'e.mp4', 'f.webm', 'dir/g.gif']) {
        expect(TurnVisuals.isVisual(p), isTrue, reason: p);
      }
      for (final p in ['a.txt', 'b.py', 'c.json', 'd.pdf', 'svg']) {
        expect(TurnVisuals.isVisual(p), isFalse, reason: p);
      }
    });

    test('files written by opencode\'s write and edit tools', () {
      final w = TurnVisuals.written([
        ('write', {'filePath': '/ws/chart.svg', 'content': _svg}),
        ('write', {'filePath': '/ws/notes.md'}),
        ('edit', {'filePath': 'page.html'}),
        ('bash', {'command': 'python3 plot.py'}),
      ]);
      expect(w, ['/ws/chart.svg', 'page.html']);
    });

    test('paths named in the answer: markdown, backticks, bare; never web links or code', () {
      const answer = 'Here is the chart: ![sales](charts/sales.svg)\n'
          'Saved as `out/plot.png` and also report.html.\n'
          'See [the page](site/index.html) or https://example.com/x.png.\n'
          '```python\nplt.savefig("hidden.png")\n```\n';
      expect(TurnVisuals.named(answer), ['charts/sales.svg', 'site/index.html', 'out/plot.png', 'report.html']);
    });

    test('what is already on screen is not shown twice', () {
      final s = TurnVisuals.shown('```file\n/ws/a.png\n```\n```images\n[{"url":"/ws/b.png"}]\n```',
          ['IMAGE_SAVED /ws/media/c.png\nThe image is shown', 'MEDIA_CARD {"files":["/ws/media/d.png"]}']);
      expect(s, containsAll(['/ws/a.png', '/ws/b.png', '/ws/media/c.png', '/ws/media/d.png']));
    });

    test('cards: existing, unseen, resolved into the workspace, capped', () {
      final files = {'/ws/chart.svg', '/ws/plot.png', '/ws/page.html', '/ws/media/x.png'};
      final cards = TurnVisuals.cardsFor(
        answer: 'Done: `chart.svg`, `missing.png` and ./plot.png',
        workspace: '/ws/',
        calls: [
          ('write', {'filePath': '/ws/page.html'}),
          ('write', {'filePath': '/ws/chart.svg'}),
        ],
        toolOutputs: ['IMAGE_SAVED /ws/media/x.png'],
        made: ['/ws/media/x.png', '/ws/plot.png'],
        exists: files.contains,
      );
      expect(cards, '```file\n/ws/chart.svg\n```\n\n```file\n/ws/plot.png\n```\n\n```file\n/ws/page.html\n```');
      expect(TurnVisuals.attach('Done.', cards), startsWith('Done.\n\n```file\n/ws/chart.svg'));
      expect(TurnVisuals.attach('', cards), cards);
      expect(TurnVisuals.attach('Done.', ''), 'Done.');
      final many = TurnVisuals.cardsFor(
          answer: '', workspace: '/ws', made: [for (var i = 0; i < 9; i++) '/ws/$i.png'], exists: (_) => true);
      expect('```file'.allMatches(many).length, TurnVisuals.maxCards);
    });

    test('new files a script made: since the turn began, skipping tool and hidden folders', () async {
      final root = await Directory.systemTemp.createTemp('tv');
      addTearDown(() => root.delete(recursive: true));
      final old = File('${root.path}/old.png')..writeAsStringSync('x');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      final since = DateTime.now().subtract(const Duration(seconds: 5));
      File('${root.path}/out/plot.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${root.path}/node_modules/x/logo.svg')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${root.path}/.cache/a.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${root.path}/bots/b1/chart.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      File('${root.path}/data.csv').writeAsStringSync('x');
      final made = TurnVisuals.madeSince(root, since, skip: const {'bots'});
      expect(made, ['${root.path}/out/plot.png']);
      expect(TurnVisuals.madeSince(root, since), containsAll(['${root.path}/out/plot.png', '${root.path}/bots/b1/chart.png']));
    });
  });

  group('markdown pictures become the chat\'s cards', () {
    test('an image on its own line is lifted; inline ones and code stay', () {
      final b64 = base64Encode(utf8.encode(_svg));
      final t = TurnVisuals.liftImages('Look:\n![chart](chart.svg)\n'
          '![photo](https://x.com/p.jpg "t")\n'
          '![d](data:image/svg+xml;base64,$b64)\n'
          'inline ![a](a.png) here\n'
          '```md\n![no](no.png)\n```');
      expect(t, contains('```file\nchart.svg\n```'));
      expect(t, contains('```images\n[{"url":"https://x.com/p.jpg","caption":"photo"}]\n```'));
      expect(t, contains('```visual\n$_svg\n```'));
      expect(t, contains('inline ![a](a.png) here'));
      expect(t, contains('```md\n![no](no.png)\n```'));
      expect(TurnVisuals.liftImages('no pictures'), 'no pictures');
    });

    test('data URIs decode', () {
      expect(utf8.decode(TurnVisuals.dataBytes('data:image/svg+xml;base64,${base64Encode(utf8.encode(_svg))}')!), _svg);
      expect(utf8.decode(TurnVisuals.dataBytes('data:image/svg+xml,${Uri.encodeComponent(_svg)}')!), _svg);
      expect(TurnVisuals.dataBytes('nope'), isNull);
    });

    testWidgets('an inline SVG data picture draws; a ```svg fence draws as a visual', (t) async {
      final b64 = base64Encode(utf8.encode(_svg));
      await t.pumpWidget(_host(MarkdownView('A dot ![dot](data:image/svg+xml;base64,$b64) in a line.\n\n```svg\n$_svg\n```')));
      await t.pump();
      expect(find.byType(InlinePicture), findsOneWidget);
      expect(find.byType(SvgPicture), findsNWidgets(2));
      expect(find.byType(VisualCard), findsOneWidget);
    });

    test('links to files on the phone open in the app; web and mail links do not', () async {
      final dir = await Directory.systemTemp.createTemp('lf');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/chart.html')..writeAsStringSync('<html></html>');
      expect(localFileOf(f.path), f.path);
      expect(localFileOf('file://${f.path}'), f.path);
      expect(localFileOf('https://example.com/a.html'), isNull);
      expect(localFileOf('mailto:a@b.c'), isNull);
      expect(localFileOf('example.com'), isNull);
      expect(localFileOf('#top'), isNull);
      expect(localFileOf('${dir.path}/missing.png'), isNull);
    });
  });

  group('generate_image reaches opencode', () {
    test('listed by name only while the server can make pictures', () {
      List<String> names(List<Map<String, dynamic>> l) => [for (final t in l) '${(t['function'] as Map)['name']}'];
      expect(names(TelesiaGateway.listing([])), ['find_tools', 'run_tool']);
      expect(names(TelesiaGateway.listing([AgentTools.imageTool, fn('remember')])), ['find_tools', 'run_tool', 'generate_image']);
      final mcp = TelesiaMcp(tools: () => TelesiaGateway.listing([AgentTools.imageTool]), call: (n, a) async => '');
      expect(mcp.listed().map((t) => t['name']), contains('generate_image'));
    });

    test('a direct call runs through the chat\'s own tool list, prefix or not', () async {
      final ran = <String>[];
      final g = TelesiaGateway(tools: () => [AgentTools.imageTool], run: (n, a) async {
        ran.add('$n ${a['prompt']}');
        return 'IMAGE_SAVED /ws/media/i.png';
      });
      expect(await g.call('generate_image', {'prompt': 'a red fox'}), startsWith('IMAGE_SAVED'));
      expect(await g.call('telesia_generate_image', {'prompt': 'b'}), startsWith('IMAGE_SAVED'));
      expect(ran, ['generate_image a red fox', 'generate_image b']);
      final off = TelesiaGateway(tools: () => [fn('remember')], run: (n, a) async => 'ran');
      expect(await off.call('generate_image', {'prompt': 'x'}), startsWith('Error: generate_image is not available'));
    });

    test('a direct call is routed to the chat whose turn made it', () async {
      final r = McpRoutes();
      r.watch({
        'type': 'message.part.updated',
        'properties': {
          'part': {
            'id': 'p1',
            'type': 'tool',
            'tool': 'telesia_generate_image',
            'sessionID': 's1',
            'state': {'status': 'running', 'input': {'prompt': 'fox'}},
          },
        },
      }, 'chat-1', {'s1'});
      expect(await r.take('generate_image', {'prompt': 'fox'}, wait: Duration.zero), 'chat-1');
    });

    test('shape to size', () {
      expect(TurnVisuals.sizeFor({}), '1024x1024');
      expect(TurnVisuals.sizeFor({'aspect': '16:9'}), '1536x1024');
      expect(TurnVisuals.sizeFor({'aspect': '9:16'}), '1024x1536');
      expect(TurnVisuals.sizeFor({'size': '512x512', 'aspect': '16:9'}), '512x512');
    });

    test('the agent is told what shows and what to do when pictures are off', () {
      expect(TelesiaGateway.skill, contains('.svg'));
      expect(TelesiaGateway.skill, contains('![what it is](path)'));
      expect(TelesiaGateway.skill, contains('visual answer'));
      expect(AgentTools.imageOffNote, startsWith('Error:'));
      expect(AgentTools.imageOffNote, contains('code_media'));
      expect(AgentTools.imageOffNote, contains('.svg'));
    });
  });
}
