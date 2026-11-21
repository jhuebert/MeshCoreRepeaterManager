import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Generic get/set for keys outside the curated sections. The curated registry
/// supplies the searchable key list; any other key can still be typed.
class SettingBrowserScreen extends StatefulWidget {
  const SettingBrowserScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<SettingBrowserScreen> createState() => _SettingBrowserScreenState();
}

class _SettingBrowserScreenState extends State<SettingBrowserScreen> {
  final _search = TextEditingController();
  final _value = TextEditingController();
  String? _key;
  String? _result;
  bool _busy = false;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _value.dispose();
    super.dispose();
  }

  List<SettingSpec> get _matches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return stockSettings;
    return stockSettings
        .where((s) =>
            s.key.toLowerCase().contains(q) ||
            s.label.toLowerCase().contains(q))
        .toList();
  }

  Future<CliService?> _cli() async =>
      widget.cli ?? context.read<AppState>().managementCli();

  Future<void> _get(String key) async {
    final cli = await _cli();
    if (!mounted) return;
    final target = context.read<AppState>().target;
    if (cli == null || target == null) return;
    setState(() {
      _busy = true;
      _key = key;
      _result = null;
    });
    final reply = await cli.read(target, 'get $key');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = reply.ok
          ? reply.value
          : (reply.kind == CliReplyKind.unknown
              ? 'No answer. Outcome unknown.'
              : reply.text);
      if (reply.ok) _value.text = reply.value;
    });
  }

  Future<void> _set() async {
    final cli = await _cli();
    if (!mounted) return;
    final target = context.read<AppState>().target;
    final key = _key;
    if (cli == null || target == null || key == null) return;
    final spec = settingFor(key);
    final error = spec?.validate(_value.text);
    if (error != null) {
      setState(() => _result = error);
      return;
    }
    setState(() => _busy = true);
    final reply =
        await cli.write(target, 'set $key ${_value.text}', family: 'settings');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = reply.ok
          ? (reply.kind == CliReplyKind.rebootNeeded
              ? 'Saved. Reboot to apply.'
              : 'Saved.')
          : (reply.kind == CliReplyKind.unknown
              ? 'No answer. Outcome unknown; re-read to check.'
              : reply.text);
    });
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Setting browser',
        refreshing: _busy,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Read or change a key directly. Serial-only keys are not listed.',
              style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                labelText: 'Search keys',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          for (final spec in _matches)
            ListTile(
              title: Text(spec.key,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13)),
              subtitle: Text(spec.label),
              onTap: () => _get(spec.key),
            ),
          const SectionHeader('Value'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _value,
              decoration: InputDecoration(
                labelText:
                    _key == null ? 'Select a key first' : 'Value for $_key',
                border: const OutlineInputBorder(),
              ),
              enabled: _key != null,
              autocorrect: false,
            ),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_result!,
                  style: const TextStyle(color: OtaTheme.accent, fontSize: 12)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.icon(
              onPressed: _key == null || _busy ? null : _set,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Set'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'Some keys change radio behaviour. Only change a key you '
              'understand.',
              style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
            ),
          ),
        ],
      );
}
