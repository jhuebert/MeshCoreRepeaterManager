import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/services/ack_collector.dart';
import 'package:meshcore_repeater_manager/services/fleet_scheduler.dart';
import 'package:meshcore_repeater_manager/services/fleet_sender.dart';
import 'package:meshcore_repeater_manager/services/fleet_store.dart';
import 'package:repeater_core/repeater_core.dart';

Uint8List ackFrame(String text, {String sender = 'Roof'}) {
  final bytes = utf8.encode('$sender: $text');
  return Uint8List.fromList([
    respCodeChannelMsgRecvV3,
    20,
    0,
    0,
    1,
    0xFF,
    0,
    1,
    2,
    3,
    4,
    ...bytes,
    0,
  ]);
}

void main() {
  group('AckCollector', () {
    test('matches a channel frame to a pending job', () {
      final collector = AckCollector();
      collector.track(FleetJobResult(
          id: 'job-1', script: '!id job-1\nver', sentAt: DateTime.now()));
      expect(collector.handleFrame(ackFrame('job-1 OK')), isTrue);
      final job = collector.history.single;
      expect(job.acks['Roof']!.ok, isTrue);
      expect(job.acks['Roof']!.output, 'OK');
    });

    test('an ACK for an unknown job is ignored', () {
      final collector = AckCollector();
      expect(collector.handleFrame(ackFrame('other OK')), isFalse);
      expect(collector.history, isEmpty);
    });

    test('decoded text can be fed from the post-login drain', () {
      final collector = AckCollector();
      collector.track(FleetJobResult(
          id: 'job-2', script: '!id job-2', sentAt: DateTime.now()));
      expect(collector.handleText('Hill', 'job-2 ran 2 ok'), isTrue);
      expect(collector.history.single.acks['Hill']!.ok, isTrue);
    });

    test('history is bounded to 100 jobs', () {
      final collector = AckCollector();
      for (var i = 0; i < 105; i++) {
        collector.track(
            FleetJobResult(id: 'job-$i', script: 'x', sentAt: DateTime.now()));
      }
      expect(collector.history, hasLength(100));
      expect(collector.export().first.id, 'job-104');
    });
  });

  group('FleetStore', () {
    test('roundtrips history and queue without secrets', () async {
      final dir = Directory.systemTemp.createTempSync('fleet_store_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/fleet.json');
      final store = FleetStore(file);
      await store.load();
      final result = FleetJobResult(
          id: 'job-1',
          script: '!id job-1\nver',
          sentAt: DateTime.utc(2026, 11, 21));
      result.acks['Roof'] = FleetAck(
          jobId: 'job-1',
          sender: 'Roof',
          output: 'OK',
          ok: true,
          at: DateTime.utc(2026, 11, 21));
      await store.saveHistory([result]);
      await store.saveQueue([
        ScheduledFleetJob(
                id: 'job-2', script: 'x', dueAt: DateTime.utc(2026, 11, 22))
            .toJson()
      ]);

      final reopened = FleetStore(file);
      await reopened.load();
      expect(reopened.history.single.acks['Roof']!.output, 'OK');
      expect(reopened.queue.single['id'], 'job-2');
      expect(store.export(), isNot(contains('psk')));
    });
  });

  group('FleetScheduler', () {
    test('schedules, cancels and fires due jobs once', () async {
      final saved = <List<ScheduledFleetJob>>[];
      final fired = <String>[];
      final scheduler = FleetScheduler(
        save: (jobs) async => saved.add(List.of(jobs)),
        onDue: (job) async => fired.add(job.id),
      );
      await scheduler.schedule(ScheduledFleetJob(
          id: 'now',
          script: 'x',
          dueAt: DateTime.now().subtract(const Duration(seconds: 1))));
      await scheduler.checkNow();
      expect(fired, ['now']);
      expect(scheduler.jobs, isEmpty);
      await scheduler.schedule(ScheduledFleetJob(
          id: 'later',
          script: 'y',
          dueAt: DateTime.now().add(Duration(days: 1))));
      await scheduler.checkNow();
      expect(fired, ['now']); // 'later' is not due
      await scheduler.cancel('later');
      expect(scheduler.jobs, isEmpty);
    });
  });

  group('FleetSender', () {
    test('rejects a bad PSK without touching the link', () async {
      final link = FakeDeviceLink();
      final sender = FleetSender(link: link, pskHex: 'not-hex');
      expect(sender.hasKey, isFalse);
      expect(() => sender.send('!id x\nver'), throwsA(isA<FormatException>()));
      expect(link.transmitted, isEmpty);
    });

    test('sends one group text packet with a valid PSK', () async {
      final link = FakeDeviceLink();
      final sender = FleetSender(link: link, pskHex: '11' * 16);
      expect(sender.hasKey, isTrue);
      await sender.send('!id job-1\nver');
      expect(link.transmitted, hasLength(1));
    });
  });
}
