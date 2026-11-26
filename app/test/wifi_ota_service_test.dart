import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshcore_repeater_manager/services/wifi_ota_service.dart';
import 'package:wifi_ota_core/wifi_ota_core.dart';

class _FakeHttp extends http.BaseClient {
  _FakeHttp(this.body);

  final String body;
  String? lastPath;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastPath = request.url.path;
    if (request.method == 'POST') {
      final chunks = <int>[];
      await for (final chunk in request.finalize()) {
        chunks.addAll(chunk);
      }
      lastBody = utf8.decode(chunks);
    }
    final text = request.method == 'GET' ? body : 'OK';
    return http.StreamedResponse(Stream.value(utf8.encode(text)), 200);
  }
}

void main() {
  test('starts the page and returns the CLI address', () async {
    final commands = <String>[];
    final service = WifiOtaService(
      (command) async {
        commands.add(command);
        return 'Started: http://192.168.4.1/update';
      },
      client: WifiOtaClient(client: _FakeHttp('')),
    );
    final url = await service.startOta();
    expect(commands, ['start ota']);
    expect(url.host, '192.168.4.1');
  });

  test('reports a refused start as a friendly error', () async {
    final service = WifiOtaService(
      (_) async => 'Error',
      client: WifiOtaClient(client: _FakeHttp('')),
    );
    expect(service.startOta(), throwsA(isA<WifiOtaException>()));
  });

  test('reports a lost reply as unknown instead of success', () async {
    final service = WifiOtaService(
      (_) async => throw StateError('timeout'),
      client: WifiOtaClient(client: _FakeHttp('')),
    );
    expect(service.startOta(), throwsA(isA<WifiOtaException>()));
  });

  test('upload uses the firmware part and the uppercase MD5', () async {
    final httpClient = _FakeHttp('');
    final service = WifiOtaService(
      (_) async => '',
      client: WifiOtaClient(client: httpClient),
    );
    final image = Uint8List.fromList('firmware'.codeUnits);
    await service.upload(
        base: Uri.parse('http://192.168.4.1/update'),
        image: image,
        md5Hex: imageMd5(image));
    expect(httpClient.lastPath, '/update');
    expect(httpClient.lastBody, contains(imageMd5(image)));
    expect(httpClient.lastBody, contains('name="firmware"'));
  });
}
