import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Neighbours come from one paged binary request. Long lists show an explicit
/// next action rather than silently truncating, and sort is chosen here.
class NeighborsScreen extends StatefulWidget {
  const NeighborsScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<NeighborsScreen> createState() => _NeighborsScreenState();
}

class _NeighborsScreenState extends State<NeighborsScreen> {
  static const _pageSize = 12;
  static const _prefixLength = 6;

  final _entries = <Neighbor>[];
  NeighborOrder _order = NeighborOrder.newest;
  int _offset = 0;
  int _total = 0;
  bool _busy = false;
  String? _problem;

  Future<void> _load({bool reset = false}) async {
    final cli = widget.cli ?? context.read<AppState>().managementCli();
    final target = context.read<AppState>().target;
    if (cli == null || target == null) return;
    if (reset) _offset = 0;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final page = await cli.neighbours(
      target,
      count: _pageSize,
      offset: _offset,
      order: _order,
      prefixLength: _prefixLength,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (page == null) {
        _problem = 'No answer from the repeater. Outcome unknown; try again.';
        return;
      }
      _total = page.total;
      if (reset) {
        _entries
          ..clear()
          ..addAll(page.entries);
      } else {
        _entries.addAll(page.entries);
      }
      _offset += page.entries.length;
    });
  }

  Future<void> _action(String command) async {
    final cli = widget.cli ?? context.read<AppState>().managementCli();
    final target = context.read<AppState>().target;
    if (cli == null || target == null) return;
    setState(() => _busy = true);
    final reply = command.startsWith('neighbor.remove')
        ? await cli.write(target, command, family: 'neighbors')
        : await cli.read(target, command);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!reply.ok) {
        _problem = reply.kind == CliReplyKind.unknown
            ? 'No answer. Outcome unknown; refresh to check.'
            : reply.text;
      }
    });
    if (reply.ok) await _load(reset: true);
  }

  Future<void> _remove(Neighbor neighbor) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remove this neighbour?'),
            content: Text('Remove ${neighbor.prefixHex} from the list?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Remove')),
            ],
          ),
        ) ??
        false;
    if (ok) await _action('neighbor.remove ${neighbor.prefixHex}');
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Neighbours',
        onRefresh: () => _load(reset: true),
        refreshing: _busy,
        children: [
          if (_problem != null) ErrorBanner(_problem!),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Row(
              children: [
                const Text('Sort:',
                    style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButton<NeighborOrder>(
                    value: _order,
                    isExpanded: true,
                    items: [
                      for (final o in NeighborOrder.values)
                        DropdownMenuItem(value: o, child: Text(o.label)),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() => _order = v);
                            _load(reset: true);
                          },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
                _total == 0
                    ? 'No neighbours reported.'
                    : '$_total known neighbours.',
                style:
                    const TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          ),
          for (final n in _entries)
            ListTile(
              leading: const Icon(Icons.cell_tower, color: OtaTheme.accent),
              title: Text(n.prefixHex,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13)),
              subtitle: Text(
                  '${n.heardSecondsAgo}s since heard · ${n.snr.toStringAsFixed(1)} dB'),
              trailing: IconButton(
                onPressed: _busy ? null : () => _remove(n),
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Remove neighbour',
              ),
            ),
          if (_offset < _total && _entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _load(),
                icon: const Icon(nextIcon),
                label: const Text('Next'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _action('discover.neighbors'),
              icon: const Icon(Icons.radar),
              label: const Text('Discover neighbors'),
            ),
          ),
        ],
      );
}
