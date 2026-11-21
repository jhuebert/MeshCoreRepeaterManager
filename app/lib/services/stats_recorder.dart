import 'package:repeater_core/repeater_core.dart';

import 'repeater_cache_store.dart';

/// Turns the reports the app already fetches into chart samples. Recording is
/// a side effect of an explicit refresh, never of opening a screen.
class StatsRecorder {
  StatsRecorder(this.cache);

  final RepeaterCacheStore cache;

  Future<void> recordStatus(RepeaterStatus status) async {
    for (final entry in statusMetricValues(status).entries) {
      await cache.addSample(entry.key, entry.value, at: status.fetchedAt);
    }
  }

  Future<void> recordNeighbourCount(int count) async {
    await cache.addSample(neighbourCount.id, count.toDouble());
  }
}
