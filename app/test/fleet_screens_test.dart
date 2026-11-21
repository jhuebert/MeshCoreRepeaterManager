import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/fleet_composer_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/fleet_results_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/fleet_screen.dart';
import 'package:meshcore_repeater_manager/services/ack_collector.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

AppState _app() {
  final app = AppState();
  app.connectionPhase = ConnectionPhase.connected;
  app.target = contact('Roof');
  app.loginPermission = 3;
  app.fleetPsk = '11' * 16;
  return app;
}

CliService _cli(List<String> commands) => CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        commands.add(command);
        return switch (command) {
          'fleet' => 'on; chan h=2a; reply 15s; tags 2; seen 1',
          'fleet tag list' => 'tags: north roof',
          _ => '> ok',
        };
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );

Future<void> _pump(WidgetTester tester, Widget child, AppState app) async {
  await tester.pumpWidget(wrap(app, child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('fleet screen reads status and tags', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, FleetScreen(cli: _cli(commands)), _app());
    expect(find.text('Composer'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Results'), findsOneWidget);
    expect(commands, contains('fleet tag list'));

    await tester.enterText(find.byKey(const Key('fleet-psk')), '22' * 16);
    await tester.pump();
    await tester.tap(find.text('Arm fleet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('fleet on'));
  });

  testWidgets('composer previews the script and byte budget', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final app = _app();
    final link = FakeDeviceLink();
    await _pump(
        tester,
        FleetComposerScreen(
            link: link, psk: app.fleetPsk, collector: app.ackCollector),
        app);
    expect(find.textContaining('!id job-'), findsWidgets);
    expect(find.textContaining('/ 157 bytes'), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('fleet-commands')), 'ver\nget radio');
    await tester.pump();
    expect(find.textContaining('get radio'), findsWidgets);
  });

  testWidgets('composer asks before sending and tracks the job',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final app = _app();
    final link = FakeDeviceLink();
    await _pump(
        tester,
        FleetComposerScreen(
            link: link, psk: app.fleetPsk, collector: app.ackCollector),
        app);
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.text('Send this job?'), findsOneWidget);
    await tester.tap(find.text('Send').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(link.transmitted, hasLength(1));
    expect(app.ackCollector.history, hasLength(1));
  });

  testWidgets('results show No reply and an explicit ACK', (tester) async {
    final app = _app();
    app.ackCollector.track(FleetJobResult(
        id: 'job-1', script: '!id job-1\nver', sentAt: DateTime.now()));
    app.ackCollector.handleText('Roof', 'job-1 OK');
    await _pump(tester, const FleetResultsScreen(), app);
    expect(find.text('job-1'), findsOneWidget);
    expect(find.text('1 replies'), findsOneWidget);
    expect(find.text('Roof'), findsOneWidget);
  });
}
