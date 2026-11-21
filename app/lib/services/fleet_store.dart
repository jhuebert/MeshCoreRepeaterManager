import 'dart:convert';
import 'dart:io';

import 'ack_collector.dart';
import 'json_store.dart';

/// Persisted queue and result history. No PSK or credentials are stored.
class FleetStore {
  FleetStore(this.file, {this.persist = true});

  final File file;

  /// In-memory mode for widget tests; real I/O stalls the fake-async zone.
  final bool persist;
  late final VersionedJsonStore _store = VersionedJsonStore(
    file,
    schema: 1,
    migrate: (raw, from) => {
      'history': raw['history'] ?? const [],
      'queue': raw['queue'] ?? const [],
    },
  );
  List<FleetJobResult> _history = [];
  List<Map<String, dynamic>> _queue = [];

  Future<void> load() async {
    if (!persist) return;
    final data = await _store.read() ?? const <String, dynamic>{};
    _history = ((data['history'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => FleetJobResult.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    _queue = ((data['queue'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<FleetJobResult> get history => List.unmodifiable(_history);
  List<Map<String, dynamic>> get queue => List.unmodifiable(_queue);

  Future<void> saveHistory(List<FleetJobResult> history) async {
    _history = List.of(history.take(AckCollector.maxHistory));
    await _persist();
  }

  Future<void> saveQueue(List<Map<String, dynamic>> queue) async {
    _queue = List.of(queue);
    await _persist();
  }

  String export() => const JsonEncoder.withIndent('  ')
      .convert(_history.map((r) => r.toJson()).toList());

  Future<void> _persist() async {
    if (!persist) return;
    await _store.write({
      'history': _history.map((r) => r.toJson()).toList(),
      'queue': _queue,
    });
  }
}
