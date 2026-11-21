// MQTT observer contract: key registry and status-line parsers. The firmware
// echoes password/token/pwd on read; the app never requests those keys.

import 'setting_spec.dart';

class MqttKey {
  const MqttKey(this.key, this.label, this.input, this.secret);

  final String key;
  final String label;
  final SettingInput input;
  final bool secret;
}

const mqttSharedKeys = <MqttKey>[
  MqttKey('mqtt.iata', 'IATA code', SettingInput.text, false),
  MqttKey('mqtt.origin', 'Origin name', SettingInput.text, false),
  MqttKey('mqtt.ntp', 'NTP server', SettingInput.text, false),
  MqttKey(
      'mqtt.interval', 'Status interval (minutes)', SettingInput.number, false),
  MqttKey('mqtt.rx', 'Receive', SettingInput.toggle, false),
  MqttKey('mqtt.status', 'Publish status', SettingInput.toggle, false),
  MqttKey('mqtt.packets', 'Publish packets', SettingInput.toggle, false),
  MqttKey('mqtt.raw', 'Publish raw frames', SettingInput.toggle, false),
  MqttKey('mqtt.tx', 'Own transmissions', SettingInput.text, false),
];

const wifiKeys = <MqttKey>[
  MqttKey('wifi.ssid', 'Network name', SettingInput.text, false),
  MqttKey('wifi.pwd', 'Wi-Fi password', SettingInput.text, true),
  MqttKey('wifi.powersave', 'Power saving', SettingInput.text, false),
];

const brokerKeys = <MqttKey>[
  MqttKey('enabled', 'Enabled', SettingInput.toggle, false),
  MqttKey('server', 'Broker address', SettingInput.text, false),
  MqttKey('port', 'Port', SettingInput.number, false),
  MqttKey('username', 'Username', SettingInput.text, false),
  MqttKey('password', 'Password', SettingInput.text, true),
  MqttKey('audience', 'JWT audience', SettingInput.text, false),
  MqttKey('owner', 'Owner key', SettingInput.text, false),
  MqttKey('email', 'Email', SettingInput.text, false),
  MqttKey('topic', 'Topic template', SettingInput.text, false),
  MqttKey('token', 'Topic token', SettingInput.text, true),
];

MqttKey? mqttKeyBySuffix(String suffix) {
  for (final key in brokerKeys) {
    if (key.key == suffix) return key;
  }
  for (final key in [...mqttSharedKeys, ...wifiKeys]) {
    if (key.key == suffix || key.key.endsWith('.$suffix')) return key;
  }
  return null;
}

class MqttStatus {
  const MqttStatus({
    required this.wifi,
    required this.time,
    required this.slots,
    required this.received,
    required this.published,
    required this.dropped,
    required this.queueUsed,
    required this.queueMax,
    this.heapFree,
    this.heapTotal,
  });

  final String wifi;
  final String time;
  final String slots;
  final int received;
  final int published;
  final int dropped;
  final int queueUsed;
  final int queueMax;
  final int? heapFree;
  final int? heapTotal;

  static MqttStatus? parse(String reply) {
    final text = reply.trim();
    if (!text.startsWith('mqtt ')) return null;
    int after(String key) {
      final m = RegExp('$key[:\\s]+(\\d+)').firstMatch(text);
      return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
    }

    final heap = RegExp(r'heap:(\d+)/(\d+)').firstMatch(text);
    return MqttStatus(
      wifi: _field(text, 'wifi') ?? 'unknown',
      time: _field(text, 'time') ?? 'unknown',
      slots: _field(text, 'slots') ?? '0/0',
      received: after('rx'),
      published: after('pub'),
      dropped: after('drop'),
      queueUsed: _numbers(text, 'q')?.$1 ?? 0,
      queueMax: _numbers(text, 'q')?.$2 ?? 0,
      heapFree: heap == null ? null : int.tryParse(heap.group(1)!),
      heapTotal: heap == null ? null : int.tryParse(heap.group(2)!),
    );
  }

  static String? _field(String text, String key) {
    final m = RegExp('$key:([^ ]+)').firstMatch(text);
    return m?.group(1);
  }

  static (int, int)? _numbers(String text, String key) {
    final m = RegExp('$key:(\\d+)/(\\d+)').firstMatch(text);
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }
}

class WifiStatus {
  const WifiStatus(this.connected, this.ip, this.rssi);

  final bool connected;
  final String ip;
  final int? rssi;

  static WifiStatus? parse(String reply) {
    final text = reply.trim();
    if (!text.startsWith('wifi ')) return null;
    final ip = RegExp(r'ip:(\S+)').firstMatch(text)?.group(1) ?? '';
    final rssi =
        int.tryParse(RegExp(r'rssi:(-?\d+)').firstMatch(text)?.group(1) ?? '');
    return WifiStatus(text.startsWith('wifi connected'), ip, rssi);
  }
}

/// `mqtt1 connected wifi:up q:0` / `mqtt2 config wifi:down`.
class BrokerStatus {
  const BrokerStatus(this.slot, this.state, this.wifi);

  final int slot;
  final String state;
  final String wifi;

  static BrokerStatus? parse(String reply, {required int slot}) {
    final text = reply.trim();
    if (!text.startsWith('mqtt$slot ')) return null;
    final parts = text.split(RegExp(r'\s+'));
    return BrokerStatus(
      slot,
      parts.length > 1 ? parts[1] : 'unknown',
      MqttStatus._field(text, 'wifi') ?? 'unknown',
    );
  }
}
