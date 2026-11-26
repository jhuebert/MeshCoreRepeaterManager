import 'dart:typed_data';

import 'package:wifi_ota_core/wifi_ota_core.dart';

/// Orchestrates the repeater's built-in HTTP update page.
///
/// `start ota` is a write and is only sent after the operator chose this
/// method. The CLI reply is the authority for the page address. No password
/// is ever sent over HTTP.
class WifiOtaService {
  WifiOtaService(this.cli, {WifiOtaClient? client})
      : client = client ?? WifiOtaClient();

  /// Any admin CLI exchange. In production this is `UpdateFlow`'s client.
  final Future<String> Function(String command) cli;
  final WifiOtaClient client;

  Future<Uri> startOta() async {
    late final String reply;
    try {
      reply = await cli('start ota');
    } catch (e) {
      throw WifiOtaException(
          'No answer from the repeater. Outcome unknown; try again.');
    }
    final trimmed = reply.trim();
    if (trimmed.toLowerCase().startsWith('err') || trimmed == 'Error') {
      throw const WifiOtaException(
          'The repeater has no WiFi update page. It may be a different board '
          'or build, or WiFi update may be disabled.');
    }
    return parseStartOtaReply(trimmed);
  }

  Future<WifiIdentity> identity(Uri base) => client.identity(base);

  Future<void> upload({
    required Uri base,
    required Uint8List image,
    required String md5Hex,
    String filename = 'firmware.bin',
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
  }) =>
      client.upload(
        base: base,
        firmware: image,
        md5Hex: md5Hex,
        filename: filename,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
}
