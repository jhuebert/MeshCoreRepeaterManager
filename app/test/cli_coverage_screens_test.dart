import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/audit_log_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/diagnostics_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/identity_key_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/operations_screen.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/management_audit_store.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

CliService _cli(List<String> commands) => CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        commands.add(command);
        if (command == 'ver') return 'v1.18.0';
        if (command == 'board') return 'XiaoS3';
        if (command.startsWith('get ')) return '> configured';
        return '> ok';
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );

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
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('operations read freely but confirm a reboot', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, OperationsScreen(cli: _cli(commands)), _app());
    await tester.tap(find.text('Read firmware version'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('ver'));

    await tester.tap(find.text('Reboot the repeater'));
    await tester.pump();
    expect(find.text('Run "reboot" on the repeater?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(commands.contains('reboot'), isFalse);
  });

  testWidgets('diagnostics reads board facts on open', (tester) async {
    final commands = <String>[];
    await _pump(tester, DiagnosticsScreen(cli: _cli(commands)), _app());
    expect(commands, contains('ver'));
    expect(commands, contains('board'));
    expect(commands, contains('sensor list'));
    expect(commands, contains('gps'));
  });

  testWidgets('diagnostics offers region actions and generic get',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, DiagnosticsScreen(cli: _cli(commands)), _app());
    await tester.tap(find.text('region save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('region save'));
  });

  testWidgets('identity change applies a confirmed valid key', (tester) async {
    final commands = <String>[];
    await _pump(tester, IdentityKeyScreen(cli: _cli(commands)), _app());
    await tester.enterText(find.byKey(const Key('identity-key')), '11' * 64);
    await tester.enterText(
        find.byKey(const Key('identity-confirm')), 'CHANGE IDENTITY');
    await tester.pump();
    await tester.tap(find.text('Change identity'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(commands.any((c) => c.startsWith('set prv.key')), isTrue);
  });

  testWidgets('audit log shows redacted writes and export', (tester) async {
    final dir = Directory.systemTemp.createTempSync('audit_ui_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = _app();
    app.auditStore =
        ManagementAuditStore(File('${dir.path}/audit.json'), persist: false);
    await app.auditStore!.load();
    await app.auditStore!.record('set password secret',
        repeaterKeyHex: app.target!.publicKeyHex,
        family: 'access',
        replyKind: 'ok',
        outcome: AuditOutcome.ok);
    await _pump(tester, const AuditLogScreen(), app);
    expect(find.textContaining('[redacted]'), findsWidgets);
    expect(find.text('Copy all history'), findsOneWidget);
  });

  testWidgets('the audit screen warns before old writes roll off',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('audit_warn_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = _app();
    app.auditStore =
        ManagementAuditStore(File('${dir.path}/audit.json'), persist: false);
    await app.auditStore!.load();
    for (var i = 0; i < 905; i++) {
      await app.auditStore!.record('set name $i',
          repeaterKeyHex: 'aa',
          family: 'settings',
          replyKind: 'ok',
          outcome: AuditOutcome.ok);
    }
    await _pump(tester, const AuditLogScreen(), app);
    expect(find.textContaining('The history is nearly full'), findsOneWidget);
    expect(find.text('Copy all history'), findsOneWidget);
  });

  testWidgets('audit history filters by outcome', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('audit_filter_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = _app();
    app.auditStore =
        ManagementAuditStore(File('${dir.path}/audit.json'), persist: false);
    await app.auditStore!.load();
    await app.auditStore!.record('set name Roof',
        repeaterKeyHex: 'aa',
        family: 'settings',
        replyKind: 'ok',
        outcome: AuditOutcome.ok);
    await app.auditStore!.record('setperm bb 3',
        repeaterKeyHex: 'bb',
        family: 'access',
        replyKind: 'error',
        outcome: AuditOutcome.error);

    await app.auditStore!.record(
      'set name Old',
      at: DateTime.now().subtract(const Duration(days: 30)),
      repeaterKeyHex: 'aa',
      family: 'settings',
      replyKind: 'ok',
      outcome: AuditOutcome.ok,
    );

    await _pump(tester, const AuditLogScreen(), app);
    expect(find.text('3 of 3 entries'), findsOneWidget);
    await tester.tap(find.text('Copy all history'));
    await tester.pump();

    await tester.tap(find.text('All time').first);
    await tester.pump();
    await tester.tap(find.text('Last 7 days').last);
    await tester.pump();
    expect(find.text('2 of 3 entries'), findsOneWidget);

    await tester.tap(find.text('All families').first);
    await tester.pump();
    await tester.tap(find.text('access').last);
    await tester.pump();
    expect(find.text('1 of 3 entries'), findsOneWidget);

    await tester.tap(find.text('All repeaters').first);
    await tester.pump();
    await tester.tap(find.text('bb').last);
    await tester.pump();
    expect(find.text('1 of 3 entries'), findsOneWidget);

    await tester.tap(find.text('All outcomes').first);
    await tester.pump();
    await tester.tap(find.text('error').last);
    await tester.pump();
    expect(find.text('1 of 3 entries'), findsOneWidget);
    expect(find.text('setperm bb 3'), findsOneWidget);
    expect(find.text('set name Roof'), findsNothing);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    expect(find.text('3 of 3 entries'), findsOneWidget);
  });

  testWidgets('identity change needs a typed confirmation', (tester) async {
    final commands = <String>[];
    await _pump(tester, IdentityKeyScreen(cli: _cli(commands)), _app());
    await tester.enterText(find.byKey(const Key('identity-key')), 'ab' * 64);
    await tester.enterText(find.byKey(const Key('identity-confirm')), 'wrong');
    await tester.pump();
    await tester.tap(find.text('Change identity'));
    await tester.pump();
    expect(find.textContaining('Type CHANGE IDENTITY'), findsWidgets);
    expect(commands.any((c) => c.startsWith('set prv.key')), isFalse);
  });
}
