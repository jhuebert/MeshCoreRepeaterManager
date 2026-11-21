import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/ack_collector.dart';
import '../../services/bulk_settings_controller.dart';
import '../../services/cli_service.dart';
import '../../services/fleet_sender.dart';
import '../../services/fleet_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Apply one settings change to a whole tag-defined group. The target is a
/// group, not a single repeater, and only curated safe settings are offered.
class BulkSettingsScreen extends StatefulWidget {
  const BulkSettingsScreen({super.key, this.cli, this.send});

  final CliService? cli;

  /// Test seam for the group send. Production uses the fleet channel.
  final Future<void> Function(String script, String id)? send;

  @override
  State<BulkSettingsScreen> createState() => _BulkSettingsScreenState();
}

class _BulkSettingsScreenState extends State<BulkSettingsScreen> {
  final _values = <String, String>{};
  final _tags = <String>{};
  final _at = TextEditingController();
  List<String> _availableTags = const [];
  bool _ack = true;
  bool _perSetting = false;
  bool _scheduled = false;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTags());
  }

  @override
  void dispose() {
    _at.dispose();
    super.dispose();
  }

  FleetService? _fleet() {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    if (cli == null || app.target == null) return null;
    return FleetService(cli, app.target!);
  }

  Future<void> _loadTags() async {
    final tags = await _fleet()?.tags();
    if (!mounted || tags == null) return;
    setState(() => _availableTags = tags);
  }

  List<FleetJob> _jobs() => BulkSettingsController(
        send: (_, __) async {},
        audit: (_, __) async {},
      ).build(
        values: _values,
        oneScriptPerSetting: _perSetting,
        tags: _tags.toList()..sort(),
        ack: _ack,
        at: _scheduled ? int.tryParse(_at.text.trim()) : null,
      );

  String? _validation() {
    if (_values.isEmpty) return 'Choose at least one setting';
    for (final entry in _values.entries) {
      final error = validateBulkValue(entry.key, entry.value);
      if (error != null) return '$entry.key: $error';
    }
    for (final job in _jobs()) {
      if (scriptBytes(composeJob(job)) > FleetJob.byteLimit) {
        return 'A script is over ${FleetJob.byteLimit} bytes. Use fewer '
            'settings per job.';
      }
    }
    if (_scheduled && int.tryParse(_at.text.trim()) == null) {
      return 'Enter a device-clock Unix timestamp';
    }
    return null;
  }

  Future<void> _apply() async {
    final app = context.read<AppState>();
    final link = app.connection.link;
    final error = _validation();
    if (error != null || (link == null && widget.send == null)) {
      setState(() => _problem = error ?? 'Connect a companion first.');
      return;
    }
    final jobs = _jobs();
    final preview = jobs.map(composeJob).join('\n\n');
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Apply to the group?'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      'Targets: ${_tags.isEmpty ? 'all fleet members' : _tags.join(', ')}'),
                  Text('Jobs: ${jobs.length}'),
                  Text('Replies: ${_ack ? 'always' : 'none'}'),
                  const SizedBox(height: 8),
                  Text(preview,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11)),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Apply')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    setState(() => _busy = true);
    final controller = BulkSettingsController(
      send: (script, id) async {
        if (widget.send != null) {
          await widget.send!(script, id);
        } else {
          await FleetSender(
            link: link!,
            pskHex: app.fleetPsk,
            senderName: app.connection.companionName,
          ).send(script);
        }
        app.ackCollector.track(FleetJobResult(
            id: id,
            script: script,
            sentAt: DateTime.now(),
            tags: _tags.toList()));
      },
      audit: (id, script) => app.recordFleetSend(id, script),
    );
    try {
      await controller.apply(jobs);
    } catch (e) {
      if (mounted) setState(() => _problem = 'Apply failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Bulk settings',
        refreshing: _busy,
        footer: FilledButton.icon(
          onPressed: _busy ? null : _apply,
          icon: const Icon(Icons.send),
          label: const Text('Apply'),
        ),
        children: [
          if (_problem != null) ErrorBanner(_problem!),
          finalError(),
          const SectionHeader('Target tags'),
          if (_availableTags.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('No tags on the nodes. The script reaches everyone.',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
            ),
          for (final tag in _availableTags)
            CheckboxListTile(
              title: Text(tag),
              value: _tags.contains(tag),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _tags.add(tag);
                } else {
                  _tags.remove(tag);
                }
              }),
            ),
          const SectionHeader('Settings to apply'),
          for (final spec in bulkSafeSettings)
            SettingField(
              key: Key('bulk-${spec.key}'),
              label: spec.label,
              value: _values[spec.key],
              help: spec.help,
              error: _values.containsKey(spec.key)
                  ? validateBulkValue(spec.key, _values[spec.key]!)
                  : null,
              onChanged: (v) => setState(() {
                if (v.isEmpty) {
                  _values.remove(spec.key);
                } else {
                  _values[spec.key] = v;
                }
              }),
            ),
          const SectionHeader('Mode'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('One job')),
                ButtonSegment(value: true, label: Text('One per setting')),
              ],
              selected: {_perSetting},
              onSelectionChanged: (s) => setState(() => _perSetting = s.first),
            ),
          ),
          SwitchListTile(
            title: const Text('Ask for replies'),
            subtitle: const Text('One ACK per repeater that ran the job.'),
            value: _ack,
            onChanged: (v) => setState(() => _ack = v),
          ),
          SwitchListTile(
            title: const Text('Schedule on the repeater'),
            subtitle: const Text('Uses the device clock. Lost on reboot.'),
            value: _scheduled,
            onChanged: (v) => setState(() => _scheduled = v),
          ),
          if (_scheduled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('bulk-at'),
                controller: _at,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Device Unix timestamp',
                    border: OutlineInputBorder()),
              ),
            ),
          const SectionHeader('Preview'),
          for (final job in _jobs())
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(composeJob(job),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11)),
                  Text(
                      '${scriptBytes(composeJob(job))} / '
                      '${FleetJob.byteLimit} bytes',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 11)),
                ],
              ),
            ),
        ],
      );

  Widget finalError() {
    final error = _validation();
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(error,
          style: const TextStyle(color: OtaTheme.bad, fontSize: 12)),
    );
  }
}
