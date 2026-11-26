import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

void main() {
  group('OtaStatus.parse', () {
    test('parses the frozen line', () {
      final status = OtaStatus.parse(
          'running=1.18.0 sha=0123456789abcdef state=ready size=1194441 off=1194441 err=0');
      expect(status, isNotNull);
      expect(status!.running, '1.18.0');
      expect(status.shaPrefix, '0123456789abcdef');
      expect(status.state, OtaPhase.ready);
      expect(status.size, 1194441);
      expect(status.offset, 1194441);
      expect(status.err, 0);
      expect(status.ok, isTrue);
    });

    test('parses every state keyword', () {
      for (final entry in const {
        'idle': OtaPhase.idle,
        'staging': OtaPhase.staging,
        'ready': OtaPhase.ready,
        'error': OtaPhase.error,
        'unsupported': OtaPhase.unsupported,
      }.entries) {
        final status = OtaStatus.parse(
            'running=v sha=0000000000000000 state=${entry.key} size=0 off=0 err=9');
        expect(status?.state, entry.value, reason: entry.key);
      }
    });

    test('unsupported with zeroed sha is a normal reply', () {
      final status = OtaStatus.parse(
          'running=1.18.0 sha=0000000000000000 state=unsupported size=0 off=0 err=0');
      expect(status!.state, OtaPhase.unsupported);
    });

    test('rejects anything that is not the frozen line', () {
      expect(OtaStatus.parse(''), isNull);
      expect(OtaStatus.parse('Err - OTA unsupported on this platform'), isNull);
      expect(OtaStatus.parse('usage: ota ...'), isNull);
      expect(OtaStatus.parse('running=v sha=zz state=idle size=0 off=0 err=0'),
          isNull);
      expect(
          OtaStatus.parse(
              'running=v sha=0000000000000000 state=staging size=1 off=0 err=0 extra'),
          isNull);
    });
  });

  group('classifyApplyOutcome', () {
    OtaStatus status({
      String sha = '1111111111111111',
      String state = 'idle',
      int size = 100,
      int err = 0,
    }) =>
        OtaStatus.parse(
            'running=v sha=$sha state=$state size=$size off=$size err=$err')!;

    ApplyOutcome classify(OtaStatus? s) => classifyApplyOutcome(
          s,
          expectedShaPrefix: 'aaaaaaaaaaaaaaaa',
          expectedSize: 100,
        );

    test('a running-image hash match is the only verified outcome', () {
      expect(classify(status(sha: 'AAAAAAAAAAAAAAAA')), ApplyOutcome.verified);
      expect(classify(status(sha: '1111111111111111', state: 'ready')),
          isNot(ApplyOutcome.verified));
    });

    test('a verified staged slot means the apply did not commit', () {
      expect(classify(status(state: 'ready')), ApplyOutcome.stagedNotApplied);
      // A different size is not our staged image.
      expect(classify(status(state: 'ready', size: 99)),
          isNot(ApplyOutcome.stagedNotApplied));
    });

    test('an old running image or an error is a definite non-success', () {
      expect(classify(status()), ApplyOutcome.rolledBack);
      expect(classify(status(err: 4)), ApplyOutcome.failed);
      expect(classify(status(state: 'error')), ApplyOutcome.failed);
    });

    test('no answer yet means keep polling', () {
      expect(classify(null), ApplyOutcome.unknown);
    });
  });

  group('error labels', () {
    test('labels the frozen codes', () {
      expect(otaErrLabel(0), 'OK');
      expect(otaErrLabel(1), isNot('OK'));
      expect(otaErrLabel(7), contains('token'));
      for (var code = 10; code <= 16; code++) {
        expect(otaErrLabel(code), isNot(contains('unknown')));
      }
      expect(otaErrLabel(123), contains('123'));
    });
  });

  group('parseStageReply', () {
    test('parses the frozen success line', () {
      final reply =
          parseStageReply('OK - staging armed (size=1194441) token=deadbeef');
      expect(reply, isNotNull);
      expect(reply!.size, 1194441);
      expect(reply.token, 0xDEADBEEF);
    });

    test('failure replies do not parse as success', () {
      expect(parseStageReply('Err - battery gate active; staging refused'),
          isNull);
      expect(parseStageReply('Err - size must be 1..2147483647'), isNull);
    });
  });

  group('apply/rollback reply markers', () {
    test('accepts the frozen success lines', () {
      expect(isApplyReply('OK - applied; rebooting'), isTrue);
      expect(isRollbackReply('OK - rolling back; rebooting'), isTrue);
    });

    test('rejects failure replies', () {
      expect(
          isApplyReply('Err - no verified staging (see ota status)'), isFalse);
      expect(isRollbackReply('Err - could not set boot partition'), isFalse);
      expect(isCliErrorReply('Err - whatever'), isTrue);
      expect(isCliErrorReply('OK - applied; rebooting'), isFalse);
    });
  });
}
