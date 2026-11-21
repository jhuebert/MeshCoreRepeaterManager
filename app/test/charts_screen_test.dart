import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/charts_screen.dart';
import 'package:meshcore_repeater_manager/services/repeater_cache_store.dart';

import 'support.dart';

Future<RepeaterCacheStore> _cacheWithSamples() async {
  final cache = RepeaterCacheStore(
      File('${Directory.systemTemp.path}/charts_test_cache.json'),
      persist: false);
  await cache.load();
  for (final sample in [
    MetricSample('batteryMv', 3900, DateTime.utc(2026, 11, 21, 8)),
    MetricSample('batteryMv', 4100, DateTime.utc(2026, 11, 21, 9)),
    MetricSample('packetsSent', 10, DateTime.utc(2026, 11, 21, 8)),
  ]) {
    await cache.addSample(sample.metric, sample.value, at: sample.at);
  }
  return cache;
}

AppState _app() {
  final app = AppState();
  app.connectionPhase = ConnectionPhase.connected;
  app.target = contact('Roof');
  return app;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(wrap(_app(), child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('charts open from cached samples without any command',
      (tester) async {
    final commands = <String>[];
    final cache = await _cacheWithSamples();
    await _pump(tester,
        StatsChartsScreen(cli: fakeCli(commands: commands), cache: cache));
    expect(commands, isEmpty);
    expect(find.text('Battery voltage'), findsOneWidget);
    expect(find.textContaining('Last reading'), findsOneWidget);
    expect(find.text('Statistics'), findsWidgets);
  });

  testWidgets('metric picker and time range switch with no mesh traffic',
      (tester) async {
    final commands = <String>[];
    final cache = await _cacheWithSamples();
    await _pump(tester,
        StatsChartsScreen(cli: fakeCli(commands: commands), cache: cache));

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pump();
    await tester.tap(find.text('Packets sent').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Total since the repeater booted.', skipOffstage: false),
        findsOneWidget);
    expect(commands, isEmpty);

    await tester.tap(find.text('7 d'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, isEmpty);
  });

  testWidgets('an explicit refresh records new samples', (tester) async {
    final cache = await _cacheWithSamples();
    await _pump(tester, StatsChartsScreen(cli: fakeCli(), cache: cache));
    final before = cache.samples('batteryMv').length;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(cache.samples('batteryMv').length, greaterThan(before));
  });

  testWidgets('auto refresh is opt in', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final cache = await _cacheWithSamples();
    await _pump(tester, StatsChartsScreen(cli: fakeCli(), cache: cache));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.textContaining('Stops after 12 refreshes'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.textContaining('Off by default'), findsOneWidget);
  });
}
