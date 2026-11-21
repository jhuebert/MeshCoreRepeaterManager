import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Access list. Changing an entry requires confirmation, and lowering or
/// removing the companion's own entry asks again so the app cannot lock itself
/// out by accident.
class AdminAclScreen extends StatefulWidget {
  const AdminAclScreen({super.key, this.cli, this.ownPrefixHex});

  final CliService? cli;
  final String? ownPrefixHex;

  @override
  State<AdminAclScreen> createState() => _AdminAclScreenState();
}

class _AdminAclScreenState extends State<AdminAclScreen> {
  List<AclEntry> _entries = [];
  DateTime? _fetchedAt;
  String? _ownPrefix;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _loadOwnKey();
  }

  Future<void> _loadOwnKey() async {
    if (widget.ownPrefixHex != null) {
      setState(() => _ownPrefix = widget.ownPrefixHex);
      return;
    }
    final info = await context.read<AppState>().connection.link?.selfInfo();
    if (!mounted || info == null) return;
    setState(() {
      _ownPrefix = info.publicKey
          .sublist(0, 6)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    });
  }

  Future<void> _refresh() async {
    final cli = widget.cli ?? context.read<AppState>().managementCli();
    final target = context.read<AppState>().target;
    if (cli == null || target == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final list = await cli.accessList(target);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (list == null) {
        _problem = 'No answer from the repeater. Outcome unknown; try again.';
      } else {
        _entries = list;
        _fetchedAt = DateTime.now();
      }
    });
  }

  Future<void> _setPermission(AclEntry entry, int permission) async {
    final isOwn = entry.prefixHex == _ownPrefix;
    final lowering = permission <= entry.role;
    if (isOwn && lowering) {
      final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Change your own access?'),
              content: const Text(
                'This is the companion the app uses. Lowering its access may '
                'lock you out. Continue only if another admin can restore it.',
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Continue')),
              ],
            ),
          ) ??
          false;
      if (!ok) return;
    }
    if (!mounted) return;
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    final target = app.target;
    if (cli == null || target == null || !mounted) return;
    setState(() => _busy = true);
    await cli.write(
      target,
      'setperm ${entry.prefixHex} $permission',
      family: 'access',
    );
    if (mounted) setState(() => _busy = false);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Access list',
        onRefresh: _refresh,
        refreshing: _busy,
        children: [
          if (_problem != null) ErrorBanner(_problem!),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'These keys can talk to the repeater. Set access to Guest to '
              'remove an entry.',
              style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
            ),
          ),
          if (_fetchedAt != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LastKnownLabel(_fetchedAt!),
            ),
          if (_entries.isEmpty && _fetchedAt != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('No entries were reported.',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
            ),
          for (final entry in _entries)
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(entry.prefixHex,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)),
                        if (entry.prefixHex == _ownPrefix) ...[
                          const SizedBox(width: 8),
                          const StatusPill('This companion',
                              color: OtaTheme.warn),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Text('Access:',
                            style: TextStyle(
                                color: OtaTheme.textMuted, fontSize: 12)),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: entry.role,
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('Guest')),
                            DropdownMenuItem(
                                value: 1, child: Text('Read only')),
                            DropdownMenuItem(
                                value: 2, child: Text('Read and write')),
                            DropdownMenuItem(value: 3, child: Text('Admin')),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) =>
                                  v == null ? null : _setPermission(entry, v),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
}
