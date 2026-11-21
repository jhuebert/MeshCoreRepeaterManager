import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:device_link/device_link.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/ack_collector.dart';
import 'package:meshcore_repeater_manager/services/fleet_scheduler.dart';
import 'package:meshcore_repeater_manager/services/management_audit_store.dart';
import 'package:meshcore_repeater_manager/services/repeater_directory.dart';

import 'support.dart';

void main() {
  test('fleet stores and scheduler initialize from a support directory',
      () async {
    final dir = Directory.systemTemp.createTempSync('fleet_init_test');
    addTearDown(() {
      dir.deleteSync(recursive: true);
    });
    final app = AppState();
    await app.initFleetServices(dir);
    expect(app.fleetStore, isNotNull);
    expect(app.fleetScheduler, isNotNull);
    // A due job exercises both the save closure and the send callback; with
    // no link it safely does nothing.
    await app.fleetScheduler!.schedule(ScheduledFleetJob(
        id: 'job-1', script: '!id job-1\nver', dueAt: DateTime.now()));
    await app.fleetScheduler!.checkNow();
    expect(app.fleetScheduler!.jobs, isEmpty);
    app.fleetScheduler!.stop();
  });

  test('fleet helpers are safe before a link or audit store exists', () async {
    final app = AppState();
    await app.recordFleetSend('job-0', '!id job-0\nver');
    await app.resendFleetJob(FleetJobResult(
        id: 'job-0', script: '!id job-0\nver', sentAt: DateTime.now()));
  });

  test('management services need a link, client and target', () {
    final app = AppState();
    expect(app.managementCli(), isNull);
    expect(app.cacheForTarget(), isNull);
    expect(app.canWrite, isFalse);
  });

  test('fleet sends are audited and resent with the same script', () async {
    final dir = Directory.systemTemp.createTempSync('fleet_app_state_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState();
    app.tcpLinkFactory = (_, __) => FakeDeviceLink();
    await app.connectTcp(host: '127.0.0.1', port: 5000);
    app.target = contact('Roof');
    app.auditStore = ManagementAuditStore(File('${dir.path}/audit.json'));
    await app.auditStore!.load();
    app.fleetPsk = '11' * 16;

    await app.recordFleetSend('job-1', '!id job-1\nver');
    expect(app.auditStore!.entries().single.family, 'fleet');

    final result = FleetJobResult(
        id: 'job-1', script: '!id job-1\nver', sentAt: DateTime.now());
    await app.resendFleetJob(result);
    expect(app.connection.link, isNotNull);
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
