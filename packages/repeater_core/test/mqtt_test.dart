import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  test('combined status line from captured firmware parses', () {
    final status = MqttStatus.parse(
        'mqtt wifi:down time:ok slots:0/0 rx:3851 pub:0 drop:0 q:0/8 heap:249584/229364')!;
    expect(status.wifi, 'down');
    expect(status.time, 'ok');
    expect(status.slots, '0/0');
    expect(status.received, 3851);
    expect(status.published, 0);
    expect(status.dropped, 0);
    expect(status.queueUsed, 0);
    expect(status.queueMax, 8);
    expect(status.heapFree, 249584);
    expect(MqttStatus.parse('Unknown command'), isNull);
  });

  test('wifi and broker status lines parse', () {
    final wifi = WifiStatus.parse('wifi connected ip:192.0.2.10 rssi:-58')!;
    expect(wifi.connected, isTrue);
    expect(wifi.ip, '192.0.2.10');
    expect(wifi.rssi, -58);
    expect(WifiStatus.parse('wifi off')!.connected, isFalse);

    final broker = BrokerStatus.parse('mqtt1 connected wifi:up q:0', slot: 1)!;
    expect(broker.state, 'connected');
    expect(broker.wifi, 'up');
    expect(
        BrokerStatus.parse('mqtt2 config wifi:down', slot: 2)!.state, 'config');
  });

  test('secret keys are marked so the app never reads them', () {
    expect(mqttKeyBySuffix('password')!.secret, isTrue);
    expect(mqttKeyBySuffix('token')!.secret, isTrue);
    expect(mqttKeyBySuffix('wifi.pwd')!.secret, isTrue);
    expect(mqttKeyBySuffix('server')!.secret, isFalse);
    expect(mqttKeyBySuffix('iata')!.secret, isFalse);
    expect(brokerKeys.any((k) => k.secret), isTrue);
  });

  test('interval validation uses the shared numeric spec', () {
    final interval = mqttSharedKeys.firstWhere((k) => k.key == 'mqtt.interval');
    expect(interval.input, SettingInput.number);
    expect(
        SettingSpec(
                key: interval.key,
                label: interval.label,
                section: 'MQTT',
                input: interval.input,
                min: 1,
                max: 60)
            .validate('61'),
        contains('at most'));
  });
}
