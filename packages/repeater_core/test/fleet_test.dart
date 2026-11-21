import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  group('script composition', () {
    test('directives come before commands and tags are exact', () {
      final script = composeJob(const FleetJob(
        id: 'upd-2026-a1',
        tags: ['north', 'rooftop'],
        ack: true,
        delayMs: 1500,
        commands: ['set tx 20', 'get radio'],
      ));
      expect(script, '''
!id upd-2026-a1
!tags north,rooftop
!ack
!delay 1500
set tx 20
!delay 1500
get radio''');
      expect(scriptBytes(script), lessThan(FleetJob.byteLimit));
    });

    test('error-only ACK and device schedule are supported', () {
      final at = DateTime.utc(2026, 11, 21).millisecondsSinceEpoch ~/ 1000;
      expect(
          composeJob(FleetJob(
              id: 'cutover',
              ack: true,
              ackErrOnly: true,
              at: at,
              commands: ['time $at', 'reboot'])),
          contains('!at $at\n'));
      expect(composeJob(const FleetJob(id: 'x', ack: true, commands: ['ver'])),
          contains('\n!ack\n'));
    });

    test('unknown directives and a leading delay are refused', () {
      expect(() => composeJob(const FleetJob(id: 'x', commands: ['!delay 5'])),
          throwsA(isA<ArgumentError>()));
      expect(
          () => composeJob(
              const FleetJob(id: 'x', commands: ['ver', '!bogus 1'])),
          throwsA(isA<ArgumentError>()));
      expect(
          () => composeJob(FleetJob(
              id: 'x', commands: ['ver'], tags: List.filled(9, 'tag'))),
          throwsA(isA<ArgumentError>()));
      expect(
          composeJob(const FleetJob(id: 'x', commands: ['ver']))
              .contains('!ack'),
          isFalse);
    });

    test('ids are valid and generated ones are unique enough', () {
      expect(
          const FleetJob(id: 'a.b_c-1', commands: ['ver']).validate(), isNull);
      expect(const FleetJob(id: 'bad id', commands: ['ver']).validate(),
          isNotNull);
      final one = generateJobId(DateTime.utc(2026, 11, 21, 10, 30));
      final two = generateJobId(DateTime.utc(2026, 11, 21, 10, 31));
      expect(one, isNot(two));
      expect(RegExp(r'^[A-Za-z0-9._-]{1,32}$').hasMatch(one), isTrue);
    });
  });

  group('acknowledgements', () {
    test('single-command reply keeps the actual command output', () {
      final ack = FleetAck.parse(
        senderName: 'Roof',
        text: 'stats rx:12 fwd:34',
        at: DateTime.utc(2026, 11, 21),
      );
      expect(ack.jobId, 'stats');
      expect(ack.output, 'rx:12 fwd:34');
      expect(ackMatches(ack, 'stats'), isTrue);
      expect(ackMatches(ack, 'other'), isFalse);
    });

    test('multi-command summary sets the outcome', () {
      final ok = FleetAck.parse(
          senderName: 'Roof', text: 'job ran 2 ok', at: DateTime.now());
      expect(ok.ok, isTrue);
      final bad = FleetAck.parse(
          senderName: 'Roof',
          text: 'job ran 2; err: Unknown command',
          at: DateTime.now());
      expect(bad.ok, isFalse);
      expect(bad.output, contains('Unknown command'));
    });

    test('a cut reply is marked, not silently trusted', () {
      final ack = FleetAck.parse(
          senderName: 'Roof', text: 'job some output...', at: DateTime.now());
      expect(ack.output, contains('reply was cut'));
    });
  });

  group('channel frames', () {
    Uint8List channelFrame(String text, {bool v3 = true}) {
      final bytes = utf8.encode('Roof: $text');
      return Uint8List.fromList([
        v3 ? respCodeChannelMsgRecvV3 : respCodeChannelMsgRecv,
        if (v3) ...[24, 0, 0],
        1, // channel index
        0xFF, // path length: flooded
        0, // plain text
        1,
        2,
        3,
        4, // timestamp
        ...bytes,
        0,
      ]);
    }

    test('parses v3 and legacy frames', () {
      for (final v3 in [true, false]) {
        final message =
            parseChannelMessage(channelFrame('job ran 1 ok', v3: v3))!;
        expect(message.txtType, 0);
        expect(message.channelIndex, 1);
        expect(message.senderName, 'Roof');
        expect(message.body, 'job ran 1 ok');
      }
    });

    test('non-channel frames are ignored', () {
      expect(parseChannelMessage(Uint8List.fromList([0x8C, 0, 1, 2])), isNull);
    });
  });
}
