import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:wifi_ota_core/wifi_ota_core.dart';

class FakeClient extends http.BaseClient {
  FakeClient({this.status = 200, this.body = 'OK'});

  int status;
  String body;
  String? lastMethod;
  String? lastPath;
  Uint8List? lastBody;
  bool failWithException = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastMethod = request.method;
    lastPath = request.url.path;
    if (failWithException) {
      throw http.ClientException('no route to host');
    }
    if (request.method == 'POST') {
      final chunks = <int>[];
      await for (final chunk in request.finalize()) {
        chunks.addAll(chunk);
      }
      lastBody = Uint8List.fromList(chunks);
    }
    final text = status == 200 && lastMethod == 'GET'
        ? '{"id":"Roof (Manufacturer)","hardware":"ESP32"}'
        : body;
    return http.StreamedResponse(Stream.value(utf8.encode(text)), status);
  }
}

void main() {
  group('start reply', () {
    test('parses the CLI address and rejects other replies', () {
      final uri = parseStartOtaReply('Started: http://192.168.1.42/update');
      expect(uri.host, '192.168.1.42');
      expect(uri.path, '/update');
      expect(
        () => parseStartOtaReply('Error'),
        throwsA(isA<WifiOtaException>()),
      );
    });
  });

  group('md5', () {
    test('is uppercase hex', () {
      final digest = imageMd5(Uint8List.fromList('hello'.codeUnits));
      expect(digest, '5D41402ABC4B2A76B9719D911017C592');
    });
  });

  group('client', () {
    test('identity reads the endpoint and parses hardware', () async {
      final fake = FakeClient();
      final identity = await WifiOtaClient(client: fake)
          .identity(Uri.parse('http://192.168.1.42/update'));
      expect(identity.isEsp32, isTrue);
      expect(identity.id, contains('Roof'));
      expect(fake.lastPath, '/update/identity');
    });

    test('upload sends one firmware part and the MD5 field', () async {
      final fake = FakeClient();
      final image = Uint8List.fromList('firmware bytes'.codeUnits);
      final progress = <(int, int)>[];
      await WifiOtaClient(client: fake).upload(
        base: Uri.parse('http://192.168.1.42/update'),
        firmware: image,
        md5Hex: imageMd5(image),
        onProgress: (sent, total) => progress.add((sent, total)),
      );
      expect(fake.lastMethod, 'POST');
      expect(fake.lastPath, '/update');
      final text = utf8.decode(fake.lastBody!);
      expect(text, contains('name="MD5"'));
      expect(text, contains(imageMd5(image)));
      expect(text, contains('name="firmware"; filename="firmware.bin"'));
      expect(progress.last, (image.length, image.length));
    });

    test('a missing or non-uppercase MD5 is refused before upload', () async {
      final fake = FakeClient();
      final client = WifiOtaClient(client: fake);
      expect(
        () => client.upload(
          base: Uri.parse('http://x/update'),
          firmware: Uint8List(4),
          md5Hex: 'abc',
        ),
        throwsA(isA<WifiOtaException>()),
      );
      expect(
        () => client.upload(
          base: Uri.parse('http://x/update'),
          firmware: Uint8List(4),
          md5Hex: 'ABCD',
          filename: 'filesystem',
        ),
        throwsA(isA<WifiOtaException>()),
      );
      expect(fake.lastBody, isNull);
    });

    test('stopping before the first chunk sends nothing', () async {
      final fake = FakeClient();
      expect(
        () => WifiOtaClient(client: fake).upload(
          base: Uri.parse('http://x/update'),
          firmware: Uint8List(32),
          md5Hex: 'ABCD',
          shouldCancel: () => true,
        ),
        throwsA(isA<WifiUploadCancelled>()),
      );
      expect(fake.lastBody, isNull);
    });

    test('stopping between chunks aborts the stream', () async {
      final fake = FakeClient();
      var chunks = 0;
      expect(
        () => WifiOtaClient(client: fake).upload(
          base: Uri.parse('http://x/update'),
          firmware: Uint8List(64 * 1024),
          md5Hex: 'ABCD',
          shouldCancel: () => chunks++ >= 2,
        ),
        throwsA(isA<WifiUploadCancelled>()),
      );
    });

    test(
      'a failure response and a transport error become friendly errors',
      () async {
        final rejected = FakeClient(status: 400, body: 'MD5 parameter missing');
        expect(
          () => WifiOtaClient(client: rejected).upload(
            base: Uri.parse('http://x/update'),
            firmware: Uint8List(4),
            md5Hex: 'ABCD',
          ),
          throwsA(isA<WifiOtaException>()),
        );
        final offline = FakeClient()..failWithException = true;
        expect(
          () => WifiOtaClient(client: offline)
              .identity(Uri.parse('http://x/update')),
          throwsA(isA<WifiOtaException>()),
        );
      },
    );
  });
}
