import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

final testContact = Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  name: 'tower-1',
  advType: advTypeRepeater,
  outPathLen: -1,
);

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

Uint8List _padded32(List<int> bytes) {
  final out = Uint8List(32);
  out.setRange(0, bytes.length > 32 ? 32 : bytes.length, bytes);
  return out;
}

Uint8List _cannedInfoReport({int features = otaFeatDelta | otaFeatApply}) {
  final body = <int>[
    otaWireVersion,
    ..._le32(0xDEADBEEF),
    ..._le32(0x200000),
    ..._le16(132),
    ..._le32(features),
    ..._padded32('XiaoS3_WIO_repeater-ota'.codeUnits),
    ...List<int>.generate(32, (i) => i + 0xA0),
  ];
  return buildOp(otaOpInfoReport, body: body);
}

/// `PUSH_CODE_BINARY_RESPONSE` as a companion emits it: the tag-first record
/// layout, with the RESPONSE plaintext zero-padded to a 16-byte block exactly
/// as the crypto layer delivers it.
Uint8List _pushBinaryResponse(int tag, Uint8List payload) {
  final padded = (payload.length + 15) & ~15;
  return Uint8List.fromList([
    pushCodeBinaryResponse,
    0,
    tag & 0xFF,
    (tag >> 8) & 0xFF,
    (tag >> 16) & 0xFF,
    (tag >> 24) & 0xFF,
    ...payload,
    ...List<int>.filled(padded - payload.length, 0),
  ]);
}

/// The other record layout in the field: pubkey prefix, then tag.
Uint8List _pushBinaryResponsePrefixed(int tag, Uint8List payload) =>
    Uint8List.fromList([
      pushCodeBinaryResponse,
      0,
      ...testContact.publicKey.sublist(0, 6),
      tag & 0xFF,
      (tag >> 8) & 0xFF,
      (tag >> 16) & 0xFF,
      (tag >> 24) & 0xFF,
      ...payload,
    ]);

void main() {
  test('buildInfo is an OP_INFO frame', () {
    final f = buildInfo();
    expect(f[0], 0x4F);
    expect(f[1], 0x54);
    expect(f[2], otaOpInfo);
    expect(unwrapFrame(f), isNotNull);
  });

  test('parseInfoReport reads every field', () {
    final report = _cannedInfoReport();
    final info = parseInfoReport(report);
    expect(info, isNotNull);
    expect(info!.wireVersion, 1);
    expect(info.targetId, 0xDEADBEEF);
    expect(info.slotSize, 0x200000);
    expect(info.maxLiteral, 132);
    expect(info.features, otaFeatDelta | otaFeatApply);
    expect(info.supportsDelta, isTrue);
    expect(info.supportsApply, isTrue);
    expect(info.runningVersion, 'XiaoS3_WIO_repeater-ota');
    expect(info.runningSha256, List<int>.generate(32, (i) => i + 0xA0));
  });

  test('feature getters reflect every advertised capability', () {
    final info = parseInfoReport(_cannedInfoReport(
        features: otaFeatDelta |
            otaFeatApply |
            otaFeatBlockHash |
            otaFeatStagedHash |
            otaFeatStatus |
            otaFeatPing |
            otaFeatOnlineFetch))!;
    expect(info.supportsDelta, isTrue);
    expect(info.supportsApply, isTrue);
    expect(info.supportsBlockHash, isTrue);
    expect(info.supportsStagedHash, isTrue);
    expect(info.supportsStatus, isTrue);
    expect(info.supportsPing, isTrue);
    expect(info.supportsOnlineFetch, isTrue);
  });

  test('parseInfoReport tolerates crypto-layer zero padding', () {
    final report = _cannedInfoReport();
    expect(parseInfoReport([...report, 0, 0, 0])!.wireVersion, 1);
    expect(parseInfoReport([...report, 0x01]), isNull);
    expect(parseInfoReport(report.sublist(0, report.length - 1)), isNull);
  });

  test('parseInfoReport rejects garbage', () {
    expect(parseInfoReport(const [0x4F, 0x54, 0x08]), isNull); // short + no CRC
    final corrupt = Uint8List.fromList(_cannedInfoReport());
    corrupt[10] ^= 0x40; // body byte
    expect(parseInfoReport(corrupt), isNull);
    // not a report: OP_END instead of OP_INFO_REPORT
    final endFrame = buildOp(otaOpEnd, seq: 1);
    expect(parseInfoReport(endFrame), isNull);
  });

  test('queryNodeInfo round-trips through the binary-request path', () async {
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      if (reqData.isEmpty || reqData[0] != reqTypeOta) return;
      final build = buildInfo();
      expect(reqData, [reqTypeOta, build.length, ...build]);
      link.simulatePush(_pushBinaryResponse(tag, _cannedInfoReport()));
    };
    final info = await queryNodeInfo(link, testContact,
        timeout: const Duration(seconds: 1));
    expect(info, isNotNull);
    expect(info!.targetId, 0xDEADBEEF);
    expect(info.runningVersion, 'XiaoS3_WIO_repeater-ota');
  });

  test('queryNodeInfo reads the pubkey-prefix record layout too', () async {
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      link.simulatePush(_pushBinaryResponsePrefixed(tag, _cannedInfoReport()));
    };
    final info = await queryNodeInfo(link, testContact,
        timeout: const Duration(seconds: 1));
    expect(info!.runningSha256, List<int>.generate(32, (i) => i + 0xA0));
  });

  test('queryNodeInfo resolves null when the node does not answer', () async {
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      // silent node: never pushes
    };
    final info = await queryNodeInfo(link, testContact,
        timeout: const Duration(milliseconds: 200));
    expect(info, isNull);
  });

  test('queryNodeInfo resolves null on a malformed report', () async {
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      final garbage = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
      link.simulatePush(_pushBinaryResponse(tag, garbage));
    };
    final info = await queryNodeInfo(link, testContact,
        timeout: const Duration(milliseconds: 300));
    expect(info, isNull);
  });
}
