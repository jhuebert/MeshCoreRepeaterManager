import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'connection_sheet.dart';
import 'repeater_picker_sheet.dart';
import 'routing_sheet.dart';
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
                    InfoRow(label: 'Access', value: app.permissionLabel),
                    InfoRow(label: 'Route', value: _routeLabel(app)),
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

  static String _routeLabel(AppState app) {
    final path = app.manualRoutePath.trim();
    if (path == '0') return 'Direct';
    if (path.isNotEmpty) return 'Via $path';
    return app.target?.hasDirectRoute == true ? 'Saved direct' : 'Zero hop';
  }

  List<Widget> _activityTiles(
      BuildContext context, AppState app, RepeaterCapabilities? caps) {
    final fork = caps?.firmwareKind == FirmwareKind.fork;
    final confirmed = caps?.confidence == CapabilityConfidence.confirmed;
    final forkReady = fork && confirmed;
    final hasMqtt = caps?.mqtt ?? false;
    final hasFleet = caps?.fleet ?? false;
    final writeReason = app.canWrite ? '' : 'Sign in with write access';
    // A locked fork tile opens the firmware activity; a tile locked by role
    // shows why and is not tappable. Writes need a read-write session.
    String forkReason(bool capabilityOk) => !capabilityOk
        ? 'Update-enabled fork'
        : (app.canWrite ? '' : 'Sign in with write access');
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
        writeReason
      ),
      (
        Icons.manage_search,
        'Setting browser',
        'Read or change a key directly.',
        AppRoutes.browser,
        app.canWrite,
        writeReason
      ),
      (
        fleetIcon,
        'Access list',
        'Who can talk to this repeater.',
        AppRoutes.acl,
        app.canWrite,
        writeReason
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
        app.canWrite,
        writeReason
      ),
      (
        Icons.filter_alt_outlined,
        'Filter',
        'Build and check packet rules before sending them.',
        AppRoutes.filter,
        forkReady && app.canWrite,
        forkReason(forkReady)
      ),
      (
        Icons.groups_outlined,
        'Fleet',
        'Send one job to a group of repeaters and collect replies.',
        AppRoutes.fleet,
        forkReady && app.canWrite,
        forkReason(forkReady)
      ),
      (
        Icons.cloud_outlined,
        'MQTT',
        'Configure the observer and two brokers.',
        AppRoutes.mqtt,
        hasMqtt && app.canWrite,
        forkReason(hasMqtt)
      ),
      (
        Icons.wifi,
        'WiFi update',
        'Use the repeater’s built-in update page over your LAN.',
        AppRoutes.wifiOta,
        app.canWrite,
        writeReason
      ),
      (
        Icons.tune,
        'Fork features',
        'Radio2, battery gate, mesh clock, bot and power profile.',
        AppRoutes.extras,
        forkReady && app.canWrite,
        forkReason(forkReady)
      ),
      (
        Icons.build_outlined,
        'Operations',
        'Clock, adverts, logs, reboot and other one-shot actions.',
        AppRoutes.operations,
        app.canWrite,
        writeReason
      ),
      (
        Icons.monitor_outlined,
        'Diagnostics',
        'Region, sensors, GPS, bridge and board facts.',
        AppRoutes.diagnostics,
        app.canWrite,
        writeReason
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
        app.isAdmin,
        app.isAdmin ? '' : 'Sign in as admin'
      ),
      (
        Icons.content_paste_go,
        'Bulk settings',
        'Apply a safe setting to a tag-defined group of repeaters.',
        AppRoutes.bulkSettings,
        hasFleet && app.canWrite,
        forkReason(hasFleet)
      ),
    ];
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: OutlinedButton.icon(
          onPressed: () => showRoutingSheet(context),
          icon: const Icon(Icons.route),
          label: Text('Route: ${_routeLabel(app)}'),
        ),
      ),
      const SizedBox(height: 6),
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
          onTap: unlocked
              ? () => Navigator.of(context).pushNamed(route)
              : reason == 'Update-enabled fork'
                  ? () => Navigator.of(context).pushNamed(AppRoutes.update)
                  : null,
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
