import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../services/secret_store.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// MQTT observer configuration. Secret fields are write-only: the app never
/// reads them back, never caches them and clears the draft after saving.
class MqttScreen extends StatefulWidget {
  const MqttScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<MqttScreen> createState() => _MqttScreenState();
}

class _MqttScreenState extends State<MqttScreen> {
  MqttStatus? _status;
  WifiStatus? _wifi;
  final Map<int, BrokerStatus?> _brokers = {};
  final Map<String, String> _values = {};
  final Map<String, String> _drafts = {};
  final Map<String, TextEditingController> _controllers = {};
  bool _busy = false;
  String? _problem;

  TextEditingController _controller(String key) =>
      _controllers.putIfAbsent(key, () => TextEditingController());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refresh();
      await _loadRemembered();
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadRemembered() async {
    final store = context.read<AppState>().secretStore;
    if (store == null || !mounted) return;
    for (final field in SecretField.values) {
      if (!store.isRemembered(field)) continue;
      final value = await store.resolve(field, '');
      if (!mounted) return;
      setState(() {
        _controller(field.storageKey).text = value;
        _drafts[field.storageKey] = value;
      });
    }
  }

  CliService? _cli() => widget.cli ?? context.read<AppState>().managementCli();
  Contact? _target() => context.read<AppState>().target;

