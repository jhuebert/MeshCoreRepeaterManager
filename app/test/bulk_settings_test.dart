import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/bulk_settings_screen.dart';
import 'package:meshcore_repeater_manager/services/bulk_settings_controller.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

void main() {
  group('BulkSettingsController', () {
    test('one job holds all set lines in stable order', () {
      final jobs = BulkSettingsController(
        send: (_, __) async {},
        audit: (_, __) async {},
      ).build(
        values: {'repeat': 'on', 'name': 'Roof'},
        oneScriptPerSetting: false,
        tags: const ['north'],
        ack: true,
      );
      expect(jobs, hasLength(1));
      expect(composeJob(jobs.first), contains('set name Roof\nset repeat on'));
      expect(composeJob(jobs.first), contains('!tags north'));
      expect(composeJob(jobs.first), contains('!ack'));
    });

    test('one job per setting uses distinct ids', () {
      final jobs = BulkSettingsController(
        send: (_, __) async {},
        audit: (_, __) async {},
      ).build(
        values: {'repeat': 'on', 'name': 'Roof'},
        oneScriptPerSetting: true,
        tags: const [],
        ack: false,
      );
      expect(jobs, hasLength(2));
      expect(jobs[0].id, isNot(jobs[1].id));
      expect(composeJob(jobs[0]), contains('set name Roof'));
      expect(composeJob(jobs[1]), contains('set repeat on'));
    });

    test('apply sends and audits every job', () async {
      final sent = <String>[];
      final audited = <String>[];
      final jobs = BulkSettingsController(
        send: (script, id) async => sent.add(id),
        audit: (id, _) async => audited.add(id),
      ).build(
        values: {'repeat': 'on', 'name': 'Roof'},
        oneScriptPerSetting: true,
        tags: const [],
        ack: true,
      );
      await BulkSettingsController(
        send: (script, id) async => sent.add(id),
        audit: (id, _) async => audited.add(id),
      ).apply(jobs);
      expect(sent, hasLength(2));
      expect(audited, sent);
    });
  });

  testWidgets('bulk screen offers only curated settings and previews script',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final app = AppState();
    app.connectionPhase = ConnectionPhase.connected;
    app.target = contact('Roof');
    app.loginPermission = 3;
    final cli = CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async =>
          command == 'fleet tag list' ? 'tags: north' : '> ok',
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );
    await tester.pumpWidget(wrap(app, BulkSettingsScreen(cli: cli)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('bulk-repeat')), findsOneWidget);
    expect(find.byKey(const Key('bulk-name')), findsOneWidget);
    expect(find.text('Password'), findsNothing);

    await tester.enterText(find.byKey(const Key('bulk-name')), 'Hill');
    await tester.pump();
    expect(find.textContaining('set name Hill'), findsWidgets);
    expect(find.textContaining('/ 157 bytes'), findsWidgets);

    // One job per setting produces one preview per change.
    await tester.tap(find.text('One per setting'));
    await tester.pump();
    expect(find.textContaining('bulk-'), findsWidgets);

    await tester.tap(find.text('Schedule on the repeater'));
    await tester.pump();
    expect(find.byKey(const Key('bulk-at')), findsOneWidget);

    // Without a link, Apply reports the problem instead of sending anything.
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(find.textContaining('device-clock Unix timestamp'), findsWidgets);
  });

  testWidgets('bulk screen sends a confirmed job through an injected channel',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final app = AppState();
    app.target = contact('Roof');
    app.loginPermission = 3;
    final sent = <String>[];
    final cli = CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async =>
          command == 'fleet tag list' ? 'tags: north' : '> ok',
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );
    await tester.pumpWidget(wrap(
      app,
      BulkSettingsScreen(
        cli: cli,
        send: (script, id) async => sent.add(script),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byKey(const Key('bulk-name')), 'Hill');
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(find.text('Apply to the group?'), findsOneWidget);
    await tester.tap(find.text('Apply').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(sent, hasLength(1));
    expect(sent.single, contains('set name Hill'));
    expect(app.ackCollector.history, hasLength(1));
  });
}
