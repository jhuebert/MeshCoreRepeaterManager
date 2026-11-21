import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/mqtt_screen.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/secret_store.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

CliService _cli(List<String> commands) => CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        commands.add(command);
        if (command == 'get mqtt.status') {
          return 'mqtt wifi:down time:ok slots:0/0 rx:3851 pub:0 drop:0 q:0/8 heap:249584/229364';
        }
        if (command == 'get wifi.status') {
          return 'wifi connected ip:192.0.2.10 rssi:-58';
        }
        if (command.startsWith('get mqtt1.status')) {
          return 'mqtt1 off wifi:down q:0';
        }
        if (command.startsWith('get mqtt2.status')) {
          return 'mqtt2 config wifi:down q:0';
        }
        if (command.startsWith('get ')) return '> configured';
        return '> ok';
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );

AppState _app() {
  final app = AppState();
  app.connectionPhase = ConnectionPhase.connected;
  app.target = contact('Roof');
  app.loginPermission = 3;
  return app;
}

Future<void> _pump(WidgetTester tester, CliService cli) async {
  await tester.pumpWidget(wrap(_app(), MqttScreen(cli: cli)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('MQTT screen reads status and never reads secret values',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, _cli(commands));

    expect(find.text('MQTT observer'), findsWidgets);
    expect(commands, contains('get mqtt.status'));
    expect(commands, contains('get mqtt1.status'));
    expect(commands, contains('get mqtt2.status'));
    for (final secret in ['password', 'token', 'wifi.pwd']) {
      expect(
          commands.any((c) => c.startsWith('get ') && c.endsWith('.$secret')),
          isFalse);
      expect(commands.any((c) => c == 'get $secret'), isFalse);
    }
  });

  testWidgets('secret fields are masked and cleared after saving',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, _cli(commands));

    final passwordField = find.byKey(const Key('mqtt1.password'));
    await tester.enterText(passwordField, 'secret');
    await tester.pump();
    await tester.tap(find.text('Save broker 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('set mqtt1.password secret'));
    // The draft was cleared, so the field is empty again.
    expect(passwordField, findsOneWidget);
  });

  testWidgets('a remembered secret is prefilled from storage on open',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final backend = MemorySecretBackend();
    await backend.write(SecretField.mqtt2Password.storageKey, 'stored-secret');
    final app = _app();
    app.secretBackendFactory = () => backend;
    await app.initSecretStore();
    await tester.pumpWidget(wrap(app, MqttScreen(cli: _cli(<String>[]))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final field =
        tester.widget<TextField>(find.byKey(const Key('mqtt2.password')));
    expect(field.controller!.text, 'stored-secret');
    expect(field.obscureText, isTrue);
  });

  testWidgets('saving a remembered secret updates the stored value',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final backend = MemorySecretBackend();
    await backend.write(SecretField.mqtt1Password.storageKey, 'old');
    final app = _app();
    app.secretBackendFactory = () => backend;
    await app.initSecretStore();
    await tester.pumpWidget(wrap(app, MqttScreen(cli: _cli(<String>[]))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byKey(const Key('mqtt1.password')), 'new');
    await tester.pump();
    await tester.tap(find.text('Save broker 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(await backend.read(SecretField.mqtt1Password.storageKey), 'new');
  });

  testWidgets('MQTT secrets can be remembered per field and forgotten',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final backend = MemorySecretBackend();
    final app = _app();
    app.secretBackendFactory = () => backend;
    await app.initSecretStore();
    await tester.pumpWidget(wrap(app, MqttScreen(cli: _cli(<String>[]))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byKey(const Key('mqtt1.password')), 'secret');
    await tester.pump();
    await tester.tap(find.text('Remember on this device').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(await backend.read(SecretField.mqtt1Password.storageKey), 'secret');

    await tester.tap(find.text('Forget stored value').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(await backend.read(SecretField.mqtt1Password.storageKey), isNull);

    // Toggling the opt-in off also forgets, without the Forget button.
    await tester.enterText(find.byKey(const Key('mqtt1.password')), 'again');
    await tester.pump();
    await tester.tap(find.text('Remember on this device').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Remember on this device').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(await backend.read(SecretField.mqtt1Password.storageKey), isNull);
  });

  testWidgets('Wi-Fi recovery asks before sending', (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, _cli(commands));
    await tester.tap(find.text('Reconnect Wi-Fi'));
    await tester.pump();
    expect(find.text('Reconnect Wi-Fi?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(commands.contains('mqtt recover'), isFalse);
  });
}
