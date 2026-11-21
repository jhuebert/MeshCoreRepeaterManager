import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../services/filter_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';
import 'filter_rule_editor_screen.dart';
import 'filter_stats_screen.dart';

/// Packet filter rules, channels and rate limit. One explicit refresh loads
/// the whole list; pages are followed so a long list is never truncated.
class FilterScreen extends StatefulWidget {
  const FilterScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<FilterScreen> createState() => _FilterScreenState();
}

class _FilterScreenState extends State<FilterScreen> {
  FilterStatus? _status;
  List<FilterRule> _rules = [];
  FilterStats? _stats;
  List<String> _channels = [];
  bool _busy = false;
  String? _problem;
  final _chanName = TextEditingController();

  @override
  void dispose() {
    _chanName.dispose();
    super.dispose();
  }

  FilterService? _service() {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    if (cli == null || app.target == null) return null;
    return FilterService(cli, app.target!);
  }

  Future<void> _refresh() async {
    final service = _service();
    if (service == null || _busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final status = await service.status();
    final rules = await service.allRules();
    final stats = await service.stats();
    final chanReply =
        await service.cli.read(service.target, 'filter chan list');
    final channels = <String>[];
    if (chanReply.ok) {
      for (final line in chanReply.text.split('\n')) {
        final name = line.trim();
        if (name.isEmpty ||
            name.startsWith('next=') ||
            name.startsWith('Err')) {
          continue;
        }
        channels.add(name.split(RegExp(r'\s')).first);
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = status;
      _rules = rules;
      _stats = stats;
      _channels = channels;
      if (status == null) {
        _problem = 'No answer from the repeater. Outcome unknown; try again.';
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
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
        _problem = reply.kind == CliReplyKind.unknown
            ? 'No answer. Outcome unknown; refresh to check.'
            : reply.text;
      }
    });
    if (reply.ok) await _refresh();
  }

  Future<void> _addRule() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => FilterRuleEditorScreen(cli: widget.cli)),
    );
    if (result == true) await _refresh();
  }

  Future<void> _deleteRule(FilterRule rule) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this rule?'),
            content: Text('Rule ${rule.index}: ${rule.summary}'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
    if (ok) await _run('filter del ${rule.index}');
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return ManagementScaffold(
      title: 'Packet filter',
      onRefresh: _refresh,
      refreshing: _busy,
      actions: [
        IconButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => FilterStatsScreen(cli: widget.cli)),
          ),
          icon: const Icon(Icons.bar_chart),
          tooltip: 'Statistics',
        ),
      ],
      footer: FilledButton.icon(
        onPressed: _busy ? null : _addRule,
        icon: const Icon(Icons.add),
        label: const Text('Add rule'),
      ),
      children: [
        if (_problem != null) ErrorBanner(_problem!),
        const SectionHeader('Filter'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SwitchListTile(
            title: const Text('Packet filter on'),
            subtitle: Text(status == null
                ? 'Not read yet'
                : '${status.rules}/${status.maxRules} rules, '
                    '${status.channels}/${status.maxChannels} channels'),
            value: status?.on ?? false,
            onChanged: status == null
                ? null
                : (v) => _run(v ? 'filter on' : 'filter off'),
          ),
        ),
        const SectionHeader('Rules, in evaluation order'),
        if (_rules.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('No rules yet. The first matching rule wins.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          ),
        for (final rule in _rules)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Text('${rule.index}',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rule.summary,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12)),
                        Text('${_stats?.hits[rule.index] ?? rule.hits} hits',
                            style: const TextStyle(
                                color: OtaTheme.textMuted, fontSize: 11)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _busy
                        ? null
                        : () => _run(rule.enabled
                            ? 'filter disable ${rule.index}'
                            : 'filter enable ${rule.index}'),
                    icon: Icon(rule.enabled
                        ? Icons.toggle_on
                        : Icons.toggle_off_outlined),
                    tooltip: rule.enabled ? 'Disable' : 'Enable',
                  ),
                  IconButton(
                    onPressed: _busy || rule.index == 0
                        ? null
                        : () =>
                            _run('filter move ${rule.index} ${rule.index - 1}'),
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: 'Move earlier',
                  ),
                  IconButton(
                    onPressed: _busy || rule.index == _rules.length - 1
                        ? null
                        : () =>
                            _run('filter move ${rule.index} ${rule.index + 1}'),
                    icon: const Icon(Icons.arrow_downward),
                    tooltip: 'Move later',
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => _deleteRule(rule),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete rule',
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _run('filter clear'),
            icon: const Icon(Icons.clear_all),
            label: const Text('Clear all rules'),
          ),
        ),
        const SectionHeader('Channels'),
        for (final channel in _channels)
          ListTile(
            leading: const Icon(Icons.tag, color: OtaTheme.accent),
            title: Text(channel),
            trailing: IconButton(
              onPressed: _busy ? null : () => _run('filter chan del $channel'),
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'Delete channel',
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('channel-name'),
                  controller: _chanName,
                  decoration: const InputDecoration(
                      labelText: 'Channel name', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style:
                    OutlinedButton.styleFrom(minimumSize: const Size(80, 48)),
                onPressed: _busy || _chanName.text.trim().isEmpty
                    ? null
                    : () => _run('filter chan add ${_chanName.text.trim()}'),
                child: const Text('Add'),
              ),
            ],
          ),
        ),
        const SectionHeader('Advert rate limit'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            status == null
                ? 'Not read yet'
                : 'Window: ${status.ratelimitHours} h. '
                    'Cache ${status.cacheUsed}/${status.maxCache}. '
                    'Limiter drops: ${status.limiterDrops}.',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: OutlinedButton(
            onPressed: _busy ? null : () => _run('filter ratelimit clear'),
            child: const Text('Clear rate history'),
          ),
        ),
      ],
    );
  }
}
