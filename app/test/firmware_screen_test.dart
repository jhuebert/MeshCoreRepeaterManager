import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/firmware_screen.dart';
import 'package:meshcore_repeater_manager/screens/radio_settings_screen.dart';

import 'support.dart';

const _board = 'Xiao_S3_WIO_repeater_observer';
final _targetId = targetIdForEnvironment(_board);

AppState _app() {
  final app = AppState();
  app.library = FakeLibrary();
  // Catalog: one stable release with two boards, one dev release.
  app.catalog = catalog([
    release('v1.1.0-rc5', images: [
      asset(_board, 'v1.1.0-rc5', size: 1024),
      asset('RAK_4631_repeater', 'v1.1.0-rc5', size: 1024),
    ]),
    release('v1.0.0-old', images: [
      asset('RAK_4631_repeater', 'v1.0.0-old', size: 1024),
    ]),
    release('v1.1.0-dev.9', images: [
      asset(_board, 'v1.1.0-dev.9', size: 1024),
    ]),
  ]);
  app.nodeInfo = nodeInfo(targetId: _targetId);
  return app;
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the picker shows versions, not devices', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    // One row per version; the device names and the board dropdown are gone,
    // and the verbose explainer line is gone too.
    expect(find.textContaining('image for your board'), findsNothing);
    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    expect(find.text('RAK_4631_repeater'), findsNothing);
    expect(find.text(_board), findsNothing);
    expect(find.text('All boards'), findsNothing);
    // Releases without an image for this board are hidden.
    expect(find.text('v1.0.0-old'), findsNothing);
  });

  testWidgets('the step bar sits in the app bar above the tabs',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    final wizard = find.text('Step 4 of 8');
    expect(wizard, findsOneWidget);
    expect(find.ancestor(of: wizard, matching: find.byType(AppBar)),
        findsOneWidget);
    expect(tester.getRect(wizard).bottom,
        lessThan(tester.getRect(find.text('GitHub')).top));

    // The standalone library manager has no wizard chrome.
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    expect(find.text('Step 4 of 8'), findsNothing);
  });

  testWidgets('tapping a version selects the image for the node board',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 3)),
        env: _board,
        version: 'v1.1.0-rc5',
        fileName: '$_board-v1.1.0-rc5.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();

    expect(app.selectedAsset?.env, _board);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('with no detected board a version lets you pick its image',
      (tester) async {
    _bigView(tester);
    final app = _app();
    // The node answered `ota status` but not OP_INFO, so there is no board to
    // scope the picker against (the reported symptom).
    app.nodeInfo = null;
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 7)),
        env: 'RAK_4631_repeater',
        version: 'v1.1.0-rc5',
        fileName: asset('RAK_4631_repeater', 'v1.1.0-rc5').name);
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    // No auto-selection: every release in the track is listed.
    expect(find.text('v1.0.0-old'), findsOneWidget);
    expect(find.textContaining('capability check'), findsOneWidget);

    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();

    expect(find.text('Pick the image for your repeater'), findsOneWidget);
    await tester.tap(find.text('RAK_4631_repeater'));
    await tester.pumpAndSettle();

    expect(app.selectedAsset?.env, 'RAK_4631_repeater');
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('offline versions are selectable when the board is unknown',
      (tester) async {
    _bigView(tester);
    final app = _app();
    app.nodeInfo = null;
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 1)),
        env: _board,
        version: 'v1.1.0-rc5',
        fileName: '$_board-v1.1.0-rc5.bin');
    lib.addImage(Uint8List.fromList(List.filled(64, 2)),
        env: 'RAK_4631_repeater',
        version: 'v1.1.0-rc5',
        fileName: 'RAK_4631_repeater-v1.1.0-rc5.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    // Both boards are saved under the same version; it is still listed.
    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();

    expect(find.text('Pick the image for your repeater'), findsOneWidget);
    await tester.tap(find.text(_board));
    await tester.pumpAndSettle();

    expect(app.selectedLibraryEntry?.env, _board);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('a generic bin asks for a board when the handshake is silent',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    final running = lib.addImage(Uint8List.fromList(List.filled(64, 9)),
        env: _board,
        version: 'v1.1.0-rc5',
        fileName: '$_board-v1.1.0-rc5.bin');
    app.nodeStatus = nodeStatus(shaPrefix: running.sha256.substring(0, 16));
    app.nodeInfo = null; // no OP_INFO answer on sign-in
    lib.addImage(Uint8List.fromList(List.filled(64, 5)),
        env: 'custom',
        version: 'custom',
        fileName: 'firmware.bin',
        origin: 'import');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('firmware.bin'));
    await tester.pumpAndSettle();

    expect(app.selectedImage, isNotNull);
    // No local hash lookup can name a board: the operator must choose one.
    expect(app.needsBoardForImage, isTrue);
    expect(find.text('Choose board'), findsOneWidget);
    var next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(next.onPressed, isNull);

    await tester.tap(find.text('Choose board'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_board));
    await tester.pumpAndSettle();
    next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('a generic bin needs no local base, only a board',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 9)),
        env: 'custom',
        version: 'custom',
        fileName: 'firmware.bin',
        origin: 'import');
    app.nodeStatus = nodeStatus(shaPrefix: '0123456789abcdef');
    app.nodeInfo = null;
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('firmware.bin'));
    await tester.pumpAndSettle();

    // The node supplies the running bytes, so no local base is looked up.
    expect(app.remoteDiff, isNull);
    expect(app.needsBoardForImage, isTrue);
    expect(app.selectedBoardOverride, isNull);
  });

  testWidgets('a generic bin with no board clues asks for one and proceeds',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    app.nodeStatus = nodeStatus(shaPrefix: '0123456789abcdef');
    app.nodeInfo = null;
    lib.addImage(Uint8List.fromList(List.filled(64, 5)),
        env: 'custom',
        version: 'custom',
        fileName: 'firmware.bin',
        origin: 'import');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('firmware.bin'));
    await tester.pumpAndSettle();

    // The image is selected; the missing board is an action, not a dead end.
    expect(app.selectedImage, isNotNull);
    expect(app.needsBoardForImage, isTrue);
    expect(find.textContaining('Choose the board this image'), findsOneWidget);
    final blocked = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(blocked.onPressed, isNull);

    await tester.tap(find.text('Choose board'));
    await tester.pumpAndSettle();
    expect(find.text('Which board is this image for?'), findsOneWidget);
    await tester.tap(find.text(_board));
    await tester.pumpAndSettle();

    expect(app.selectedEnvironment, _board);
    expect(app.needsBoardForImage, isFalse);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('a custom build still hides saved versions offline',
      (tester) async {
    _bigView(tester);
    final app = _app();
    // The node answered the handshake, but its build is not in the catalog —
    // there is genuinely no image the app could match to it.
    app.nodeInfo = nodeInfo(targetId: 0x12345678);
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 1)),
        env: _board,
        version: 'v1.1.0-rc5',
        fileName: '$_board-v1.1.0-rc5.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    expect(find.text("This node's board is not recognized"), findsOneWidget);
    expect(find.text('v1.1.0-rc5'), findsNothing);
  });

  testWidgets('continuing from firmware opens the comparison step',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 3)),
        env: _board,
        version: 'v1.1.0-rc5',
        fileName: '$_board-v1.1.0-rc5.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Radio settings'));
    await tester.pumpAndSettle();

    expect(find.byType(RadioSettingsScreen), findsOneWidget);
  });

  testWidgets('stable and dev are separate, newest-first tabs', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    expect(find.text('v1.1.0-dev.9'), findsNothing);

    await tester.tap(find.text('Dev'));
    await tester.pump();

    expect(find.text('v1.1.0-dev.9'), findsOneWidget);
    expect(find.text('v1.1.0-rc5'), findsNothing);
  });

  testWidgets('going offline shows only the versions this device holds',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 1)),
        env: _board,
        version: 'v1.1.0-rc5',
        fileName: '$_board-v1.1.0-rc5.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    expect(app.offlineMode, isTrue);
    expect(find.text('Offline'), findsNothing); // the Offline tab is gone
    expect(find.text('v1.1.0-rc5'), findsOneWidget); // saved → shown
    expect(find.text('v1.1.0-dev.9'), findsNothing); // not saved
    expect(find.textContaining('saved for offline use'), findsNothing);

    // Toggle back online from the same button.
    await tester.tap(find.byTooltip('Offline. Tap to go online.'));
    await tester.pumpAndSettle();
    expect(app.offlineMode, isFalse);
  });

  testWidgets('offline with nothing saved shows the empty state',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    expect(find.text('No versions saved for offline use yet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Go online'));
    await tester.pumpAndSettle();
    expect(app.offlineMode, isFalse);
    expect(find.text('v1.1.0-rc5'), findsOneWidget);
  });

  testWidgets('in offline mode a downloaded version is one row',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 1)),
        env: _board,
        version: 'v1.1.0-rc5',
        fileName: '$_board-v1.1.0-rc5.bin');
    lib.addImage(Uint8List.fromList(List.filled(64, 2)),
        env: 'RAK_4631_repeater',
        version: 'v1.1.0-rc5',
        fileName: 'RAK_4631_repeater-v1.1.0-rc5.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 version(s) on this device'), findsOneWidget);
    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    expect(find.textContaining('saved for offline use'), findsNothing);
    expect(find.text('RAK_4631_repeater'), findsNothing);

    // Tapping it picks the image built for this node's board.
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();
    expect(app.selectedLibraryEntry?.env, _board);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('selecting a downloaded image enables the review step',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 3)),
        env: _board, version: 'v1.1.0-rc5');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();

    expect(app.selectedImage, isNotNull);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Radio settings'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('a version already fully saved shows the saved state',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    for (final name in [
      '$_board-v1.1.0-rc5.bin',
      'RAK_4631_repeater-v1.1.0-rc5.bin',
    ]) {
      lib.addImage(Uint8List.fromList(List.filled(8, name.length)),
          env: _board, version: 'v1.1.0-rc5', fileName: name);
    }
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.byIcon(Icons.cloud_done), findsWidgets);
    final saved = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.cloud_done).first,
        matching: find.byType(IconButton),
      ),
    );
    expect(saved.onPressed, isNull);
  });
}
