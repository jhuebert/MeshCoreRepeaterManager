import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// App-wide preferences and local data. No mesh traffic happens here.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SectionHeader('Firmware'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: SwitchListTile(
              title: const Text('Offline mode'),
              subtitle: const Text(
                'Never contact GitHub. Only saved versions are shown.',
              ),
              value: app.offlineMode,
              onChanged: app.setOfflineMode,
            ),
          ),
        ),
        const SectionHeader('Mesh economy'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Soft request warning',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Optional. Shows a reminder in the connection sheet '
                    'after this many requests in one session. Nothing is '
                    'blocked and the setting is not saved.',
                    style: TextStyle(
                        color: OtaTheme.textMuted, fontSize: 12, height: 1.3),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final option in [null, 25, 50, 100, 200])
                        ChoiceChip(
                          label: Text(option == null ? 'Off' : '$option'),
                          selected: app.requestMeter.budget == option,
                          onSelected: (_) => app.requestMeter.setBudget(option),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SectionHeader('Local data'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.history, color: OtaTheme.accent),
              title: const Text('Management history'),
              subtitle: Text(
                '${app.auditStore?.entries().length ?? 0} recent writes '
                'are kept on this device, with secrets removed.',
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            'The admin password is never saved. Firmware images and the '
            'offline setting stay on this device.',
            style:
                TextStyle(color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}
