// Browser use with SubMac closed (owner 2026-11-07, docs/bot-autonomy.md): the browser agent's InAppWebView widgets
// need a drawn frame, so with no screen every step failed on "the browser view is not ready". Now: tabs opened with no
// screen are off-screen web views (HeadlessInAppWebView), and when those cannot start the task continues in read-only
// mode (FetchBrowser). A bot's browser task thinks on the bot's own model (BotBrowserModel).
//
// Run: flutter test test/browser_background_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:agent/models.dart';
import 'package:agent/services/bot_llm.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/browser_agent.dart';
import 'package:agent/services/browser_jobs.dart';
import 'package:agent/services/byok.dart';
import 'package:agent/services/byok_fetch.dart';
import 'package:agent/services/fetch_browser.dart';
import 'package:agent/services/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _home = '''<html><head><title>Shop news</title></head><body>
<nav><a href="/about">About</a></nav>
<article><h1>Prices this week</h1><p>The red kettle costs 24 dollars this week, down from 30. Stock is limited to the first
hundred buyers and ships within two days from the Nairobi warehouse.</p>
<p>See the <a href="/kettles/red">red kettle page</a> or <a href="https://other.example/review">an outside review</a>.</p>
<a href="#top">Top</a><a href="javascript:void(0)">JS</a><a href="mailto:x@y.z">Mail</a>
</article></body></html>''';

const _kettle = '''<html><head><title>Red kettle</title></head><body><main><h1>Red kettle</h1>
<p>Price: 24 USD. Capacity 1.7 litres. Warranty two years. Ships from Nairobi within two days of the order date.</p></main></body></html>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FetchBrowser: read-only page reads with numbered links', () {
    final pages = {'https://shop.example/': _home, 'https://shop.example/kettles/red': _kettle};
    late List<String> got;
    setUp(() {
      got = [];
      FetchBrowser.getOverride = (url) async {
        got.add(url);
        final b = pages[url];
        return (status: b == null ? 404 : 200, ct: 'text/html; charset=utf-8', body: b ?? '<html><body>Not found</body></html>', url: url);
      };
    });
    tearDown(() {
      FetchBrowser.getOverride = null;
      FetchBrowser.I.forget('j1');
    });

    test('parse: title, readable text, absolute deduped links (no #, javascript:, mailto:)', () {
      final p = FetchBrowser.parse(_home, 'https://shop.example/');
      expect(p.title, 'Shop news');
      expect(p.text, contains('red kettle costs 24 dollars'));
      expect(p.links.map((l) => l.url), ['https://shop.example/about', 'https://shop.example/kettles/red', 'https://other.example/review']);
      expect(p.note, isEmpty);
    });

    test('open → click a link number → find → back', () async {
      var v = await FetchBrowser.I.execute('j1', 'browser_open', {'url': 'shop.example/'});
      expect(v, contains('Read-only page'));
      expect(v, contains('[2] red kettle page → https://shop.example/kettles/red'));
      v = await FetchBrowser.I.execute('j1', 'browser_click', {'id': 2});
      expect(v, contains('Capacity 1.7 litres'));
      expect(got.last, 'https://shop.example/kettles/red');
      expect(await FetchBrowser.I.execute('j1', 'browser_find', {'text': 'warranty'}), contains('Warranty two years'));
      expect(await FetchBrowser.I.execute('j1', 'browser_find', {'text': 'bluetooth'}), contains('not on this page'));
      v = await FetchBrowser.I.execute('j1', 'browser_back', {});
      expect(v, contains('Prices this week'));
      expect(await FetchBrowser.I.execute('j1', 'browser_click', {'id': 99}), startsWith('Error: no link [99]'));
    });

    test('typing, sign-in and forms answer that they need SubMac open', () async {
      await FetchBrowser.I.execute('j1', 'browser_open', {'url': 'https://shop.example/'});
      for (final t in ['browser_type', 'browser_login', 'browser_select', 'browser_js', 'browser_upload']) {
        expect(await FetchBrowser.I.execute('j1', t, {}), contains('needs SubMac open'), reason: t);
      }
      final batch = await FetchBrowser.I.execute('j1', 'browser_act', {
        'actions': [
          {'action': 'click', 'id': 2},
          {'action': 'type', 'id': 3, 'text': 'x'},
        ]
      });
      expect(batch, contains('Capacity 1.7 litres'));
      expect(batch, contains('needs the real browser'));
    });

    test('blocked and script-only pages say so', () {
      final blocked = FetchBrowser.parse('<html><body>Just a moment... checking your browser</body></html>', 'https://x.example', status: 403);
      expect(blocked.note, contains('needs the real browser'));
      final shell = FetchBrowser.parse('<html><body><div id="root"></div>${'<script>var a=1;</script>' * 400}</body></html>', 'https://y.example');
      expect(shell.note, contains('scripts'));
    });
  });

  group('BrowserJobs with no screen', () {
    tearDown(() {
      BrowserAgent.noScreen = null;
      BrowserAgent.headlessStarter = null;
      BrowserAgent.I.headlessFailed = false;
      FetchBrowser.getOverride = null;
      BrowserJobs.I.runTool = null;
    });

    test('a step that cannot get a browser view switches the task to read-only mode and still answers', () async {
      BrowserAgent.noScreen = () => true;
      FetchBrowser.getOverride = (url) async => (status: 200, ct: 'text/html', body: _kettle, url: url);
      final j = BrowserJob('bx1', 'Check the kettle price', '', 'conv1', 20, unattended: true);
      BrowserJobs.I.runTool = (job, name, args, id) async => 'Error: Bad state: the browser view is not ready';
      final out = await BrowserJobs.I.ownToolForTest(j, 'browser_open', {'url': 'https://shop.example/kettles/red'});
      expect(j.fetchMode, isTrue);
      expect(BrowserAgent.I.headlessFailed, isTrue);
      expect(out, contains('READ-ONLY mode'));
      expect(out, contains('Price: 24 USD'));
      // From then on its browser steps never touch the real browser.
      var real = 0;
      BrowserJobs.I.runTool = (job, name, args, id) async {
        real++;
        return 'x';
      };
      expect(await BrowserJobs.I.ownToolForTest(j, 'browser_find', {'text': 'warranty'}), contains('Warranty two years'));
      expect(real, 0);
      expect(BrowserJobs.I.systemFor(j), contains('READ-ONLY MODE'));
    });

    test('with a screen the same error is the real browser\'s and is passed on as it is', () async {
      BrowserAgent.noScreen = () => false;
      final j = BrowserJob('bx2', 'g', '', 'conv1', 20);
      BrowserJobs.I.runTool = (job, name, args, id) async => 'Error: Bad state: the browser view is not ready';
      final out = await BrowserJobs.I.ownToolForTest(j, 'browser_open', {'url': 'https://a.example'});
      expect(j.fetchMode, isFalse);
      expect(out, 'Error: Bad state: the browser view is not ready');
    });

    test('a new task starts in read-only mode when the off-screen browser already failed this session', () async {
      BrowserAgent.noScreen = () => true;
      BrowserAgent.I.headlessFailed = true;
      BrowserJobs.I.runTool = (job, name, args, id) async => 'x';
      final r = await BrowserJobs.I.execute('browser_task', {'goal': 'Read the news', 'wait': false}, 'conv-ro');
      expect(r, contains('Started browser task'));
      final j = BrowserJobs.I.jobs.last;
      expect(j.fetchMode, isTrue);
      BrowserJobs.I.stop(j);
    });

    test('noBrowserView recognises the no-view failures only', () {
      expect(BrowserJobs.noBrowserView('Error: Bad state: the browser view is not ready'), isTrue);
      expect(BrowserJobs.noBrowserView('Error: TimeoutException after 0:00:20.000000: Future not completed'), isTrue);
      expect(BrowserJobs.noBrowserView('Error: Bad state: no screen: the off-screen browser could not start (x)'), isTrue);
      expect(BrowserJobs.noBrowserView('Error: no element [12] on the page'), isFalse);
      expect(BrowserJobs.noBrowserView('Opened https://a.example'), isFalse);
    });
  });

  group('BotBrowserModel: a bot\'s browser task on its own model', () {
    late ByokStore store;
    final submac = ModelRef(ProviderConfig(id: 'submac', name: 'SubMac', baseUrl: 'https://x', defaultModel: 'submac'), 'submac');
    setUp(() {
      ByokStore.I.resetForTests(
          ByokConfig(providers: [
            ByokProvider(id: 'byok-aaaa1111', kind: ByokKind.openaiCompatible, name: 'Mine', baseUrl: 'https://api.mine.example/v1', keys: [ByokKey(id: 'k-a', name: 'main', hint: 'wxyz')], models: [
              ByokModel(id: 'm-vision', vision: true, tools: true),
              ByokModel(id: 'm-text', vision: false),
              ByokModel(id: 'm-notools', tools: false),
            ]),
            ByokProvider(id: 'byok-bbbb2222', kind: ByokKind.anthropic, name: 'Claude', baseUrl: 'https://api.anthropic.com/v1', keys: [ByokKey(id: 'k-b', name: 'main', hint: 'wxyz')], models: [ByokModel(id: 'c1')]),
          ]),
          {'k-a': 'sk-aaaaaaaaaaaa', 'k-b': 'sk-bbbbbbbbbbbb'});
      store = ByokStore.I;
    });
    tearDown(() => ByokStore.I.resetForTests());

    Bot bot(String model) => Bot(id: 'b', name: 'Nova', role: '', persona: '', model: model);

    test('OpenAI-compatible key: the bot\'s own provider; a text-only model gets no screenshots', () {
      final a = BotBrowserModel.of(bot('byok-aaaa1111|m-vision'), submac, store: store);
      expect(a.onOwnModel, isTrue);
      expect(a.byok!.model.id, 'm-vision');
      expect(a.sees, isTrue);
      final t = BotBrowserModel.of(bot('byok-aaaa1111|m-text'), submac, store: store);
      expect(t.onOwnModel, isTrue);
      expect(t.sees, isFalse);
    });

    test('Anthropic key, or a model without tools: SubMac\'s model, with the reason', () {
      final a = BotBrowserModel.of(bot('byok-bbbb2222|c1'), submac, store: store);
      expect(a.onOwnModel, isFalse);
      expect(a.submac!.model, 'submac');
      expect(a.note, contains('Anthropic'));
      final n = BotBrowserModel.of(bot('byok-aaaa1111|m-notools'), submac, store: store);
      expect(n.onOwnModel, isFalse);
      expect(n.note, contains('no tool calling'));
    });

    test('no bot: SubMac\'s route as before', () {
      final a = BotBrowserModel.of(null, submac, store: store);
      expect(a.submac, same(submac));
      expect(a.note, isEmpty);
    });

    test('withoutImages drops picture parts only', () {
      final out = BotBrowserModel.withoutImages([
        {'role': 'system', 'content': 'rules'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'page'},
            {'type': 'image_url', 'image_url': {'url': 'data:...'}},
          ]
        },
      ]);
      expect(out[0]['content'], 'rules');
      expect(out[1]['content'], [
        {'type': 'text', 'text': 'page'}
      ]);
    });

    test('the tool-calling request and answer in the OpenAI shape', () {
      final p = store.providers.first;
      final r = ByokFetch.toolChatRequest(p, 'k-1', 'm-vision', [
        {'role': 'user', 'content': 'hi'}
      ], [
        {'type': 'function', 'function': {'name': 'browser_open', 'parameters': {}}}
      ], maxTokens: 100);
      expect(r.url.toString(), 'https://api.mine.example/v1/chat/completions');
      expect(r.headers['Authorization'], 'Bearer k-1');
      expect(r.body, contains('"tools"'));
      expect(r.body, contains('"stream":false'));
      final a = ByokFetch.toolChatAnswer({
        'choices': [
          {
            'message': {
              'content': 'Opening',
              'tool_calls': [
                {'id': 'c1', 'function': {'name': 'browser_open', 'arguments': '{"url":"https://a.example"}'}}
              ]
            },
            'finish_reason': 'tool_calls'
          }
        ],
        'usage': {'total_tokens': 120, 'prompt_tokens': 100, 'completion_tokens': 20}
      });
      expect(a.text, 'Opening');
      expect(a.calls.single, {'id': 'c1', 'name': 'browser_open', 'arguments': '{"url":"https://a.example"}'});
      expect(a.tokens, 120);
      expect(ByokFetch.toolChatOk(store.providers.last), isFalse);
      expect(() => ByokFetch.toolChatAnswer({'nope': 1}), throwsA(isA<ByokError>()));
    });

    test('byokStep turns the answer into the agent core\'s LlmResult (override seam)', () async {
      BotBrowserModel.stepOverride = (pick, msgs, tools) async => LlmResult('ok', [ToolCall(id: 'x', name: 'finish', arguments: '{}')], 'tool_calls', 9);
      addTearDown(() => BotBrowserModel.stepOverride = null);
      final pick = BotBrowserModel.of(bot('byok-aaaa1111|m-vision'), submac, store: store).byok!;
      final r = await BotBrowserModel.byokStep(pick, const [], const []);
      expect(r.toolCalls.single.name, 'finish');
      expect(r.tokens, 9);
    });
  });

  group('off-screen tabs (source checks: the plugin cannot run in a unit test)', () {
    final agent = File('lib/services/browser_agent.dart').readAsStringSync();
    final layer = File('lib/widgets/browser_layer.dart').readAsStringSync();
    final boot = File('android_native/BootReceiver.kt').readAsStringSync();

    test('a tab opened with no screen is a HeadlessInAppWebView with the same callbacks and the page script', () {
      expect(agent, contains('HeadlessInAppWebView('));
      expect(agent, contains('if (wantHeadless) {'));
      for (final cb in ['onWebViewCreated: (c) => onCreated(t, c)', 'onLoadStop: (c, u) => onLoadStop(t, u)', 'initialUserScripts: userScripts',
        'onJsConfirm:', 'onCreateWindow: (c, a) => onCreateWindow(a)', 'onDownloadStartRequest:']) {
        expect(agent, contains(cb), reason: cb);
      }
      expect(agent, contains('_disposeHeadless(tabs[i]);'), reason: 'a closed tab frees its off-screen view');
    });

    test('the browser layer never builds a second web view for an off-screen tab', () {
      expect(layer, contains('t.headless ? const SizedBox.shrink() : BrowserLayer.webViewBuilder(t)'));
    });

    test('BootReceiver re-arms after a restart when only missions are on', () {
      expect(boot, contains('flutter.missions_on_v1'));
      expect(boot, contains('missions.isNotEmpty()'));
    });
  });

  test('an off-screen tab that cannot start marks the session and removes the tab (test starter)', () async {
    BrowserAgent.noScreen = () => true;
    BrowserAgent.headlessStarter = (t) async => throw StateError('no webview provider');
    addTearDown(() {
      BrowserAgent.noScreen = null;
      BrowserAgent.headlessStarter = null;
      BrowserAgent.I.headlessFailed = false;
    });
    final out = await BrowserAgent.I.execute('browser_open', {'url': 'https://a.example'});
    expect(out, startsWith('Error:'));
    expect(BrowserJobs.noBrowserView(out), isTrue);
    expect(BrowserAgent.I.headlessFailed, isTrue);
    expect(BrowserAgent.I.tabs.where((t) => t.headless), isEmpty);
  });
}
