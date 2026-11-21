import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/fleet_composer_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/fleet_queue_screen.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/fleet_scheduler.dart';
import 'package:meshcore_repeater_manager/services/fleet_service.dart';
import 'package:meshcore_repeater_manager/services/fleet_store.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

Contact _target() => contact('Roof');

CliService _cli(List<String> commands) => CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        commands.add(command);
        return switch (command) {
          'fleet' => 'on; chan h=2a; tags 1; seen 0',
          'fleet tag list' => 'tags: north',
          'fleet seen job-1' => 'OK - key job-1 seen',
          'fleet off' => '> ok',
          _ => '> ok',
        };
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );

void main() {
  test('fleet service reads status, tags and seen, and writes config',
      () async {
    final commands = <String>[];
    final service = FleetService(_cli(commands), _target());
    expect(await service.status(), contains('chan h=2a'));
    expect(await service.tags(), ['north']);
    expect(await service.seen('job-1'), isTrue);
    await service.write('fleet off');
    expect(commands, contains('fleet off'));
  });

  test('scheduler loads existing jobs and replaces a duplicate id', () async {
    final saved = <List<ScheduledFleetJob>>[];
    final scheduler = FleetScheduler(
      save: (jobs) async => saved.add(List.of(jobs)),
      onDue: (_) async {},
    );
    await scheduler.load([
      ScheduledFleetJob(id: 'a', script: 'x', dueAt: DateTime.now()),
    ]);
    expect(scheduler.jobs, hasLength(1));
    await scheduler.schedule(ScheduledFleetJob(
        id: 'a', script: 'y', dueAt: DateTime.now().add(Duration(days: 1))));
    expect(scheduler.jobs, hasLength(1));
    expect(scheduler.jobs.single.script, 'y');
  });

  test('scheduler stops at the bounded number of checks', () async {
    var checks = 0;
    final scheduler = FleetScheduler(
      save: (_) async {},
      onDue: (_) async {},
      tick: const Duration(milliseconds: 10),
    );
    // Drive the same body checkNow uses, without wall-clock timers.
    for (var i = 0; i < FleetScheduler.maxChecks + 1; i++) {
      await scheduler.checkNow();
      checks++;
    }
    expect(checks, greaterThan(FleetScheduler.maxChecks));
    scheduler.start();
    scheduler.stop();
  });

  testWidgets('composer reports an invalid job id', (tester) async {
    final app = AppState();
    app.target = _target();
    await tester.pumpWidget(wrap(app, const FleetComposerScreen()));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('fleet-id')), 'bad id');
    await tester.pump();
    expect(find.textContaining('job id needs'), findsWidgets);
  });

  testWidgets('queue screen lists a scheduled job and cancels it',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('fleet_queue_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState();
    app.target = _target();
    app.fleetStore = FleetStore(File('${dir.path}/fleet.json'), persist: false);
    await app.fleetStore!.load();
    app.fleetScheduler = FleetScheduler(
      save: (jobs) =>
          app.fleetStore!.saveQueue(jobs.map((j) => j.toJson()).toList()),
      onDue: (_) async {},
    );
    await app.fleetScheduler!.schedule(ScheduledFleetJob(
        id: 'job-later',
        script: '!id job-later\nver',
        dueAt: DateTime.now().add(const Duration(days: 1))));
    await tester.pumpWidget(wrap(app, const FleetQueueScreen()));
    await tester.pump();
    expect(find.text('job-later'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.cancel_outlined));
    await tester.pump();
    expect(app.fleetScheduler!.jobs, isEmpty);
  });
}
