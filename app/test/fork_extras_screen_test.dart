import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/fork_extras_screen.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

CliService _cli(List<String> commands, {bool radio2On = false}) => CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        commands.add(command);
        return switch (command) {
          'radio2 status' => radio2On
              ? 'on; preset=913.225,62.5,7,8'
              : 'off; preset=913.225,62.5,7,8',
          'battery' => 'batt 3900mV; gate off; drops 0',
          'clock mesh' => 'off slots=33/22 tol=60/60 now=2026-03-03T21:07:58Z',
          'bot' => 'bot: off, name (node), chan (none)',
          'get radio.rxps' =>
            '> desired=off,effective=continuous,supported=yes,err=0,fail=0,level=8,catch=8.2,preamble=0,rx=4063,sleep=6085',
          'get cpu.freq' => '> 80',
          _ => '> ok',
        };
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
  await tester.pumpWidget(wrap(_app(), ForkExtrasScreen(cli: cli)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('reads all five fork features on demand', (tester) async {
    final commands = <String>[];
    await _pump(tester, _cli(commands));
    for (final command in [
      'radio2 status',
      'battery',
      'clock mesh',
      'bot',
      'get radio.rxps',
      'get cpu.freq',
    ]) {
      expect(commands, contains(command));
    }
    expect(find.text('Fork features'), findsWidgets);
  });

  testWidgets('an enabled radio2 preset is read only', (tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, _cli(commands, radio2On: true));
    final preset = find.byKey(const Key('radio2.preset'));
    expect(preset, findsOneWidget);
    expect(tester.widget<TextField>(preset).enabled, isFalse);
  });

  testWidgets('a battery gate with resume below suspend is refused',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, _cli(commands));
    await tester.enterText(find.byKey(const Key('battery.suspend')), '3900');
    await tester.enterText(find.byKey(const Key('battery.resume')), '3800');
    await tester.pump();
    await tester.tap(find.text('Set gate'));
    await tester.pump();
    expect(find.textContaining('Resume must be above suspend'), findsWidgets);
    expect(commands.contains('battery 3900 3800'), isFalse);
  });

  testWidgets('power saving refuses to run while radio2 is enabled',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, _cli(commands, radio2On: true));
    await tester.tap(find.text('Enable power saving'));
    await tester.pump();
    expect(find.textContaining('Turn radio2 off'), findsWidgets);
    expect(commands.any((c) => c.startsWith('set radio.rxps')), isFalse);
  });
}
