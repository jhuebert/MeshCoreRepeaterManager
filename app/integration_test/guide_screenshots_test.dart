// Captures the screenshots embedded in the user guide (README.md) from the
// real widget tree, on an attached device. Run via scripts/screenshots.sh.
//
// flutter test must NOT be used for this: `flutter test` renders text with a
// placeholder font, so its goldens are unreadable. An integration test runs a
// real Flutter view with real fonts; we pin the view to the guide's 860x1864
// capture size and write each screen's RepaintBoundary straight to a PNG.
//
// Screens are driven from test/support.dart fixtures, so no companion, radio,
// network or filesystem is needed. Adding a screenshot to the guide means
// adding a _Shot below and an embed in README.md.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/connect_screen.dart';
import 'package:meshcore_repeater_manager/screens/firmware_screen.dart';
import 'package:meshcore_repeater_manager/screens/login_screen.dart';
import 'package:meshcore_repeater_manager/screens/radio_settings_screen.dart';
import 'package:meshcore_repeater_manager/screens/review_screen.dart';
import 'package:meshcore_repeater_manager/screens/target_screen.dart';
import 'package:meshcore_repeater_manager/services/github_source.dart';
import 'package:meshcore_repeater_manager/services/radio_plan.dart';

import '../test/support.dart' as fix;

// The guide embeds 860x1864 PNGs. Capture a phone-sized logical viewport
// (430x932 dp) at 2x so the layout and text weight match a real handset;
// capturing at 860x1864 logical pixels would lay the UI out as a tablet.
const _width = 860.0;
const _height = 1864.0;
const _scale = 2.0;
const _board = 'Xiao_S3_WIO_repeater_observer';
const _stamp = 'v1.1.0-rc5';

/// One guide screenshot: the fixture state, the screen, and optional setup
/// that has to run before/after the first pump.
class _Shot {
  const _Shot({
    required this.file,
    required this.state,
    required this.screen,
    this.prepare,
    this.interact,
  });

  final String file;
  final AppState Function() state;
  final Widget Function(AppState app) screen;
  final Future<void> Function(AppState app)? prepare;
  final Future<void> Function(WidgetTester tester)? interact;
}

final _targetId = targetIdForEnvironment(_board);

/// Deterministic stand-in for a contact's public key.
Uint8List _key(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => i + seed));

final _livePreset = LoRaPreset(
  frequencyHz: 910525000,
  bandwidthHz: 62500,
  spreadingFactor: 7,
  codingRate: 5,
);

/// Catalog with a stable version for our board, a dev version, and one release
/// with no image for the node (hidden by the picker).
Catalog _catalog() => fix.catalog([
      fix.release('v1.1.0-rc5', images: [
        fix.asset(_board, _stamp, size: 1449824),
        fix.asset('RAK_4631_repeater', _stamp, size: 1449824),
      ]),
      fix.release('v1.1.0-dev.9', images: [
        fix.asset(_board, 'v1.1.0-dev.9', size: 1512000),
      ]),
      fix.release('v1.0.0-old', images: [
        fix.asset('RAK_4631_repeater', 'v1.0.0-old'),
      ]),
    ]);

/// An app that has signed in to a known board but has not picked an image.
AppState _signedInApp() {
  final app = AppState();
  app.target = fix.contact('Riley Ridge');
  app.nodeStatus = fix.nodeStatus();
  app.nodeInfo = fix.nodeInfo(targetId: _targetId);
  app.nodePreset = _livePreset;
  app.catalog = _catalog();
  app.library = fix.FakeLibrary();
  return app;
}

