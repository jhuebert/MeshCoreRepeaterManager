import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

void main() {
  test('parses each frozen ota net phase', () {
    for (final phase in WifiNetPhase.values) {
      final status = WifiNetStatus.parse(
          'net=${phase.name} ver=1.18.0-r4 sha=39483a72 got=4096 size=8192 err=0');
      expect(status, isNotNull);
      expect(status!.phase, phase);
      expect(status.version, '1.18.0-r4');
      expect(status.shaPrefix, '39483a72');
      expect(status.received, 4096);
      expect(status.size, 8192);
      expect(status.err, 0);
      expect(status.ok, isTrue);
    }
  });

  test('parses the idle line with empty version and zero sha', () {
    final status =
        WifiNetStatus.parse('net=idle ver= sha=00000000 got=0 size=0 err=0');
    expect(status, isNotNull);
    expect(status!.phase, WifiNetPhase.idle);
    expect(status.version, isEmpty);
  });

  test('rejects unknown phases and malformed lines', () {
    expect(
        WifiNetStatus.parse('net=bogus ver=1 sha=00000000 got=0 size=0 err=0'),
        isNull);
    expect(WifiNetStatus.parse('net=idle'), isNull);
    expect(
        WifiNetStatus.parse('net=error ver=1 sha=zzzzzzzz got=0 size=0 err=11'),
        isNull);
    expect(
        WifiNetStatus.parse('net=error ver=1 sha=00000000 got=0 size=0 err=11')!
            .ok,
        isFalse);
  });
}
