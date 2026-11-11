// Owner 2026-11-10: the row under the composer is three quiet pills — Model, Think · level, and one permission
// pill that only shows the choice when tapped. The level is Auto, Light or Deep; Auto sends no hint at all.
import 'dart:io';

import 'package:agent/services/thinking_level.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('three levels, one word each, and the names the engine uses', () {
    expect(Thinking.all.map(Thinking.word), ['Auto', 'Light', 'Deep']);
    expect(Thinking.effort(ThinkingLevel.auto), isNull, reason: 'Auto leaves it to the model');
    expect(Thinking.effort(ThinkingLevel.light), 'low');
    expect(Thinking.effort(ThinkingLevel.deep), 'high');
    expect(Thinking.variantFor(ThinkingLevel.deep), 'high', reason: 'opencode names its variants the same way');
  });

  test('the composer carries three pills, and the permission is one pill now', () {
    final src = File('lib/widgets/composer.dart').readAsStringSync();
    expect(src, contains('ModelPill(),'));
    expect(src, contains('ThinkingPill(),'));
    expect(src, contains('PermissionPill(),'));
    expect(src, contains("keyName: 'perm-pill'"), reason: 'one pill, the choice is asked for in a sheet');
    expect(src, isNot(contains("seg(tr('Autopilot')")), reason: 'two words are not always showing any more');
    expect(src, contains("keyName: 'think-pill'"));
  });

  test('the model pill says Model, not the whole model id', () {
    final src = File('lib/widgets/model_picker.dart').readAsStringSync();
    expect(src, contains("Text(tr('Model')"));
  });

  test('the variants come from the engine answer, weakest first', () {
    final body = {
      'all': [
        {'id': 'byok-openai', 'models': <String, dynamic>{}},
        {
          'id': 'byok-anthropic',
          'models': {
            'claude': {
              'variants': {'high': {}, 'low': {}, 'medium': {}},
            },
          },
        },
      ],
    };
    expect(Thinking.variantsIn(body, 'byok-anthropic', 'claude'), ['low', 'medium', 'high']);
    expect(Thinking.variantsIn(body, 'byok-openai', 'gpt'), isEmpty, reason: 'a model that does not think');
    expect(Thinking.variantsIn(null, 'byok-anthropic', 'claude'), isEmpty);
  });

  test('Light takes the weakest variant the model has, Deep the strongest; Auto sends none', () {
    expect(Thinking.pick(['low', 'medium', 'high'], ThinkingLevel.auto), isNull);
    expect(Thinking.pick(['low', 'medium', 'high'], ThinkingLevel.light), 'low');
    expect(Thinking.pick(['low', 'medium', 'high'], ThinkingLevel.deep), 'high');
    expect(Thinking.pick(const [], ThinkingLevel.deep), isNull, reason: 'nothing to send');
  });
}
