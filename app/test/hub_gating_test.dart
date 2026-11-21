import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/shell/connection_sheet.dart';
import 'package:meshcore_repeater_manager/shell/repeater_hub_screen.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

AppState _app(int permission) {
  final app = AppState();
  app.connectionPhase = ConnectionPhase.connected;
  app.companionName = 'Gate companion';
  app.target = contact('Roof');
  app.loginPermission = permission;
  app.capabilities = const RepeaterCapabilities(
    firmwareKind: FirmwareKind.fork,
    confidence: CapabilityConfidence.confirmed,
    ota: true,
    filter: true,
    fleet: true,
    mqtt: true,
  );
  return app;
}

Future<void> _pumpHub(WidgetTester tester, AppState app) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(wrap(app, const RepeaterHubScreen()));
  await tester.pump();
}

void main() {
  testWidgets('read only sessions see locked write tiles with a reason',
      (tester) async {
    await _pumpHub(tester, _app(1));
    expect(find.text('Read only'), findsOneWidget);
    expect(find.textContaining('Sign in with write access'), findsWidgets);
    expect(find.textContaining('Sign in as admin'), findsWidgets);
  });

  testWidgets('admin sessions unlock every available activity', (tester) async {
    await _pumpHub(tester, _app(3));
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Sign in with write access'), findsNothing);
    expect(find.text('Sign in as admin'), findsNothing);
    expect(find.text('Filter'), findsWidgets);
    expect(find.text('Fleet'), findsWidgets);
  });

  testWidgets('a read-write session still cannot change node identity',
      (tester) async {
    await _pumpHub(tester, _app(2));
    expect(find.text('Read-write'), findsOneWidget);
    expect(find.textContaining('Sign in as admin'), findsWidgets);
    expect(find.text('Sign in with write access'), findsNothing);
  });

  testWidgets('connection sheet shows the session request count and budget',
      (tester) async {
    final app = _app(3);
    app.requestMeter
      ..record(5)
      ..setBudget(3);
    await tester.pumpWidget(wrap(app, const ConnectionSheet()));
    await tester.pump();
    expect(find.text('5'), findsWidgets);
    expect(find.textContaining('Mesh budget reached'), findsOneWidget);
  });
}
