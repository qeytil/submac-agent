import 'dart:io';

import 'package:agent/services/apk_build.dart';
import 'package:agent/services/skill_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('skill_save stores, refuses collisions, and reads back as a skill', () async {
    final dir = await Directory.systemTemp.createTemp('skill_lib_test');
    SkillLibrary.I.setDirForTest(dir);
    addTearDown(() async => dir.delete(recursive: true));
    final lib = SkillLibrary.I;
    const target = SkillLibrary.agent;

    // Too short to reuse: refused with a reason.
    expect(await lib.save(target, id: 'tiny', name: 'Tiny', desc: 'd', body: 'short'), isNotNull);
    // A library id is taken: refused.
    expect(await lib.save(target, id: ApkBuild.skillId, name: 'x', desc: 'd', body: 'a body that is long enough for the check'), isNotNull);

    // Saved (the messy id is cleaned), listed, installed and readable.
    final e = await lib.save(target, id: 'CV to PDF!', name: 'CV to PDF', desc: 'Turns a CV text file into a PDF', tags: ['cv', 'pdf'],
        body: '1. read the file\n2. code_run the script\n3. check the output pdf');
    expect(e, isNull);
    final s = lib.byId('cv-to-pdf');
    expect(s, isNotNull);
    expect(s!.local, isTrue);
    expect(s.cat, 'mine');
    expect(lib.has(target, 'cv-to-pdf'), isTrue);
    expect(await lib.body('cv-to-pdf'), contains('code_run'));
    expect(lib.search('cv pdf').map((x) => x.id), contains('cv-to-pdf'));

    // A local id can be overwritten (the update wins, version bumps, still local).
    expect(await lib.save(target, id: 'cv-to-pdf', name: 'CV to PDF', desc: 'updated', body: 'now with steps two and three checked twice'), isNull);
    expect(lib.byId('cv-to-pdf')!.v, 2);
    expect(lib.byId('cv-to-pdf')!.local, isTrue);
    // skill_use reads it back like any other skill.
    final r = await lib.execute('skill_use', {'id': 'cv-to-pdf'}, target);
    expect(r, contains('Skill: CV to PDF'));
  });
}
