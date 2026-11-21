import 'package:flutter/material.dart';
import 'package:device_link/device_link.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/ack_collector.dart';
import '../../services/fleet_sender.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Compose one fleet job, preview the exact text and confirm before sending.
class FleetComposerScreen extends StatefulWidget {
  const FleetComposerScreen({
    super.key,
    this.link,
    this.availableTags = const [],
    this.psk,
    this.collector,
  });

  final RadioLink? link;
  final List<String> availableTags;
  final String? psk;
  final AckCollector? collector;

  @override
  State<FleetComposerScreen> createState() => _FleetComposerScreenState();
}

class _FleetComposerScreenState extends State<FleetComposerScreen> {
  late final TextEditingController _id;
  final _commands = TextEditingController();
  final _delay = TextEditingController();
  final _at = TextEditingController();
  final _selectedTags = <String>{};
  bool _ack = false;
  bool _ackErr = false;
  bool _scheduled = false;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _id = TextEditingController(text: generateJobId(DateTime.now()));
    _commands.text = 'ver';
    _at.text = DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch
        .toString();
  }

  @override
  void dispose() {
    _id.dispose();
    _commands.dispose();
    _delay.dispose();
    _at.dispose();
    super.dispose();
  }

  FleetJob _job() {
    final lines = _commands.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final delay = int.tryParse(_delay.text.trim());
    return FleetJob(
      id: _id.text.trim(),
      tags: _selectedTags.toList()..sort(),
      ack: _ack,
      ackErrOnly: _ackErr,
      at: _scheduled ? int.tryParse(_at.text.trim()) : null,
      delayMs: (delay != null && delay > 0) ? delay : null,
      commands: lines,
    );
  }

  String? get _script {
    try {
      return composeJob(_job());
    } on ArgumentError {
      return null;
    }
  }

  String? get _validation {
    final error = _job().validate();
    if (error != null) return error;
    final script = _script;
    if (script != null && scriptBytes(script) > FleetJob.byteLimit) {
      return 'Script is ${scriptBytes(script)} bytes; the limit is '
          '${FleetJob.byteLimit}. Use a shorter job.';
    }
    if (_scheduled && int.tryParse(_at.text.trim()) == null) {
      return 'Enter a device-clock Unix timestamp for the schedule';
    }
    return null;
  }

  Future<void> _send() async {
    final script = _script;
    final app = context.read<AppState>();
    final error = _validation;
    if (script == null || error != null) {
      setState(() => _problem = error);
      return;
    }
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Send this job?'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      'Tags: ${_selectedTags.isEmpty ? 'all' : _selectedTags.join(', ')}'),
                  Text(
                      'ACK: ${_ack ? (_ackErr ? 'errors only' : 'always') : 'none'}'),
                  Text(
                      'Schedule: ${_scheduled ? 'on device at ${_at.text}' : 'now'}'),
                  const SizedBox(height: 8),
                  Text(script,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Send')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    final link = widget.link ?? app.connection.link;
    final psk = widget.psk ?? app.fleetPsk;
    final sender = FleetSender(
        link: link!, pskHex: psk, senderName: app.connection.companionName);
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await sender.send(script);
      final job = _job();
      (widget.collector ?? app.ackCollector).track(FleetJobResult(
        id: job.id,
        script: script,
        sentAt: DateTime.now(),
        tags: job.tags,
      ));
      await app.recordFleetSend(job.id, script);
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } catch (e) {
      if (mounted) setState(() => _problem = 'Send failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final script = _script ?? '';
    final bytes = scriptBytes(script);
    return ManagementScaffold(
      title: 'Fleet composer',
      refreshing: _busy,
      footer: FilledButton.icon(
        onPressed: _busy || _validation != null ? null : _send,
        icon: const Icon(Icons.send),
        label: const Text('Send'),
      ),
      children: [
        if (_problem != null) ErrorBanner(_problem!),
        if (_validation != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_validation!,
                style: const TextStyle(color: OtaTheme.bad, fontSize: 12)),
          ),
        const SectionHeader('Job'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const Key('fleet-id'),
            controller: _id,
            decoration: const InputDecoration(
                labelText: 'Job id', border: OutlineInputBorder()),
            autocorrect: false,
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SectionHeader('Tags'),
        if (widget.availableTags.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('No tags on the repeaters yet. Sending to all.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          ),
        for (final tag in widget.availableTags)
          CheckboxListTile(
            title: Text(tag),
            value: _selectedTags.contains(tag),
            onChanged: (v) => setState(() {
              if (v == true) {
                _selectedTags.add(tag);
              } else {
                _selectedTags.remove(tag);
              }
            }),
          ),
        const SectionHeader('Replies and timing'),
        SwitchListTile(
          title: const Text('Ask for replies'),
          subtitle: const Text('Each repeater answers with the job result.'),
          value: _ack,
          onChanged: (v) => setState(() {
            _ack = v;
            if (!v) _ackErr = false;
          }),
        ),
        if (_ack)
          SwitchListTile(
            title: const Text('Only report errors'),
            value: _ackErr,
            onChanged: (v) => setState(() => _ackErr = v),
          ),
        SwitchListTile(
          title: const Text('Schedule on the repeater'),
          subtitle: const Text(
              'Uses the device clock. Jobs kept in RAM are lost on reboot.'),
          value: _scheduled,
          onChanged: (v) => setState(() => _scheduled = v),
        ),
        if (_scheduled)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('fleet-at'),
              controller: _at,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Device Unix timestamp',
                  border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            key: const Key('fleet-delay'),
            controller: _delay,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Delay between lines, ms',
                border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SectionHeader('Commands, one per line'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const Key('fleet-commands'),
            controller: _commands,
            maxLines: 5,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), hintText: 'ver\nget radio'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SectionHeader('Preview'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(script.isEmpty ? '(nothing yet)' : script,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('$bytes / ${FleetJob.byteLimit} bytes',
              style: TextStyle(
                  color: bytes > FleetJob.byteLimit
                      ? OtaTheme.bad
                      : OtaTheme.textMuted,
                  fontSize: 12)),
        ),
      ],
    );
  }
}
