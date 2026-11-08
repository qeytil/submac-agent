import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/screens/feedback_screen.dart';
import 'package:agent/services/feedback.dart';
import 'package:agent/ui/feedback_words.dart';
import 'package:agent/ui/i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException, StorageException;

// A real 1x1 PNG, so Image.memory can decode the thumbnails.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0, 0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

FeedbackShot shot([String name = 'a.png', String mime = 'image/png', int? size]) =>
    FeedbackShot(name: name, mime: mime, bytes: size == null ? _png : Uint8List(size));

class FakeBackend implements FeedbackBackend {
  @override
  String? userId = 'u1';
  final uploads = <String>[];
  final rows = <Map<String, dynamic>>[];
  final removed = <String>[];
  Object? failUpload; // thrown once on the next upload
  Object? failInsert; // thrown once on the next insert
  int uploadCalls = 0;
  Completer<void>? holdInsert;

  @override
  Future<void> upload(String path, Uint8List bytes, String mime) async {
    uploadCalls++;
    if (failUpload != null) {
      final e = failUpload!;
      failUpload = null;
      throw e;
    }
    uploads.add(path);
  }

  @override
  Future<void> insert(Map<String, dynamic> row) async {
    if (holdInsert != null) await holdInsert!.future;
    if (failInsert != null) {
      final e = failInsert!;
      failInsert = null;
      throw e;
    }
    rows.add(row);
  }

  @override
  Future<void> remove(List<String> paths) async => removed.addAll(paths);
}

class MemStore implements FeedbackDraftStore {
  FeedbackDraft? d;
  int clears = 0;
  MemStore([this.d]);
  @override
  Future<void> clear() async {
    d = null;
    clears++;
  }

  @override
  Future<FeedbackDraft?> load() async => d;
  @override
  Future<void> save(FeedbackDraft draft) async => d = draft;
}

class FakePicker implements FeedbackPicker {
  List<FeedbackShot> next = [];
  int? askedMax;
  @override
  Future<FeedbackShot?> camera() async => shot('photo.jpg', 'image/jpeg');
  @override
  Future<List<FeedbackShot>> gallery(int max) async {
    askedMax = max;
    return next;
  }
}

const _device = FeedbackDevice(appVersion: '1.13.104', buildNumber: '174', deviceModel: 'Google Pixel 8', osVersion: 'Android 15 (SDK 35)', locale: 'so');
FeedbackSender sender(FakeBackend b) => FeedbackSender(backend: b, device: () async => _device, newId: () => 'fid');

Widget app(Widget child) => MaterialApp(home: child);

