import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/wifi_connector.dart';

void main() {
  test('manual connector always reports unavailable', () async {
    const connector = ManualWifiConnector();
    expect(await connector.supported, isFalse);
    expect(await connector.join('MeshCore-OTA'), WifiJoinResult.unavailable);
  });

  test('fake connector records the requested network', () async {
    final connector = FakeWifiConnector();
    expect(await connector.supported, isTrue);
    expect(await connector.join('MeshCore-OTA'), WifiJoinResult.joined);
    expect(connector.joined, ['MeshCore-OTA']);
  });

  test('denied and unavailable results are reported, never thrown', () async {
    expect(await FakeWifiConnector(result: WifiJoinResult.denied).join('x'),
        WifiJoinResult.denied);
    expect(
        await FakeWifiConnector(result: WifiJoinResult.unavailable).join('x'),
        WifiJoinResult.unavailable);
  });

  test('platform connector refuses an empty name before shelling out',
      () async {
    var called = 0;
    final connector = PlatformWifiConnector(
      runner: (_, __) async {
        called++;
        throw StateError('should not run');
      },
    );
    expect(await connector.join('  '), WifiJoinResult.denied);
    expect(called, 0);
  });

  test('platform connector maps exit codes to outcomes', () async {
    final calls = <(String, List<String>)>[];
    for (final platform in [
      (true, false, false),
      (false, true, false),
      (false, false, true),
    ]) {
      final connector = PlatformWifiConnector(
        isLinux: platform.$1,
        isMacOS: platform.$2,
        isWindows: platform.$3,
        runner: (executable, arguments) async {
          calls.add((executable, arguments));
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(await connector.supported, isTrue);
      expect(await connector.join('MeshCore-OTA'), WifiJoinResult.joined);
    }
    expect(calls, hasLength(3));
    for (final call in calls) {
      expect(call.$1, isNotEmpty);
      expect(call.$2.join(' '), contains('MeshCore-OTA'));
    }
    final denied = PlatformWifiConnector(
      isLinux: true,
      runner: (_, __) async => ProcessResult(0, 1, '', 'not found'),
    );
    expect(await denied.join('MeshCore-OTA'), WifiJoinResult.denied);
    final missing = PlatformWifiConnector(
      isLinux: true,
      runner: (_, __) => throw 'no tool',
    );
    expect(await missing.join('MeshCore-OTA'), WifiJoinResult.unavailable);
  });

  test('the default runner launches a process', () async {
    await defaultProcessRunner(Platform.resolvedExecutable, ['--version']);
  });
}