  Future<void> _refresh() async {
    final cli = _cli();
    final target = _target();
    if (cli == null || target == null) return;
    setState(() => _busy = true);
    final statusText = await cli.read(target, 'get mqtt.status');
    final wifiText = await cli.read(target, 'get wifi.status');
    final one = await cli.read(target, 'get mqtt1.status');
    final two = await cli.read(target, 'get mqtt2.status');
    final keys = [
      ...mqttSharedKeys.where((k) => !k.secret).map((k) => k.key),
      ...wifiKeys.where((k) => !k.secret).map((k) => k.key),
      for (final slot in [1, 2])
        ...brokerKeys.where((k) => !k.secret).map((k) => 'mqtt$slot.${k.key}'),
    ];
    final values = <String, String>{};
    for (final key in keys) {
      final reply = await cli.read(target, 'get $key');
      if (reply.ok) values[key] = reply.value;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = MqttStatus.parse(statusText.text);
      _wifi = WifiStatus.parse(wifiText.text);
      _brokers[1] = BrokerStatus.parse(one.text, slot: 1);
      _brokers[2] = BrokerStatus.parse(two.text, slot: 2);
      _values
        ..clear()
        ..addAll(values);
      if (!statusText.ok && !wifiText.ok) {
        _problem = 'No answer from the repeater. Outcome unknown; try again.';
      }
    });
    for (final entry in values.entries) {
      if (_drafts.containsKey(entry.key)) continue;
      final controller = _controller(entry.key);
      if (controller.text != entry.value) controller.text = entry.value;
    }
  }

  Future<void> _saveCard(Iterable<String> keys) async {
    final cli = _cli();
    final target = _target();
    final store = context.read<AppState>().secretStore;
    if (cli == null || target == null) return;
    final pending = keys.where(_drafts.containsKey).toList();
    if (pending.isEmpty) return;
    setState(() => _busy = true);
    for (final key in pending) {
      final reply =
          await cli.write(target, 'set $key ${_drafts[key]}', family: 'mqtt');
      final spec = mqttKeyBySuffix(key.split('.').last);
      final isSecret = spec?.secret ?? false;
      if (reply.ok && !isSecret) {
        _values[key] = _drafts[key]!;
      }
      if (isSecret) {
        final field = secretFieldForConfigKey(key);
        if (reply.ok &&
            field != null &&
            store != null &&
            store.isRemembered(field)) {
          await store.remember(field, _drafts[key]!);
        } else {
          // Not opted in: the secret leaves this screen after the write.
          _controller(key).clear();
        }
      }
      _drafts.remove(key);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _recover() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Reconnect Wi-Fi?'),
            content: const Text(
              'The repeater drops and rejoins the Wi-Fi station, then '
              'reconnects both MQTT slots.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Reconnect')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    final cli = _cli();
    final target = _target();
    if (cli == null || target == null) return;
    await cli.write(target, 'mqtt recover', family: 'mqtt');
  }

  Widget _keyRow(MqttKey spec, String fullKey) {
    final secret = spec.secret;
    final controller = _controller(fullKey);
    if (secret) {
      final field = secretFieldForConfigKey(fullKey);
      final store = context.read<AppState>().secretStore;
      return SecretFieldControl(
        label: spec.label,
        fieldKey: fullKey,
        controller: controller,
        onChanged: (v) => setState(() => _drafts[fullKey] = v),
        eligible: field != null,
        storeAvailable: store?.available ?? false,
        remembered: field == null ? false : store?.isRemembered(field) ?? false,
        onRemember: (value) async {
          if (store == null || field == null) return;
          if (value) {
            await store.remember(field, controller.text.trim());
          } else {
            await store.forget(field);
          }
        },
        onForget: () async {
          if (store == null || field == null) return;
          await store.forget(field);
          controller.clear();
          _drafts.remove(fullKey);
        },
        help: 'Write only. The repeater echoes these on read, so the app '
            'never requests them.',
      );
    }
    // Non-secret values are loaded from the node on refresh.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        key: Key(fullKey),
        controller: controller,
        autocorrect: false,
        onChanged: (v) => setState(() => _drafts[fullKey] = v),
        decoration: InputDecoration(
          labelText: spec.label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the opt-in store changes so the remember controls reflect
    // what is actually saved.
    context.watch<AppState>();
    final status = _status;
    return ManagementScaffold(
      title: 'MQTT observer',
      onRefresh: _refresh,
      refreshing: _busy,
      children: [
        if (_problem != null) ErrorBanner(_problem!),
        const SectionHeader('Status'),
        if (status == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Not read yet.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
          )
        else ...[
          InfoRow(label: 'Wi-Fi', value: status.wifi),
          InfoRow(label: 'Clock', value: status.time),
          InfoRow(label: 'Slots', value: status.slots),
          InfoRow(label: 'Received', value: '${status.received}'),
          InfoRow(label: 'Published', value: '${status.published}'),
          InfoRow(
              label: 'Queue', value: '${status.queueUsed}/${status.queueMax}'),
        ],
        if (_wifi != null)
          InfoRow(
              label: 'Address',
              value: _wifi!.connected
                  ? '${_wifi!.ip} (${_wifi!.rssi ?? 0} dBm)'
                  : 'not connected'),
        for (final slot in [1, 2])
          Builder(
            builder: (context) {
              final keys = brokerKeys.map((k) => 'mqtt$slot.${k.key}').toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader('Broker $slot'),
                  if (_brokers[slot] != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                          '${_brokers[slot]!.state}, Wi-Fi ${_brokers[slot]!.wifi}',
                          style: const TextStyle(
                              color: OtaTheme.textMuted, fontSize: 12)),
                    ),
                  for (final spec in brokerKeys)
                    _keyRow(spec, 'mqtt$slot.${spec.key}'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _saveCard(keys),
                      child: Text('Save broker $slot'),
                    ),
                  ),
                ],
              );
            },
          ),
        const SectionHeader('Shared MQTT settings'),
        for (final spec in mqttSharedKeys) _keyRow(spec, spec.key),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: _busy
                ? null
                : () => _saveCard(mqttSharedKeys.map((k) => k.key)),
            child: const Text('Save shared settings'),
          ),
        ),
        const SectionHeader('Wi-Fi'),
        for (final spec in wifiKeys) _keyRow(spec, spec.key),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed:
                _busy ? null : () => _saveCard(wifiKeys.map((k) => k.key)),
            child: const Text('Save Wi-Fi'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _recover,
            icon: const Icon(Icons.wifi),
            label: const Text('Reconnect Wi-Fi'),
          ),
        ),
      ],
    );
  }
}
