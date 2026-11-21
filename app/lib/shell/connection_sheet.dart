import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'connection_form.dart';

/// Link details and connection controls, reachable from the top-right dot on
/// every screen. The form is the same one used by the update activity.
class ConnectionSheet extends StatelessWidget {
  const ConnectionSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              const Icon(Icons.link, color: OtaTheme.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Connection',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (app.connectionPhase == ConnectionPhase.connected) ...[
            InfoRow(
                label: 'Companion',
                value: app.companionName.isEmpty
                    ? 'Companion'
                    : app.companionName),
            InfoRow(
                label: 'Transport',
                value: app.connection.lastEndpoint ?? app.transportKind),
            InfoRow(label: 'Contacts', value: '${app.contacts.length}'),
            if (app.target != null)
              InfoRow(label: 'Repeater', value: app.target!.name),
            InfoRow(
              label: 'Requests this session',
              value: '${app.requestMeter.count}',
            ),
            if (app.requestMeter.overBudget)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Mesh budget reached (${app.requestMeter.budget}). '
                  'Refresh only what you need.',
                  style: const TextStyle(color: OtaTheme.warn, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: app.reconnect,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reconnect'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          ConnectionForm(
            onConnected: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
