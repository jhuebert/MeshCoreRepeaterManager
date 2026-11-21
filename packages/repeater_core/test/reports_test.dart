import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

Contact _contact() =>
    Contact(publicKey: Uint8List.fromList(List.generate(32, (i) => i + 3)));

Uint8List _frame(int tag, Uint8List report, {bool prefix = true}) =>
    Uint8List.fromList([
      0x8C,
      0,
      if (prefix) ..._contact().publicKey.sublist(0, 6),
      tag & 0xFF,
      (tag >> 8) & 0xFF,
      (tag >> 16) & 0xFF,
      (tag >> 24) & 0xFF,
      ...report,
      0,
      0,
      0,
    ]);

void main() {
  group('access list', () {
    test('parses 7-byte rows and stops at the zero permission byte', () {
      final p = Uint8List.fromList([
        ...List.generate(6, (i) => i + 1),
        3, // admin
        ...List.generate(6, (i) => i + 10),
        1, // read only
        0, // end / padding
        0,
        0,
      ]);
      final list = parseAccessList(p);
      expect(list, hasLength(2));
      expect(list[0].role, 3);
      expect(list[0].roleLabel, 'Admin');
      expect(list[0].prefixHex, '010203040506');
      expect(list[1].roleLabel, 'Read only');
    });

    test('an empty list parses to zero rows', () {
      expect(parseAccessList(Uint8List(16)), isEmpty);
    });
  });

  group('neighbours', () {
    test('builds the version-0 request fields', () {
      final req = buildNeighboursRequest(
          count: 8, offset: 5, order: NeighborOrder.strongest, prefixLength: 4);
      expect(req.length, 11);
      expect(req[0], 0);
      expect(req[1], 8);
      expect(req[2] | (req[3] << 8), 5);
      expect(req[4], 2);
      expect(req[5], 4);
    });

    test('parses a page with total count and signed SNR', () {
      final b = ByteData(4 + 2 * 9);
      b.setUint16(0, 12, Endian.little); // total neighbours on the node
      b.setUint16(2, 2, Endian.little); // rows in this page
      var o = 4;
      void row(List<int> prefix, int heard, int snrX4) {
        for (final byte in prefix) {
          b.setUint8(o++, byte);
        }
        b.setUint32(o, heard, Endian.little);
        o += 4;
        b.setInt8(o++, snrX4);
      }

      row([1, 2, 3, 4], 30, 28); // 7.0 dB
      row([5, 6, 7, 8], 90, -12); // -3.0 dB
      final page = parseNeighbours(b.buffer.asUint8List(), prefixLength: 4);
      expect(page.total, 12);
      expect(page.entries, hasLength(2));
      expect(page.entries[0].prefixHex, '01020304');
      expect(page.entries[0].heardSecondsAgo, 30);
      expect(page.entries[0].snr, 7.0);
      expect(page.entries[1].snr, -3.0);
    });

    test('a truncated report is refused, not silently shortened', () {
      final b = ByteData(4 + 4);
      b.setUint16(0, 1, Endian.little);
      b.setUint16(2, 1, Endian.little);
      expect(parseNeighbours(b.buffer.asUint8List(), prefixLength: 6).entries,
          isEmpty);
    });
  });

  group('owner info', () {
    test('splits version, name and owner and ignores zero padding', () {
      final payload = Uint8List.fromList([
        ...'v1.18.0\nMy Repeater\nJason'.codeUnits,
        0,
        0,
        0,
      ]);
      final info = OwnerInfo.parse(payload);
      expect(info.version, 'v1.18.0');
      expect(info.name, 'My Repeater');
      expect(info.owner, 'Jason');
    });
  });

  group('raw response extraction', () {
    test('accepts the pubkey-prefix layout', () {
      final frame = _frame(9, Uint8List.fromList([1, 2, 3]), prefix: true);
      final payload = binaryResponseRaw(frame, _contact().publicKey, askTag: 9);
      expect(payload, isNotNull);
      expect(payload!.sublist(0, 3), [1, 2, 3]);
    });

    test('accepts a tag-first frame whose prefix does not match', () {
      final frame = _frame(10, Uint8List.fromList([7, 8]), prefix: false);
      final payload =
          binaryResponseRaw(frame, _contact().publicKey, askTag: 10);
      expect(payload!.sublist(0, 2), [7, 8]);
    });

    test('a wrong tag is refused', () {
      final frame = _frame(11, Uint8List.fromList([1]));
      expect(
          binaryResponseRaw(frame, _contact().publicKey, askTag: 12), isNull);
    });

    test('RepeaterReqClient.requestRaw matches the tag and returns the report',
        () async {
      final link = FakeDeviceLink();
      List<int>? sent;
      link.binaryRequestHandler = (_, data, tag) async {
        sent = data;
        link.simulatePush(_frame(tag, Uint8List.fromList([4, 5, 6])));
      };
      final payload = await RepeaterReqClient(link)
          .requestRaw(_contact(), 0x07, data: const [0]);
      expect(sent, [0x07, 0]);
      expect(payload.sublist(0, 3), [4, 5, 6]);
    });
  });
}
