import 'dart:io';

import 'package:agent/services/ai_models.dart';
import 'package:agent/widgets/media_cards.dart';
import 'package:agent/widgets/media_lightbox.dart';
import 'package:agent/widgets/media_view.dart';
import 'package:agent/widgets/video_inline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {bool still = false, TextDirection dir = TextDirection.ltr}) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(400, 900), disableAnimations: still),
        child: Directionality(
          textDirection: dir,
          child: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(24), child: child)),
        ),
      ),
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('media_cards_test'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String file(String name, int bytes) {
    final f = File('${dir.path}/$name')..writeAsBytesSync(List.filled(bytes, 1));
    return f.path;
  }

  Map<String, dynamic> card(String kind, List<String> files, {String prompt = 'a calm sea at dawn', String model = 'my-model'}) =>
      {'v': 1, 'kind': kind, 'files': files, 'prompt': prompt, 'model': model};

  testWidgets('status pill shows the task, then the live progress line in place', (t) async {
    await t.pumpWidget(host(const MediaSkeleton(callId: 'c9', task: 'video')));
    expect(find.text('Creating your video'), findsOneWidget);
    AiModels.progress.value = {'c9': 'Getting a file ready'};
    await t.pump();
    await t.pumpAndSettle();
    expect(find.text('Getting a file ready'), findsOneWidget);
    expect(find.text('Creating your video'), findsNothing);
    AiModels.progress.value = const {};
  });

  testWidgets('with reduced motion nothing animates', (t) async {
    await t.pumpWidget(host(const MediaSkeleton(callId: 'c1', task: 'image'), still: true));
    await t.pump();
    expect(t.hasRunningAnimations, isFalse);
  });

  testWidgets('sound: a light chip with the file name and size, opened by a tap', (t) async {
    final p = file('voice.mp3', 2048);
    await t.pumpWidget(host(GeneratedMediaCard(card: card('audio', [p]))));
    await t.pump();
    expect(find.text('voice.mp3'), findsOneWidget);
    expect(find.text('MP3 · 2 KB'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Open preview for voice.mp3')), findsOneWidget);
    expect(find.text('Variations'), findsNothing, reason: 'no chrome on the card itself');
  });

  testWidgets('video card has one quiet corner action: full screen', (t) async {
    final p = file('clip.mp4', 1024);
    await t.pumpWidget(host(GeneratedMediaCard(card: card('video', [p]))));
    await t.pump();
    expect(find.bySemanticsLabel('Full screen'), findsOneWidget);
  });

  testWidgets('video card: wide frame, play glyph, size, labelled for the reader', (t) async {
    final p = file('clip.mp4', 3 * 1024 * 1024);
    await t.pumpWidget(host(GeneratedMediaCard(card: card('video', [p]))));
    await t.pump();
    expect(find.byType(InlineVideo), findsOneWidget, reason: 'videos play right in the chat');
    expect(find.byType(AspectRatio), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Play video clip.mp4')), findsOneWidget);
  });

  testWidgets('a picture made on another phone shows a calm placeholder while it comes from the account', (t) async {
    await t.pumpWidget(host(GeneratedMediaCard(card: card('image', ['/nowhere/ai_1.png']))));
    await t.pump();
    expect(find.byType(MediaPlaceholder), findsOneWidget);
  });

  testWidgets('a set of pictures is a fanned stack of turned tiles', (t) async {
    await t.pumpWidget(host(GeneratedMediaCard(card: card('images', ['/nowhere/a.png', '/nowhere/b.png']))));
    await t.pumpAndSettle();
    expect(find.byType(MediaPhotoStack), findsOneWidget);
    final turns = t.widgetList<Transform>(find.descendant(of: find.byType(MediaPhotoStack), matching: find.byType(Transform))).toList();
    expect(turns.length, greaterThanOrEqualTo(2));
    expect(find.byType(MediaPlaceholder), findsNWidgets(2));
  });

  testWidgets('files show as document tiles', (t) async {
    final a = file('notes.pdf', 1024);
    await t.pumpWidget(host(GeneratedMediaCard(card: card('file', [a], prompt: '', model: ''))));
    await t.pump();
    expect(find.textContaining('notes.pdf'), findsOneWidget);
  });

  testWidgets('the call view crossfades from the status pill to the card', (t) async {
    final p = file('song.mp3', 4096);
    final result = AiModels.cardLine(card('audio', [p]));
    await t.pumpWidget(host(const AiMediaCall(callId: 'x', arguments: '{"task":"music"}')));
    expect(find.text('Creating your music'), findsOneWidget);
    await t.pumpWidget(host(AiMediaCall(callId: 'x', arguments: '{"task":"music"}', result: result)));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('song.mp3'), findsOneWidget, reason: 'the card is in while the pill fades out');
    await t.pumpAndSettle();
    expect(find.text('Creating your music'), findsNothing);
    expect(find.text('song.mp3'), findsOneWidget);
  });

  testWidgets('right-to-left layout renders', (t) async {
    final p = file('voice.mp3', 2048);
    await t.pumpWidget(host(GeneratedMediaCard(card: card('audio', [p])), dir: TextDirection.rtl));
    await t.pump();
    expect(find.text('voice.mp3'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('full-screen view: close, save, share, and paging through a set', (t) async {
    await t.pumpWidget(host(Builder(
      builder: (c) => TextButton(onPressed: () => openMediaLightbox(c, ['/nowhere/a.png', '/nowhere/b.png']), child: const Text('open')),
    )));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Close'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Download')), findsOneWidget);
    expect(find.bySemanticsLabel('Share'), findsOneWidget);
    expect(find.bySemanticsLabel('Next'), findsOneWidget);
    expect(find.bySemanticsLabel('Previous'), findsNothing);
    await t.tap(find.bySemanticsLabel('Next'));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Previous'), findsOneWidget);
    expect(find.bySemanticsLabel('Next'), findsNothing);
    await t.tap(find.bySemanticsLabel('Close').hitTestable().last);
    await t.pumpAndSettle();
    expect(find.byType(MediaLightbox), findsNothing);
  });

  test('which calls become cards, and how a card reads aloud', () {
    expect(AiMediaCall.shows('ai_call', null), isTrue);
    expect(AiMediaCall.shows('ai_call', 'Error: nope'), isFalse);
    expect(AiMediaCall.shows('ai_call', 'Reply from m:\nhi'), isFalse);
    expect(AiMediaCall.shows('ai_call', AiModels.cardLine({'kind': 'image', 'files': ['/a.png']})), isTrue);
    expect(AiMediaCall.shows('web_search', null), isFalse);
    expect(GeneratedMediaCard.describe(card('image', ['/a.png']), 1), 'Picture: a calm sea at dawn (my-model)');
    expect(GeneratedMediaCard.describe(card('video', ['/a.mp4'], prompt: ''), 1), 'Video (my-model)');
  });
}
