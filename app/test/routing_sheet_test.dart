import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/shell/repeater_hub_screen.dart';
import 'package:meshcore_repeater_manager/shell/routing_sheet.dart';
import 'package:meshcore_repeater_manager/widgets/management.dart';

import 'support.dart';

({AppState app, FakeDeviceLink link}) _app() {
  final link = FakeDeviceLink();
  final app = AppState();
  app.connection.attachForTest(link, CompanionClient(link));
  app.target = contact('Roof');
  return (app: app, link: link);
}

Future<void> _pumpSheet(WidgetTester tester, AppState app) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(wrap(app, const Scaffold(body: RoutingSheet())));
  await tester.pump();
}

class _ThrowingLink extends FakeDeviceLink {
  @override
  Future<void> setContactPath(Contact contact,
          {required List<int> path, required int encodedPathLen}) =>
      throw StateError('companion refused');
}

void main() {
  test('applyRoute pushes a custom path to the companion', () async {
    final (app: app, link: link) = _app();
    app.setManualRoutePath('c0ff,c0c0');
    expect(app.manualRouteError, isNull);
    expect(await app.applyRoute(), isNull);
    expect(link.contactPathWrites, hasLength(1));
    expect(link.contactPathWrites.single.encodedPathLen, isNonZero);
    expect(link.contactPathWrites.single.path, hasLength(4));
  });

  test('applyRoute with no override uses a zero-hop route', () async {
    final (app: app, link: link) = _app();
    expect(await app.applyRoute(), isNull);
    expect(link.contactPathWrites.single.path, isEmpty);
    expect(link.contactPathWrites.single.encodedPathLen, 0);
  });

  test('applyRoute reports a failed companion write', () async {
    final link = _ThrowingLink();
    final app = AppState();
    app.connection.attachForTest(link, CompanionClient(link));
    app.target = contact('Roof');
    app.setManualRoutePath('c0ff');
    final error = await app.applyRoute();
    expect(error, contains('Could not apply the route'));
    expect(app.manualRouteError, isNotNull);
  });

  test('applyRoute reports errors without a companion', () async {
    final app = AppState();
    expect(await app.applyRoute(), contains('Connect a companion'));
  });

  testWidgets('invalid paths are rejected before apply is enabled',
      (tester) async {
    final (app: app, link: link) = _app();
    await _pumpSheet(tester, app);
    await tester.tap(find.text('Via hops'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('routing-path')), 'zzzz');
    await tester.pump();
    expect(find.byType(FilledButton), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(link.contactPathWrites, isEmpty);
  });

  testWidgets('a custom path is applied from the sheet', (tester) async {
    final (app: app, link: link) = _app();
    await _pumpSheet(tester, app);
    await tester.tap(find.text('Via hops'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('routing-path')), 'c0ff');
    await tester.pump();
    await tester.tap(find.text('Apply route'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(link.contactPathWrites, hasLength(1));
    expect(find.text('Route applied.'), findsOneWidget);
  });

  testWidgets('direct mode applies a zero-hop route', (tester) async {
    final (app: app, link: link) = _app();
    await _pumpSheet(tester, app);
    await tester.tap(find.text('Direct'));
    await tester.pump();
    expect(app.manualRoutePath, '0');
    await tester.tap(find.text('Apply route'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final write = link.contactPathWrites.single;
    expect(write.path, isEmpty);
    expect(write.encodedPathLen, 0);
  });

  testWidgets('management screens expose the same routing button',
      (tester) async {
    final (app: app, link: _) = _app();
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(wrap(
      app,
      const Scaffold(
        body: ManagementScaffold(title: 'Test', children: [Text('body')]),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.route));
    await tester.pump();
    expect(find.text('Repeater route'), findsOneWidget);
  });

  testWidgets('the hub shows the current route and opens the sheet',
      (tester) async {
    final (app: app, link: _) = _app();
    app.setManualRoutePath('0');
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(wrap(app, const RepeaterHubScreen()));
    await tester.pump();
    expect(find.text('Direct'), findsWidgets);
    await tester.tap(find.textContaining('Route:').first);
    await tester.pump();
    expect(find.text('Repeater route'), findsOneWidget);
  });
}
