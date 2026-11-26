import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart' show ApplyOutcome;
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/verify_screen.dart';

import 'support.dart';

/// The verify step must never claim success unless the node reported the image
/// that was sent, and a rollback is a rollback — not a verified update.
void main() {
  /// Pump the verify screen in [phase]. No flow is wired, so the screen's
  /// automatic apply fails immediately and leaves the phase exactly as set.
  Future<void> pumpVerify(WidgetTester tester, AppState app) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(app, const VerifyScreen()));
    await tester.pump();
  }

  testWidgets('a verified image is reported as verified', (tester) async {
    final app = AppState()
      ..updatePhase = UpdatePhase.done
      ..verifyMatched = true
      ..rolledBack = false;
    await pumpVerify(tester, app);

    expect(find.text('Update verified'), findsOneWidget);
    expect(find.text('Rolled back to the previous firmware'), findsNothing);
  });

  testWidgets('a rollback is never shown as a verified update', (tester) async {
    final app = AppState()
      ..updatePhase = UpdatePhase.done
      ..verifyMatched = true // the node answered — but on the old image
      ..rolledBack = true;
    await pumpVerify(tester, app);

    expect(find.text('Rolled back to the previous firmware'), findsOneWidget);
    expect(find.text('Update verified'), findsNothing);
    expect(find.textContaining('image matches the one that was sent'),
        findsNothing);
  });

  testWidgets('a staged but uncommitted update offers an apply retry',
      (tester) async {
    final app = AppState()
      ..updatePhase = UpdatePhase.failed
      ..verifyMatched = false
      ..applyOutcome = ApplyOutcome.stagedNotApplied;
    await pumpVerify(tester, app);

    expect(find.text('Update not committed'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('still holding the verified image'),
        findsOneWidget);
  });

  testWidgets('rollback is unavailable while the reboot is still deciding',
      (tester) async {
    final app = AppState()..updatePhase = UpdatePhase.verifying;
    await pumpVerify(tester, app);

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Roll back'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a WiFi upload does not run a second apply', (tester) async {
    final app = AppState()
      ..otaMethod = OtaMethod.wifi
      ..updatePhase = UpdatePhase.done
      ..verifyMatched = true;
    await pumpVerify(tester, app);

    expect(find.text('Update verified'), findsOneWidget);
    expect(find.text('Roll back'), findsNothing);
    expect(find.textContaining('Node is rebooting'), findsNothing);
  });

  testWidgets('a version-only result is not called a hash match',
      (tester) async {
    final app = AppState()
      ..otaMethod = OtaMethod.wifi
      ..updatePhase = UpdatePhase.done
      ..verifyMatched = true
      ..verificationLevel = VerificationLevel.versionOnly;
    await pumpVerify(tester, app);

    expect(find.text('Firmware updated'), findsOneWidget);
    expect(find.text('Update verified'), findsNothing);
    expect(find.textContaining('version match only'), findsOneWidget);
  });
}
