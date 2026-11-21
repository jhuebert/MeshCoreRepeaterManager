import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/management.dart';

/// App-side scheduled jobs. These need the app to be running; device-side
/// `!at` is the RAM-only alternative and is offered in the composer.
class FleetQueueScreen extends StatelessWidget {
  const FleetQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final jobs = app.fleetScheduler?.jobs ?? const [];
    return ManagementScaffold(
      title: 'Scheduled jobs',
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'These jobs fire while the app is running. The repeater clock is '
            'the authority for device-side schedules.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        if (jobs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nothing scheduled.',
                style: TextStyle(color: OtaTheme.textMuted)),
          ),
        for (final job in jobs)
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule, color: OtaTheme.accent),
              title: Text(job.id,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13)),
              subtitle: Text('Due ${job.dueAt.toLocal()}'),
              trailing: IconButton(
                onPressed: () => app.fleetScheduler?.cancel(job.id),
                icon: const Icon(Icons.cancel_outlined),
                tooltip: 'Cancel job',
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            'To schedule on the repeater instead, use "Schedule on the '
            'repeater" in the composer. Those jobs are lost on reboot.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }
}
