import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/app_settings_screen.dart';

import 'support.dart';

void main() {
  testWidgets('mesh budget chips are opt-in and never persisted',
      (tester) async {
    final app = AppState();
    await tester.pumpWidget(wrap(app, const AppSettingsScreen()));
    await tester.pump();

    expect(find.text('Soft request warning'), findsOneWidget);
    expect(app.requestMeter.budget, isNull);
    await tester.tap(find.text('50'));
    await tester.pump();
    expect(app.requestMeter.budget, 50);
    await tester.tap(find.text('Off'));
    await tester.pump();
    expect(app.requestMeter.budget, isNull);
  });
}
