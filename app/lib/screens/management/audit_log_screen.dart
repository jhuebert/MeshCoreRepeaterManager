import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../services/management_audit_store.dart';
import '../../theme.dart';
import '../../widgets/management.dart';

/// Local history of management writes. Secrets were redacted at write time,
/// so both the list and the export are safe to share.
class AuditLogScreen extends StatelessWidget {
  const AuditLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final store = app.auditStore;
    final entries = store?.entries() ?? const [];
    return ManagementScaffold(
      title: 'Management history',
      footer: store == null
          ? null
          : OutlinedButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: store.export())),
              icon: const Icon(Icons.copy),
              label: const Text('Copy history'),
            ),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Writes only. Reads and single refreshes are not recorded. '
            'Values that could be secrets were removed before saving.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No management writes yet.',
                style: TextStyle(color: OtaTheme.textMuted)),
          ),
        for (final entry in entries)
          Card(
            child: ListTile(
              title: Text(entry.command,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              subtitle: Text(
                  '${entry.family} · ${entry.kind} · ${entry.outcome.name} · '
                  '${entry.at.toLocal()}'),
              trailing: Icon(
                entry.outcome == AuditOutcome.ok
                    ? Icons.check_circle_outline
                    : Icons.help_outline,
                color: entry.outcome == AuditOutcome.ok
                    ? OtaTheme.ok
                    : OtaTheme.warn,
                size: 18,
              ),
            ),
          ),
      ],
    );
  }
}
