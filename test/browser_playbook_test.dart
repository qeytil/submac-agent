// Site skills (P3, browser-godmode): a flow that worked once replays with no model calls per step.
// Signatures are kind + label + href, never coordinates; the first mismatch hands the job back to the agent.
import 'dart:convert';
import 'dart:io';

import 'package:agent/services/browser/page_model.dart';
import 'package:agent/services/browser/playbook.dart';
import 'package:agent/services/browser/site_skills.dart';
import 'package:flutter_test/flutter_test.dart';

PageElement el(int id, String kind, String label, {String href = ''}) =>
    PageElement(id: id, kind: kind, label: label, href: href);

void main() {
  group('PlayStep', () {
    test('JSON round-trips and keeps the signature', () {
      final s = PlayStep(act: 'type', kind: 'field(text)', label: 'Search', value: 'flights', submit: true);
      final back = PlayStep.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map);
      expect(back, isNotNull);
      expect(back!.act, 'type');
      expect(back.kind, 'field(text)');
      expect(back.label, 'Search');
      expect(back.value, 'flights');
      expect(back.submit, isTrue);
      expect(PlayStep.fromJson(const {}), isNull, reason: 'a step with no act is not a step');
    });

    test('the line a person reads names the control and the value', () {
      expect(PlayStep(act: 'click', kind: 'button', label: 'Place order').line, 'click button "Place order"');
      expect(PlayStep(act: 'type', kind: 'field(text)', label: 'Email', value: 'a@b.c').line, contains('type into field "Email"'));
      expect(PlayStep(act: 'select', kind: 'dropdown', label: 'Size', value: 'Large').line, contains('choose "Large"'));
      expect(PlayStep(act: 'scroll', value: 'down').line, 'scroll down');
    });
  });

  group('resolveStep', () {
    final els = [
      el(1, 'button', 'Search'),
      el(2, 'button', 'Search'),
      el(3, 'link', 'Search', href: 'https://shop.test/search'),
      el(4, 'field(text)', 'Search'),
      el(5, 'button', 'Place order'),
    ];

    test('matches the same kind and label, in order', () {
      final step = PlayStep(act: 'click', kind: 'button', label: 'Search');
      expect(resolveStep(step, els)!.id, 1);
      expect(resolveStep(PlayStep(act: 'click', kind: 'button', label: 'Search', nth: 1), els)!.id, 2);
    });

    test('a field step never lands on a button with the same words', () {
      expect(resolveStep(PlayStep(act: 'type', kind: 'field(text)', label: 'Search'), els)!.id, 4);
      expect(resolveStep(PlayStep(act: 'type', kind: 'field(text)', label: 'Place order'), els), isNull);
    });

    test('falls back to a partial label, then to the href', () {
      final loose = [el(9, 'button', 'Search flights and hotels')];
      expect(resolveStep(PlayStep(act: 'click', kind: 'button', label: 'Search flights'), loose)!.id, 9);
      final byHref = [el(7, 'link', 'Go', href: 'https://shop.test/search')];
      expect(resolveStep(PlayStep(act: 'click', kind: 'link', label: 'Something else', href: 'https://shop.test/search'), byHref)!.id, 7);
    });

    test('nothing on the page means null: the agent takes over', () {
      expect(resolveStep(PlayStep(act: 'click', kind: 'button', label: 'Buy now'), els), isNull);
    });
  });

  group('compressSteps', () {
    test('drops what cannot be replayed and collapses repeated scrolls', () {
      final steps = compressSteps([
        {'do': 'click', 'k': 'button', 't': 'Search'},
        {'do': 'scroll', 'v': 'down'},
        {'do': 'scroll', 'v': 'down'},
        {'do': 'type', 'k': 'field(text)', 't': 'Search', 'v': ''},
        {'do': 'click', 'k': 'button', 't': ''},
        {'do': 'type', 'k': 'field(text)', 't': 'Search', 'v': 'shoes'},
        {'do': 'tap_at', 'v': '50,50'},
      ]);
      expect(steps.length, 3, reason: 'click, one scroll, one type');
      expect(steps[0].label, 'Search');
      expect(steps[1].act, 'scroll');
      expect(steps[2].value, 'shoes');
    });

    test('caps the list and never keeps a password', () {
      final steps = compressSteps([
        {'do': 'type', 'k': 'field(password)', 't': 'Password', 'v': 'hunter2'},
        for (var i = 0; i < 60; i++) {'do': 'click', 'k': 'button', 't': 'Next $i'},
      ], cap: 10);
      expect(steps.length, 10);
      expect(steps.any((s) => s.kind.contains('password')), isFalse);
    });
  });

  test('withValues replaces typed values by label or by step number', () {
    final steps = [
      PlayStep(act: 'type', kind: 'field(text)', label: 'From', value: 'Nairobi'),
      PlayStep(act: 'type', kind: 'field(text)', label: 'To', value: 'Hargeisa'),
      PlayStep(act: 'click', kind: 'button', label: 'Search'),
    ];
    final v = withValues(steps, {'from': 'Mogadishu', '2': 'Dubai'});
    expect(v[0].value, 'Mogadishu');
    expect(v[1].value, 'Dubai');
    expect(v[2].act, 'click', reason: 'a click has no value to replace');
    expect(withValues(steps, const {})[0].value, 'Nairobi');
  });

  test('Playbook JSON round-trips and reads as a skill the user can understand', () {
    final p = Playbook(id: 'book-a-hotel', name: 'Book a hotel', site: 'shop.test', goal: 'when the user needs a room',
        steps: [PlayStep(act: 'type', kind: 'field(text)', label: 'City', value: 'Hargeisa')], runs: 3, wins: 2);
    final back = Playbook.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map);
    expect(back, isNotNull);
    expect(back!.id, 'book-a-hotel');
    expect(back.steps.single.label, 'City');
    expect(back.runs, 3);
    expect(p.readable, contains('# Book a hotel'));
    expect(p.readable, contains('type into field "City"'));
    expect(Playbook.fromJson(const {'id': 'x', 'steps': []}), isNull, reason: 'a playbook with no steps is not a skill');
    expect(playbookId('Book a flight!'), 'book-a-flight');
  });

  group('SiteSkills storage', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('sm_skills');
      SiteSkills.I.setDirForTest(dir);
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Playbook book(String id, String site, {String name = 'A flow'}) =>
        Playbook(id: id, name: name, site: site, steps: [PlayStep(act: 'click', kind: 'button', label: 'Go')]);

    test('saves, lists and forgets', () async {
      expect(await SiteSkills.I.save(book('one', 'shop.test')), isNull);
      expect(await SiteSkills.I.save(book('two', 'www.bank.test')), isNull);
      final all = await SiteSkills.I.all();
      expect(all.length, 2);
      expect(await SiteSkills.I.byId('one'), isNotNull);
      expect(await SiteSkills.I.byId('nope'), isNull);
      await SiteSkills.I.forget('one');
      expect((await SiteSkills.I.all()).length, 1);
    });

    test('host matching ignores www and accepts subdomains', () async {
      await SiteSkills.I.save(book('shop', 'shop.test'));
      await SiteSkills.I.save(book('bank', 'bank.test'));
      expect((await SiteSkills.I.forHost('www.shop.test')).single.id, 'shop');
      expect((await SiteSkills.I.forHost('shop.test')).single.id, 'shop');
      expect((await SiteSkills.I.forHost('m.bank.test')).single.id, 'bank');
      expect(await SiteSkills.I.forHost('other.test'), isEmpty);
    });

    test('a replay is counted: runs, and wins only when the agent never took over', () async {
      await SiteSkills.I.save(book('flow', 'shop.test'));
      // Each replay starts by loading the skill, as browser_play does — never a stale in-memory copy.
      await SiteSkills.I.bump((await SiteSkills.I.byId('flow'))!, win: true);
      await SiteSkills.I.bump((await SiteSkills.I.byId('flow'))!, win: false);
      final after = (await SiteSkills.I.byId('flow'))!;
      expect(after.runs, 2);
      expect(after.wins, 1);
    });

    test('a save with no steps is refused, so the list never holds an empty skill', () async {
      final empty = Playbook(id: 'none', name: 'Nothing', site: 'shop.test', steps: const []);
      expect(await SiteSkills.I.save(empty), isNotNull);
      expect(await SiteSkills.I.all(), isEmpty);
    });
  });
}
