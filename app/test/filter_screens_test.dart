import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/management/filter_rule_editor_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/filter_screen.dart';
import 'package:meshcore_repeater_manager/screens/management/filter_stats_screen.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:repeater_core/repeater_core.dart';

import 'support.dart';

AppState _app() {
  final app = AppState();
  app.connectionPhase = ConnectionPhase.connected;
  app.target = contact('Roof');
  app.loginPermission = 3;
  return app;
}

CliService _filterCli(List<String> commands) => CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        commands.add(command);
        return switch (command) {
          'filter' =>
            'on; rules 1/32; chans 1/32; ratelimit advert 0h; cache 0/512; limiter 0; aborted 0',
          'filter list 0' => '0: drop advert hits=5\n...',
          'filter stats' =>
            '0: drop advert hits=5\nlimiter 2 aborted 1 saved air 120s',
          'filter chan list' => '#memes\nnext=1',
          _ => '> ok',
        };
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );

Future<void> _pump(WidgetTester tester, Widget child, CliService cli) async {
  await tester.pumpWidget(wrap(_app(), child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('filter screen loads status, rules and channels', (tester) async {
    final commands = <String>[];
    await _pump(
        tester, FilterScreen(cli: _filterCli(commands)), _filterCli(commands));
    expect(find.text('Packet filter'), findsWidgets);
    expect(find.text('1/32 rules, 1/32 channels'), findsOneWidget);
    expect(commands, contains('filter list 0'));
    expect(commands, contains('filter list 1'));
  });

  testWidgets('editor validates a bad pattern and previews the command',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, FilterRuleEditorScreen(cli: _filterCli(commands)),
        _filterCli(commands));
    expect(find.text('Add rule'), findsOneWidget);

    await tester.enterText(
        find.descendant(
            of: find.byKey(const Key('sender')),
            matching: find.byType(TextField)),
        'A||B');
    await tester.pump();
    expect(find.textContaining('empty alternative'), findsWidgets);
    expect(find.byType(FilledButton), findsWidgets);
  });

  testWidgets('editor dry runs and sends the previewed command',
      (tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    final cli = _filterCli(commands);
    await _pump(tester, FilterRuleEditorScreen(cli: cli), cli);

    await tester.enterText(
        find.descendant(
            of: find.byKey(const Key('sender')),
            matching: find.byType(TextField)),
        'SpamBot');
    await tester.pump();
    expect(find.textContaining('matches (sender)'), findsWidgets);

    await tester.tap(find.text('Forward'));
    await tester.pump();
    await tester.tap(find.text('Add rule'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('filter add forward sender=SpamBot'));
  });

  testWidgets('editor translates a regex and shows the result before use',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(tester, FilterRuleEditorScreen(cli: _filterCli(commands)),
        _filterCli(commands));
    // The regex box is the last text field, after all condition fields.
    await tester.enterText(find.byType(TextField).last, r'^(Alice|Bob)$');
    await tester.pump();
    await tester.tap(find.text('Translate'));
    await tester.pump();
    expect(find.text(r'^Alice$|^Bob$'), findsWidgets);
    expect(find.textContaining('top-level alternatives'), findsWidgets);
  });

  testWidgets('filter screen sends master switch and maintenance commands',
      (tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    final cli = _filterCli(commands);
    await _pump(tester, FilterScreen(cli: cli), cli);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('filter off'));

    // Deleting a rule asks first; cancelling must not send a command.
    final before = commands.length;
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();
    expect(find.text('Delete this rule?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(commands.length, before);
  });

  testWidgets('rules can be exported and imported with validation',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <String>[];
    await _pump(
        tester, FilterScreen(cli: _filterCli(commands)), _filterCli(commands));

    await tester.tap(find.byIcon(Icons.file_download));
    await tester.pump();
    expect(find.text('Exported rules'), findsOneWidget);
    expect(find.textContaining('"schema": 1'), findsWidgets);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.file_upload));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.file_upload));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('filter-import')), 'not json');
    await tester.pump();
    await tester.tap(find.text('Import'));
    await tester.pump();
    expect(
        find.textContaining('Use a rule set exported as JSON'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('filter-import')),
      '{"schema":1,"rules":[{"action":"drop","channels":["#x"]}]}',
    );
    await tester.pump();
    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(commands, contains('filter add chan=#x'));

    // The editor and statistics buttons use the same shared navigation.
    await tester.tap(find.text('Add rule'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('New filter rule'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bar_chart));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Filter statistics'), findsOneWidget);
  });

  testWidgets('an import with a refused write reports the firmware error',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final cli = CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        if (command == 'filter') {
          return 'on; rules 0/32; chans 0/32; ratelimit advert 0h; cache 0/512; limiter 0; aborted 0';
        }
        if (command.startsWith('filter add')) return 'Err - rule rejected';
        return '> ok';
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          throw const RepeaterRequestException('not used'),
    );
    await _pump(tester, FilterScreen(cli: cli), cli);
    await tester.tap(find.byIcon(Icons.file_upload));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('filter-import')),
      '{"schema":1,"rules":[{"action":"drop","channels":["#y"]}]}',
    );
    await tester.pump();
    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('rule rejected'), findsWidgets);
  });

  testWidgets('filter statistics screen shows totals', (tester) async {
    final commands = <String>[];
    await _pump(tester, FilterStatsScreen(cli: _filterCli(commands)),
        _filterCli(commands));
    expect(find.text('2'), findsWidgets);
    expect(find.text('1'), findsWidgets);
    expect(commands, contains('filter stats'));
  });
}
