// "Always on" (owner 2026-11-08): the steady foreground service and the few-minute local pulse that keeps the digital
// people present and catches a heartbeat the OS killed and never redelivered. The Android side is mocked: these tests
// only check what the app asks the native layer to do, and when a wake is (not) fired.
//
// Run: flutter test test/always_on_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/services/always_on.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/system_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Docs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Docs(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late List<(String, Map<String, dynamic>?)> calls;
  late AppState s;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('alwayson');
    PathProviderPlatform.instance = _Docs(tmp.path);
    await Bots.I.init();
    AlwaysOn.I.debugSet(true);
    calls = [];
    SystemBridge.debugCalls = (m, a) => calls.add((m, a));
    s = AppState();
    s.repo.testUserId = 'u1';
  });

  tearDown(() async {
    SystemBridge.debugCalls = null;
    Bots.I.bots.removeWhere((x) => x.id.startsWith('ao'));
    Bots.I.onWake = null;
    AlwaysOn.I.debugSet(true);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('on: a finished run turns the service-off into the steady line, not off', () async {
    await SystemBridge.I.keepAlive(false);
    final c = calls.single;
    expect(c.$1, 'keepAlive');
    expect(c.$2!['on'], isTrue);
    expect(c.$2!['text'], AlwaysOn.body);
  });

  test('off: a finished run really turns the service off', () async {
    AlwaysOn.I.debugSet(false);
    await SystemBridge.I.keepAlive(false);
    expect(calls.single.$2!['on'], isFalse);
  });

  test('on: a running line still goes through as given', () async {
    await SystemBridge.I.keepAlive(true, text: 'Nova · Hourly news');
    expect(calls.single.$2!['text'], 'Nova · Hourly news');
  });

  test('a pulse wakes a heartbeat the OS missed, and never one that already ran', () async {
    final woke = <String>[];
    Bots.I.onWake = (bot, reason, ins, kind) async => woke.add(reason);
    final b = Bot(id: 'ao1', name: 'Nova', role: 'Researcher', persona: '')
      ..active = true
      ..heartbeatHours = 6
      ..convId = 'conv-ao1';
    Bots.I.bots.add(b);

    // Not due: the exact alarm fired recently.
    b.lastWake = DateTime.now().subtract(const Duration(hours: 1));
    await s.alwaysOnTickForTest();
    expect(woke, isEmpty);

    // The exact alarm was killed and never redelivered: the pulse catches it.
    b.lastWake = DateTime.now().subtract(const Duration(hours: 7));
    await s.alwaysOnTickForTest();
    expect(woke, ['heartbeat']);

    // Every pulse still re-asserts the steady line, whether or not a wake fired.
    expect(calls.where((c) => c.$1 == 'keepAlive').last.$2!['text'], AlwaysOn.body);
  });

  test('a pulse never wakes a bot with no heartbeat or one that is quiet', () async {
    final woke = <String>[];
    Bots.I.onWake = (bot, reason, ins, kind) async => woke.add(reason);
    final b = Bot(id: 'ao2', name: 'Nova', role: 'Researcher', persona: '')
      ..active = true
      ..heartbeatHours = 0
      ..convId = 'conv-ao2';
    Bots.I.bots.add(b);
    b.lastWake = DateTime.now().subtract(const Duration(days: 3));
    await s.alwaysOnTickForTest();
    expect(woke, isEmpty);
  });
}
