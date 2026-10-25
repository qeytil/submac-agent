import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/tool_scope.dart';

Map<String, dynamic> _t(String name) => {
      'type': 'function',
      'function': {'name': name, 'description': '', 'parameters': {}},
    };

void main() {
  group('ToolScope: only the tools a message needs', () {
    test('a plain question opens no gated group', () {
      expect(ToolScope.hinted('What is the capital of Kenya?'), isEmpty);
    });

    test('messages point at the right groups', () {
      expect(ToolScope.hinted('Book me a hotel in Nairobi'), contains(ToolScope.browser));
      expect(ToolScope.hinted('Remind me tomorrow at 7'), contains(ToolScope.schedule));
      expect(ToolScope.hinted('Make a PDF invoice'), contains(ToolScope.files));
      expect(ToolScope.hinted('Draw a logo for my shop'), contains(ToolScope.media));
      expect(ToolScope.hinted('When is maghrib today?'), contains(ToolScope.life));
      expect(ToolScope.hinted('Check my gmail inbox'), contains(ToolScope.apps));
      expect(ToolScope.hinted('Build me a website for my cafe'), contains(ToolScope.files));
      expect(ToolScope.hinted('Code a small game in javascript'), contains(ToolScope.files));
    });

    test('attachments open files; a connected app name opens apps', () {
      expect(ToolScope.hinted('look at this', attachments: true), contains(ToolScope.files));
      expect(ToolScope.hinted('add it to Todoist please', appNames: ['Todoist']), contains(ToolScope.apps));
    });

    test('unknown and core tools are always sent; gated ones only when open', () {
      final tools = [_t('web_search'), _t('remember'), _t('browser_task'), _t('schedule_task'), _t('my_custom_tool')];
      final none = ToolScope.filter(tools, {});
      final names = none.map((t) => (t['function'] as Map)['name']).toList();
      expect(names, containsAll(['web_search', 'remember', 'my_custom_tool']));
      expect(names, isNot(contains('browser_task')));
      expect(names, isNot(contains('schedule_task')));
      final withBrowser = ToolScope.filter(tools, {ToolScope.browser}).map((t) => (t['function'] as Map)['name']).toList();
      expect(withBrowser, contains('browser_task'));
      expect(ToolScope.filter(tools, {}, all: true).length, tools.length);
    });

    test('order is kept so the prompt prefix stays stable', () {
      final tools = [_t('a'), _t('browser_task'), _t('b')];
      final f = ToolScope.filter(tools, {ToolScope.browser});
      expect(f.map((t) => (t['function'] as Map)['name']).toList(), ['a', 'browser_task', 'b']);
    });

    test('closed groups are named in plain words', () {
      final line = ToolScope.closedLine({ToolScope.browser});
      expect(line, isNot(contains('the browser')));
      expect(line, contains('scheduled tasks'));
      expect(ToolScope.closedLine(ToolScope.groups.toSet()), isEmpty);
    });
  });
}
