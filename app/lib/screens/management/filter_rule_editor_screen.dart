import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../services/filter_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Build one filter rule with live validation, regex help and a dry run. The
/// exact command is shown before it can be sent.
class FilterRuleEditorScreen extends StatefulWidget {
  const FilterRuleEditorScreen({super.key, this.cli, this.index});

  final CliService? cli;

  /// Index being edited, or null for a new rule.
  final int? index;

  @override
  State<FilterRuleEditorScreen> createState() => _FilterRuleEditorScreenState();
}

class _FilterRuleEditorScreenState extends State<FilterRuleEditorScreen> {
  static const _fields = <(String, String, String)>[
    ('type', 'Packet types', 'advert, txt, data, any'),
    ('route', 'Route', 'flood or direct'),
    ('hops', 'Hops', '3 or [2,*]'),
    ('len', 'Payload length', '80 or [*,80]'),
    ('snr', 'Signal to noise', '-4 or [*, -8.5]'),
    ('path', 'Path', r'[^]HEX>HEX[$]'),
    ('hsize', 'Path ID sizes', '1,2,3,4'),
    ('chan', 'Channels', '#memes,#local'),
    ('chanhash', 'Channel tag', 'two hex digits'),
    ('region', 'Regions', 'home, unscoped'),
    ('sender', 'Sender pattern', r'^SpamBot$'),
    ('text', 'Text pattern', '^BEACON'),
    ('prob', 'Match percent', '1 to 100'),
    ('throttle', 'Throttle seconds', '1 to 65535'),
  ];

  static const _samples = <({String sender, String text})>[
    (sender: 'SpamBot', text: 'BEACON 123'),
    (sender: 'Alice', text: 'Hello on #local'),
    (sender: 'Bob', text: 'RX in place'),
  ];

  final _controllers = <String, TextEditingController>{};
  String _action = 'drop';
  final _regex = TextEditingController();
  Translation? _translation;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    for (final (key, _, _) in _fields) {
      _controllers[key] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _regex.dispose();
    super.dispose();
  }

  String _value(String key) => _controllers[key]?.text.trim() ?? '';

  FilterRule _rule() {
    final fields = <String, String>{
      for (final (key, _, _) in _fields)
        if (_value(key).isNotEmpty) key: _value(key),
    };
    var rule = FilterRule(action: _action, index: widget.index ?? 0);
    for (final entry in fields.entries) {
      rule = applyCondition(rule, '${entry.key}=${entry.value}');
    }
    return rule;
  }

  List<PatternIssue> get _patternIssues {
    final out = <PatternIssue>[];
    for (final key in ['sender', 'text']) {
      final value = _value(key);
      if (value.isEmpty) continue;
      for (final issue in validatePattern(value, sender: key == 'sender')) {
        out.add(PatternIssue('$key: ${issue.message}', fixable: issue.fixable));
      }
    }
    return out;
  }

  String? _fieldError(String key) {
    final value = _value(key);
    if (value.isEmpty) return null;
    if (key == 'sender' || key == 'text') {
      final errors = _patternIssues
          .where((i) => i.message.startsWith('$key:'))
          .map((i) => i.message.substring(key.length + 2));
      return errors.isEmpty ? null : errors.join(' ');
    }
    if (key == 'prob') {
      final n = int.tryParse(value);
      if (n == null || n < 1 || n > 100) return 'Use a number from 1 to 100';
    }
    if (key == 'throttle') {
      final n = int.tryParse(value);
      if (n == null || n < 1 || n > 65535) return 'Use 1 to 65535 seconds';
    }
    if (key == 'chan' || key == 'region' || key == 'type' || key == 'hsize') {
      if (value.contains(RegExp(r'[,="]'))) {
        return 'Commas and quotes separate values; remove them from a name';
      }
    }
    if (key == 'chanhash' && !RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(value)) {
      return 'Use two hex digits';
    }
    if (key == 'route' && value != 'flood' && value != 'direct') {
      return 'Use flood or direct';
    }
    if (key == 'hops' || key == 'len' || key == 'snr') {
      if (!RegExp(r'^(\[|\()?[^\]\),]+,?[^\]\),]*(\]|\))?$').hasMatch(value)) {
        return 'Use a number or an interval like [2,*]';
      }
    }
    return null;
  }

  bool get _hasErrors =>
      _fields.any((f) => _fieldError(f.$1) != null) ||
      _patternIssues.isNotEmpty;

  void _translate() {
    final input = _regex.text.trim();
    if (input.isEmpty) return;
    setState(() => _translation = translateRegex(input));
  }

  void _applyTranslation() {
    final t = _translation;
    if (t == null) return;
    // Default to the sender field; the operator can cut and paste into text.
    setState(() => _controllers['sender']!.text = t.result);
  }

  Future<void> _add() async {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    final target = app.target;
    if (cli == null || target == null || _hasErrors) return;
    final command = ruleToAddCommand(_rule());
    setState(() {
      _busy = true;
      _problem = null;
    });
    final reply = await FilterService(cli, target).write(command);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!reply.ok) {
      setState(() => _problem = reply.kind == CliReplyKind.unknown
          ? 'No answer. Outcome unknown; check the rules before retrying.'
          : reply.text);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final rule = _rule();
    final command = ruleToAddCommand(rule);
    return ManagementScaffold(
      title: widget.index == null ? 'New filter rule' : 'Edit filter rule',
      refreshing: _busy,
      footer: FilledButton.icon(
        onPressed: _busy || _hasErrors ? null : _add,
        icon: const Icon(Icons.add),
        label: Text(widget.index == null ? 'Add rule' : 'Save rule'),
      ),
      children: [
        if (_problem != null) ErrorBanner(_problem!),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Every condition must match for the rule to act. The first '
            'matching rule wins.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        const SectionHeader('Action'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'drop', label: Text('Drop')),
              ButtonSegment(value: 'forward', label: Text('Forward')),
            ],
            selected: {_action},
            onSelectionChanged: (s) => setState(() => _action = s.first),
          ),
        ),
        const SectionHeader('Conditions'),
        for (final (key, label, hint) in _fields)
          SettingField(
            key: Key(key),
            label: label,
            value: _value(key).isEmpty ? null : _value(key),
            help: hint,
            error: _fieldError(key),
            onChanged: (v) => setState(() => _controllers[key]!.text = v),
          ),
        const SectionHeader('Paste a regex'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _regex,
            onChanged: (_) => setState(() {}),
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Common regex to translate',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: OutlinedButton.icon(
            onPressed: _translate,
            icon: const Icon(Icons.translate),
            label: const Text('Translate'),
          ),
        ),
        if (_translation != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_translation!.result,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
          for (final warning in _translation!.warnings)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Text(warning,
                  style: const TextStyle(color: OtaTheme.warn, fontSize: 11)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: OutlinedButton(
              onPressed: _applyTranslation,
              child: const Text('Use translated pattern'),
            ),
          ),
        ],
        const SectionHeader('Dry run'),
        for (final sample in _samples) ...[
          for (final key in ['sender', 'text'])
            if (_value(key).isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '${sample.sender}: ${sample.text}  ->  '
                  '${dryRun(_value(key), key == 'sender' ? sample.sender : sample.text).matched ? 'matches' : 'no match'} '
                  '($key)',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
        ],
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('Advisory only. The repeater is the authority.',
              style: TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
        ),
        const SectionHeader('Command preview'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(command,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: OtaTheme.accent)),
        ),
      ],
    );
  }
}
