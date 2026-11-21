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
    expect(find.text('Copy history'), findsOneWidget);
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