List<_Shot> _shots() {
  Future<void> seedLibrary(AppState app) async {
    final lib = app.library as fix.FakeLibrary;
    lib.addImage(Uint8List.fromList(List<int>.filled(1449824, 1)),
        env: _board,
        version: _stamp,
        fileName: '$_board-$_stamp.bin');
    lib.addImage(Uint8List.fromList(List<int>.filled(1449824, 2)),
        env: 'RAK_4631_repeater',
        version: _stamp,
        fileName: 'RAK_4631_repeater-$_stamp.bin');
    lib.addImage(Uint8List.fromList(List<int>.filled(4096, 3)),
        env: 'custom',
        version: 'custom',
        fileName: 'my-build.bin',
        origin: 'import');
    app.libraryEntries = await lib.list();
  }

  return [
    _Shot(
      file: '01-connect.png',
      state: () {
        final app = AppState();
        app.connectionPhase = ConnectionPhase.connected;
        app.companionName = 'MeshCore-nc3';
        app.contacts = List.generate(
            5, (i) => fix.contact('repeater ${i + 1}', key: _key(i + 1)));
        return app;
      },
      screen: (_) => const ConnectScreen(),
      // The guide shows the phone (Bluetooth) layout. Pin the choice so the
      // capture is identical on desktop and on a handset.
      interact: (tester) async {
        await tester.tap(find.text('Bluetooth'));
        await tester.pumpAndSettle();
      },
    ),
    _Shot(
      file: '02-repeater.png',
      state: () {
        final app = AppState();
        app.contacts = [
          fix.contact('Riley Ridge'),
          fix.contact('Harper'),
          fix.contact('Cedar Grove', key: _key(3), hops: 1),
          fix.contact('Basecamp', key: _key(4)),
        ];
        app.target = app.contacts.first;
        return app;
      },
      screen: (_) => const TargetScreen(),
    ),
    _Shot(
      file: '03-admin.png',
      state: () {
        final app = AppState();
        app.target = fix.contact('Riley Ridge');
        return app;
      },
      screen: (_) => const LoginScreen(),
    ),
    _Shot(
      file: '04-firmware.png',
      state: _signedInApp,
      screen: (_) => const FirmwareScreen(),
    ),
    _Shot(
      file: '06-radio.png',
      state: () {
        final app = _signedInApp();
        // An older running version, so the estimate is for a real transfer
        // rather than a delta against an identical image.
        app.nodeStatus = fix.nodeStatus(running: 'v1.1.0-r3');
        return app;
      },
      prepare: (app) async {
        await seedLibrary(app);
        final entry = app.libraryEntries.firstWhere((e) => e.env == _board);
        await app.selectLibraryEntryForUpdate(entry);
        app.radioPlan = RadioPlan(
          mode: RadioMode.tempRadio,
          preset: RadioPlan.suggestTempRadio(_livePreset),
        );
      },
      screen: (_) => const RadioSettingsScreen(),
    ),
    _Shot(
      file: '07-review.png',
      state: () {
        final app = _signedInApp();
        // An older running version, so the summary describes a real update
        // instead of "already up to date".
        app.nodeStatus = fix.nodeStatus(running: 'v1.1.0-r3');
        return app;
      },
      prepare: (app) async {
        await seedLibrary(app);
        app.companionName = 'MeshCore-nc3';
        app.transportKind = 'tcp';
        app.tcpHost = '10.0.0.8';
        final entry = app.libraryEntries.firstWhere((e) => e.env == _board);
        await app.selectLibraryEntryForUpdate(entry);
        app.remoteDiff = fix.remoteDiff(
          literalBytes: 59392,
          copyBytes: 1390432,
          queries: 37,
        );
        app.radioPlan = RadioPlan(
          mode: RadioMode.tempRadio,
          preset: RadioPlan.suggestTempRadio(_livePreset),
        );
      },
      screen: (_) => const ReviewScreen(),
    ),
    _Shot(
      file: '08-offline.png',
      state: () {
        final app = _signedInApp();
        app.offlineMode = true;
        return app;
      },
      prepare: seedLibrary,
      screen: (_) => const FirmwareScreen(),
    ),
    _Shot(
      file: '09-library.png',
      state: _signedInApp,
      prepare: seedLibrary,
      screen: (_) => const FirmwareScreen(updateMode: false),
    ),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final outDir = Directory(const String.fromEnvironment('SCREENSHOT_DIR'));
  if (!outDir.path.startsWith('/')) {
    throw StateError('SCREENSHOT_DIR must be an absolute path');
  }

  testWidgets('capture the user guide screenshots', (tester) async {
    tester.view.physicalSize = const Size(_width, _height);
    tester.view.devicePixelRatio = _scale;
    addTearDown(tester.view.reset);

    await outDir.create(recursive: true);
    for (final shot in _shots()) {
      final app = shot.state();
      if (shot.prepare != null) await shot.prepare!(app);

      final boundaryKey = GlobalKey();
      await tester.pumpWidget(fix.wrap(
        app,
        RepaintBoundary(key: boundaryKey, child: shot.screen(app)),
      ));
      await tester.pump();
      await tester.pumpAndSettle();
      if (shot.interact != null) {
        await shot.interact!(tester);
        await tester.pumpAndSettle();
      }

      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: _scale);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw StateError('no PNG bytes for ${shot.file}');
      final bytes = byteData.buffer.asUint8List();
      await File('${outDir.path}/${shot.file}').writeAsBytes(bytes);
      // ignore: avoid_print
      print('wrote ${shot.file} (${bytes.length} bytes, ${boundary.size})');
    }
  });
}
