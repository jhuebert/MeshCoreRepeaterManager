import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'connection_sheet.dart';
import 'repeater_picker_sheet.dart';
import 'routes.dart';

/// The landing screen. Management activities are tiles; nothing loads mesh
/// data just because this screen opened.
class RepeaterHubScreen extends StatelessWidget {
  const RepeaterHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.connectionPhase == ConnectionPhase.connected;
    final target = app.target;
    final caps = app.capabilities;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SectionHeader('Repeater'),
        if (!connected)
          _PromptCard(
            icon: Icons.link_off,
            title: 'No companion connected',
            body: 'Connect a companion to manage a repeater.',
            action: 'Connection',
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const ConnectionSheet(),
            ),
          ),
        if (connected && target == null)
          _PromptCard(
            icon: Icons.cell_tower,
            title: 'Choose a repeater',
            body: 'Pick one the companion knows, or enter its public key.',
            action: 'Choose',
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const RepeaterPickerSheet(),
            ),
          ),
        if (connected && target != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(repeaterIcon, color: OtaTheme.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            target.name.isEmpty
                                ? target.publicKeyHex.substring(0, 12)
                                : target.name,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton(
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => const RepeaterPickerSheet(),
                          ),
                          child: const Text('Change'),
                        ),
                      ],
                    ),
                    InfoRow(
                      label: 'Public key',
                      value: target.publicKeyHex.substring(0, 12),
                    ),
                    InfoRow(
                      label: 'Board',
                      value: app.detectedBoard ?? 'Unknown',
                    ),
                    InfoRow(
                      label: 'Firmware',
                      value: app.nodeInfo?.runningVersion.isNotEmpty == true
                          ? app.nodeInfo!.runningVersion
                          : (app.nodeStatus == null
                              ? 'Unknown'
                              : 'Repeater answered the update check'),
                    ),
                    InfoRow(
                      label: 'Access',
                      value: app.nodeStatus == null
                          ? 'Not signed in'
                          : 'Signed in',
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SectionHeader('Firmware'),
          _PromptCard(
            icon: updateIcon,
            title: 'Update firmware',
            body: 'Check the repeater, pick a version and send it over the '
                'companion.',
            action: 'Start',
            onTap: () => Navigator.of(context).pushNamed(AppRoutes.update),
          ),
          const SectionHeader('Management'),
          ..._activityTiles(context, app, caps),
        ],
        if (app.capabilityError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ErrorBanner(app.capabilityError!),
          ),
      ],
    );
  }

  static String _label(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  List<Widget> _activityTiles(
      BuildContext context, AppState app, RepeaterCapabilities? caps) {
    final fork = caps?.firmwareKind == FirmwareKind.fork;
    final confirmed = caps?.confidence == CapabilityConfidence.confirmed;
    // Locked fork tiles open the firmware activity; stock management tiles
    // open their own screen. Writes need at least a read-write session.
    final tiles = <(IconData, String, String, String, bool, String)>[
      (
        Icons.monitor_heart_outlined,
        'Status',
        'Battery, uptime and packet counters from one status request.',
        AppRoutes.status,
        true,
        ''
      ),
      (
        settingsIcon,
        'Settings',
        'Read and change the repeater settings.',
        AppRoutes.settings,
        app.canWrite,
        'Sign in with write access'
      ),
      (
        Icons.manage_search,
        'Setting browser',
        'Read or change a key directly.',
        AppRoutes.browser,
        true,
        ''
      ),
      (
        fleetIcon,
        'Access list',
        'Who can talk to this repeater.',
        AppRoutes.acl,
        app.canWrite,
        'Sign in with write access'
      ),
      (
        Icons.hub_outlined,
        'Neighbours',
        'Nearby repeaters and their signal strength.',
        AppRoutes.neighbors,
        true,
        ''
      ),
      (
        Icons.show_chart,
        'Statistics',
        'Battery, traffic and uptime trends from saved readings.',
        AppRoutes.stats,
        true,
        ''
      ),
      (
        Icons.terminal,
        'Command line',
        'Run a raw command for anything without a dedicated screen.',
        AppRoutes.cli,
        true,
        ''
      ),
      (
        Icons.filter_alt_outlined,
        'Filter',
        'Build and check packet rules before sending them.',
        AppRoutes.filter,
        fork && confirmed,
        'Update-enabled fork'
      ),
      (
        Icons.groups_outlined,
        'Fleet',
        'Send one job to a group of repeaters and collect replies.',
        AppRoutes.fleet,
        fork && confirmed,
        'Update-enabled fork'
      ),
      (
        Icons.cloud_outlined,
        'MQTT',
        'Configure the observer and two brokers.',
        AppRoutes.mqtt,
        caps?.mqtt ?? false,
        'Update-enabled fork'
      ),
      (
        Icons.wifi,
        'WiFi update',
        'Use the repeater’s built-in update page over your LAN.',
        AppRoutes.wifiOta,
        true,
        ''
      ),
      (
        Icons.tune,
        'Fork features',
        'Radio2, battery gate, mesh clock, bot and power profile.',
        AppRoutes.extras,
        fork && confirmed,
        'Update-enabled fork'
      ),
      (
        Icons.build_outlined,
        'Operations',
        'Clock, adverts, logs, reboot and other one-shot actions.',
        AppRoutes.operations,
        true,
        ''
      ),
      (
        Icons.monitor_outlined,
        'Diagnostics',
        'Region, sensors, GPS, bridge and board facts.',
        AppRoutes.diagnostics,
        true,
        ''
      ),
      (
        Icons.history,
        'History',
        'Local record of management writes with secrets removed.',
        AppRoutes.audit,
        true,
        ''
      ),
      (
        Icons.key,
        'Node identity',
        'Change the repeater private key and migrate local data.',
        AppRoutes.identity,
        app.canWrite,
        'Sign in with write access'
      ),
      (
        Icons.content_paste_go,
        'Bulk settings',
        'Apply a safe setting to a tag-defined group of repeaters.',
        AppRoutes.bulkSettings,
        caps?.fleet ?? false,
        'Update-enabled fork'
      ),
    ];
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: OutlinedButton.icon(
          onPressed: app.identifying
              ? null
              : () => app.identifyCapabilities(force: true),
          icon: app.identifying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search),
          label: const Text('Identify firmware'),
        ),
      ),
      const SizedBox(height: 6),
      if (caps != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 6,
            children: [
              StatusPill(_label(caps.firmwareKind.name)),
              StatusPill(_label(caps.confidence.name),
                  color: confirmed ? OtaTheme.ok : OtaTheme.warn),
              if (caps.ota) const StatusPill('OTA', color: OtaTheme.ok),
              if (caps.filter) const StatusPill('Filter', color: OtaTheme.ok),
              if (caps.fleet) const StatusPill('Fleet', color: OtaTheme.ok),
              if (caps.mqtt) const StatusPill('MQTT', color: OtaTheme.ok),
            ],
          ),
        ),
      if (caps == null)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            'Firmware has not been identified yet. Unknown does not mean '
            'unsupported.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
      for (final (icon, title, body, route, unlocked, reason) in tiles)
        ActivityTile(
          icon: icon,
          title: title,
          subtitle: unlocked ? body : '$body $reason.',
          locked: !unlocked,
          badge: unlocked ? 'Ready' : 'Locked',
          onTap: () => Navigator.of(context).pushNamed(route),
        ),
    ];
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: OtaTheme.accent),
                    const SizedBox(width: 10),
                    Text(title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(body,
                    style: const TextStyle(
                        color: OtaTheme.textMuted, fontSize: 12, height: 1.4)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onTap,
                  icon: const Icon(nextIcon),
                  label: Text(action),
                ),
              ],
            ),
          ),
        ),
      );
}
