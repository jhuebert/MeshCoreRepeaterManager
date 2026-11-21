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

/// Status and owner facts. One binary status request replaces a dozen CLI get
/// calls; values come from the cache on open and are refreshed explicitly.
class RepeaterStatusScreen extends StatefulWidget {
  const RepeaterStatusScreen({super.key, this.cli, this.cache});

  final CliService? cli;
  final RepeaterCacheStore? cache;

  @override
  State<RepeaterStatusScreen> createState() => _RepeaterStatusScreenState();
}

class _RepeaterStatusScreenState extends State<RepeaterStatusScreen> {
  static const _statusKey = 'status';
  static const _ownerKey = 'owner';

  RepeaterStatus? _status;
  DateTime? _statusAt;
  OwnerInfo? _owner;
  DateTime? _ownerAt;
  bool _busy = false;
  String? _problem;
  Map<String, List<MetricSample>> _samples = {};

  @override
  void initState() {
    super.initState();
    _loadCache();
  }

  Future<void> _loadCache() async {
    final cache = widget.cache ?? context.read<AppState>().cacheForTarget();
    if (cache == null) return;
    await cache.load();
    final status = cache.read(_statusKey);
    final owner = cache.read(_ownerKey);
    final samples = <String, List<MetricSample>>{
      for (final spec in [...statusMetrics, neighbourCount])
        spec.id: downsample(cache.samples(spec.id), maxPoints: 40),
    };
    if (!mounted) return;
    setState(() {
      if (status?.value is Map) {
        _status = RepeaterStatus.fromJson(
            Map<String, dynamic>.from(status!.value as Map));
        _statusAt = status.fetchedAt;
      }
      if (owner?.value is Map) {
        final m = Map<String, dynamic>.from(owner!.value as Map);
        _owner = OwnerInfo(m['version'] as String? ?? '',
            m['name'] as String? ?? '', m['owner'] as String? ?? '');
        _ownerAt = owner.fetchedAt;
      }
      _samples = samples;
    });
  }

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    final target = app.target;
    final cache = widget.cache ?? app.cacheForTarget();
    if (cli == null || target == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final status = await cli.status(target);
    final owner = await cli.owner(target);
    if (status != null) {
      await cache?.write(_statusKey, status.toJson());
      if (cache != null) await StatsRecorder(cache).recordStatus(status);
    }
    if (owner != null) {
      await cache?.write(_ownerKey, {
        'version': owner.version,
        'name': owner.name,
        'owner': owner.owner,
      });
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (status != null) {
        _status = status;
        _statusAt = DateTime.now();
      }
      if (owner != null) {
        _owner = owner;
        _ownerAt = DateTime.now();
      }
      if (status == null && owner == null) {
        _problem = 'No answer from the repeater. Outcome unknown; try again.';
      }
    });
    await _loadCache();
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return ManagementScaffold(
      title: 'Status',
      onRefresh: _refresh,
      refreshing: _busy,
      children: [
        if (_problem != null) ErrorBanner(_problem!),
        const SectionHeader('Repeater'),
        if (s == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('No status has been read yet. Tap refresh.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          )
        else ...[
          RefreshableValue(
              label: 'Battery',
              value: '${s.batteryMilliVolts} mV',
              fetchedAt: _statusAt),
          Padding(
            padding: const EdgeInsets.fromLTRB(134, 0, 16, 4),
            child: MetricSparkline(
                metricId: 'batteryMv', samples: _samples['batteryMv'] ?? []),
          ),
          RefreshableValue(
              label: 'Uptime',
              value:
                  '${s.uptimeSecs ~/ 3600} h ${(s.uptimeSecs % 3600) ~/ 60} min',
              fetchedAt: _statusAt),
          RefreshableValue(
              label: 'Signal to noise',
              value: '${s.lastSnr.toStringAsFixed(1)} dB',
              fetchedAt: _statusAt),
          RefreshableValue(
              label: 'Noise floor',
              value: '${s.noiseFloor} dBm',
              fetchedAt: _statusAt),
          const SectionHeader('Traffic'),
          RefreshableValue(
              label: 'Received',
              value: '${s.packetsReceived}',
              fetchedAt: _statusAt),
          RefreshableValue(
              label: 'Sent', value: '${s.packetsSent}', fetchedAt: _statusAt),
          Padding(
            padding: const EdgeInsets.fromLTRB(134, 0, 16, 4),
            child: MetricSparkline(
                metricId: 'packetsSent',
                samples: _samples['packetsSent'] ?? []),
          ),
          RefreshableValue(
              label: 'TX airtime',
              value: '${s.totalAirTimeSecs} s',
              fetchedAt: _statusAt),
          RefreshableValue(
              label: 'RX airtime',
              value: '${s.rxAirTimeSecs} s',
              fetchedAt: _statusAt),
          RefreshableValue(
              label: 'Errors', value: '${s.errorEvents}', fetchedAt: _statusAt),
        ],
        const SectionHeader('Owner'),
        if (_owner == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('No owner information has been read yet.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          )
        else ...[
          RefreshableValue(
              label: 'Firmware', value: _owner!.version, fetchedAt: _ownerAt),
          RefreshableValue(
              label: 'Name', value: _owner!.name, fetchedAt: _ownerAt),
          RefreshableValue(
              label: 'Owner', value: _owner!.owner, fetchedAt: _ownerAt),
        ],
      ],
    );
  }
}
