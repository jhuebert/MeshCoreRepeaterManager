import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../services/management_audit_store.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Local history of management writes. Secrets were redacted at write time,
/// so both the list and the export are safe to share. Filters narrow the view;
/// export always includes the whole stored log. The store keeps the newest
/// entries only, so the screen warns before old ones roll off.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  String? _family;
  AuditOutcome? _outcome;
  String? _repeater;
  String _range = 'All time';

  static const _ranges = ['All time', 'Today', 'Last 7 days'];

  List<AuditEntry> _filtered(List<AuditEntry> entries) {
    final now = DateTime.now();
    return entries.where((entry) {
      if (_family != null && entry.family != _family) return false;
      if (_outcome != null && entry.outcome != _outcome) return false;
      if (_repeater != null && entry.repeaterKeyHex != _repeater) return false;
      if (_range == 'Today' &&
          entry.at.isBefore(DateTime(now.year, now.month, now.day))) {
        return false;
      }
      if (_range == 'Last 7 days' &&
          entry.at.isBefore(now.subtract(const Duration(days: 7)))) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final store = app.auditStore;
    final all = store?.entries() ?? const [];
    final shown = _filtered(all);
    final families = all.map((e) => e.family).toSet().toList()..sort();
    final repeaters = all.map((e) => e.repeaterKeyHex).toSet().toList()..sort();
    final filtersActive = _family != null ||
        _outcome != null ||
        _repeater != null ||
        _range != 'All time';

    return ManagementScaffold(
      title: 'Management history',
      footer: store == null
          ? null
          : OutlinedButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: store.export())),
              icon: const Icon(Icons.copy),
              label: const Text('Copy all history'),
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
        if (all.length >= ManagementAuditStore.maxEntries - 100)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              'The history is nearly full. Older entries roll off after 1000 '
              'writes; copy the log now to keep them.',
              style: TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.3),
            ),
          ),
        const SectionHeader('Filters'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DropdownButton<String>(
                value: _range,
                items: [
                  for (final range in _ranges)
                    DropdownMenuItem(value: range, child: Text(range)),
                ],
                onChanged: (v) => setState(() => _range = v ?? 'All time'),
              ),
              DropdownButton<String?>(
                value: _family,
                hint: const Text('All families'),
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('All families')),
                  for (final family in families)
                    DropdownMenuItem(value: family, child: Text(family)),
                ],
                onChanged: (v) => setState(() => _family = v),
              ),
              DropdownButton<AuditOutcome?>(
                value: _outcome,
                hint: const Text('All outcomes'),
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('All outcomes')),
                  for (final outcome in AuditOutcome.values)
                    DropdownMenuItem(value: outcome, child: Text(outcome.name)),
                ],
                onChanged: (v) => setState(() => _outcome = v),
              ),
              DropdownButton<String?>(
                value: _repeater,
                hint: const Text('All repeaters'),
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('All repeaters')),
                  for (final key in repeaters)
                    DropdownMenuItem(
                      value: key,
                      child: Text(
                          key.length > 8 ? '${key.substring(0, 8)}...' : key),
                    ),
                ],
                onChanged: (v) => setState(() => _repeater = v),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text('${shown.length} of ${all.length} entries',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
              const Spacer(),
              if (filtersActive)
                TextButton(
                  onPressed: () => setState(() {
                    _family = null;
                    _outcome = null;
                    _repeater = null;
                    _range = 'All time';
                  }),
                  child: const Text('Clear filters'),
                ),
            ],
          ),
        ),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No entries match these filters.',
                style: TextStyle(color: OtaTheme.textMuted)),
          ),
        for (final entry in shown)
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
