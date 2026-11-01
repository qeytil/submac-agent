import 'dart:convert';

import 'package:agent/services/forged_tools.dart';
import 'package:agent/services/web_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// Core loop v3, part 2 (owner 2026-11-01: "never useless and dumb"): the agent can search without a key on more than
/// one engine, research in one call, and make its own tools when no tool fits.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('keyless search engines', () {
    test('Bing: link around the h2, click-through links decoded, captions kept', () {
      final real = base64Url.encode(utf8.encode('https://www.britannica.com/place/Somalia')).replaceAll('=', '');
      const page = '<ol id="b_results">'
          '<li class="b_algo" data-id><div class="b_tpcn"><a class="tilk" href="https://en.wikipedia.org/wiki/Somalia" h="ID=1">'
          '<div class="tpic"></div></a></div><a href="https://en.wikipedia.org/wiki/Somalia" h="ID=2"><h2><strong>Somalia</strong> - '
          'Wikipedia</h2></a><div class="b_caption"><p class="b_lineclamp3">Somalia has an estimated population over 19 million.</p></div></li>';
      final page2 = '<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;u=a1$real&amp;ntb=1">Somalia | '
          'Britannica</a></h2><div class="b_caption"><p>Map, religion, currency.</p></div></li></ol>';
      final r = WebTools.parseBing('$page$page2', 6);
      expect(r.length, 2);
      expect(r[0]['url'], 'https://en.wikipedia.org/wiki/Somalia');
      expect(r[0]['title'], 'Somalia - Wikipedia');
      expect(r[0]['snippet'], contains('19 million'));
      expect(r[1]['url'], 'https://www.britannica.com/place/Somalia');
    });

    test('Brave: each data-type="web" block gives its link, title and snippet', () {
      const page = '<div data-type="web" data-keynav="true"><div class="result-content"><a href="https://www.unfpa.org/data/world-population/SO" '
          'class="l1"><div class="site-name">UNFPA</div></a><div class="title search-snippet-title line-clamp-1">Somalia Population 2025 - UNFPA</div>'
          '<div class="snippet-description">Total Population (2025): <strong>19,700,000</strong></div></div></div>'
          '<div data-type="web"><a href="https://search.brave.com/settings">x</a></div>';
      final r = WebTools.parseBraveHtml(page, 6);
      expect(r.length, 1, reason: 'a Brave-internal link is not a result');
      expect(r[0]['url'], 'https://www.unfpa.org/data/world-population/SO');
      expect(r[0]['title'], 'Somalia Population 2025 - UNFPA');
      expect(r[0]['snippet'], contains('19,700,000'));
    });
  });

  group('research keeps the passages that answer the question', () {
    test('key terms drop the small words', () {
      expect(WebTools.keyTerms('What is the population of Somalia in 2025?'), containsAll(['population', 'somalia', '2025']));
      expect(WebTools.keyTerms('What is the population of Somalia?'), isNot(contains('the')));
    });
    test('the matching paragraphs, in page order, within the budget', () {
      final text = [
        'Cookie settings and newsletter sign-up for our readers everywhere.',
        'Somalia is a country in the Horn of Africa with a long coastline on the Indian Ocean.',
        'The population of Somalia was estimated at 19.7 million in 2025 by the UN Population Fund.',
        'Related articles and more stories you may like from around the region today.',
      ].join('\n\n');
      final p = WebTools.bestPassages(text, WebTools.keyTerms('population of Somalia 2025'), 2000);
      expect(p, contains('19.7 million'));
      expect(p, isNot(contains('Cookie settings')));
      expect(p.indexOf('Horn of Africa'), lessThan(p.indexOf('19.7 million')), reason: 'page order is kept');
    });
    test('nothing matching falls back to the start of the page', () {
      final p = WebTools.bestPassages('A long first paragraph about something else entirely, really.', ['zebra'], 100);
      expect(p, startsWith('A long first paragraph'));
    });
    test('web_research is a tool the model can call', () {
      expect(WebTools.names, contains('web_research'));
      final def = WebTools.definitions.firstWhere((d) => (d['function'] as Map)['name'] == 'web_research');
      expect(((def['function'] as Map)['parameters'] as Map)['required'], ['question']);
    });
  });

  group('the agent makes its own tools', () {
    test('tool_make is offered, and own tools are named my_<name> with their own schema', () {
      expect(ForgedTools.definitions.single['function']['name'], 'tool_make');
      final t = ForgedTool(name: 'vat_total', description: 'Adds VAT to a price.', language: 'python', code: 'print(ARGS["p"]*1.2)',
          params: {'p': {'type': 'number'}}, required: ['p']);
      final d = t.definition()['function'] as Map;
      expect(d['name'], 'my_vat_total');
      expect((d['parameters'] as Map)['required'], ['p']);
      expect(d['description'], contains('your own tool'));
    });
    test('a saved tool survives a restart unchanged', () {
      final t = ForgedTool(name: 'csv_sum', description: 'Sums a CSV column.', language: 'shell', code: 'echo "\$ARGS"', uses: 4, version: 2);
      final back = ForgedTool.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      expect([back.name, back.language, back.code, back.uses, back.version], [t.name, t.language, t.code, 4, 2]);
    });
    test('shell tools get their inputs as \$ARGS, quotes escaped', () {
      final cmd = ForgedTools.shellCommand('echo "\$ARGS"', jsonEncode({'q': "it's"}));
      expect(cmd, startsWith("export ARGS='{\"q\":\"it'\\''s\"}'"));
      expect(cmd, endsWith('echo "\$ARGS"'));
    });
    test('a bad name is refused before anything is saved', () async {
      final r = await ForgedTools.execute('tool_make', {'action': 'save', 'name': 'Bad Name!', 'language': 'python', 'code': 'print(1)'});
      expect(r, startsWith('Error: name must be'));
    });
    test('an unknown my_ tool is not handled', () => expect(ForgedTools.handles('my_nothing_here'), isFalse));
  });
}
