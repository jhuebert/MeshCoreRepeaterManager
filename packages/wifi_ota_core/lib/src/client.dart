import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A structured upload failure. [friendly] is safe to show to an operator.
class WifiOtaException implements Exception {
  const WifiOtaException(this.friendly);

  final String friendly;

  @override
  String toString() => 'WifiOtaException: $friendly';
}

/// The update page did not answer. On a fresh `start ota` this usually means
/// the repeater opened its softAP and the app is not on that network yet.
class WifiIdentityUnreachable extends WifiOtaException {
  const WifiIdentityUnreachable(super.friendly);
}

/// The operator stopped the upload. Nothing was claimed as installed.
class WifiUploadCancelled extends WifiOtaException {
  const WifiUploadCancelled() : super('The upload was stopped.');
}

class WifiIdentity {
  const WifiIdentity(this.id, this.hardware);

  final String id;
  final String hardware;

  factory WifiIdentity.fromJson(Map<String, dynamic> json) => WifiIdentity(
        json['id'] as String? ?? '',
        json['hardware'] as String? ?? '',
      );

  bool get isEsp32 => hardware.toLowerCase().contains('esp32');
}

/// Parse `Started: http://<ip>/update` from the admin CLI. The reply is the
/// authority for the address; nothing else is guessed.
Uri parseStartOtaReply(String reply) {
  final match = RegExp(r'Started:\s*(https?://\S+)').firstMatch(reply);
  if (match == null) {
    throw const WifiOtaException(
      'The repeater did not return an update address. It may not support '
      'WiFi update.',
    );
  }
  final uri = Uri.tryParse(match.group(1)!);
  if (uri == null || uri.host.isEmpty) {
    throw const WifiOtaException('The update address was not valid.');
  }
  return uri;
}

/// Uppercase hex MD5 of the image, as the firmware expects.
String imageMd5(Uint8List bytes) => md5.convert(bytes).toString().toUpperCase();

/// The one AsyncElegantOTA client used by the app.
class WifiOtaClient {
  WifiOtaClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  Future<WifiIdentity> identity(Uri base) async {
    final uri = base.resolve('update/identity');
    late final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on http.ClientException catch (e) {
      throw WifiIdentityUnreachable(
        'Could not reach the update page: ${e.message}',
      );
    }
    if (response.statusCode != 200) {
      throw WifiIdentityUnreachable(
        'The update page answered ${response.statusCode}.',
      );
    }
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return WifiIdentity.fromJson(decoded);
    } on FormatException {
      throw const WifiIdentityUnreachable(
        'The update identity was not valid JSON.',
      );
    }
  }

  /// Upload [firmware] as one `firmware` file part plus the required
  /// uppercase `MD5` field. A filename of `filesystem` would make the
  /// firmware write a filesystem image instead, so it is refused.
  Future<void> upload({
    required Uri base,
    required Uint8List firmware,
    required String md5Hex,
    String filename = 'firmware.bin',
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (shouldCancel?.call() ?? false) throw const WifiUploadCancelled();
    if (filename == 'filesystem') {
      throw const WifiOtaException(
        'A firmware image cannot be named filesystem.',
      );
    }
    if (md5Hex.isEmpty || RegExp(r'^[0-9A-F]+$').hasMatch(md5Hex) == false) {
      throw const WifiOtaException('The MD5 must be uppercase hex.');
    }
    final uri = base.resolve('update');
    final request = http.MultipartRequest('POST', uri)
      ..fields['MD5'] = md5Hex
      ..files.add(
        http.MultipartFile(
          'firmware',
          _progressStream(firmware, onProgress, shouldCancel),
          firmware.length,
          filename: filename,
        ),
      );

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on http.ClientException catch (e) {
      throw WifiOtaException('The upload failed: ${e.message}');
    }
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200 || body.trim() != 'OK') {
      throw WifiOtaException(
        'The repeater rejected the image (${response.statusCode}: '
        '${body.trim()}).',
      );
    }
  }

  static Stream<List<int>> _progressStream(
    Uint8List bytes,
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
  ) async* {
    const chunk = 8 * 1024;
    var sent = 0;
    while (sent < bytes.length) {
      if (shouldCancel?.call() ?? false) throw const WifiUploadCancelled();
      final end = (sent + chunk).clamp(0, bytes.length);
      final part = bytes.sublist(sent, end);
      yield part;
      sent = end;
      onProgress?.call(sent, bytes.length);
    }
    onProgress?.call(bytes.length, bytes.length);
  }

  void close() => _client.close();
}
