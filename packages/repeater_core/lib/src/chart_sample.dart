// Chart data model and conversions. Pure Dart: the app decides colours and
// widgets, the codec package owns what a metric means and how it is sampled.

import 'status.dart';

class MetricSample {
  const MetricSample(this.metric, this.value, this.at);

  final String metric;
  final double value;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'metric': metric,
        'value': value,
        'at': at.toIso8601String(),
      };

  factory MetricSample.fromJson(Map<String, dynamic> json) => MetricSample(
        json['metric'] as String,
        (json['value'] as num).toDouble(),
        DateTime.tryParse(json['at'] as String) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class MetricSpec {
  const MetricSpec(
    this.id,
    this.label,
    this.unit,
    this.description, {
    this.decimals = 0,
  });

  final String id;
  final String label;
  final String unit;
  final String description;
  final int decimals;

  String format(double value) => '${value.toStringAsFixed(decimals)}$unit';
}

/// Metrics recorded from the binary status report, in display order.
const statusMetrics = <MetricSpec>[
  MetricSpec('batteryMv', 'Battery voltage', ' mV',
      'Reported by the repeater. Around 3.3 V is empty, 4.2 V is full.'),
  MetricSpec('batteryPct', 'Battery charge', '%',
      'An estimate from the reported voltage, not a fuel gauge.'),
  MetricSpec('snr', 'Last signal to noise', ' dB',
      'Signal quality of the last packet the repeater received.',
      decimals: 1),
  MetricSpec('noiseFloor', 'Noise floor', ' dBm', 'Background radio noise.'),
  MetricSpec('packetsRecv', 'Packets received', '',
      'Total since the repeater booted.'),
  MetricSpec(
      'packetsSent', 'Packets sent', '', 'Total since the repeater booted.'),
  MetricSpec('txAirtime', 'TX airtime', ' s', 'Total transmit time.'),
  MetricSpec('rxAirtime', 'RX airtime', ' s', 'Total receive time.'),
  MetricSpec('errors', 'Error events', '', 'Radio error events since boot.'),
  MetricSpec('uptime', 'Uptime', ' s', 'Time since the repeater booted.'),
];

/// Neighbour count is recorded from the paged neighbours query.
const MetricSpec neighbourCount = MetricSpec('neighbours', 'Neighbours', '',
    'Known neighbours, recorded when the list is refreshed.');

MetricSpec? metricFor(String id) {
  for (final m in statusMetrics) {
    if (m.id == id) return m;
  }
  if (id == neighbourCount.id) return neighbourCount;
  return null;
}

/// A rough lithium-cell estimate. The repeater reports voltage only.
double estimateBatteryPercent(int milliVolts) {
  const empty = 3300;
  const full = 4200;
  final pct = (milliVolts - empty) * 100 / (full - empty);
  return pct.clamp(0, 100).toDouble();
}

/// One status report becomes one sample per metric, all at the same time.
Map<String, double> statusMetricValues(RepeaterStatus status) =>
    <String, double>{
      'batteryMv': status.batteryMilliVolts.toDouble(),
      'batteryPct': estimateBatteryPercent(status.batteryMilliVolts),
      'snr': status.lastSnr,
      'noiseFloor': status.noiseFloor.toDouble(),
      'packetsRecv': status.packetsReceived.toDouble(),
      'packetsSent': status.packetsSent.toDouble(),
      'txAirtime': status.totalAirTimeSecs.toDouble(),
      'rxAirtime': status.rxAirTimeSecs.toDouble(),
      'errors': status.errorEvents.toDouble(),
      'uptime': status.uptimeSecs.toDouble(),
    };

/// Keep at most [maxPoints], preferring the newest samples. Called before a
/// chart is drawn so old data never grows without bound.
List<MetricSample> downsample(
  List<MetricSample> samples, {
  required int maxPoints,
}) {
  if (samples.length <= maxPoints) return List.unmodifiable(samples);
  return List.unmodifiable(samples.sublist(samples.length - maxPoints));
}

/// Samples at or after [now] minus [range], oldest first.
List<MetricSample> samplesSince(
  List<MetricSample> samples,
  Duration range, {
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(range);
  return samples.where((s) => !s.at.isBefore(cutoff)).toList()
    ..sort((a, b) => a.at.compareTo(b.at));
}
