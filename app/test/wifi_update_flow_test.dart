import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/services/update_flow.dart';
import 'package:ota_core/ota_core.dart';

import 'support.dart';

class _ScriptedClient extends CompanionClient {
  _ScriptedClient(super.link, this.replies, {this.failAll = false});

  final Map<String, String> replies;
  final bool failAll;
  final List<String> commands = [];

  @override
  Future<String> remoteCli(Contact target, String command,
      {Duration timeout = const Duration(seconds: 45)}) async {
    commands.add(command);
    if (failAll) throw CompanionTimeoutException('lost');
    for (final entry in replies.entries) {
      if (command.startsWith(entry.key)) return entry.value;
    }
    return 'OK';
  }
}

void main() {
  const sha =
      '39483a7200000000000000000000000000000000000000000000000000000000';

  test('online fetch sets version, SHA and start in that order', () async {
    final client = _ScriptedClient(FakeDeviceLink(), {
      'ota fetch ver': 'OK - online version set ver=1.18.0-r4',
      'ota fetch sha': 'OK - online sha set sha=39483a72',
      'ota fetch start': 'OK - online fetch armed ver=1.18.0-r4',
    });
    final flow = UpdateFlow(client: client, link: client.link);
    await flow.startOnlineFetch(contact('Roof'), '1.18.0-r4', sha);
    expect(client.commands, [
      'ota fetch ver 1.18.0-r4',
      'ota fetch sha sha256:$sha',
      'ota fetch start',
    ]);
  });

  test('a refused fetch step stops before arming the download', () async {
    final client = _ScriptedClient(FakeDeviceLink(), {
      'ota fetch ver': 'OK - online version set ver=1.18.0-r4',
      'ota fetch sha': 'Err - sha256 must be 64 hex chars',
    });
    final flow = UpdateFlow(client: client, link: client.link);
    await expectLater(
      flow.startOnlineFetch(contact('Roof'), '1.18.0-r4', 'bad'),
      throwsA(isA<UpdateFlowException>()),
    );
    expect(client.commands, hasLength(2));
  });

  test('net status parses the frozen line and tolerates a lost reply',
      () async {
    final client = _ScriptedClient(FakeDeviceLink(), {
      'ota net':
          'net=asset ver=1.18.0-r4 sha=39483a72 got=4096 size=8192 err=0',
    });
    final flow = UpdateFlow(client: client, link: client.link);
    final status = await flow.netStatus(contact('Roof'));
    expect(status, isNotNull);
    expect(status!.phase, WifiNetPhase.asset);
    expect(status.received, 4096);

    final silent = _ScriptedClient(FakeDeviceLink(), {}, failAll: true);
    final quietFlow = UpdateFlow(client: silent, link: silent.link);
    expect(await quietFlow.netStatus(contact('Roof')), isNull);
  });
}
