import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../services/repeater_cache_store.dart';
import '../../services/stats_recorder.dart';
import '../../theme.dart';
import '../../widgets/charts/metric_chart.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Trends from cached samples. Opening this screen sends no mesh traffic; a
/// refresh is explicit, and automatic refresh is opt-in and bounded.
class StatsChartsScreen extends StatefulWidget {
  const StatsChartsScreen({super.key, this.cli, this.cache});

  final CliService? cli;
  final RepeaterCacheStore? cache;

  @override
  State<StatsChartsScreen> createState() => _StatsChartsScreenState();
}

class _StatsChartsScreenState extends State<StatsChartsScreen> {
  static const _ranges = <(String, Duration?)>[
    ('1 h', Duration(hours: 1)),
    ('24 h', Duration(hours: 24)),
    ('7 d', Duration(days: 7)),
    ('All', null),
  ];
  static const _maxAutoRefreshes = 12;
  static const _autoInterval = Duration(seconds: 60);
  static const _maxChartPoints = 300;

  String _metricId = 'batteryMv';
  int _range = 1;
  List<MetricSample> _samples = [];
  bool _busy = false;
  bool _autoRefresh = false;
  int _autoDone = 0;
  Timer? _timer;

  List<MetricSpec> get _metrics => [...statusMetrics, neighbourCount];
  MetricSpec get _metric => metricFor(_metricId) ?? statusMetrics.first;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final cache = widget.cache ?? context.read<AppState>().cacheForTarget();
    if (cache == null) return;
    await cache.load();
    if (!mounted) return;
    setState(() => _samples = _visible(cache.samples(_metricId)));
  }

  List<MetricSample> _visible(List<MetricSample> all) {
    final range = _ranges[_range].$2;
    final inRange =
        range == null ? all : samplesSince(all, range, now: DateTime.now());
    return downsample(inRange, maxPoints: _maxChartPoints);
  }

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    final target = app.target;
    final cache = widget.cache ?? app.cacheForTarget();
    if (cli == null || target == null || cache == null || _busy) return;
    setState(() => _busy = true);
    final status = await cli.status(target);
    if (status != null) await StatsRecorder(cache).recordStatus(status);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _samples = _visible(cache.samples(_metricId));
    });
  }

  void _setAutoRefresh(bool enabled) {
    setState(() {
      _autoRefresh = enabled;
      _autoDone = 0;
    });
    _timer?.cancel();
    if (!enabled) return;
    _timer = Timer.periodic(_autoInterval, (timer) {
      if (_autoDone >= _maxAutoRefreshes) {
        timer.cancel();
        if (mounted) setState(() => _autoRefresh = false);
        return;
      }
      _autoDone++;
      _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final last = _samples.isEmpty ? null : _samples.last.at;
    return ManagementScaffold(
      title: 'Statistics',
      onRefresh: _refresh,
      refreshing: _busy,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Trends come from readings you took earlier. Nothing is fetched '
            'just by opening this screen.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: DropdownButton<String>(
            value: _metricId,
            isExpanded: true,
            items: [
              for (final spec in _metrics)
                DropdownMenuItem(value: spec.id, child: Text(spec.label)),
            ],
            onChanged: (id) async {
              if (id == null) return;
              setState(() => _metricId = id);
              await _load();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: [
              for (var i = 0; i < _ranges.length; i++)
                ButtonSegment(value: i, label: Text(_ranges[i].$1)),
            ],
            selected: {_range},
            onSelectionChanged: (s) async {
              setState(() => _range = s.first);
              await _load();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(_metric.description,
              style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: MetricChart(metric: _metric, samples: _samples),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: last == null
              ? const LastKnownLabelPlaceholder()
              : LastKnownLabel(last, prefix: 'Last reading'),
        ),
        const SectionHeader('Samples'),
        if (_samples.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('No readings in this range yet.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          ),
        for (final sample in _samples.reversed.take(10))
          InfoRow(
            label: _timeLabel(sample.at),
            value: _metric.format(sample.value),
          ),
        const SectionHeader('Automatic refresh'),
        SwitchListTile(
          title: const Text('Refresh every minute'),
          subtitle: Text(
            _autoRefresh
                ? 'Stops after $_maxAutoRefreshes refreshes. $_autoDone done.'
                : 'Off by default. Needs the companion connected.',
          ),
          value: _autoRefresh,
          onChanged: _setAutoRefresh,
        ),
      ],
    );
  }

  static String _timeLabel(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}

/// Shown when there is nothing on screen to date.
class LastKnownLabelPlaceholder extends StatelessWidget {
  const LastKnownLabelPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => const Text(
        'No reading yet',
        style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
      );
}
