import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/board_family.dart';
import 'package:meshcore_repeater_manager/services/wifi_connector.dart';
import 'package:meshcore_repeater_manager/services/wifi_status.dart';
import 'package:ota_core/ota_core.dart';
import 'package:wifi_ota_core/wifi_ota_core.dart';

import 'support.dart';

class _ScriptedClient extends CompanionClient {
  _ScriptedClient(super.link, this.replies);

  final Map<String, String> replies;
  final List<String> commands = [];
  int statusCalls = 0;

  @override
  Future<LoginResult> login(Contact target, String password,
      {Duration timeout = const Duration(seconds: 45)}) async {
    commands.add('login');
    return const LoginResult(ok: true, isAdmin: true);
  }

  @override
  Future<String> remoteCli(Contact target, String command,
      {Duration timeout = const Duration(seconds: 45)}) async {
    commands.add(command);
    if (command == 'ota status') {
      statusCalls++;
      final ready = replies['ota status:ready'] ?? 'false';
      if (statusCalls > 1 && ready == 'true') {
        return replies['ota status:readyLine']!;
      }
    }
    for (final entry in replies.entries) {
      if (entry.key.startsWith('ota status:')) continue;
      if (command.startsWith(entry.key)) return entry.value;
    }
    return 'OK';
  }
}

class _FakeHttp extends http.BaseClient {
  _FakeHttp(this.identity, {this.failFirstGet = false});

  final String identity;
  final bool failFirstGet;
  int _gets = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET') {
      _gets++;
      if (failFirstGet && _gets == 1) {
        return http.StreamedResponse(Stream.value(utf8.encode('offline')), 500);
      }
    }
    final text = request.method == 'GET' ? identity : 'OK';
    return http.StreamedResponse(Stream.value(utf8.encode(text)), 200);
  }
}

Future<AppState> _appWithFlow(Map<String, String> replies) async {
  final app = AppState();
  app.tcpLinkFactory = (_, __) {
    final link = FakeDeviceLink();
    link.frameHandler = (frame) {
      if (frame.isNotEmpty && frame[0] == cmdGetContacts) {
        link.simulatePush(
            Uint8List.fromList([respCodeEndOfContacts, 0, 0, 0, 0]));
      }
    };
    return link;
  };
  app.clientFactory = (link) => _ScriptedClient(link, replies);
  await app.connectTcp(host: '127.0.0.1', port: 5000);
  app.selectTarget(contact('Roof'));
  return app;
}

Future<void> _selectImage(AppState app, String env, String version) async {
  final dir = await Directory.systemTemp.createTemp('mcrm_wifi_test_');
  app.applicationSupportDirectory = () async => dir;
  await app.initServices();
  final bytes = Uint8List.fromList('a firmware image'.codeUnits);
  final entry = await app.importLocalImage(bytes,
      fileName: '$env-$version.bin', env: env, version: version);
  await app.selectLibraryEntryForUpdate(entry);
}

String _sha16(Uint8List bytes) =>
    bytesToHex(AppState.sha256List(bytes).sublist(0, 8));

