import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/radio_settings_screen.dart';
import 'package:meshcore_repeater_manager/services/radio_plan.dart';

import 'support.dart';

const _live = LoRaPreset(
  frequencyHz: 910525000,
  bandwidthHz: 62500,
  spreadingFactor: 7,
  codingRate: 5,
);

AppState _app({RadioMode mode = RadioMode.tempRadio, bool? radio2}) {
  final app = AppState();
  app.target = contact('riley');
  app.nodePreset = _live;
  app.radio2Enabled = radio2;
  app.radioPlan = RadioPlan(
    mode: mode,
    preset: RadioPlan.suggestTempRadio(_live),
  );
  return app;
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('offers the three radios and explains the private preset',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(find.text('Live mesh'), findsOneWidget);
    expect(find.text('Temporary private channel'), findsOneWidget);
    expect(find.text('The repeater\'s second preset'), findsOneWidget);
    expect(find.text('PRIVATE PRESET'), findsOneWidget);
    expect(find.textContaining('renews it automatically'), findsOneWidget);
    expect(find.text('Step 5 of 8'), findsOneWidget);
  });

  testWidgets('the private channel renews itself; no duration input',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(
        find.textContaining('${RadioPlan.tempRadioChunkMinutes}-minute chunks'),
        findsOneWidget);
    expect(find.textContaining('renews it automatically'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Keep the preset for (minutes)'),
        findsNothing);
  });

  testWidgets('an invalid preset is refused before continuing', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '100');
    await tester.pump();

    expect(
        find.textContaining('frequency must be 150 to 2500'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review'),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('the private preset starts from the repeater settings',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    // No region-specific "suggest" button: the fields are prefilled from the
    // node's own preset and stay editable for other regions.
    expect(find.text('Suggest settings'), findsNothing);
    expect(find.textContaining('Started from the repeater'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Frequency (MHz)'),
    );
    expect(field.controller!.text, isNotEmpty);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review'),
    );
    expect(save.onPressed, isNotNull);
  });

  testWidgets('continuing stores the preset, then moves on', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '914');
    await tester.pump();
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(app.radioPlan.mode, RadioMode.tempRadio);
    expect(app.radioPlan.preset!.frequencyMhz, 914);
    // The next wizard step is the review summary.
    expect(find.text('Step 6 of 8'), findsOneWidget);
  });

  testWidgets('switching to live mesh hides the preset and shows the path',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    await tester.tap(find.text('Live mesh'));
    await tester.pump();

    expect(find.text('PRIVATE PRESET'), findsNothing);
    expect(find.text('Direct path override (optional)'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(app.radioPlan.mode, RadioMode.liveMesh);
  });

  testWidgets('no transfer time is guessed before the comparison',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(Uint8List.fromList(List.filled(120000, 3)),
        env: 'Xiao_S3_WIO_repeater_observer', version: 'v1.1.0-rc5');
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(entry);

    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(find.textContaining('Estimated transfer:'), findsNothing);
    expect(find.textContaining('airtime'), findsNothing);
  });

  testWidgets('the direct path override accepts and rejects paths',
      (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.liveMesh);
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(find.text('Step 5 of 8'), findsOneWidget);
    expect(find.text('Direct path override (optional)'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Direct path override (optional)'),
        'c0ff');
    await tester.pump();
    expect(app.manualRoutePath, 'c0ff');

    await tester.enterText(
        find.widgetWithText(TextField, 'Direct path override (optional)'),
        'not-hex');
    await tester.pumpAndSettle();
    expect(app.manualRouteError, isNotNull);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review'),
    );
    expect(save.onPressed, isNull);
    expect(find.text('Fix the direct path override above.'), findsOneWidget);
  });

  testWidgets('an existing radio2 configuration is called out', (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.radio2, radio2: true);
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(find.textContaining('radio2 is already enabled'), findsOneWidget);
    expect(find.textContaining('will not change the node'), findsOneWidget);
  });

  testWidgets('radio2 must clear the live band', (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.radio2, radio2: false);
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    // Same frequency as the live preset: refused.
    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '910.525');
    await tester.pump();

    expect(find.textContaining('must not overlap'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review'),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('an existing radio2 preset is used without editing',
      (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.radio2, radio2: true);
    app.radio2Preset = _live.copyWith(frequencyHz: 914000000);
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(find.textContaining('Using the repeater\'s current radio2 preset'),
        findsOneWidget);
    expect(find.widgetWithText(TextField, 'Frequency (MHz)'), findsNothing);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(app.radioPlan.preset!.frequencyMhz, 914);
  });

  testWidgets('tempradio warns that radio2 is paused during the transfer',
      (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.tempRadio, radio2: true);
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(
        find.textContaining(
            'radio2 is paused while the private channel is in use'),
        findsOneWidget);
  });
}
