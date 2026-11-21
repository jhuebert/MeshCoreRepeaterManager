import 'dart:async';

import 'package:flutter/foundation.dart';

/// A job waiting for its device-clock due time. The app must be running for
/// this to fire; device-side `!at` is the RAM-only alternative.
class ScheduledFleetJob {
  const ScheduledFleetJob({
    required this.id,
    required this.script,
    required this.dueAt,
    this.tags = const [],
  });

  final String id;
  final String script;
  final DateTime dueAt;
  final List<String> tags;

  Map<String, dynamic> toJson() => {
        'id': id,
        'script': script,
        'dueAt': dueAt.toIso8601String(),
        'tags': tags,
      };

  factory ScheduledFleetJob.fromJson(Map<String, dynamic> json) =>
      ScheduledFleetJob(
        id: json['id'] as String,
        script: json['script'] as String,
        dueAt: DateTime.tryParse(json['dueAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        tags: (json['tags'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// Timer-based queue with a bounded number of due checks. Persisted through
/// [save] so a restart keeps pending jobs.
class FleetScheduler {
  FleetScheduler({
    required this.save,
    required this.onDue,
    this.onQueueChanged,
    this.tick = const Duration(seconds: 10),
  });

  final Future<void> Function(List<ScheduledFleetJob>) save;
  final Future<void> Function(ScheduledFleetJob) onDue;
  final Duration tick;

  /// Notified whenever the queue becomes active or empty. The app uses this
  /// to hold a foreground service while a scheduled job is still pending.
  final Future<void> Function(bool active)? onQueueChanged;

  final List<ScheduledFleetJob> _jobs = [];
  Timer? _timer;
  int _checks = 0;

  static const maxChecks = 360; // one hour at the default tick

  List<ScheduledFleetJob> get jobs => List.unmodifiable(_jobs);

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(tick, (_) => _check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> load(List<ScheduledFleetJob> jobs) async {
    _jobs
      ..clear()
      ..addAll(jobs);
    if (_jobs.isNotEmpty && onQueueChanged != null) await onQueueChanged!(true);
  }

  Future<void> schedule(ScheduledFleetJob job) async {
    if (_jobs.isEmpty && onQueueChanged != null) await onQueueChanged!(true);
    _jobs.removeWhere((j) => j.id == job.id);
    _jobs.add(job);
    await save(_jobs);
  }

  Future<void> cancel(String id) async {
    _jobs.removeWhere((j) => j.id == id);
    await save(_jobs);
    if (_jobs.isEmpty && onQueueChanged != null) await onQueueChanged!(false);
  }

  Future<void> _check() async {
    if (_checks >= maxChecks) {
      stop();
      if (_jobs.isEmpty && onQueueChanged != null) await onQueueChanged!(false);
      return;
    }
    _checks++;
    final now = DateTime.now();
    final due = _jobs.where((j) => !j.dueAt.isAfter(now)).toList();
    for (final job in due) {
      await onDue(job);
      _jobs.removeWhere((j) => j.id == job.id);
    }
    if (due.isNotEmpty) await save(_jobs);
    if (due.isNotEmpty && _jobs.isEmpty && onQueueChanged != null) {
      await onQueueChanged!(false);
    }
  }

  /// Visible for tests with a fake scheduler clock.
  @visibleForTesting
  Future<void> checkNow() => _check();
}
