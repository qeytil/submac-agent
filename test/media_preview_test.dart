import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/models.dart';
import 'package:agent/services/media_store.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/media_view.dart';
import 'package:agent/widgets/media_lightbox.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v1.13.88 media preview (owner 2026-10-24: "images and files say not on this device"). Cards kept the absolute path
// from the phone that made the file; on another phone, after a reinstall or in the dev build the file was missing
// and the card said "Not found on this phone" (pictures showed nothing). Files are now kept in the account and
// fetched back; a card only says "not available" when the file is gone from both.

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

const _otherPhone = '/data/user/0/com.telesia.app.dev/app_flutter/workspace';

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Lets real file work finish: each step completes on the real event loop and continues on the next pump.
Future<void> _settleIo(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
}

void main() {
  late Directory ws;
  late List<String> downloads;
  late List<String> uploads;
  Map<String, Uint8List> cloud = {};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Named like the app's own folder (…/workspace) so paths map the same way they do on a phone.
    ws = Directory('${(await Directory.systemTemp.createTemp('ws')).path}/workspace')..createSync();
    downloads = [];
    uploads = [];
    cloud = {};
    final s = MediaStore.I;
    s.resetForTest();
    s.workspace = () async => ws.path;
    s.cacheDir = () async => '${ws.path}/.cloud';
    s.userId = () => 'u1';
    s.download = (key) async {
      downloads.add(key);
      final b = cloud[key];
      if (b == null) throw Exception('Object not found');
      return b;
    };
    s.upload = (key, f, mime) async {
      uploads.add('$key|$mime');
      cloud[key] = await f.readAsBytes();
    };
  });

  tearDown(() async {
    try {
      await ws.parent.delete(recursive: true);
    } catch (_) {}
  });

  group('paths', () {
    test('file:// links, %20 and quotes are cleaned', () {
      expect(MediaStore.normalize('file:///data/x/My%20Report.pdf'), '/data/x/My Report.pdf');
      expect(MediaStore.normalize('`/a/b.png`'), '/a/b.png');
      expect(MediaStore.normalize('"media/c.png"'), 'media/c.png');
      expect(MediaStore.normalize('https://x.com/a%20b.png'), 'https://x.com/a%20b.png');
    });

    test('a path from another phone or install maps to the same place in the workspace', () {
      expect(MediaStore.workspaceRel('$_otherPhone/media/cat.png'), 'media/cat.png');
      expect(MediaStore.workspaceRel('file://$_otherPhone/out/report.pdf'), 'out/report.pdf');
      expect(MediaStore.workspaceRel('./out/a.csv'), 'out/a.csv');
      expect(MediaStore.workspaceRel('workspace/out/a.csv'), 'out/a.csv');
      expect(MediaStore.workspaceRel('/storage/emulated/0/Download/a.pdf'), isNull);
      expect(MediaStore.workspaceRel('$_otherPhone/../secret'), isNull);
    });

    test('storage keys sit in the user folder (bucket RLS) and are the same on every phone', () {
      expect(MediaStore.keyFor('u1', '$_otherPhone/media/cat.png'), 'u1/workspace/media/cat.png');
      expect(MediaStore.keyFor('u1', '/data/user/0/com.telesia.app/app_flutter/workspace/media/cat.png'),
          'u1/workspace/media/cat.png');
      expect(MediaStore.keyFor('u1', 'media/my cat (1).png'), 'u1/workspace/media/my_cat__1_.png');
      final outside = MediaStore.keyFor('u1', '/storage/emulated/0/Download/a.pdf');
      expect(outside, startsWith('u1/workspace/phone/'));
      expect(outside, endsWith('/a.pdf'));
    });

    test('finds the files a reply or tool result shows', () {
      const reply = 'Here it is.\n\n```file\n/ws/out/report.pdf\n```\n\n```photos\n["/ws/media/a.png", "https://x.com/b.png"]\n```\n'
          '```images\n{"items":[{"url":"file:///ws/media/c.png"}]}\n```';
      expect(MediaStore.pathsIn(reply), containsAll(['/ws/out/report.pdf', '/ws/media/c.png']));
      expect(MediaStore.pathsIn(reply), isNot(contains('https://x.com/b.png')));
      expect(MediaStore.pathsIn('IMAGE_SAVED /ws/media/d.png\nThe image is shown.'), ['/ws/media/d.png']);
      expect(MediaStore.pathsIn('```page\n<html></html>\n```'), isEmpty);
    });

    test('cardPath cleans file:// links', () {
      expect(AgentTools.cardPath('file:///nowhere/a%20b.pdf'), '/nowhere/a b.pdf');
    });
  });

  group('finding a file', () {
    test('a file on this phone is used as it is, with no download', () async {
      final f = File('${ws.path}/media/here.png')..createSync(recursive: true);
      f.writeAsBytesSync(_png);
      final got = await MediaStore.I.resolve(f.path);
      expect(got?.path, f.path);
      expect(downloads, isEmpty);
    });

    test('a file from another phone is found in this workspace when it is here', () async {
      File('${ws.path}/media/cat.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png);
      final got = await MediaStore.I.resolve('$_otherPhone/media/cat.png');
      expect(got?.path, '${ws.path}/media/cat.png');
      expect(downloads, isEmpty);
    });

    test('missing here: downloaded from the account into the same workspace place, once', () async {
      cloud['u1/workspace/out/report.pdf'] = Uint8List.fromList(utf8.encode('%PDF-1.4'));
      final got = await MediaStore.I.resolve('$_otherPhone/out/report.pdf');
      expect(got?.path, '${ws.path}/out/report.pdf');
      expect(await got!.readAsString(), '%PDF-1.4');
      await MediaStore.I.resolve('$_otherPhone/out/report.pdf');
      expect(downloads, ['u1/workspace/out/report.pdf'], reason: 'the local copy is used the second time');
    });

    test('gone everywhere: null, remembered for the session, asked again on retry', () async {
      expect(await MediaStore.I.resolve('$_otherPhone/out/lost.pdf'), isNull);
      expect(await MediaStore.I.resolve('$_otherPhone/out/lost.pdf'), isNull);
      expect(downloads.length, 1);
      cloud['u1/workspace/out/lost.pdf'] = Uint8List.fromList([1, 2, 3]);
      expect(await MediaStore.I.resolve('$_otherPhone/out/lost.pdf', retry: true), isNotNull);
    });

    test('signed out: nothing is fetched', () async {
      MediaStore.I.userId = () => null;
      expect(await MediaStore.I.resolve('$_otherPhone/out/report.pdf'), isNull);
      expect(downloads, isEmpty);
    });
  });

  group('keeping a copy in the account', () {
    test('uploads once, again only when the file changes', () async {
      final f = File('${ws.path}/media/made.png')..createSync(recursive: true);
      f.writeAsBytesSync(_png);
      expect(await MediaStore.I.keep(f.path), 'u1/workspace/media/made.png');
      expect(uploads, ['u1/workspace/media/made.png|image/png']);
      await MediaStore.I.keep(f.path);
      expect(uploads.length, 1);
      f.writeAsBytesSync([..._png, 0, 0]);
      f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      await MediaStore.I.keep(f.path);
      expect(uploads.length, 2);
    });

    test('a reply keeps every file it shows; missing files and signed-out are skipped', () async {
      final a = File('${ws.path}/out/a.pdf')..createSync(recursive: true);
      a.writeAsStringSync('%PDF');
      await MediaStore.I.keepAllIn('```file\n${a.path}\n```\n```file\n/nowhere/b.pdf\n```');
      expect(uploads, ['u1/workspace/out/a.pdf|application/pdf']);
      MediaStore.I.userId = () => null;
      expect(await MediaStore.I.keep(a.path), isNull);
    });

    test('a file made on one phone opens on another', () async {
      final made = File('${ws.path}/media/sunset.png')..createSync(recursive: true);
      made.writeAsBytesSync(_png);
      await MediaStore.I.keep(made.path);
      // The first phone's copy is not on the other phone.
      await made.parent.parent.delete(recursive: true);
      // The "other phone": a fresh workspace, same account.
      final other = Directory('${(await Directory.systemTemp.createTemp('ws2')).path}/workspace')..createSync();
      addTearDown(() => other.parent.delete(recursive: true));
      MediaStore.I.resetForTest();
      MediaStore.I.workspace = () async => other.path;
      final got = await MediaStore.I.resolve(made.path);
      expect(got?.path, '${other.path}/media/sunset.png');
      expect(await got!.readAsBytes(), _png);
    });
  });

  group('attachments', () {
    test('bytes become a cache file to open; a storage copy is fetched; nothing at all is null', () async {
      final a = Attachment(name: 'photo.jpg', mime: 'image/jpeg', bytes: _png);
      final f = await MediaStore.I.attachmentFile(a);
      expect(f, isNotNull);
      expect(await f!.readAsBytes(), _png);

      final b = Attachment(name: 'notes.pdf', mime: 'application/pdf', path: 'u1/c1/1_notes.pdf');
      final g = await MediaStore.I.attachmentFile(b, fetch: (p) async => Uint8List.fromList(utf8.encode('%PDF $p')));
      expect(await g!.readAsString(), '%PDF u1/c1/1_notes.pdf');
      expect(b.bytes, isNotNull, reason: 'kept for the chip');

      final c = Attachment(name: 'gone.pdf', mime: 'application/pdf', path: 'u1/c1/2_gone.pdf');
      expect(await MediaStore.I.attachmentFile(c, fetch: (p) async => throw Exception('404')), isNull);
    });
  });

  group('cards', () {
    testWidgets('a file from another phone shows its name, kind and size after it arrives', (t) async {
      cloud['u1/workspace/out/report.pdf'] = Uint8List.fromList(utf8.encode('%PDF-1.4 hello'));
      await t.pumpWidget(_host(const FileCard('$_otherPhone/out/report.pdf')));
      expect(find.textContaining('Getting it from your account'), findsOneWidget);
      await _settleIo(t);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('PDF · 14 B'), findsOneWidget);
      expect(find.textContaining('Not found on this phone'), findsNothing);
    });

    testWidgets('only a file gone everywhere says so, with try again', (t) async {
      await t.pumpWidget(_host(const FileCard('$_otherPhone/out/lost.xlsx')));
      await _settleIo(t);
      expect(find.textContaining('Not available any more'), findsOneWidget);
      cloud['u1/workspace/out/lost.xlsx'] = Uint8List.fromList([1, 2, 3, 4]);
      await t.tap(find.text('lost.xlsx'));
      await _settleIo(t);
      expect(find.text('Spreadsheet · 4 B'), findsOneWidget);
    });

    testWidgets('a picture from another phone shows inline once it arrives', (t) async {
      cloud['u1/workspace/media/cat.png'] = _png;
      await t.pumpWidget(_host(const ImageResultCard(path: 'file://$_otherPhone/media/cat.png')));
      expect(find.byType(MediaPlaceholder), findsOneWidget);
      await _settleIo(t);
      expect(find.byType(TrueShapeImage), findsOneWidget);
    });

    testWidgets('a picture gone everywhere is a quiet line, not an empty space', (t) async {
      await t.pumpWidget(_host(const ImageResultCard(path: '$_otherPhone/media/lost.png')));
      await _settleIo(t);
      expect(find.textContaining('Picture · Not available any more'), findsOneWidget);
    });
  });

  group('viewer (the one shared lightbox)', () {
    Widget viewer() => MaterialApp(
          home: MediaLightbox(
            paths: const ['a.png', 'b.png', 'c.png'],
            picture: (src) => SizedBox(width: 200, height: 200, child: Text('pic $src')),
          ),
        );

    testWidgets('swipes between pictures; Close, Share and Download float on top', (t) async {
      await t.pumpWidget(viewer());
      expect(find.text('pic a.png'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Download')), findsOneWidget);
      expect(find.bySemanticsLabel('Share'), findsOneWidget);
      expect(find.text('a.png'), findsOneWidget, reason: 'the file name is the only title');
      await t.drag(find.byKey(const ValueKey('image-viewer-pages')), const Offset(-500, 0));
      await t.pumpAndSettle();
      expect(find.text('b.png'), findsOneWidget);
    });

    testWidgets('double-tap zooms in and locks the page swipe; again fits it back', (t) async {
      await t.pumpWidget(viewer());
      final center = t.getCenter(find.text('pic a.png'));
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(center);
      await t.pumpAndSettle();
      PageView pv() => t.widget<PageView>(find.byKey(const ValueKey('image-viewer-pages')));
      expect(pv().physics, isA<NeverScrollableScrollPhysics>());
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(center);
      await t.pumpAndSettle();
      expect(pv().physics, isA<PageScrollPhysics>());
    });
  });
}
