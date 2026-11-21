import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

Contact _contact() =>
    Contact(publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)));

Uint8List _response(int tag, Uint8List report, {List<int>? prefix}) =>
    Uint8List.fromList([
      0x8C,
      0,
      if (prefix != null) ...prefix,
      tag & 0xFF,
      (tag >> 8) & 0xFF,
      (tag >> 16) & 0xFF,
      (tag >> 24) & 0xFF,
      ...report,
      // Crypto zero padding; the parser must slice by exact length.
      0,
      0,
      0,
    ]);

Uint8List _report() {
  final b = ByteData(RepeaterStatus.reportLength);
  b.setUint16(0, 4200, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  group('binaryResponsePayload', () {
    final contact = _contact();
    final report = _report();

    test('accepts the tag-first layout', () {
      final frame = _response(0x1234, report);
      expect(
          binaryResponsePayload(frame, contact.publicKey,
              askTag: 0x1234, exactLength: 56),
          hasLength(56));
    });

    test('accepts the pubkey-prefix layout', () {
      final frame =
          _response(7, report, prefix: contact.publicKey.sublist(0, 6));
      final payload =
          binaryResponsePayload(frame, contact.publicKey, exactLength: 56)!;
      expect(payload, hasLength(56));
      expect(payload[0], 4200 & 0xFF);
    });

    test('rejects a wrong tag, prefix or response code', () {
      final good =
          _response(1, report, prefix: contact.publicKey.sublist(0, 6));
      expect(
          binaryResponsePayload(good, contact.publicKey,
              askTag: 2, exactLength: 56),
          isNull);
      final wrongPrefix = _response(1, report, prefix: List.filled(6, 9));
      expect(
          binaryResponsePayload(wrongPrefix, contact.publicKey,
              askTag: 1, exactLength: 56),
          isNull);
      final notBinary = Uint8List.fromList([0x01, ...good.skip(1)]);
      expect(
          binaryResponsePayload(notBinary, contact.publicKey, exactLength: 56),
          isNull);
    });
  });

  test('RepeaterReqClient sends the req type and matches the reply tag',
      () async {
    final link = FakeDeviceLink();
    final contact = _contact();
    final client = RepeaterReqClient(link);
    List<int>? sentData;
    link.binaryRequestHandler = (_, data, tag) async {
      sentData = data;
      link.simulatePush(_response(tag, _report()));
    };

    final payload = await client.request(contact, 0x01,
        exactLength: RepeaterStatus.reportLength);
    expect(sentData, [0x01]);
    expect(parseStatusReport(payload)!.batteryMilliVolts, 4200);
  });

  test('the exception explains the request that went unanswered', () {
    const e = RepeaterRequestException('no reply');
    expect(e.toString(), 'RepeaterRequestException: no reply');
  });

  test('requestRaw times out as an unknown outcome', () async {
    final link = FakeDeviceLink();
    expect(
      () => RepeaterReqClient(link).requestRaw(_contact(), 0x07,
          timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RepeaterRequestException>()),
    );
  });

  test('a timeout is an unknown outcome, not a success', () async {
    final link = FakeDeviceLink();
    final client = RepeaterReqClient(link);
    expect(
      () => client.request(_contact(), 0x01,
          exactLength: 56, timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RepeaterRequestException>()),
    );
  });
}
