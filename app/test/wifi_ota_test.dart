import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/wifi_ota_screen.dart';

import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/wifi_connector.dart';
import 'package:meshcore_repeater_manager/services/wifi_ota_service.dart';
import 'package:repeater_core/repeater_core.dart';
import 'package:wifi_ota_core/wifi_ota_core.dart';

import 'support.dart';

class _FakeHttp extends http.BaseClient {
  _FakeHttp(this.body, {this.postBody = 'OK', this.identityFailures = 0});

  String body;
  String postBody;
  int identityFailures;
  String? lastPath;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastPath = request.url.path;
    if (request.method == 'POST') {
      final chunks = <int>[];
      await for (final c in request.finalize()) {
        chunks.addAll(c);
      }
      lastBody = utf8.decode(chunks);
    }
    if (request.method == 'GET' && identityFailures > 0) {
      identityFailures--;
      return http.StreamedResponse(Stream.value(utf8.encode('offline')), 500);
    }
    final reply = request.method == 'POST' ? postBody : body;
    return http.StreamedResponse(Stream.value(utf8.encode(reply)), 200);
  }
}

AppState _app() {
  final app = AppState();
  app.connectionPhase = ConnectionPhase.connected;
  app.target = contact('Roof');
  app.loginPermission = 3;
  return app;
}

CliService _cli(List<String> commands,
        {String otaReply = 'Started: http://192.168.1.42/update'}) =>
    CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        commands.add(command);
        if (command == 'start ota') return otaReply;
        return '> ok';
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );

void main() {
  test('service arms the page, checks identity and uploads with MD5', () async {
    final commands = <String>[];
    final httpClient = _FakeHttp('{"id":"Roof","hardware":"ESP32"}');
    final service = WifiOtaService(
      _cli(commands),
      contact('Roof'),
      client: WifiOtaClient(client: httpClient),
    );
    final url = await service.startOta();
    expect(url.host, '192.168.1.42');
    expect(commands, contains('start ota'));
    final identity = await service.identity(url);
    expect(identity.isEsp32, isTrue);
    final image = Uint8List.fromList('firmware'.codeUnits);
    httpClient.body = 'OK';
    await service.upload(base: url, image: image, md5Hex: imageMd5(image));
    expect(httpClient.lastPath, '/update');
    expect(httpClient.lastBody, contains(imageMd5(image)));
  });

  test('service reports a refused start as a friendly error', () async {
    final service = WifiOtaService(
      _cli(<String>[], otaReply: 'Error'),
      contact('Roof'),
      client: WifiOtaClient(client: _FakeHttp('{}')),
    );
    expect(service.startOta(), throwsA(isA<WifiOtaException>()));
  });

  testWidgets('screen refuses a non-ESP32 identity', (tester) async {
    final app = AppState();
    app.target = contact('Roof');
    await tester.pumpWidget(wrap(
      app,
      WifiOtaScreen(
        cli: _cli(<String>[]),
        client: WifiOtaClient(
            client: _FakeHttp('{"id":"Roof","hardware":"nRF52"}')),
        image: Uint8List(4),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('ESP32 only'), findsWidgets);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('screen disables start without an image', (tester) async {
    final app = AppState();
    app.target = contact('Roof');
    await tester.pumpWidget(wrap(app, const WifiOtaScreen()));
    await tester.pump();
    expect(find.text('Choose a firmware first'), findsOneWidget);
  });

  testWidgets('screen shows a failed upload instead of claiming success',
      (tester) async {
    final app = AppState();
    app.target = contact('Roof');
    final httpClient =
        _FakeHttp('{"id":"Roof","hardware":"ESP32"}', postBody: 'FAIL');
    await tester.pumpWidget(wrap(
      app,
      WifiOtaScreen(
        cli: _cli(<String>[]),
        client: WifiOtaClient(client: httpClient),
        image: Uint8List.fromList('firmware'.codeUnits),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Upload'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('rejected the image'), findsWidgets);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a verified upload reports the version after reboot',
      (tester) async {
    final app = AppState();
    app.target = contact('Roof');
    await tester.pumpWidget(wrap(
      app,
      WifiOtaScreen(
        cli: _cli(<String>[]),
        client: WifiOtaClient(
            client: _FakeHttp('{"id":"Roof","hardware":"ESP32"}')),
        image: Uint8List.fromList('firmware'.codeUnits),
        verify: () async => 'v1.18.0-new',
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Upload'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('v1.18.0-new'), findsWidgets);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('a softAP join reconnects and retries the identity read',
      (tester) async {
    final app = _app();
    final connector = FakeWifiConnector();
    var reconnects = 0;
    final httpClient =
        _FakeHttp('{"id":"Roof","hardware":"ESP32"}', identityFailures: 1);
    await tester.pumpWidget(wrap(
      app,
      WifiOtaScreen(
        cli: _cli(<String>[]),
        client: WifiOtaClient(client: httpClient),
        image: Uint8List.fromList('firmware'.codeUnits),
        connector: connector,
        reconnect: () async => reconnects++,
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(connector.joined, ['MeshCore-OTA']);
    expect(reconnects, 1);
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets('an unsupported join shows a manual fallback and Continue',
      (tester) async {
    final app = _app();
    final connector = FakeWifiConnector(result: WifiJoinResult.unavailable);
    final httpClient =
        _FakeHttp('{"id":"Roof","hardware":"ESP32"}', identityFailures: 1);
    await tester.pumpWidget(wrap(
      app,
      WifiOtaScreen(
        cli: _cli(<String>[]),
        client: WifiOtaClient(client: httpClient),
        image: Uint8List.fromList('firmware'.codeUnits),
        connector: connector,
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('cannot join a network for you'), findsWidgets);
    expect(find.text('Continue'), findsOneWidget);
    // The manual path is a single attempt; Continue re-reads the identity.
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets('screen preflights before offering an upload', (tester) async {
    final commands = <String>[];
    final image = Uint8List.fromList('firmware'.codeUnits);
    final app = AppState();
    app.connectionPhase = ConnectionPhase.connected;
    app.target = contact('Roof');
    app.loginPermission = 3;
    final httpClient = _FakeHttp('{"id":"Roof","hardware":"ESP32"}');
    await tester.pumpWidget(wrap(
      app,
      WifiOtaScreen(
        cli: _cli(commands),
        client: WifiOtaClient(client: httpClient),
        image: image,
        version: 'v1.18.0',
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('192.168.1.42'), findsWidgets);
    expect(find.text('Upload'), findsOneWidget);
    expect(find.textContaining('no password'), findsWidgets);
  });
}
