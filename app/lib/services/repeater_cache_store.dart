import 'dart:io';

import 'json_store.dart';

/// Where a cached value came from. The UI uses this alongside its timestamp.
class CacheSource {
  static const remote = 'remote';
  static const localEdit = 'local-edit';
  static const fleetAck = 'fleet-ack';
  static const stale = 'stale';
}

class CacheEntry {
  const CacheEntry({
    required this.value,
    required this.fetchedAt,
    required this.source,
  });

  final Object? value;
  final DateTime fetchedAt;
  final String source;

  factory CacheEntry.fromJson(Map<String, dynamic> json) => CacheEntry(
        value: json['value'],
        fetchedAt: json['fetchedAt'] is String
            ? DateTime.tryParse(json['fetchedAt'] as String) ??
                DateTime.fromMillisecondsSinceEpoch(0)
            : DateTime.fromMillisecondsSinceEpoch(0),
        source: json['source'] as String? ?? CacheSource.remote,
      );

  Map<String, dynamic> toJson() => {
        'value': value,
        'fetchedAt': fetchedAt.toIso8601String(),
        'source': source,
      };

  bool get isStale => source == CacheSource.stale;
}

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

/// Per-repeater cache of non-secret settings, status snapshots and samples.
/// Reads are synchronous from memory so opening a screen never touches the
/// mesh; every refresh is explicit.
class RepeaterCacheStore {
  RepeaterCacheStore(this.file, {this.persist = true});

  /// Keep a bounded history per metric: a year of daily points, or a long
  /// manual-refresh session. Older points are dropped, never silently kept.
  static const maxSamplesPerMetric = 720;

  final File file;

  /// In-memory mode for widget tests: real file I/O hangs the fake-async
  /// zone, but the same cache logic still applies.
  final bool persist;
  late final VersionedJsonStore _store = VersionedJsonStore(
    file,
    schema: 1,
    migrate: _migrate,
  );
  Map<String, dynamic> _values = {};
  List<MetricSample> _samples = [];

  Future<void> load() async {
    // In-memory mode keeps values written before load; there is no disk to
    // read them back from.
    if (!persist) return;
    final data = await _store.read() ?? const <String, dynamic>{};
    _values = Map<String, dynamic>.from(
        (data['values'] as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ??
            const {});
    _samples = ((data['samples'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => MetricSample.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  CacheEntry? read(String key) {
    final raw = _values[key];
    if (raw is! Map) return null;
    return CacheEntry.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<void> write(
    String key,
    Object value, {
    String source = CacheSource.remote,
    DateTime? at,
  }) async {
    _values[key] = CacheEntry(
      value: value,
      fetchedAt: at ?? DateTime.now(),
      source: source,
    ).toJson();
    await _persist();
  }

  /// Keep the last known value but mark it stale after a failed write or a
  /// firmware change, so the UI can ask for a refresh instead of claiming it
  /// is current.
  Future<void> markStale(String key) async {
    final entry = read(key);
    if (entry == null) return;
    _values[key] = CacheEntry(
      value: entry.value,
      fetchedAt: entry.fetchedAt,
      source: CacheSource.stale,
    ).toJson();
    await _persist();
  }

  /// A verified apply or rollback changed the running firmware: every cached
  /// value must be re-read and capabilities re-detected.
  Future<void> invalidateAll() async {
    _values.clear();
    await _persist();
  }

  List<MetricSample> samples(String metric) =>
      _samples.where((s) => s.metric == metric).toList()
        ..sort((a, b) => a.at.compareTo(b.at));

  Future<void> addSample(
    String metric,
    double value, {
    DateTime? at,
  }) async {
    _samples.add(MetricSample(metric, value, at ?? DateTime.now()));
    final perMetric = _samples.where((s) => s.metric == metric).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (perMetric.length > maxSamplesPerMetric) {
      final drop = perMetric
          .take(perMetric.length - maxSamplesPerMetric)
          .map((s) => s.at)
          .toSet();
      _samples.removeWhere((s) => s.metric == metric && drop.contains(s.at));
    }
    await _persist();
  }

  Future<void> _persist() async {
    if (!persist) return;
    await _store.write({
      'values': _values,
      'samples': _samples.map((s) => s.toJson()).toList(),
    });
  }

  Map<String, dynamic> _migrate(Map<String, dynamic> raw, int from) {
    // Schema 0 held bare values. Keep them, labelled as old remote reads.
    final old = (raw['values'] as Map?) ?? const {};
    final epoch = DateTime.fromMillisecondsSinceEpoch(0).toIso8601String();
    return {
      'values': old.map((key, value) => MapEntry(
            key.toString(),
            value is Map
                ? value
                : {'value': value, 'fetchedAt': epoch, 'source': 'remote'},
          )),
      'samples': raw['samples'] ?? const [],
    };
  }
}
