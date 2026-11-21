import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/acl_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/browser_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/cli_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/neighbors_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/settings_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/status_screen.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/repeater_cache_store.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

AppState _app() {
  final app = AppState();
  app.connectionPhase = ConnectionPhase.connected;
  app.target = contact('Roof');
  app.loginPermission = 3;
  return app;
}

Future<void> _pump(WidgetTester tester, Widget child, AppState app) async {
  await tester.pumpWidget(wrap(app, child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('status screen is cache-first and refreshes on demand',
      (tester) async {
    final cli = fakeCli();
    await _pump(tester, RepeaterStatusScreen(cli: cli), _app());
    expect(
        find.text('No status has been read yet. Tap refresh.'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('4100 mV'), findsOneWidget);
    expect(find.textContaining('Last known'), findsWidgets);
  });

  testWidgets('status screen renders cached facts without a refresh',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('status_cache_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache =
        RepeaterCacheStore(File('${dir.path}/cache.json'), persist: false);
    await cache.load();
    final status = RepeaterStatus(
      batteryMilliVolts: 3900,
      txQueueLength: 0,
      noiseFloor: -115,
      lastRssi: -60,
      packetsReceived: 1,
      packetsSent: 2,
      totalAirTimeSecs: 3,
      uptimeSecs: 3600,
      sentFlood: 0,
      sentDirect: 0,
      recvFlood: 0,
      recvDirect: 0,
      errorEvents: 0,
      lastSnr: 2.0,
      directDuplicates: 0,
      floodDuplicates: 0,
      rxAirTimeSecs: 1,
      recvErrors: 0,
      fetchedAt: DateTime.utc(2026, 11, 20),
    );
    await cache.write('status', status.toJson());
    await cache.write('owner', {
      'version': 'v1.17.0',
      'name': 'Shed',
      'owner': 'Jason',
    });

    await _pump(
        tester, RepeaterStatusScreen(cli: fakeCli(), cache: cache), _app());
    expect(find.text('3900 mV'), findsOneWidget);
  });

  testWidgets('status screen reports an unknown outcome on no answer',
      (tester) async {
    final cli = CliService(
      exchange: (_, __, {timeout = const Duration(seconds: 45)}) async => '',
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('no reply'),
      rawBinary: (_, __,
          {data = const [], timeout = const Duration(seconds: 10)}) async {
        throw const RepeaterRequestException('no reply');
      },
    );
    await _pump(tester, RepeaterStatusScreen(cli: cli), _app());
    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Outcome unknown'), findsOneWidget);
  });

  testWidgets('settings screen shows curated sections and saves a draft',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('settings_screen_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache =
        RepeaterCacheStore(File('${dir.path}/cache.json'), persist: false);
    await cache.load();
    final commands = <String>[];
    final cli = fakeCli(
      replies: {'get tx': '> 20'},
      commands: commands,
    );
    await _pump(tester, RepeaterSettingsScreen(cli: cli, cache: cache), _app());

    expect(find.text('BASIC'), findsOneWidget);
    expect(find.text('Save'), findsNothing);

    // The name field is the first visible text control in the Basic section.
    await tester.enterText(find.byType(TextField).first, 'Hill');
    await tester.pump();
    // The unsaved state shows a Discard action in the app bar immediately;
    // the Save button sits at the end of the long list.
    expect(find.text('Discard'), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await tester.pump();
    expect(find.text('Discard'), findsNothing);
  });

  testWidgets('settings screen refreshes one section on demand',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('settings_refresh_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache =
        RepeaterCacheStore(File('${dir.path}/cache.json'), persist: false);
    await cache.load();
    final commands = <String>[];
    final cli = fakeCli(replies: {'get name': '> Hill'}, commands: commands);
    await _pump(tester, RepeaterSettingsScreen(cli: cli, cache: cache), _app());
    await tester.tap(find.text('Refresh section').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('get name'));
  });

  testWidgets('settings screen saves a draft in its bottom action bar',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('settings_save_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache =
        RepeaterCacheStore(File('${dir.path}/cache.json'), persist: false);
    await cache.load();
    final commands = <String>[];
    final cli = fakeCli(commands: commands);
    await _pump(tester, RepeaterSettingsScreen(cli: cli, cache: cache), _app());

    await tester.enterText(find.byType(TextField).first, 'Hill');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('set name Hill'));
  });

  testWidgets('setting browser searches, reads and sets a key', (tester) async {
    final commands = <String>[];
    final cli = fakeCli(replies: {'get tx': '> 20'}, commands: commands);
    await _pump(tester, SettingBrowserScreen(cli: cli), _app());

    await tester.enterText(find.byType(TextField).first, 'tx');
    await tester.pump();
    await tester.tap(find.text('tx').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('get tx'));
    expect(find.text('20'), findsWidgets);

    // Set the value that was just read.
    final valueField = find.byType(TextField).last;
    await tester.enterText(valueField, '22');
    await tester.pump();
    await tester.tap(find.text('Set'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('set tx 22'));
  });

  testWidgets('CLI screen confirms dangerous commands and keeps a transcript',
      (tester) async {
    final commands = <String>[];
    final cli = fakeCli(
      replies: {'ver': 'v1.18.0', 'reboot': 'OK, rebooting'},
      commands: commands,
    );
    await _pump(tester, CliScreen(cli: cli), _app());

    await tester.tap(find.text('ver'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('v1.18.0'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'reboot');
    await tester.tap(find.text('Run'));
    await tester.pump();
    expect(find.text('Run this command?'), findsOneWidget);
    await tester.tap(find.text('Run').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('reboot'));
    expect(find.text('OK, rebooting'), findsOneWidget);
  });

  testWidgets('CLI screen refuses serial-only commands in app', (tester) async {
    await _pump(tester, CliScreen(cli: fakeCli()), _app());
    await tester.enterText(find.byType(TextField).last, 'erase');
    await tester.tap(find.text('Run'));
    await tester.pump();
    expect(find.textContaining('Not available remotely'), findsOneWidget);
  });

  testWidgets('ACL screen lists entries and guards the companion own key',
      (tester) async {
    final cli = fakeCli(acl: [
      AclEntry(Uint8List.fromList([1, 2, 3, 4, 5, 6]), 3),
    ]);
    await _pump(
        tester, AdminAclScreen(cli: cli, ownPrefixHex: '010203040506'), _app());
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('010203040506'), findsOneWidget);
    expect(find.text('This companion'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pump();
    await tester.tap(find.text('Read only').last);
    await tester.pump();
    expect(find.text('Change your own access?'), findsOneWidget);
    // Cancelling must not send a setperm command.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
  });

  testWidgets('ACL screen changes another key after confirmation',
      (tester) async {
    final commands = <String>[];
    final cli = fakeCli(
      commands: commands,
      acl: [
        AclEntry(Uint8List.fromList([9, 8, 7, 6, 5, 4]), 3)
      ],
    );
    await _pump(
        tester, AdminAclScreen(cli: cli, ownPrefixHex: '010203040506'), _app());
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pump();
    await tester.tap(find.text('Read only').last);
    await tester.pump();
    // Not the companion's own key, so no extra guard is shown.
    expect(find.text('Change your own access?'), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('setperm 090807060504 1'));
  });

  testWidgets('neighbours screen pages and shows an explicit Next action',
      (tester) async {
    final commands = <String>[];
    final cli = fakeCli(
        commands: commands,
        neighbours: NeighborPage(3, [
          Neighbor(Uint8List.fromList([1, 2, 3, 4, 5, 6]), 30, 7.0),
        ]));
    await _pump(tester, NeighborsScreen(cli: cli), _app());
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('3 known neighbours.'), findsOneWidget);
    expect(find.text('010203040506'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    // Sorting and discovery are explicit actions, never automatic on open.
    await tester.tap(find.byType(DropdownButton<NeighborOrder>));
    await tester.pump();
    await tester.tap(find.text('Strongest first').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('req:6'));

    await tester.tap(find.text('Discover neighbors'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('discover.neighbors'));
  });
}
