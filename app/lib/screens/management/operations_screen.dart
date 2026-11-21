import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// One-shot maintenance actions. Each shows the exact command, asks before
/// changing state and reports the firmware reply or an explicit unknown.
class OperationsScreen extends StatefulWidget {
  const OperationsScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends State<OperationsScreen> {
  static const _actions = <(String, String, String, bool)>[
    ('ver', 'Read firmware version', 'ver', false),
    ('board', 'Read board name', 'board', false),
    ('power', 'Read power state', 'power', false),
    ('clock', 'Read the clock', 'clock', false),
    ('advert', 'Send an advert', 'advert', true),
    ('advert.zerohop', 'Send a zero-hop advert', 'advert.zerohop', true),
    ('log start', 'Start the packet log', 'log start', true),
    ('log stop', 'Stop the packet log', 'log stop', true),
    ('log erase', 'Erase the packet log', 'log erase', true),
    ('clear stats', 'Clear statistics', 'clear stats', true),
    ('reboot', 'Reboot the repeater', 'reboot', true),
    ('poweroff', 'Power the repeater off', 'poweroff', true),
  ];

  final _value = TextEditingController();
  String? _last;
  bool _busy = false;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  CliService? _cli() => widget.cli ?? context.read<AppState>().managementCli();
  Contact? _target() => context.read<AppState>().target;

  Future<void> _run(String label, String command, bool dangerous) async {
    if (dangerous) {
      final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(label),
              content: Text('Run "$command" on the repeater?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Run')),
              ],
            ),
          ) ??
          false;
      if (!ok || !mounted) return;
    }
    final cli = _cli();
    final target = _target();
    if (cli == null || target == null) return;
    setState(() => _busy = true);
    final reply = dangerous
        ? await cli.write(target, command, family: 'operations')
        : await cli.read(target, command);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _last = reply.kind == CliReplyKind.unknown && reply.text.isEmpty
          ? 'No answer. Outcome unknown.'
          : '$command -> ${reply.text}';
    });
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Operations',
        refreshing: _busy,
        children: [
          if (_last != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_last!,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          const SectionHeader('Set the clock'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('time-value'),
              controller: _value,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Unix timestamp', border: OutlineInputBorder()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton(
              onPressed: _busy || int.tryParse(_value.text) == null
                  ? null
                  : () => _run('Set time?', 'time ${_value.text}', true),
              child: const Text('Set time'),
            ),
          ),
          const SectionHeader('Maintenance actions'),
          for (final (_, label, command, dangerous) in _actions)
            ListTile(
              title: Text(label),
              subtitle: Text(command,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : () => _run(label, command, dangerous),
            ),
        ],
      );
}
