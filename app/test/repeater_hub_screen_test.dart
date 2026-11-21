import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/shell/repeater_hub_screen.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

void main() {
  AppState connectedApp() {
    final app = AppState();
    app.connectionPhase = ConnectionPhase.connected;
    app.companionName = 'Fake companion';
    app.target = contact('Roof');
    app.nodeInfo = nodeInfo();
    app.nodeStatus = nodeStatus();
    return app;
  }

  testWidgets('shows identity, cached capabilities and locked fork tiles',
      (tester) async {
    final app = connectedApp()
      ..capabilities = const RepeaterCapabilities(
        firmwareKind: FirmwareKind.fork,
        confidence: CapabilityConfidence.confirmed,
        ota: true,
      );
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(wrap(app, const RepeaterHubScreen()));

    expect(find.text('Roof'), findsOneWidget);
    expect(find.text('Fork'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.text('Ready'), findsWidgets);
    expect(find.text('Identify firmware'), findsOneWidget);
  });

  testWidgets('an unidentified repeater is not claimed unsupported',
      (tester) async {
    final app = connectedApp();
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(wrap(app, const RepeaterHubScreen()));
    expect(find.textContaining('Firmware has not been identified yet'),
        findsOneWidget);
  });

  testWidgets('write tiles are locked without a write-capable session',
      (tester) async {
    final app = connectedApp();
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(wrap(app, const RepeaterHubScreen()));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    // Every write-capable tile is locked until sign-in grants write access.
    expect(find.textContaining('Sign in with write access'), findsWidgets);
  });

  testWidgets('a stock repeater shows fork tiles as locked', (tester) async {
    final app = connectedApp()
      ..capabilities = const RepeaterCapabilities(
        firmwareKind: FirmwareKind.stock,
        confidence: CapabilityConfidence.confirmed,
      );
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(wrap(app, const RepeaterHubScreen()));
    expect(find.text('Stock'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('Locked'), findsWidgets);
  });
}
