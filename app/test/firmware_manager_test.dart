import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/firmware_screen.dart';

import 'support.dart';

const _board = 'Xiao_S3_WIO_repeater_observer';

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

const _stamp = 'v1.1.0-rc5';

Future<AppState> _app() async {
  final app = AppState();
  final lib = FakeLibrary();
  // One downloaded version (both boards share the stamp, like real releases).
  lib.addImage(Uint8List.fromList(List.filled(64, 1)),
      env: _board,
      version: _stamp,
      fileName: '$_board-$_stamp.bin');
  lib.addImage(Uint8List.fromList(List.filled(64, 2)),
      env: 'RAK_4631_repeater',
      version: _stamp,
      fileName: 'RAK_4631_repeater-$_stamp.bin');
  // One imported (custom) bin.
  lib.addImage(Uint8List.fromList(List.filled(64, 3)),
      env: 'custom',
      version: 'custom',
      fileName: 'my-build.bin',
      origin: 'import');
  app.library = lib;
  app.libraryEntries = await lib.list();
  app.catalog = catalog([
    release('v1.1.0-rc5', images: [
      asset(_board, _stamp, size: 64),
      asset('RAK_4631_repeater', _stamp, size: 64),
    ]),
    release('v1.0.0-old', images: [
      asset('RAK_4631_repeater', 'v1.0.0-old', size: 64),
    ]),
  ]);
  return app;
}

void main() {
  _managerModeTests();

  testWidgets('the standalone manager has no wizard chrome and no device list',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    expect(find.text('Firmware library'), findsOneWidget);
    expect(find.text('Choose the image'), findsNothing);
    expect(find.text('Review update'), findsNothing);
    expect(find.text('All boards'), findsNothing); // board dropdown is gone
    expect(find.text('RAK_4631_repeater'), findsNothing); // no device rows
    expect(find.textContaining('Versions are treated as a unit'), findsNothing);
    // The offline switch is still there — managing is the point here.
    expect(find.byTooltip('Go offline'), findsOneWidget);
  });

  testWidgets('the manager lists every release, not just one board\'s',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    expect(find.text('v1.0.0-old'), findsOneWidget);
  });

  testWidgets('tapping a release downloads any missing images', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    // Everything is already saved, so the tap is a no-op with feedback.
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('v1.1.0-rc5 is already saved'), findsOneWidget);
    expect(app.imageError, isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('a saved version can be deleted from the GitHub tab',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await app.selectLibraryEntryForUpdate(
        app.libraryEntries.firstWhere((e) => e.env == _board));
    expect(app.selectedLibraryEntry, isNotNull);

    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    await tester.tap(find.byTooltip('Delete this version (2 image(s))'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Delete v1.1.0-rc5?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(app.libraryEntries.length, 1); // only the imported bin remains
    expect(app.libraryEntries.single.fileName, 'my-build.bin');
    expect(app.selectedLibraryEntry, isNull); // selection was repaired
    expect(app.selectedImage, isNull);
  });

  testWidgets('imported bins stay on their own tab in offline mode',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    // Offline GitHub view: only the saved version.
    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    expect(find.text('v1.0.0-old'), findsNothing); // not downloaded
    expect(find.textContaining('1 version(s) on this device'), findsOneWidget);

    // Imported is untouched by offline mode.
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();
    expect(find.text('my-build.bin'), findsOneWidget);
    expect(find.text('Import a .bin'), findsOneWidget);
  });

  testWidgets('an import appears without restarting the screen',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();
    expect(find.text('dropped-in.bin'), findsNothing);

    // Simulate what the import button does; the screen must refresh itself.
    await app.importLocalImage(
      Uint8List.fromList(List.filled(32, 8)),
      fileName: 'dropped-in.bin',
    );
    await tester.pump();
    expect(find.text('dropped-in.bin'), findsOneWidget);
  });

  testWidgets('no field-pack copy remains in the manager', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    expect(find.textContaining('field pack'), findsNothing);
  });
}

void _managerModeTests() {
  testWidgets('a partial version shows the warn icon and allows save',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    final lib = app.library as FakeLibrary;
    await lib.delete(
        app.libraryEntries.firstWhere((e) => e.env == 'RAK_4631_repeater'));
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    expect(find.byIcon(Icons.cloud_download), findsOneWidget);
    expect(find.byIcon(Icons.cloud_done), findsNothing);
  });

  testWidgets('deleting a partially saved version removes what is stored',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    final lib = app.library as FakeLibrary;
    await lib.delete(
        app.libraryEntries.firstWhere((e) => e.env == 'RAK_4631_repeater'));
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    await tester.tap(_tooltipContaining('Delete this version'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(app.libraryEntries.where((e) => e.origin == 'github'), isEmpty);
    expect(app.libraryEntries.single.fileName, 'my-build.bin');
  });

  testWidgets('tapping a version while offline reports nothing to do',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('Nothing new to download'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('an unknown board explains version matching is impossible',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    app.nodeInfo = nodeInfo(targetId: 0x11111111);

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.textContaining('board is not recognized'), findsOneWidget);
    expect(find.text('v1.1.0-rc5'), findsNothing);
  });

  testWidgets('offline with versions saved only for other boards explains it',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    // The node reported a known board, so the picker can scope to it.
    app.nodeInfo = nodeInfo(targetId: targetIdForEnvironment(_board));
    final lib = app.library as FakeLibrary;
    // Drop the node-board image, keep the other one.
    await lib.delete(app.libraryEntries.firstWhere((e) => e.env == _board));
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing saved for your board'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Go online'), findsOneWidget);
    expect(find.text('v1.1.0-rc5'), findsNothing);
  });

  testWidgets('imported files can be inspected and selected for the update',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();

    // Details dialog shows the hash.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('SHA-256'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Close'));
    await tester.pumpAndSettle();

    // There is no local delta-base picker any more: the node supplies the
    // bytes. Selecting the file for the update is the only action.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Use as delta base'), findsNothing);

    await tester.tap(find.text('Use for the update'));
    await tester.pumpAndSettle();
    expect(app.selectedLibraryEntry?.fileName, 'my-build.bin');
  });

  testWidgets('a downloaded version can be deleted from the catalog tab',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    await tester.tap(_tooltipContaining('Delete this version').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(app.libraryEntries.where((e) => e.origin == 'github'), isEmpty);
  });
}

Finder _tooltipContaining(String substring) => find.byWidgetPredicate(
    (w) => w is Tooltip && w.message.toString().contains(substring));
