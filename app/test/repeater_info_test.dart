import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:repeater_core/repeater_core.dart';

Contact _contact() =>
    Contact(publicKey: Uint8List.fromList(List.filled(32, 4)));

void main() {
  test('accessList parses the binary ACL report', () async {
    final cli = CliService(
      exchange: (_, __, {timeout = const Duration(seconds: 45)}) async =>
          throw StateError('not used'),
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
      rawBinary: (_, type,
          {data = const [], timeout = const Duration(seconds: 10)}) async {
        expect(data, accessListRequest);
        return Uint8List.fromList([
          ...List.generate(6, (i) => i + 1),
          3,
          0,
          0,
        ]);
      },
    );
    final list = await cli.accessList(_contact());
    expect(list, hasLength(1));
    expect(list!.single.roleLabel, 'Admin');
  });

  test('neighbours passes paging fields and parses the page', () async {
    late Uint8List request;
    final cli = CliService(
      exchange: (_, __, {timeout = const Duration(seconds: 45)}) async =>
          throw StateError('not used'),
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
      rawBinary: (_, type,
          {data = const [], timeout = const Duration(seconds: 10)}) async {
        expect(type, 0x06);
        request = Uint8List.fromList(data);
        final b = ByteData(4 + 11);
        b.setUint16(0, 3, Endian.little);
        b.setUint16(2, 1, Endian.little);
        var o = 4;
        for (final x in [9, 8, 7, 6, 5, 4]) {
          b.setUint8(o++, x);
        }
        b.setUint32(o, 12, Endian.little);
        b.setInt8(o + 4, 16);
        return b.buffer.asUint8List();
      },
    );
    final page = await cli.neighbours(_contact(),
        count: 8, offset: 0, order: NeighborOrder.strongest);
    expect(request[1], 8);
    expect(request[4], 2);
    expect(request[5], 6);
    expect(page!.total, 3);
    expect(page.entries.single.heardSecondsAgo, 12);
    expect(page.entries.single.snr, 4.0);
  });

  test('owner parses the three-line report', () async {
    final cli = CliService(
      exchange: (_, __, {timeout = const Duration(seconds: 45)}) async =>
          throw StateError('not used'),
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
      rawBinary: (_, type,
              {data = const [], timeout = const Duration(seconds: 10)}) async =>
          Uint8List.fromList([...'v1\nRoof\nJason'.codeUnits, 0, 0]),
    );
    final info = await cli.owner(_contact());
    expect(info!.version, 'v1');
    expect(info.name, 'Roof');
    expect(info.owner, 'Jason');
  });

  test('a missing reply is reported as no data, not an empty success',
      () async {
    final cli = CliService(
      exchange: (_, __, {timeout = const Duration(seconds: 45)}) async =>
          throw StateError('not used'),
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
      rawBinary: (_, type,
          {data = const [], timeout = const Duration(seconds: 10)}) async {
        throw const RepeaterRequestException('no reply');
      },
    );
    expect(await cli.accessList(_contact()), isNull);
    expect(await cli.owner(_contact()), isNull);
  });
}
