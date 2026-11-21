import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../services/filter_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Filter counters from `filter stats`, recorded as cached samples so the
/// screen draws without another request.
class FilterStatsScreen extends StatefulWidget {
  const FilterStatsScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<FilterStatsScreen> createState() => _FilterStatsScreenState();
}

class _FilterStatsScreenState extends State<FilterStatsScreen> {
  FilterStats? _stats;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    if (cli == null || app.target == null) return;
    setState(() => _busy = true);
    final stats = await FilterService(cli, app.target!).stats();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stats = stats;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return ManagementScaffold(
      title: 'Filter statistics',
      onRefresh: _refresh,
      refreshing: _busy,
      children: [
        if (stats == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No statistics read yet. Tap refresh.',
                style: TextStyle(color: OtaTheme.textMuted)),
          )
        else ...[
          const SectionHeader('Totals'),
          InfoRow(label: 'Limiter drops', value: '${stats.limiterDrops}'),
          InfoRow(label: 'Regex aborts', value: '${stats.regexAborts}'),
          InfoRow(label: 'Airtime saved', value: '${stats.airtimeSaved} s'),
          const SectionHeader('Hits by rule'),
          if (stats.hits.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('No rule has matched yet.',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
            ),
          for (final entry in stats.hits.entries)
            InfoRow(label: 'Rule ${entry.key}', value: '${entry.value} hits'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final app = context.read<AppState>();
                      final cli = widget.cli ?? app.managementCli();
                      if (cli == null || app.target == null) return;
                      await cli.write(app.target!, 'filter stats reset',
                          family: 'filter');
                      await _refresh();
                    },
              child: const Text('Reset counters'),
            ),
          ),
        ],
      ],
    );
  }
}
