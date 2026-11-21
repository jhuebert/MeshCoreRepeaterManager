import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/repeater_cache_store.dart';
import 'package:meshcore_repeater_manager/services/stats_recorder.dart';
import 'package:repeater_core/repeater_core.dart';

void main() {
  test('a status report is recorded once per metric at the report time',
      () async {
    final dir = Directory.systemTemp.createTempSync('stats_recorder_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = RepeaterCacheStore(File('${dir.path}/cache.json'));
    await cache.load();
    final at = DateTime.utc(2026, 11, 21, 9);
    final status = RepeaterStatus(
      batteryMilliVolts: 3750,
      txQueueLength: 0,
      noiseFloor: -118,
      lastRssi: -70,
      packetsReceived: 10,
      packetsSent: 20,
      totalAirTimeSecs: 30,
      uptimeSecs: 600,
      sentFlood: 0,
      sentDirect: 0,
      recvFlood: 0,
      recvDirect: 0,
      errorEvents: 2,
      lastSnr: 6.0,
      directDuplicates: 0,
      floodDuplicates: 0,
      rxAirTimeSecs: 5,
      recvErrors: 0,
      fetchedAt: at,
    );

    await StatsRecorder(cache).recordStatus(status);

    expect(cache.samples('batteryMv').single.value, 3750);
    expect(cache.samples('batteryMv').single.at, at);
    expect(cache.samples('batteryPct').single.value, closeTo(50, 0.1));
    expect(cache.samples('errors').single.value, 2);
    expect(cache.samples('uptime').single.value, 600);
  });

  test('neighbour count is recorded as its own metric', () async {
    final dir = Directory.systemTemp.createTempSync('stats_neighbour_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = RepeaterCacheStore(File('${dir.path}/cache.json'));
    await cache.load();
    await StatsRecorder(cache).recordNeighbourCount(4);
    expect(cache.samples(neighbourCount.id).single.value, 4);
  });
}
