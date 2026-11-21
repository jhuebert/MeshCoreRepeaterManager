import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../services/fleet_service.dart';
import '../../services/secret_store.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'fleet_composer_screen.dart';
import 'fleet_queue_screen.dart';
import 'fleet_results_screen.dart';

/// Fleet dashboard: configuration on one repeater, then the composer, queue
/// and per-repeater results for group jobs.
class FleetScreen extends StatefulWidget {
  const FleetScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _psk = TextEditingController();
  String? _status;
  List<String> _tags = const [];
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _psk.text = context.read<AppState>().fleetPsk;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _psk.dispose();
    super.dispose();
  }

  FleetService? _service() {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    if (cli == null || app.target == null) return null;
    return FleetService(cli, app.target!);
  }

  Future<void> _refresh() async {
    final service = _service();
    if (service == null) return;
    setState(() => _busy = true);
    final status = await service.status();
    final tags = await service.tags();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = status;
      _tags = tags;
      if (status == null) {
        _problem = 'No answer from the repeater. Outcome unknown; try again.';
      }
    });
  }

  Future<void> _run(String command) async {
    final service = _service();
    if (service == null) return;
    setState(() => _busy = true);
    final reply = await service.write(command);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!reply.ok) {
        _problem = reply.kind.name == 'unknown'
            ? 'No answer. Outcome unknown; refresh to check.'
            : reply.text;
      }
    });
    if (reply.ok) await _refresh();
  }

  void _savePsk() {
    final app = context.read<AppState>();
    setState(() => app.fleetPsk = _psk.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Composer'),
            Tab(text: 'Queue'),
            Tab(text: 'Results'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (_problem != null) ErrorBanner(_problem!),
              const SectionHeader('Fleet on this repeater'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_status ?? 'Not read yet.',
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: OtaTheme.textMuted)),
              ),
              const SectionHeader('Channel key'),
              SecretFieldControl(
                label: 'Fleet PSK, hex',
                fieldKey: 'fleet-psk',
                controller: _psk,
                eligible: true,
                storeAvailable: app.secretStore?.available ?? false,
                remembered:
                    app.secretStore?.isRemembered(SecretField.fleetPsk) ??
                        false,
                onRemember: (value) async {
                  final store = app.secretStore;
                  if (store == null) return;
                  if (value) {
                    await store.remember(
                        SecretField.fleetPsk, _psk.text.trim());
                  } else {
                    await store.forget(SecretField.fleetPsk);
                  }
                },
                onForget: () async {
                  await app.secretStore?.forget(SecretField.fleetPsk);
                  _psk.clear();
                  _savePsk();
                },
                help: 'Without opt-in this stays in memory for this session '
                    'only. The repeater never echoes the key.',
              ),
              const SectionHeader('Tags on this node'),
              if (_tags.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('No tags. Broadcast reaches every member.',
                      style:
                          TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
                ),
              for (final tag in _tags)
                ListTile(
                  leading: const Icon(Icons.tag, color: OtaTheme.accent),
                  title: Text(tag),
                  trailing: IconButton(
                    onPressed: _busy ? null : () => _run('fleet tag del $tag'),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Delete tag',
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _run('fleet on'),
                        icon: const Icon(Icons.power_settings_new),
                        label: const Text('Arm fleet'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FleetComposerScreen(
                        availableTags: _tags,
                        psk: app.fleetPsk,
                        collector: app.ackCollector,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('New job'),
                ),
              ),
            ],
          ),
          const FleetQueueScreen(),
          const FleetResultsScreen(),
        ],
      ),
    );
  }
}
