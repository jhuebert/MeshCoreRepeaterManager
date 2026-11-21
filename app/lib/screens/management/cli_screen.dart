import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Raw CLI escape hatch. Every command goes through the same serialized,
/// audited service as the curated screens, and state-changing commands ask
/// first. The transcript shows the exact reply or an explicit unknown.
class CliScreen extends StatefulWidget {
  const CliScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<CliScreen> createState() => _CliScreenState();
}

class _CliScreenState extends State<CliScreen> {
  static const _quick = <String>[
    'ver',
    'board',
    'power',
    'clock',
    'get radio',
    'neighbors',
    'log start',
    'log stop',
  ];

  // Commands that change state or credentials. Never offered as quick actions.
  static const _dangerous = <String>[
    'reboot',
    'poweroff',
    'clkreboot',
    'password',
    'clear stats',
    'region def',
    'set prv.key',
  ];

  // Serial-only or destructive by design; the app never offers these here.
  static const _forbidden = <String>['erase', 'get prv.key', 'log'];

  final _controller = TextEditingController();
  final _history = <String>[];
  final _transcript = <({String command, String text, CliReplyKind kind})>[];
  int _historyIndex = 0;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isDangerous(String command) {
    final first = command.trim().toLowerCase().split(RegExp(r'\s+')).first;
    final head = command.trim().toLowerCase();
    return _dangerous.any((d) => d == first || head.startsWith('$d '));
  }

  bool _isForbidden(String command) {
    final head = command.trim().toLowerCase();
    return _forbidden.any((f) => head == f || head.startsWith('$f '));
  }

  Future<void> _send(String raw) async {
    final command = raw.trim();
    if (command.isEmpty) return;
    if (_isForbidden(command)) {
      _add(command, 'Not available remotely. Use serial access.',
          CliReplyKind.error);
      return;
    }
    if (_isDangerous(command)) {
      final go = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Run this command?'),
              content: Text('The repeater will run:\n\n$command'),
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
      if (!go) return;
    }
    if (!mounted) return;
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    final target = app.target;
    if (cli == null || target == null || !mounted) return;

    setState(() => _busy = true);
    final write = _isDangerous(command) || command.startsWith('set ');
    final reply = write
        ? await cli.write(target, command, family: 'cli')
        : await cli.read(target, command);
    if (!mounted) return;
    _history.add(command);
    _historyIndex = _history.length;
    _add(command, reply.text, reply.kind);
    setState(() => _busy = false);
  }

  void _add(String command, String text, CliReplyKind kind) {
    setState(() => _transcript.add((command: command, text: text, kind: kind)));
  }

  void _recall(bool up) {
    if (_history.isEmpty) return;
    _historyIndex = (_historyIndex + (up ? -1 : 1)).clamp(0, _history.length);
    _controller.text =
        _historyIndex == _history.length ? '' : _history[_historyIndex];
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Command line',
        refreshing: _busy,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'Commands run on the repeater through the companion. A lost reply '
              'is shown as unknown, never as success.',
              style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
            ),
          ),
          const SectionHeader('Quick commands'),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _quick.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) => ActionChip(
                label: Text(_quick[i],
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                onPressed: _busy ? null : () => _send(_quick[i]),
              ),
            ),
          ),
          const SectionHeader('Command'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    _recall(true);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    _recall(false);
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _controller,
                autocorrect: false,
                enabled: !_busy,
                onSubmitted: _send,
                decoration: const InputDecoration(
                  labelText: 'Command',
                  prefixText: '> ',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: FilledButton.icon(
              onPressed: _busy ? null : () => _send(_controller.text),
              icon: const Icon(playIcon),
              label: const Text('Run'),
            ),
          ),
          const SectionHeader('Transcript'),
          if (_transcript.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('No commands yet.',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
            ),
          for (final entry in _transcript)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('> ${entry.command}',
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: OtaTheme.accent)),
                  const SizedBox(height: 2),
                  Text(
                      entry.text.isEmpty
                          ? (entry.kind == CliReplyKind.unknown
                              ? 'No answer. Outcome unknown.'
                              : '(no output)')
                          : entry.text,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: entry.kind == CliReplyKind.error
                              ? OtaTheme.bad
                              : const Color(0xFFE2E8F0))),
                ],
              ),
            ),
          if (_transcript.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: OutlinedButton.icon(
                onPressed: () {
                  final text = _transcript
                      .map((e) => '> ${e.command}\n${e.text}')
                      .join('\n\n');
                  Clipboard.setData(ClipboardData(text: text));
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy transcript'),
              ),
            ),
        ],
      );
}
