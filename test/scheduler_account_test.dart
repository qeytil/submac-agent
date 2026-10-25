import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agent/services/system_tools.dart';

// ISSUES T-03: scheduled tasks belong to the account, never to the phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("account A's scheduled prompt never runs under account B", () async {
    SharedPreferences.setMockInitialValues({});
    final s = Scheduler.forTest();
    final ran = <String>[];
    s.runTask = (t) async => ran.add(t.task);
    await s.init(uid: 'user-a');
    final when = DateTime.now().add(const Duration(hours: 1)).toIso8601String();
    await s.add('A secret prompt', when, 'daily');
    final id = s.tasks.single.id;
    expect(s.tasks.single.uid, 'user-a');

    // A signs out: nothing is loaded, and the alarm firing runs nothing.
    await s.useAccount('');
    expect(s.tasks, isEmpty);
    await s.fire(id);
    expect(ran, isEmpty);
    expect(s.describe(), 'No scheduled tasks.');
    expect((await s.add('x', when, 'none')).startsWith('Error'), isTrue);

    // B signs in on the same phone: A's task is not B's and never runs.
    await s.useAccount('user-b');
    expect(s.tasks, isEmpty);
    await s.fire(id);
    expect(ran, isEmpty);

    // A signs back in: A's task is loaded again and runs for A.
    await s.useAccount('user-a');
    expect(s.tasks.map((t) => t.task), ['A secret prompt']);
    await s.fire(id);
    expect(ran, ['A secret prompt']);
  });

  test('untagged tasks move to the first signed-in account', () async {
    final next = DateTime.now().add(const Duration(hours: 2)).toIso8601String();
    SharedPreferences.setMockInitialValues({
      'scheduled': '[{"id":"s1","task":"old","next":"$next","repeat":"none"}]',
    });
    final s = Scheduler.forTest();
    await s.init(uid: 'user-a');
    expect(s.tasks.single.uid, 'user-a');
    await s.useAccount('user-b');
    expect(s.tasks, isEmpty);
  });
}
