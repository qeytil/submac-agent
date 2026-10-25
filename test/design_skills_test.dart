import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/design_skills.dart';
import 'package:agent/services/site_check.dart';
import 'package:agent/services/skill_library.dart';

/// Owner, 2026-10-24: the agent sent "unfinished ugly broken websites". It now has design and output skills (knowledge
/// and process, never a fixed style), a hint that points website and UI requests at them, and an engine guard that
/// checks every page it wrote before the final reply.
const goodPage = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>Hodan Tailoring</title>\n'
    '<link rel="stylesheet" href="style.css">\n</head>\n<body>\n<header><nav><a href="#work">Work</a> <a href="#contact">Contact</a></nav></header>\n'
    '<main>\n<section id="work"><h1>Made to measure in Mogadishu</h1><img src="img/dress.webp" alt="A blue dress" width="600" height="400"></section>\n'
    '<section id="contact"><h2>Visit us</h2><p>Call [Your phone number]</p></section>\n</main>\n<script src="app.js"></script>\n</body>\n</html>\n';

void main() {
  group('built-in design skills', () {
    test('every skill is listed in the library and its body opens offline', () {
      for (final id in DesignSkills.ids) {
        expect(SkillLibrary.builtIn.any((s) => s.id == id), isTrue, reason: id);
        expect(SkillLibrary.builtInBody(id), isNotNull, reason: id);
        expect(SkillLibrary.builtInBody(id)!.length, greaterThan(600), reason: id);
      }
    });

    test('the library prompt names them as built in', () {
      final p = SkillLibrary.I.promptFor(SkillLibrary.agent);
      for (final id in [DesignSkills.webId, DesignSkills.uiId, DesignSkills.reviewId, DesignSkills.repliesId]) {
        expect(p, contains(id));
      }
    });

    test('search finds them by plain words', () {
      expect(SkillLibrary.I.search('landing page website').map((s) => s.id), contains(DesignSkills.webId));
      expect(SkillLibrary.I.search('dashboard ui').map((s) => s.id), contains(DesignSkills.uiId));
      expect(SkillLibrary.I.search('bar chart').map((s) => s.id), contains(DesignSkills.chartsId));
    });

    test('no hard-coded look: no hex colours, rgb values or named font families anywhere', () {
      final all = [...DesignSkills.bodies.values, DesignSkills.promptRule, DesignSkills.mediaRule];
      final hex = RegExp(r'#[0-9a-fA-F]{3,8}\b');
      final rgb = RegExp(r'\b(rgb|rgba|hsl|hsla)\(', caseSensitive: false);
      final fonts = RegExp(r'\b(Inter|Roboto|Helvetica|Arial|Georgia|Poppins|Montserrat|Lato|Open Sans|Playfair|Times New Roman|Geist)\b');
      for (final t in all) {
        expect(hex.hasMatch(t), isFalse, reason: hex.firstMatch(t)?.group(0));
        expect(rgb.hasMatch(t), isFalse);
        expect(fonts.hasMatch(t), isFalse, reason: fonts.firstMatch(t)?.group(0));
      }
    });

    test('the user decides: their choices win and directions are offered only when missing', () {
      final web = DesignSkills.bodyOf(DesignSkills.webId)!;
      expect(web, contains('followed exactly'));
      expect(web, contains('2-3 directions'));
      expect(web, contains('You choose'));
      expect(web, contains('Never offer the same three directions to everyone'));
      expect(DesignSkills.promptRule, contains('follow it exactly'));
    });

    test('the process ends with complete files, a check and one final reply', () {
      final web = DesignSkills.bodyOf(DesignSkills.webId)!;
      expect(web, contains('append_file'));
      expect(web, contains(DesignSkills.reviewId));
      expect(web, contains('Never call broken work finished'));
      final timing = DesignSkills.bodyOf(DesignSkills.timingId)!;
      expect(timing, contains('Final: exactly one'));
    });
  });

  group('design hint', () {
    const site = [
      'build me a website for my tailoring shop',
      'make a landing page for my app',
      'can you design a portfolio site',
      'fix my website, it looks broken on phones',
      'ii samee websaydh ganacsigayga',
    ];
    const ui = ['design the screens for my delivery app', 'make a dashboard for my sales', 'redesign the settings ui'];
    const neither = ['what is the weather in Hargeisa', 'send a message to Ahmed', 'translate this into Somali', 'hello'];
    for (final t in site) {
      test('site: $t', () {
        expect(DesignSkills.noteFor(t), contains(DesignSkills.webId));
      });
    }
    for (final t in ui) {
      test('ui: $t', () {
        expect(DesignSkills.noteFor(t), contains(DesignSkills.uiId));
      });
    }
    for (final t in neither) {
      test('none: $t', () {
        expect(DesignSkills.noteFor(t), isEmpty);
      });
    }
  });

  group('page check', () {
    test('a complete page passes, with the user spots noted', () {
      final (p, n) = SiteCheck.checkHtml('index.html', goodPage, exists: (_) => true);
      expect(p, isEmpty, reason: p.join('\n'));
      expect(n.join(' '), contains('[Your phone number]'));
    });

    test('a page cut off halfway is a problem', () {
      final cut = goodPage.substring(0, goodPage.indexOf('<section id="contact"'));
      final (p, _) = SiteCheck.checkHtml('index.html', cut, exists: (_) => true);
      expect(p.join(' '), contains('stops before its end'));
    });

    test('a page that ends inside a tag is a problem', () {
      final (p, _) = SiteCheck.checkHtml('index.html', '${goodPage.trim()}\n<div class="a', exists: (_) => true);
      expect(p.join(' '), contains('middle of a tag'));
    });

    test('missing pictures, styles and scripts are problems', () {
      final (p, _) = SiteCheck.checkHtml('index.html', goodPage, exists: (ref) => ref != 'img/dress.webp' && ref != 'app.js');
      final all = p.join(' ');
      expect(all, contains('img/dress.webp'));
      expect(all, contains('app.js'));
    });

    test('srcset and inline style url() files are checked too', () {
      final page = goodPage.replaceFirst('<main>', '<main style="background:url(img/bg.webp)"><img src="a.webp" srcset="a.webp 1x, a2.webp 2x" alt="a" width="1" height="1">');
      final (p, _) = SiteCheck.checkHtml('index.html', page, exists: (ref) => !ref.contains('bg.webp') && ref != 'a2.webp');
      expect(p.join(' '), allOf(contains('img/bg.webp'), contains('a2.webp')));
    });

    test('links to a section that does not exist are problems', () {
      final (p, _) = SiteCheck.checkHtml('index.html', goodPage.replaceFirst('href="#work"', 'href="#prices"'), exists: (_) => true);
      expect(p.join(' '), contains('#prices'));
    });

    test('lorem ipsum, a missing title or viewport are problems', () {
      final page = goodPage
          .replaceFirst('<title>Hodan Tailoring</title>', '')
          .replaceFirst('<meta name="viewport" content="width=device-width, initial-scale=1">', '')
          .replaceFirst('Visit us', 'Lorem ipsum dolor sit amet');
      final (p, _) = SiteCheck.checkHtml('index.html', page, exists: (_) => true);
      final all = p.join(' ');
      expect(all, contains('lorem'));
      expect(all, contains('<title>'));
      expect(all, contains('viewport'));
    });

    test('"rest of the code here" gaps are problems', () {
      final (p, _) = SiteCheck.checkHtml('index.html', goodPage.replaceFirst('</main>', '<!-- rest of the sections here -->\n</main>'),
          exists: (_) => true);
      expect(p.join(' '), contains('gap'));
    });

    test('css: cut-off rules are problems, wide fixed widths without @media are notes', () {
      expect(SiteCheck.checkCss('style.css', '.a { color: red; .b { width: 10px; }').join(), contains('braces'));
      expect(SiteCheck.checkCss('style.css', '.wrap { width: 1200px; }').join(), contains('overflow'));
      expect(SiteCheck.checkCss('style.css', '.wrap { max-width: 1200px; }'), isEmpty);
      expect(SiteCheck.checkCss('style.css', '.wrap { width: 1200px; } @media (max-width: 600px) { .wrap { width: 100%; } }'), isEmpty);
    });

    test('a whole site folder on disk: passes when complete, fails on a missing file', () async {
      final dir = await Directory.systemTemp.createTemp('site_check');
      try {
        await Directory('${dir.path}/img').create();
        await File('${dir.path}/index.html').writeAsString(goodPage);
        await File('${dir.path}/style.css').writeAsString('body { margin: 0; } .hero { background: url(img/dress.webp); }');
        await File('${dir.path}/app.js').writeAsString('document.querySelectorAll("a").forEach((a) => { a.dataset.ok = "1"; });');
        await File('${dir.path}/img/dress.webp').writeAsBytes([1, 2, 3]);
        final ok = await SiteCheck.run('${dir.path}/index.html');
        expect(ok.ok, isTrue, reason: ok.text);
        expect(ok.files, 3);
        await File('${dir.path}/img/dress.webp').delete();
        final bad = await SiteCheck.run('${dir.path}/index.html');
        expect(bad.ok, isFalse);
        expect(bad.text, contains('img/dress.webp'));
        // A page alone in a shared folder goes online by itself: its local files would not.
        final alone = await SiteCheck.run('${dir.path}/index.html', alone: true);
        expect(alone.text, contains('shared folder'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('a page that was never written is a problem', () async {
      final r = await SiteCheck.run('/nope/sites/x/index.html');
      expect(r.ok, isFalse);
    });

    test('inline page cards: only real breakage counts', () {
      expect(SiteCheck.inlinePage(goodPage), isEmpty);
      expect(SiteCheck.inlinePage(goodPage.substring(0, 200)), isNotEmpty);
    });
  });

  group('site gate', () {
    test('passes a good page at once', () {
      expect(SiteGate.decide(ok: true, fixes: 0, explained: false), SiteStep.pass);
    });

    test('sends a broken page back to be fixed, at most twice', () {
      expect(SiteGate.decide(ok: false, fixes: 0, explained: false), SiteStep.fix);
      expect(SiteGate.decide(ok: false, fixes: 1, explained: false), SiteStep.fix);
      expect(SiteGate.decide(ok: false, fixes: 2, explained: false), SiteStep.explain);
    });

    test('after the fixes run out, the final reply must say what still fails, then it may go', () {
      expect(SiteGate.decide(ok: false, fixes: 2, explained: true), SiteStep.pass);
      final r = SiteReport('index.html', problems: ['index.html: missing file "a.png"'], files: 1);
      expect(SiteGate.explainNote(r), contains('what still does not work'));
      expect(SiteGate.fixNote(r), contains('a.png'));
      expect(SiteGate.fixNote(r), contains('Do not send the final reply'));
    });

    test('finds the page card in a reply', () {
      expect(SiteGate.pageBlock('Here it is.\n\n```page\n<html></html>\n```'), '<html></html>');
      expect(SiteGate.pageBlock('No card here.'), isNull);
    });
  });
}
