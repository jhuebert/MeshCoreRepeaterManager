import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../services/ack_collector.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Per-repeater ACK matrix. A repeater with no reply is shown explicitly as
/// No reply; resending reuses the same job id for firmware de-duplication.
class FleetResultsScreen extends StatefulWidget {
  const FleetResultsScreen({super.key});

  @override
  State<FleetResultsScreen> createState() => _FleetResultsScreenState();
}

class _FleetResultsScreenState extends State<FleetResultsScreen> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final results = app.ackCollector.export();
    return ManagementScaffold(
      title: 'Job results',
      onRefresh: () async => setState(() {}),
      footer: results.isEmpty
          ? null
          : OutlinedButton.icon(
              onPressed: () => Clipboard.setData(
                ClipboardData(
                    text: app.fleetStore?.export() ??
                        jsonEncode(results.map((r) => r.toJson()).toList())),
              ),
              icon: const Icon(Icons.copy),
              label: const Text('Copy all results'),
            ),
      children: [
        if (results.length >= AckCollector.maxHistory - 10)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              'Results are nearly full. Older jobs roll off after 100; copy '
              'them now to keep them.',
              style: TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.3),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Each repeater answers once. No reply means no ACK arrived inside '
            'the window, not that the job succeeded.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        if (results.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No jobs sent yet.',
                style: TextStyle(color: OtaTheme.textMuted)),
          ),
        for (final job in results)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(job.id,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)),
                      ),
                      StatusPill('${job.acks.length} replies',
                          color:
                              job.acks.isEmpty ? OtaTheme.warn : OtaTheme.ok),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Sent ${formatAge(job.sentAt)}',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 11)),
                  if (job.acks.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('No reply from any repeater.',
                          style: TextStyle(color: OtaTheme.warn, fontSize: 12)),
                    ),
                  for (final entry in job.acks.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                  entry.value.ok
                                      ? Icons.check_circle_outline
                                      : Icons.error_outline,
                                  size: 16,
                                  color: entry.value.ok
                                      ? OtaTheme.ok
                                      : OtaTheme.bad),
                              const SizedBox(width: 6),
                              Text(entry.key,
                                  style: const TextStyle(
                                      fontFamily: 'monospace', fontSize: 12)),
                            ],
                          ),
                          if (entry.value.output.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 22, top: 2),
                              child: Text(entry.value.output,
                                  style: const TextStyle(
                                      fontFamily: 'monospace', fontSize: 11)),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => app.resendFleetJob(job),
                    icon: const Icon(Icons.replay),
                    label: const Text('Resend same id'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
