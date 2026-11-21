import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:wifi_ota_core/wifi_ota_core.dart';

import 'cli_service.dart';

/// Orchestrates the stock HTTP update: arm the page through the admin CLI,
/// check the identity, then upload. No password is ever sent over HTTP.
class WifiOtaService {
  WifiOtaService(this.cli, this.target, {WifiOtaClient? client})
      : client = client ?? WifiOtaClient();

  final CliService cli;
  final Contact target;
  final WifiOtaClient client;

  /// `start ota` changes the repeater (it opens a web server), so it is
  /// audited like any other write.
  Future<Uri> startOta() async {
    final reply = await cli.write(target, 'start ota', family: 'update');
    if (!reply.ok) {
      throw WifiOtaException(reply.kind.name == 'unknown'
          ? 'No answer from the repeater. Outcome unknown; try again.'
          : (reply.text.isEmpty
              ? 'The repeater refused start ota.'
              : reply.text));
    }
    return parseStartOtaReply(reply.text);
  }

  Future<WifiIdentity> identity(Uri base) => client.identity(base);

  Future<void> upload({
    required Uri base,
    required Uint8List image,
    required String md5Hex,
    String filename = 'firmware.bin',
    void Function(int sent, int total)? onProgress,
  }) =>
      client.upload(
        base: base,
        firmware: image,
        md5Hex: md5Hex,
        filename: filename,
        onProgress: onProgress,
      );
}
