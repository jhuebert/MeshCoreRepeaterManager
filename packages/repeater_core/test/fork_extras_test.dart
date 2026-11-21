import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  test('captured radio2 status parses preset and state', () {
    final off = Radio2Status.parse('off; preset=913.225,62.5,7,8');
    expect(off.enabled, isFalse);
    expect(off.preset, '913.225,62.5,7,8');
    expect(Radio2Status.parse('on; preset=900,250,10,5').enabled, isTrue);
  });

  test('captured battery status parses and validates thresholds', () {
    final status = BatteryStatus.parse('batt 0mV; gate off; drops 0')!;
    expect(status.milliVolts, 0);
    expect(status.gateOn, isFalse);
    expect(status.drops, 0);
    expect(
        BatteryStatus.parse('batt 3900mV; gate on; drops 2')!.gateOn, isTrue);
    expect(BatteryStatus.validate(3800, 3900), isNull);
    expect(BatteryStatus.validate(3900, 3800), contains('Resume'));
    expect(BatteryStatus.validate(0, null), contains('10000'));
  });

  test('captured mesh clock status parses slots and tolerance', () {
    final status = MeshClockStatus.parse(
        'off slots=33/22 tol=60/60 now=2026-03-03T21:07:58Z')!;
    expect(status.enabled, isFalse);
    expect(status.slots, 33);
    expect(status.minVotes, 22);
    expect(status.tolerance, 60);
    expect(status.nowUtc, '2026-03-03T21:07:58Z');
    expect(MeshClockStatus.validateSlots(33, 22), isNull);
    expect(MeshClockStatus.validateSlots(2, 2), contains('3 to 33'));
    expect(MeshClockStatus.validateSlots(10, 11), contains('Votes'));
    expect(MeshClockStatus.validateTolerance(60, 60), isNull);
    expect(MeshClockStatus.validateTolerance(0, 0), contains('1 to 65535'));
  });

  test('captured bot status parses without exposing a channel key', () {
    final status = BotStatus.parse('bot: off, name (node), chan (none)');
    expect(status.enabled, isFalse);
    expect(status.name, '(node)');
    expect(status.channel, '(none)');
    expect(BotStatus.validateName('MyBot'), isNull);
    expect(BotStatus.validateName('x' * 17), contains('16'));
    expect(BotStatus.validateChannel('#memes'), isNull);
    expect(BotStatus.validateChannel('off'), isNull);
    expect(BotStatus.validateChannel('not a channel'), isNotNull);
  });

  test('captured rx power status parses and enforces radio2 exclusion', () {
    final status = RxpsStatus.parse(
        '> desired=off,effective=continuous,supported=yes,err=0,fail=0,'
        'level=8,catch=8.2,preamble=0,rx=4063,sleep=6085')!;
    expect(status.desired, 'off');
    expect(status.effective, 'continuous');
    expect(status.supported, isTrue);
    expect(status.level, 8);
    expect(status.rxMicros, 4063);
    expect(status.sleepMicros, 6085);
    expect(RxpsStatus.parse('Unknown command'), isNull);
    expect(RxpsStatus.validateRadio2Conflict(true), isNotNull);
    expect(RxpsStatus.validateRadio2Conflict(false), isNull);
    expect(RxpsStatus.validateLevel(11), isNotNull);
    expect(RxpsStatus.validatePreamble(24), isNotNull);
    expect(cpuFrequencies, contains(240));
  });
}