void main() {
  setUp(() => AppLang.I.choice = 'en');

  group('FeedbackSender', () {
    test('uploads each screenshot under <uid>/<id>/ then inserts one row with the device details', () async {
      final b = FakeBackend();
      final steps = <String>[];
      await sender(b).send(
        message: '  The send button is stuck  ',
        category: 'bug',
        shots: [shot(), shot('b.jpg', 'image/jpeg')],
        onProgress: (p) => steps.add('${p.done}/${p.total}:${p.shot}'),
      );
      expect(b.uploads, hasLength(2));
      expect(b.uploads[0], startsWith('u1/fid/1-'));
      expect(b.uploads[0], endsWith('.png'));
      expect(b.uploads[1], startsWith('u1/fid/2-'));
      expect(b.uploads[1], endsWith('.jpg'));
      expect(b.rows, hasLength(1));
      final r = b.rows.single;
      expect(r['user_id'], 'u1');
      expect(r['message'], 'The send button is stuck');
      expect(r['category'], 'bug');
      expect(r['app_version'], '1.13.104');
      expect(r['build_number'], '174');
      expect(r['device_model'], 'Google Pixel 8');
      expect(r['os_version'], 'Android 15 (SDK 35)');
      expect(r['locale'], 'so');
      expect(r['screenshot_paths'], b.uploads);
      expect(r.containsKey('status'), isFalse, reason: 'the server sets status; the insert policy only allows new');
      expect(steps, ['0/3:1', '1/3:2', '2/3:0', '3/3:0']);
    });

    test('text is required and limits are checked before anything is uploaded', () async {
      final b = FakeBackend();
      final s = sender(b);
      Future<FeedbackProblem> problem(Future<void> f) async {
        try {
          await f;
        } on FeedbackException catch (e) {
          return e.problem;
        }
        fail('no error');
      }

      expect(await problem(s.send(message: '   ')), FeedbackProblem.empty);
      expect(await problem(s.send(message: 'x' * 5001)), FeedbackProblem.tooLong);
      expect(await problem(s.send(message: 'hi', shots: List.generate(6, (_) => shot()))), FeedbackProblem.tooManyShots);
      expect(await problem(s.send(message: 'hi', shots: [shot('a.png', 'image/png', 5 * 1024 * 1024 + 1)])), FeedbackProblem.tooBig);
      expect(await problem(s.send(message: 'hi', shots: [shot('a.pdf', 'application/pdf')])), FeedbackProblem.badType);
      b.userId = null;
      expect(await problem(s.send(message: 'hi')), FeedbackProblem.signedOut);
      expect(b.uploadCalls, 0);
      expect(b.rows, isEmpty);
    });

    test('offline mid-way: the retry skips screenshots that already made it and keeps the same feedback id', () async {
      final b = FakeBackend();
      final s = sender(b);
      final shots = [shot(), shot('b.png')];
      b.failInsert = const SocketException('Failed host lookup: moeemacbvsueekuvfjbo.supabase.co');
      await expectLater(
        s.send(message: 'hello', shots: shots),
        throwsA(isA<FeedbackException>().having((e) => e.problem, 'problem', FeedbackProblem.offline)),
      );
      expect(b.uploads, hasLength(2));
      expect(b.rows, isEmpty);
      await s.send(message: 'hello', shots: shots);
      expect(b.uploadCalls, 2, reason: 'no second upload of the same pictures');
      expect(b.rows.single['screenshot_paths'], b.uploads);
    });

    test('a screenshot removed before the retry is cleaned up after the send', () async {
      final b = FakeBackend();
      final s = sender(b);
      final a = shot(), c = shot('c.png');
      b.failInsert = TimeoutException('slow');
      await expectLater(s.send(message: 'hello', shots: [a, c]), throwsA(isA<FeedbackException>()));
      await s.send(message: 'hello', shots: [a]);
      await Future<void>.delayed(Duration.zero);
      expect(b.rows.single['screenshot_paths'], [b.uploads.first]);
      expect(b.removed, [b.uploads.last]);
    });

    test('classify maps network and server errors to problems', () {
      FeedbackProblem c(Object e) => FeedbackSender.classify(e).problem;
      expect(c(const SocketException('x')), FeedbackProblem.offline);
      expect(c(TimeoutException('x')), FeedbackProblem.offline);
      expect(c(Exception('ClientException with SocketException: Failed host lookup')), FeedbackProblem.offline);
      expect(c(StorageException('The object exceeded the maximum allowed size', statusCode: '413')), FeedbackProblem.tooBig);
      expect(c(StorageException('mime type text/plain is not supported', statusCode: '415')), FeedbackProblem.badType);
      expect(c(StorageException('new row violates row-level security policy', statusCode: '403')), FeedbackProblem.tooMany);
      expect(c(const PostgrestException(message: 'new row violates row-level security policy for table "feedback"', code: '42501')),
          FeedbackProblem.tooMany);
      expect(c(const PostgrestException(message: 'JWT expired', code: 'PGRST303')), FeedbackProblem.signedOut);
      expect(c(const PostgrestException(message: 'boom', code: '500')), FeedbackProblem.server);
      expect(c(StateError('?')), FeedbackProblem.server);
    });
  });

  group('FeedbackDevice', () {
    test('locale tag shows the phone locale only when it differs, and fits the column', () {
      expect(FeedbackDevice.localeTag('so', 'so-SO'), 'so');
      expect(FeedbackDevice.localeTag('ar', 'en-US'), 'ar (en-US)');
      expect(FeedbackDevice.localeTag('en', 'zh-Hant-TW-x-private-long'), hasLength(20));
    });

    test('row values are cut to the column limits', () {
      final r = FeedbackDevice(deviceModel: 'm' * 300, appVersion: 'v' * 50).toRow();
      expect((r['device_model'] as String).length, 120);
      expect((r['app_version'] as String).length, 40);
    });

    test('read falls back safely off Android', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final d = await FeedbackDevice.read();
      expect(d.appVersion, isNotEmpty);
      expect(d.locale, isNotEmpty);
    });

    test('mime and extension helpers', () {
      expect(FeedbackLimits.mimeFor('Screenshot_1.PNG'), 'image/png');
      expect(FeedbackLimits.mimeFor('x.heic'), 'image/heic');
      expect(FeedbackLimits.mimeFor('x.pdf'), isNull);
      expect(FeedbackLimits.extFor('image/jpeg'), 'jpg');
      expect(FeedbackLimits.extFor('image/webp'), 'webp');
    });
  });

  group('FeedbackWords', () {
    test('every ft() string in the code is a key', () {
      final used = <String>{};
      final call = RegExp(r"""ft\('((?:[^'\\]|\\.)*)'""");
      for (final f in ['lib/screens/feedback_screen.dart', 'lib/screens/settings_screen.dart']) {
        for (final m in call.allMatches(File(f).readAsStringSync())) {
          used.add(m.group(1)!.replaceAll(r"\'", "'"));
        }
      }
      expect(used, isNotEmpty);
      expect(used.difference(FeedbackWords.keys.toSet()), isEmpty);
    });

    test('ft fills holes and shows the English text (the app is English only)', () {
      AppLang.I.choice = 'so'; // ignored now
      expect(ft('Send'), 'Send');
      expect(ft('{n} of {max}', {'n': '2', 'max': '5'}), '2 of 5');
      AppLang.I.choice = 'en';
      expect(ft('Thank you'), 'Thank you');
    });
  });

  group('FeedbackScreen', () {
    testWidgets('text is required: Send with an empty box shows an error and sends nothing', (t) async {
      final b = FakeBackend();
      await t.pumpWidget(app(FeedbackScreen(sender: sender(b), store: MemStore(), picker: FakePicker())));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('feedback-send')));
      await t.pump();
      expect(find.text('Write your feedback first.'), findsOneWidget);
      expect(b.rows, isEmpty);
      await t.enterText(find.byKey(const ValueKey('feedback-text')), 'Now it has words');
      await t.pump();
      expect(find.text('Write your feedback first.'), findsNothing);
    });

    testWidgets('attach from the gallery, see thumbnails, remove one, send, then the success state', (t) async {
      final b = FakeBackend();
      final store = MemStore();
      final picker = FakePicker()..next = [shot('1.png'), shot('2.png'), shot('3.png')];
      await t.pumpWidget(app(FeedbackScreen(sender: sender(b), store: store, picker: picker)));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('feedback-text')), 'Chat froze after a photo');
      await t.tap(find.byKey(const ValueKey('feedback-add')));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose from gallery'));
      await t.pumpAndSettle();
      expect(picker.askedMax, 5);
      expect(find.byType(Image), findsNWidgets(3));
      expect(find.text('3 of 5'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('feedback-remove-1')));
      await t.pump();
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text('2 of 5'), findsOneWidget);
      await t.tap(find.text('Problem'));
      await t.pump();
      await t.ensureVisible(find.byKey(const ValueKey('feedback-send')));
      await t.tap(find.byKey(const ValueKey('feedback-send')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('feedback-sent')), findsOneWidget);
      expect(find.text('Thank you'), findsOneWidget);
      expect(b.uploads, hasLength(2));
      expect(b.rows.single['message'], 'Chat froze after a photo');
      expect(b.rows.single['category'], 'bug');
      expect(store.d, isNull, reason: 'draft cleared after a successful send');
      expect(store.clears, greaterThan(0));
    });

    testWidgets('shows progress while sending', (t) async {
      final b = FakeBackend()..holdInsert = Completer<void>();
      await t.pumpWidget(app(FeedbackScreen(sender: sender(b), store: MemStore(), picker: FakePicker())));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('feedback-text')), 'hello');
      await t.tap(find.byKey(const ValueKey('feedback-send')));
      await t.pump();
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Sending...'), findsOneWidget);
      expect(find.text('Saving your feedback'), findsOneWidget);
      b.holdInsert!.complete();
      await t.pumpAndSettle();
      expect(find.text('Thank you'), findsOneWidget);
    });

    testWidgets('offline: clear error, the draft stays, Try again sends it', (t) async {
      final b = FakeBackend()..failInsert = const SocketException('Failed host lookup');
      final store = MemStore();
      final picker = FakePicker()..next = [shot()];
      await t.pumpWidget(app(FeedbackScreen(sender: sender(b), store: store, picker: picker)));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('feedback-text')), 'Offline test');
      await t.tap(find.byKey(const ValueKey('feedback-add')));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose from gallery'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('feedback-send')));
      await t.pumpAndSettle();
      expect(find.textContaining('You are offline'), findsOneWidget);
      expect(find.text('Offline test'), findsOneWidget, reason: 'text kept');
      expect(find.byType(Image), findsOneWidget, reason: 'screenshot kept');
      expect(store.d?.message, 'Offline test');
      expect(store.d?.shots, hasLength(1));
      expect(find.text('Try again'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('feedback-send')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('feedback-send')));
      await t.pumpAndSettle();
      expect(find.text('Thank you'), findsOneWidget);
      expect(b.uploadCalls, 1, reason: 'the screenshot is not uploaded twice');
      expect(b.rows, hasLength(1));
    });

    testWidgets('a saved draft comes back when the screen opens', (t) async {
      final store = MemStore(FeedbackDraft(message: 'Half written', category: 'idea', shots: [shot()]));
      await t.pumpWidget(app(FeedbackScreen(sender: sender(FakeBackend()), store: store, picker: FakePicker())));
      await t.pump();
      await t.pump();
      expect(find.text('Half written'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('1 of 5'), findsOneWidget);
    });

    testWidgets('pictures that are too big or not images are refused with a message', (t) async {
      final picker = FakePicker()..next = [shot('big.png', 'image/png', 6 * 1024 * 1024), shot('doc.pdf', 'application/pdf'), shot()];
      await t.pumpWidget(app(FeedbackScreen(sender: sender(FakeBackend()), store: MemStore(), picker: picker)));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('feedback-add')));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose from gallery'));
      await t.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('That picture is too big. Each screenshot can be up to 5 MB.'), findsOneWidget);
    });

    testWidgets('at 5 screenshots the add tile goes away', (t) async {
      final picker = FakePicker()..next = List.generate(5, (i) => shot('$i.png'));
      await t.pumpWidget(app(FeedbackScreen(sender: sender(FakeBackend()), store: MemStore(), picker: picker)));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('feedback-add')));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose from gallery'));
      await t.pumpAndSettle();
      expect(find.text('5 of 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('feedback-add')), findsNothing);
    });

    testWidgets('a server refusal for too many sends shows the daily-limit words and no retry', (t) async {
      final b = FakeBackend()
        ..failInsert = const PostgrestException(message: 'new row violates row-level security policy for table "feedback"', code: '42501');
      await t.pumpWidget(app(FeedbackScreen(sender: sender(b), store: MemStore(), picker: FakePicker())));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('feedback-text')), 'hello');
      await t.tap(find.byKey(const ValueKey('feedback-send')));
      await t.pumpAndSettle();
      expect(find.text('You have sent a lot of feedback today. Please try again tomorrow.'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
    });

    testWidgets('the screen reads left to right in English', (t) async {
      await t.pumpWidget(MaterialApp(
        home: FeedbackScreen(sender: sender(FakeBackend()), store: MemStore(), picker: FakePicker()),
      ));
      await t.pump();
      expect(find.text('Send feedback'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      expect(Directionality.of(t.element(find.byKey(const ValueKey('feedback-text')))), TextDirection.ltr);
    });
  });
}
