import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  group('classifyProbe', () {
    test('stock negative signatures', () {
      expect(classifyProbe('filter', 'Unknown command'),
          ProbeVerdict.stockNegative);
      expect(classifyProbe('get cpu.freq', '??: cpu.freq'),
          ProbeVerdict.stockNegative);
    });

    test('fork positive signatures', () {
      expect(
          classifyProbe('ota status', 'running=v1.2 sha=deadbeef state=idle'),
          ProbeVerdict.forkPositive);
      expect(classifyProbe('filter', 'Err - usage: on|off|add'),
          ProbeVerdict.forkPositive);
      expect(classifyProbe('radio2 status', 'off; preset=915,250,10,5'),
          ProbeVerdict.forkPositive);
      expect(classifyProbe('get radio.rxps', '> desired=on,effective=on'),
          ProbeVerdict.forkPositive);
    });

    test('silence and unrecognised text are unknown', () {
      expect(classifyProbe('filter', ''), ProbeVerdict.unknown);
      expect(classifyProbe('bot', 'something else'), ProbeVerdict.unknown);
    });
  });

  group('captured fork firmware replies', () {
    const replies = <String, String>{
      'ota status': 'running=v1.18.0-ota2 sha=aabbccdd state=idle',
      'filter':
          'on; rules 0/32; chans 1/32; ratelimit advert 0h; cache 0/512; limiter 0; aborted 0',
      'fleet':
          'off, chan -, tags 0/8; scripts ran:0 dup:0 noid:0 refused:0; pending 0/2; sched 0/2; seen 0/32; ackq 0/2 await 0 rtx 0; badline 0; crowded 0',
      'radio2 status': 'off; preset=913.225,62.5,7,8',
      'get mqtt.status':
          'mqtt wifi:down time:ok slots:0/0 rx:3851 pub:0 drop:0 q:0/8 heap:249584/229364',
      'battery': 'batt 0mV; gate off; drops 0',
      'clock mesh': 'off slots=33/22 tol=60/60 now=2026-03-03T21:07:58Z',
      'bot': 'bot: off, name (node), chan (none)',
      'get cpu.freq': '> 80',
      'get radio.rxps':
          '> desired=off,effective=continuous,supported=yes,err=0,fail=0,level=8,catch=8.2,preamble=0,rx=4063,sleep=6085',
    };

    test('every probe is recognised as fork positive', () {
      for (final entry in replies.entries) {
        expect(classifyProbe(entry.key, entry.value), ProbeVerdict.forkPositive,
            reason: '${entry.key} => ${entry.value}');
      }
    });

    test('the full probe set identifies every fork feature', () {
      final caps = detectCapabilities(replies: replies, otaConfirmed: true);
      expect(caps.firmwareKind, FirmwareKind.fork);
      expect(caps.confidence, CapabilityConfidence.confirmed);
      for (final feature in [
        'ota',
        'filter',
        'fleet',
        'mqtt',
        'radio2',
        'batteryGate',
        'meshClock',
        'bot',
        'powerProfile',
      ]) {
        expect(caps.supports(feature), isTrue, reason: feature);
      }
    });
  });

  group('detectCapabilities', () {
    test('an unanswered probe set leaves everything unknown', () {
      final c = detectCapabilities(replies: {
        'filter': null,
        'fleet': '',
      });
      expect(c.firmwareKind, FirmwareKind.unknown);
      expect(c.confidence, CapabilityConfidence.unknown);
      expect(c.supports('filter'), isFalse);
    });

    test('a single hit is tentative', () {
      final c = detectCapabilities(replies: {'filter': 'Err - usage: on|off'});
      expect(c.firmwareKind, FirmwareKind.fork);
      expect(c.confidence, CapabilityConfidence.tentative);
      expect(c.filter, isTrue);
    });

    test('three positive probes confirm the fork and its extras', () {
      final c = detectCapabilities(replies: {
        'filter': 'Err - usage: on|off|add',
        'fleet': 'Err - usage: on|off|chan',
        'radio2 status': 'on; preset=915,250,10,5',
        'battery': 'batt 4100mV; gate off',
      });
      expect(c.firmwareKind, FirmwareKind.fork);
      expect(c.confidence, CapabilityConfidence.confirmed);
      expect(c.filter, isTrue);
      expect(c.fleet, isTrue);
      expect(c.radio2, isTrue);
      expect(c.batteryGate, isTrue);
      expect(c.mqtt, isFalse);
    });

    test('two stock negatives confirm stock', () {
      final c = detectCapabilities(replies: {
        'filter': 'Unknown command',
        'fleet': 'Unknown command',
      });
      expect(c.firmwareKind, FirmwareKind.stock);
      expect(c.confidence, CapabilityConfidence.confirmed);
      expect(c.filter, isFalse);
    });

    test('OTA confirmation is decisive on its own', () {
      final c = detectCapabilities(
          replies: {'ota status': 'running=v1 sha=aa state=idle'},
          otaConfirmed: true);
      expect(c.firmwareKind, FirmwareKind.fork);
      expect(c.confidence, CapabilityConfidence.confirmed);
      expect(c.ota, isTrue);
    });

    test('evidence and json survive a roundtrip', () {
      final c = detectCapabilities(replies: {
        'filter': 'Err - usage: on|off',
        'fleet': 'Err - usage: chan',
        'bot': 'bot: on/off, name',
      }, otaConfirmed: true);
      final copy = RepeaterCapabilities.fromJson(c.toJson());
      expect(copy.firmwareKind, c.firmwareKind);
      expect(copy.confidence, c.confidence);
      expect(copy.bot, isTrue);
      expect(copy.evidence['filter'], c.evidence['filter']);
      expect(copy.copyWithOtaFeatures(7).otaFeatures, 7);
    });
  });
}
