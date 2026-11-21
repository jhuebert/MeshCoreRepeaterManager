import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:device_link/device_link.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/repeater_directory.dart';

import 'support.dart';

void main() {
  test('management services need a link, client and target', () {
    final app = AppState();
    expect(app.managementCli(), isNull);
    expect(app.cacheForTarget(), isNull);
    expect(app.canWrite, isFalse);
  });

  test('a connected app exposes one serialized management gateway', () async {
    final dir = Directory.systemTemp.createTempSync('app_mgmt_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState();
    app.tcpLinkFactory = (_, __) => FakeDeviceLink();
    await app.connectTcp(host: '127.0.0.1', port: 5000);
    app.target = contact('Roof');
    app.directory = RepeaterDirectory(dir);
    await app.directory!.load();

    expect(app.managementCli(), isNotNull);
    expect(app.cacheForTarget(), isNotNull);
    expect(app.connectionPhase, ConnectionPhase.connected);

    app.loginPermission = 2;
    expect(app.canWrite, isTrue);
    await app.disconnect();
  });
}
