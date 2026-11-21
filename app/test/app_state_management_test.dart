import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/ack_collector.dart';
import 'package:meshcore_repeater_manager/services/fleet_scheduler.dart';
import 'package:meshcore_repeater_manager/services/fleet_store.dart';
import 'package:meshcore_repeater_manager/services/management_audit_store.dart';
import 'package:meshcore_repeater_manager/services/repeater_directory.dart';
import 'package:meshcore_repeater_manager/services/secret_store.dart';

import 'support.dart';

void main() {
  test('a remembered fleet key is restored into the session', () async {
    final backend = MemorySecretBackend();
    await backend.write(SecretField.fleetPsk.storageKey, 'stored-psk');
    final app = AppState();
    app.secretBackendFactory = () => backend;
    await app.initSecretStore();
    expect(app.secretStore, isNotNull);
    expect(app.secretStore!.isRemembered(SecretField.fleetPsk), isTrue);
    expect(app.fleetPsk, 'stored-psk');
  });

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

  test('an interrupted identity change is finished on startup', () async {
    final dir = Directory.systemTemp.createTempSync('resume_identity_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final directory = RepeaterDirectory(dir);
    await directory.load();
    await File('${dir.path}/index.json').writeAsString(jsonEncode({
      'schema': 1,
      'profiles': [
        {
          'publicKeyHex': 'aa' * 32,
          'name': 'Roof',
          'tags': [],
        }
      ],
      'pendingIdentity': {'old': 'aa' * 32, 'new': 'ee' * 32},
    }));
    await directory.load();
    final app = AppState();
    app.directory = directory;
    await app.resumeIdentityMigration();
    expect(directory.get('ee' * 32)!.name, 'Roof');
    expect(app.log.any((line) => line.contains('interrupted identity change')),
        isTrue);
  });

  test('a due scheduled job is tracked, audited and given an ACK window',
      () async {
    final dir = Directory.systemTemp.createTempSync('due_job_test');
    addTearDown(() {
      dir.deleteSync(recursive: true);
    });
    final link = FakeDeviceLink();
    final app = AppState();
    app.connection.attachForTest(link, CompanionClient(link));
    app.fleetPsk = '11' * 16;
    await app.initFleetServices(dir);

    await app.fleetScheduler!.schedule(ScheduledFleetJob(
      id: 'job-due',
      script: '!id job-due\nver',
      dueAt: DateTime.now().subtract(const Duration(seconds: 1)),
      tags: const ['north'],
    ));
    await app.fleetScheduler!.checkNow();

    expect(link.transmitted, hasLength(1));
    expect(app.ackCollector.export().single.id, 'job-due');
    expect(app.ackCollector.export().single.tags, ['north']);
    expect(app.backgroundGuard.reasons, contains('ack:job-due'));
    await app.flushFleetHistory();
    await app.closeAckWindow('job-due');
    app.fleetScheduler!.stop();
  });

  test('a recovered ACK and its job are persisted for the next launch',
      () async {
    final dir = Directory.systemTemp.createTempSync('ack_persist_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState();
    await app.initFleetServices(dir);
    app.fleetScheduler!.stop();

    await app.trackFleetJob(FleetJobResult(
        id: 'job-9', script: '!id job-9\nver', sentAt: DateTime.now()));
    expect(app.ackCollector.handleText('Roof', 'job-9 OK'), isTrue);
    await app.flushFleetHistory();

    final reopened = FleetStore(File('${dir.path}/fleet.json'));
    await reopened.load();
    expect(reopened.history, hasLength(1));
    expect(reopened.history.single.acks['Roof']!.output, 'OK');
    expect(reopened.history.single.id, 'job-9');
  });

  test('an ACK window is held and released by job id', () async {
    final app = AppState();
    await app.openAckWindow('job-1');
    expect(app.backgroundGuard.reasons, contains('ack:job-1'));
    await app.openAckWindow('job-2');
    expect(app.backgroundGuard.reasons, {'ack:job-1', 'ack:job-2'});
    await app.closeAckWindow('job-1');
    expect(app.backgroundGuard.reasons, {'ack:job-2'});
    await app.closeAckWindow('job-1'); // idempotent
    await app.closeAckWindow('job-2');
    expect(app.backgroundGuard.reasons, isEmpty);
  });

  test('an ACK window closes itself when the reply window expires', () async {
    final app = AppState();
    app.ackWindow = const Duration(milliseconds: 1);
    await app.openAckWindow('job-expired');
    expect(app.backgroundGuard.reasons, contains('ack:job-expired'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(app.backgroundGuard.reasons, isEmpty);
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
