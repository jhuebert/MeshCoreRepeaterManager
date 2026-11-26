import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/wifi_status.dart';

void main() {
  test('reads the observer status line', () {
    expect(parseWifiStatus('wifi connected ip:192.0.2.10 rssi:-58'),
        WifiLinkState.connected);
    expect(parseWifiStatus('wifi disconnected ip:0.0.0.0 rssi:0'),
        WifiLinkState.disconnected);
  });

  test('reads the MQTT dashboard fallback', () {
    expect(parseWifiStatus('mqtt wifi:up time:ok slots:1/2'),
        WifiLinkState.connected);
    expect(parseWifiStatus('mqtt wifi:down time:wait slots:0/2'),
        WifiLinkState.disconnected);
  });

  test('an unanswered probe stays unknown', () {
    expect(parseWifiStatus(null), WifiLinkState.unknown);
    expect(parseWifiStatus(''), WifiLinkState.unknown);
    expect(parseWifiStatus('Unknown command'), WifiLinkState.unknown);
  });

  test('the SSID read never treats "not set" as a network', () {
    expect(parseWifiSsid('My Network'), 'My Network');
    expect(parseWifiSsid('not set'), isNull);
    expect(parseWifiSsid(''), isNull);
    expect(parseWifiSsid(null), isNull);
  });
}
