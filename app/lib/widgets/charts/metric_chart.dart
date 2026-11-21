import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../theme.dart';

/// One chart style for every metric, full size or as a sparkline. Colours,
/// axes and labels stay identical so the charts read as one set.
class MetricChart extends StatelessWidget {
  const MetricChart({
    super.key,
    required this.metric,
    required this.samples,
    this.compact = false,
  });

  final MetricSpec metric;
  final List<MetricSample> samples;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ordered = [...samples]..sort((a, b) => a.at.compareTo(b.at));
    if (ordered.isEmpty) {
      return SizedBox(
        height: compact ? 40 : 180,
        child: Center(
          child: Text(
            compact
                ? 'No samples yet'
                : 'No samples yet. Refresh to collect some.',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
      );
    }
    final first = ordered.first.at.millisecondsSinceEpoch.toDouble();
    final spots = ordered
        .map((s) =>
            FlSpot(s.at.millisecondsSinceEpoch.toDouble() - first, s.value))
        .toList();

    return SizedBox(
      height: compact ? 40 : 180,
      child: LineChart(
        LineChartData(
          gridData: FlGridData(
            show: !compact,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => const FlLine(
              color: Color(0x22334455),
              strokeWidth: 1,
            ),
          ),
          titlesData: compact
              ? const FlTitlesData(show: false)
              : FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    axisNameWidget: Text(
                      metric.unit.trim(),
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 10),
                    ),
                    axisNameSize: 22,
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 48,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(
                          value.toStringAsFixed(metric.decimals),
                          style: const TextStyle(
                              color: OtaTheme.textMuted, fontSize: 9),
                        ),
                      ),
                    ),
                  ),
                ),
          borderData: compact
              ? FlBorderData(show: false)
              : FlBorderData(
                  show: true,
                  border: Border.all(color: const Color(0x33445566)),
                ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: OtaTheme.accent,
              barWidth: compact ? 1.5 : 2,
              dotData: FlDotData(show: !compact && spots.length < 40),
              belowBarData: BarAreaData(
                show: !compact,
                color: OtaTheme.accent.withValues(alpha: 0.12),
              ),
            ),
          ],
          minX: 0,
          maxX: spots.last.x == spots.first.x ? 1 : spots.last.x,
        ),
      ),
    );
  }
}

/// A compact trend for a status card. Uses the same chart as the full view.
class MetricSparkline extends StatelessWidget {
  const MetricSparkline({
    super.key,
    required this.metricId,
    required this.samples,
  });

  final String metricId;
  final List<MetricSample> samples;

  @override
  Widget build(BuildContext context) {
    final metric = metricFor(metricId);
    if (metric == null) return const SizedBox.shrink();
    return MetricChart(metric: metric, samples: samples, compact: true);
  }
}
