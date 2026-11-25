import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/login_screen.dart';
import 'package:meshcore_repeater_manager/services/radio_plan.dart';

import 'support.dart' as support;

class _AutoProbeAppState extends AppState {
  _AutoProbeAppState({required this.succeed});
  final bool succeed;

  @override
  Future<void> probe({String? password}) async {
    probing = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (succeed) {
      super.nodeStatus = support.nodeStatus();
      probeError = null;
    } else {
      super.nodeStatus = null;
      probeError = 'nope';
    }
    probing = false;
    notifyListeners();
  }
}

AppState _app() {
  final app = AppState();
  app.target = support.contact('riley');
  // The screen opens the library and refreshes the catalog on the first
  // frame; give it both so a widget test never asks a platform plugin or the
  // network for them.
  app.library = support.FakeLibrary();
  app.catalog = support.catalog([
    support.release('v1.1.0-rc5', images: [
      support.asset('Xiao_S3_WIO_repeater_observer', 'v1.1.0-rc5'),
    ]),
  ]);
  return app;
}

void main() {
  testWidgets('password is optional and the sign in button is always offered',
      (tester) async {
    final app = _app();
    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();

    expect(find.text('Admin password (optional)'), findsOneWidget);
    expect(find.textContaining('already an admin on the repeater'),
        findsOneWidget);

    final check = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(check.onPressed, isNotNull); // a blank password is a valid login
  });

  testWidgets('shows the node facts the picker will be scoped to',
      (tester) async {
    final app = _app();
    app.adminPassword = '';
    app.nodeStatus = support.nodeStatus();
    app.nodeInfo = support.nodeInfo();
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    app.radio2Enabled = true;

    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();

    expect(find.text('Xiao_S3_WIO_repeater_observer'), findsOneWidget);
    expect(find.text('enabled'), findsOneWidget);
    expect(find.textContaining('v1.1.0-rc5'), findsWidgets);
    expect(find.text('Admin password (optional)'), findsNothing);

    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Choose firmware'),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('a blank password logs in and enables the next step',
      (tester) async {
    final app = _app();
    app.nodeStatus = support.nodeStatus();
    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();

    expect(app.adminPassword, '');
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Choose firmware'),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('an unknown build suggests picking the board next',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _app();
    app.nodeStatus = support.nodeStatus();
    app.nodeInfo = support.nodeInfo(targetId: 0x11112222);

    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();

    expect(find.textContaining('custom build the app does not know'),
        findsOneWidget);
  });

  testWidgets('the sign in button is locked until a node is chosen',
      (tester) async {
    final app = _app();
    app.target = null;
    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();

    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(next.onPressed, isNull);
    expect(find.textContaining('Pick a repeater first'), findsOneWidget);
  });

  testWidgets('the login helper updates the session password', (tester) async {
    final app = _app();
    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pump();
    expect(app.adminPassword, 'hunter2');
  });

  testWidgets('a successful check lands straight on the firmware step',
      (tester) async {
    final app = _AutoProbeAppState(succeed: true);
    app.target = support.contact('riley');
    app.library = support.FakeLibrary();
    app.catalog = support.catalog([
      support.release('v1.1.0-rc5', images: [
        support.asset('Xiao_S3_WIO_repeater_observer', 'v1.1.0-rc5'),
      ]),
    ]);

    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Choose firmware'), findsOneWidget);
    expect(app.probing, isFalse);
  });

  testWidgets('a failed check stays on the sign-in screen', (tester) async {
    final app = _AutoProbeAppState(succeed: false);
    app.target = support.contact('riley');
    app.library = support.FakeLibrary();
    app.catalog = support.catalog([
      support.release('v1.1.0-rc5', images: [
        support.asset('Xiao_S3_WIO_repeater_observer', 'v1.1.0-rc5'),
      ]),
    ]);

    await tester.pumpWidget(support.wrap(app, const LoginScreen()));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Choose firmware'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.text('nope'), findsOneWidget);
  });
}