void main() {
  test('a stock repeater falls back to WiFi only when its board is known',
      () async {
    final app = await _appWithFlow({
      'ota status': 'Unknown command',
      'board': 'Heltec V3',
    });
    app.catalog = catalog([
      release('v1.1.0', images: [asset('heltec_v3', 'v1.1.0')])
    ]);
    await app.probe();
    expect(app.nodeStatus, isNull);
    expect(app.wifiOnlyMode, isTrue);
    expect(app.stockBoardEnvironment, 'heltec_v3');
    expect(app.wifiUploadSupported, isTrue);
    expect(app.onlineFetchSupported, isFalse);
    expect(app.probeError, contains('WiFi update'));
  });

  test('a stock repeater with an unknown board keeps WiFi hidden', () async {
    final app = await _appWithFlow({
      'ota status': 'Unknown command',
      'board': 'Unlisted board',
    });
    app.catalog = catalog([
      release('v1.1.0', images: [asset('heltec_v3', 'v1.1.0')])
    ]);
    await app.probe();
    expect(app.wifiOnlyMode, isTrue);
    expect(esp32EnvironmentForBoard(app.boardReply!, ['heltec_v3']), isNull);
    expect(app.wifiUploadSupported, isFalse);
  });

  test('observer gating uses the feature bit and read-only WiFi facts',
      () async {
    final app = await _appWithFlow({
      'ota status': nodeStatus().running.isNotEmpty
          ? 'running=v1.1.0 sha=2979666babcfc001 state=idle size=0 off=0 err=0'
          : '',
    });
    const env = 'xiao_s3_wio_repeater_observer';
    app.nodeInfo = nodeInfo(
        targetId: targetIdForEnvironment(env),
        features: otaFeatDelta |
            otaFeatApply |
            otaFeatBlockHash |
            otaFeatOnlineFetch);
    expect(app.onlineFetchSupported, isTrue);
    expect(app.wifiUploadSupported, isTrue);
    expect(app.wifiLanAvailable, isFalse);
    app.wifiLink = WifiLinkState.connected;
    expect(app.wifiLanAvailable, isTrue);
    app.wifiLink = WifiLinkState.disconnected;
    app.wifiSsid = 'My Network';
    expect(app.wifiLanAvailable, isTrue);
  });

  test('online fetch needs the selected release to match the node board',
      () async {
    final app = await _appWithFlow({});
    const env = 'xiao_s3_wio_repeater_observer';
    app.nodeInfo = nodeInfo(
        targetId: targetIdForEnvironment(env),
        features: otaFeatDelta | otaFeatApply | otaFeatOnlineFetch);
    await _selectImage(app, env, 'v1.18.0-r4');
    expect(app.selectedVersionToken, '1.18.0-r4');
    expect(app.selectedSha256, isNotNull);
    expect(app.onlineFetchBoardMatches, isTrue);
    expect(app.onlineFetchReady, isTrue);
  });

  test('WiFi update dispatches before the LoRa radio plan is checked',
      () async {
    final version = 'v1.18.0-r4';
    final prefix = _sha16(Uint8List.fromList('a firmware image'.codeUnits));
    final app = await _appWithFlow({
      'start ota': 'Started: http://192.168.4.1/update',
      'ota status':
          'running=$version sha=$prefix state=idle size=0 off=0 err=0',
      'ver': '$version (Build: today)',
    });
    app.nodeInfo = nodeInfo();
    await _selectImage(app, 'xiao_s3_wio', version);
    app.setOtaMethod(OtaMethod.wifi);
    app.wifiConnectorFactory = FakeWifiConnector();
    app.wifiClientFactory =
        WifiOtaClient(client: _FakeHttp('{"id":"Roof","hardware":"ESP32"}'));
    final client = app.client as _ScriptedClient;

    await app.runUpdate(version: version);
    expect(client.commands, contains('start ota'));
    expect(app.updatePhase, UpdatePhase.done);
    expect(app.verifyMatched, isTrue);
    expect(app.verificationLevel, VerificationLevel.hash);
  });

  test('an unreachable hotspot joins once and keeps the page address',
      () async {
    const version = 'v1.18.0-r4';
    final prefix = _sha16(Uint8List.fromList('a firmware image'.codeUnits));
    final app = await _appWithFlow({
      'start ota': 'Started: http://192.168.4.1/update',
      'ota status':
          'running=$version sha=$prefix state=idle size=0 off=0 err=0',
      'ver': '$version (Build: today)',
    });
    app.nodeInfo = nodeInfo();
    await _selectImage(app, 'xiao_s3_wio', version);
    app.setOtaMethod(OtaMethod.wifi);
    final connector = FakeWifiConnector();
    app.wifiConnectorFactory = connector;
    app.wifiClientFactory = WifiOtaClient(
        client:
            _FakeHttp('{"id":"Roof","hardware":"ESP32"}', failFirstGet: true));

    await app.runUpdate(version: version);
    expect(connector.joined, ['MeshCore-OTA']);
    expect(app.updatePhase, UpdatePhase.done);
    expect(app.wifiOtaUrl, Uri.parse('http://192.168.4.1/update'));
  });

  test('a stock WiFi update proves only the version, not the image hash',
      () async {
    const version = 'v1.18.0-r4';
    final app = await _appWithFlow({
      'start ota': 'Started: http://192.168.4.1/update',
      'ota status': 'Unknown command',
      'ver': '$version (Build: today)',
    });
    app.wifiOnlyMode = true;
    app.stockBoardEnvironment = 'xiao_s3_wio';
    await _selectImage(app, 'xiao_s3_wio', version);
    app.setOtaMethod(OtaMethod.wifi);
    app.wifiClientFactory =
        WifiOtaClient(client: _FakeHttp('{"id":"Roof","hardware":"ESP32"}'));

    await app.runUpdate(version: version);
    expect(app.updatePhase, UpdatePhase.done);
    expect(app.verifyMatched, isTrue);
    expect(app.verificationLevel, VerificationLevel.versionOnly);
  });

  test('online download dispatches to ready to apply without a local upload',
      () async {
    const env = 'xiao_s3_wio_repeater_observer';
    const version = 'v1.18.0-r4';
    final app = await _appWithFlow({
      'ota status':
          'running=v1.18.0 sha=2979666babcfc001 state=idle size=0 off=0 err=0',
      'ota status:ready': 'true',
      'ota status:readyLine':
          'running=$version sha=2979666babcfc001 state=ready size=1024 off=1024 err=0',
      'ota fetch ver': 'OK - online version set ver=$version',
      'ota fetch sha': 'OK - online sha set sha=12345678',
      'ota fetch start': 'OK - online fetch armed ver=$version',
      'ota net': 'net=ready ver=$version sha=12345678 got=1024 size=1024 err=0',
    });
    app.nodeInfo = nodeInfo(
        targetId: targetIdForEnvironment(env),
        features: otaFeatDelta | otaFeatApply | otaFeatOnlineFetch);
    await _selectImage(app, env, version);
    app.setOtaMethod(OtaMethod.onlineFetch);

    await app.runUpdate(version: version);
    final client = app.client as _ScriptedClient;
    expect(client.commands, contains('ota fetch ver 1.18.0-r4'));
    expect(client.commands, contains('ota fetch start'));
    expect(client.commands, isNot(contains('start ota')));
    expect(app.updatePhase, UpdatePhase.readyToApply);
    expect(app.onlineNetStatus?.phase, WifiNetPhase.ready);
  });

  test('method changes clear the saved update page', () async {
    final app = await _appWithFlow({});
    app.setOtaMethod(OtaMethod.wifi);
    app.wifiOtaUrl = Uri.parse('http://192.168.4.1/update');
    expect(app.wifiOtaUrl, Uri.parse('http://192.168.4.1/update'));
    app.setOtaMethod(OtaMethod.lora);
    expect(app.wifiOtaUrl, isNull);
  });
}
