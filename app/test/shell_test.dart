import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';

import 'package:meshcore_repeater_manager/screens/firmware_screen.dart';
import 'package:meshcore_repeater_manager/shell/app_shell.dart';
import 'package:meshcore_repeater_manager/shell/connection_sheet.dart';
import 'package:meshcore_repeater_manager/shell/repeater_picker_sheet.dart';
import 'package:meshcore_repeater_manager/shell/routes.dart';
import 'package:provider/provider.dart';

import 'support.dart';

Widget _host(Widget child, [AppState? app]) =>
    ChangeNotifierProvider<AppState>.value(
      value: app ?? AppState(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => child,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('every named route opens an activity', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        navigatorKey: navKey,
        onGenerateRoute: generateRoute,
        home: const SizedBox(),
      ),
    ));
    for (final name in [
      AppRoutes.update,
      AppRoutes.library,
      AppRoutes.status,
      AppRoutes.settings,
      AppRoutes.browser,
      AppRoutes.cli,
      AppRoutes.acl,
      AppRoutes.neighbors,
      AppRoutes.stats,
      AppRoutes.filter,
      AppRoutes.filterEditor,
      AppRoutes.fleet,
      AppRoutes.mqtt,
      AppRoutes.wifiOta,
      AppRoutes.extras,
      AppRoutes.operations,
      AppRoutes.diagnostics,
      AppRoutes.audit,
      AppRoutes.identity,
    ]) {
      expect(
          generateRoute(RouteSettings(name: name)), isA<MaterialPageRoute>());
      navKey.currentState!.pushNamed(name);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      navKey.currentState!.pop();
      await tester.pump();
    }
    expect(generateRoute(const RouteSettings(name: '/unknown')), isNull);
  });

  testWidgets('named routes open the update activity and the library',
      (tester) async {
    expect(generateRoute(const RouteSettings(name: '/unknown')), isNull);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        onGenerateRoute: generateRoute,
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                ElevatedButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.update),
                  child: const Text('Update'),
                ),
                ElevatedButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.library),
                  child: const Text('Library route'),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Library route'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FirmwareScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Connect the companion'), findsOneWidget);
  });

  testWidgets('management routes open their own screens', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) {
        final app = AppState();
        app.target = contact('Roof');
        return app;
      },
      child: MaterialApp(
        onGenerateRoute: generateRoute,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.settings),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('shell switches destinations on mobile and desktop',
      (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const MaterialApp(home: AppShell()),
    ));
    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(find.text('Offline mode'), findsOneWidget);
    await tester.tap(find.text('Library'));
    await tester.pump();
    expect(find.text('Library'), findsWidgets);

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('connection sheet shows link details and reconnect',
      (tester) async {
    final app = AppState();
    app.connectionPhase = ConnectionPhase.connected;
    app.companionName = 'Gate companion';
    app.target = contact('Roof');
    await tester.pumpWidget(_host(const ConnectionSheet(), app));
    await _openSheet(tester);
    expect(find.text('Gate companion'), findsWidgets);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    await tester.tap(find.text('Reconnect'));
    await tester.pump();
  });

  testWidgets('picker selects a known repeater or a pasted key',
      (tester) async {
    final app = AppState();
    app.connectionPhase = ConnectionPhase.connected;
    app.contacts = [contact('Roof')];
    await tester.pumpWidget(_host(const RepeaterPickerSheet(), app));
    await _openSheet(tester);
    expect(find.text('Roof'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'not a public key');
    await tester.tap(find.text('Use key'));
    await tester.pump();
    expect(find.text('Enter the 64-character public key.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ab' * 32);
    await tester.tap(find.text('Use key'));
    await tester.pump();
    expect(app.target!.publicKeyHex, 'ab' * 32);
  });
}
