import 'dart:typed_data';

import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

RepeaterStatus _status(
        {int battery = 4100, int errors = 0, int uptime = 100}) =>
    RepeaterStatus(
      batteryMilliVolts: battery,
      txQueueLength: 0,
      noiseFloor: -118,
      lastRssi: -70,
      packetsReceived: 10,
      packetsSent: 20,
      totalAirTimeSecs: 30,
      uptimeSecs: uptime,
      sentFlood: 0,
      sentDirect: 0,
      recvFlood: 0,
      recvDirect: 0,
      errorEvents: errors,
      lastSnr: 6.0,
      directDuplicates: 0,
      floodDuplicates: 0,
      rxAirTimeSecs: 5,
      recvErrors: 0,
      fetchedAt: DateTime.utc(2026, 11, 21),
    );

void main() {
  group('metric registry', () {
    test('every status metric has a spec', () {
      for (final spec in statusMetrics) {
        expect(metricFor(spec.id), same(spec));
        expect(spec.label, isNotEmpty);
      }
      expect(metricFor('neighbours'), neighbourCount);
      expect(metricFor('nope'), isNull);
    });

    test('battery percent is a clamped estimate', () {
      expect(estimateBatteryPercent(3300), 0);
      expect(estimateBatteryPercent(4200), 100);
      expect(estimateBatteryPercent(5000), 100);
      expect(estimateBatteryPercent(2000), 0);
      expect(estimateBatteryPercent(3750), closeTo(50, 0.1));
    });

    test('specs format with their unit', () {
      expect(metricFor('batteryMv')!.format(4100), '4100 mV');
      expect(metricFor('snr')!.format(6.0), '6.0 dB');
    });
  });

  group('status conversion', () {
    test('one report becomes one sample per metric', () {
      final values = statusMetricValues(_status(battery: 3750, errors: 2));
      expect(values, hasLength(statusMetrics.length));
      expect(values['batteryMv'], 3750);
      expect(values['batteryPct'], closeTo(50, 0.1));
      expect(values['errors'], 2);
      expect(values['snr'], 6.0);
    });
  });

  group('sample helpers', () {
    MetricSample sample(String id, double value, int minute) =>
        MetricSample(id, value, DateTime.utc(2026, 11, 21, 12, minute));

    test('downsample keeps the newest points', () {
      final samples = [
        for (var i = 0; i < 10; i++) sample('batteryMv', i.toDouble(), i)
      ];
      final kept = downsample(samples, maxPoints: 3);
      expect(kept.map((s) => s.value), [7.0, 8.0, 9.0]);
      expect(downsample(samples, maxPoints: 20), hasLength(10));
    });

    test('samplesSince honours the range and sorts oldest first', () {
      final samples = [
        sample('batteryMv', 1, 0),
        sample('batteryMv', 2, 30),
        sample('batteryMv', 3, 55),
      ];
      final window = samplesSince(samples, const Duration(minutes: 40),
          now: DateTime.utc(2026, 11, 21, 12, 55));
      expect(window.map((s) => s.value), [2.0, 3.0]);
    });

    test('json roundtrip keeps timestamp and value', () {
      final s = sample('batteryMv', 4100, 5);
      final copy = MetricSample.fromJson(s.toJson());
      expect(copy.metric, s.metric);
      expect(copy.value, s.value);
      expect(copy.at, s.at);
    });
  });
}
