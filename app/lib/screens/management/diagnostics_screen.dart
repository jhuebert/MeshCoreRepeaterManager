import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Board-dependent facts and the remaining command families: region, sensors,
/// GPS, bridge keys and power diagnostics. Reads happen only on refresh.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  static const _facts = <(String, String)>[
    ('ver', 'Firmware'),
    ('board', 'Board'),
    ('get bootloader.ver', 'Bootloader'),
    ('eth.status', 'Ethernet'),
    ('get pwrmgt.support', 'Power support'),
    ('get pwrmgt.source', 'Power source'),
    ('get pwrmgt.bootreason', 'Boot reason'),
    ('get pwrmgt.bootmv', 'Boot voltage'),
  ];

  final _outputs = <String, String>{};
  final _key = TextEditingController();
  final _value = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  CliService? _cli() => widget.cli ?? context.read<AppState>().managementCli();
  Contact? _target() => context.read<AppState>().target;

  Future<void> _read() async {
    final cli = _cli();
    final target = _target();
    if (cli == null || target == null) return;
    setState(() => _busy = true);
    final outputs = <String, String>{};
    for (final (command, _) in _facts) {
      final reply = await cli.read(target, command);
      outputs[command] = reply.ok ? reply.value : reply.text;
    }
    for (final command in ['region', 'sensor list', 'gps', 'get bridge.type']) {
      final reply = await cli.read(target, command);
      outputs[command] = reply.ok ? reply.text : reply.text;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outputs
        ..clear()
        ..addAll(outputs);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _read());
  }

  Future<void> _write(String command) async {
    final cli = _cli();
    final target = _target();
    if (cli == null || target == null) return;
    setState(() => _busy = true);
    final reply = await cli.write(target, command, family: 'diagnostics');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = reply.kind == CliReplyKind.unknown
          ? 'No answer. Outcome unknown; refresh to check.'
          : (reply.ok ? null : reply.text);
    });
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Diagnostics',
        onRefresh: _read,
        refreshing: _busy,
        children: [
          if (_problem != null) ErrorBanner(_problem!),
          const SectionHeader('Facts'),
          for (final (command, label) in _facts)
            InfoRow(label: label, value: _outputs[command] ?? 'unknown'),
          const SectionHeader('Region'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_outputs['region'] ?? 'not read',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ),
          for (final command in [
            'region save',
            'region home',
            'region default',
            'region list'
          ])
            ListTile(
              title: Text(command,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              onTap: _busy ? null : () => _write(command),
            ),
          const SectionHeader('Sensors'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_outputs['sensor list'] ?? 'not read',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ),
          const SectionHeader('GPS'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_outputs['gps'] ?? 'not read',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ),
          for (final command in ['gps on', 'gps off', 'gps sync', 'gps diag'])
            ListTile(
              title: Text(command,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              onTap: _busy ? null : () => _write(command),
            ),
          const SectionHeader('Bridge'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Type: ${_outputs['get bridge.type'] ?? 'unknown'}',
                style:
                    const TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          ),
          const SectionHeader('Generic get / set'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('diagnostic-key'),
              controller: _key,
              decoration: const InputDecoration(
                  labelText: 'Key, e.g. region home or bridge.enabled',
                  border: OutlineInputBorder()),
              autocorrect: false,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              key: const Key('diagnostic-value'),
              controller: _value,
              decoration: const InputDecoration(
                  labelText: 'Value (leave blank to read)',
                  border: OutlineInputBorder()),
              autocorrect: false,
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton(
                    onPressed: _busy || _key.text.trim().isEmpty
                        ? null
                        : () async {
                            final cli = _cli();
                            final target = _target();
                            if (cli == null || target == null) return;
                            setState(() => _busy = true);
                            final reply = await cli.read(
                                target, 'get ${_key.text.trim()}');
                            if (!mounted) return;
                            setState(() {
                              _busy = false;
                              _value.text = reply.ok ? reply.value : reply.text;
                            });
                          },
                    child: const Text('Get'),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton(
                    onPressed: _busy || _key.text.trim().isEmpty
                        ? null
                        : () => _write(
                            'set ${_key.text.trim()} ${_value.text.trim()}'),
                    child: const Text('Set'),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
}
