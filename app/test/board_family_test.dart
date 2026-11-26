import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/board_family.dart';

void main() {
  test('matches a board reply against a known ESP32 environment', () {
    const envs = ['heltec_v3', 'xiao_s3_wio', 'station_g2', 'rak4631'];
    expect(esp32EnvironmentForBoard('Heltec V3', envs), 'heltec_v3');
    expect(esp32EnvironmentForBoard('Xiao S3 WIO', envs), 'xiao_s3_wio');
    expect(esp32EnvironmentForBoard('Station G2', envs), 'station_g2');
  });

  test('matches partial manufacturer names without guessing', () {
    expect(esp32EnvironmentForBoard('T-Beam', ['lilygo_tbeam_SX1262']),
        'lilygo_tbeam_SX1262');
    expect(esp32EnvironmentForBoard('Unlisted board', ['heltec_v3']), isNull);
    expect(esp32EnvironmentForBoard('', ['heltec_v3']), isNull);
  });

  test('never infers WiFi support from a non-ESP32 environment', () {
    expect(esp32EnvironmentForBoard('RAK 4631', ['rak4631_nrf52']), isNull);
    expect(esp32EnvironmentForBoard('Xiao RP2040', ['xiao_rp2040']), isNull);
  });
}
