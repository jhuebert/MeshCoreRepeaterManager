import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/target_screen.dart';

import 'support.dart';

void main() {
  testWidgets('repeaters and the manual key are separate tabs', (tester) async {
    final app = AppState();
    app.contacts = [
      contact('riley'),
      contact('harper', key: keyOf(2)),
      contact('chatty companion', advType: advTypeChat, key: keyOf(3)),
    ];

    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    expect(find.text('Repeaters'), findsOneWidget);
    expect(find.text('Public key'), findsOneWidget);
    expect(find.text('riley'), findsOneWidget);
    expect(find.text('harper'), findsOneWidget);
    expect(find.text('chatty companion'), findsNothing);

    // Nothing selected: the next step is locked with an explanation.
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(next.onPressed, isNull);
    expect(find.textContaining('Choose a repeater'), findsOneWidget);
  });

  testWidgets('the step bar sits in the app bar above the tabs',
      (tester) async {
    final app = AppState();
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    final wizard = find.text('Step 2 of 8');
    expect(wizard, findsOneWidget);
    expect(find.ancestor(of: wizard, matching: find.byType(AppBar)),
        findsOneWidget);
    expect(tester.getRect(wizard).bottom,
        lessThan(tester.getRect(find.text('Repeaters')).top));
  });

  testWidgets('selecting a repeater unlocks the next step', (tester) async {
    final app = AppState();
    app.contacts = [contact('riley')];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    await tester.tap(find.text('riley'));
    await tester.pump();

    expect(app.target?.name, 'riley');
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('the manual tab accepts a 64-hex public key', (tester) async {
    final app = AppState();
    app.contacts = const [];

    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();
    await tester.tap(find.text('Public key'));
    await tester.pumpAndSettle();

    final key = 'ab' * 32;
    await tester.enterText(find.byType(TextField), key);
    await tester.pump();

    // Too short until 64 characters.
    final short = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Use this node'),
    );
    expect(short.onPressed, isNotNull); // 64 chars already entered

    await tester.tap(find.widgetWithText(OutlinedButton, 'Use this node'));
    await tester.pump();

    expect(app.target, isNotNull);
    expect(app.target!.publicKeyHex, key);
  });

  testWidgets('a short manual key cannot be used', (tester) async {
    final app = AppState();
    app.contacts = const [];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();
    await tester.tap(find.text('Public key'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abcd');
    await tester.pump();

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Use this node'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('show all contacts reveals non-repeaters', (tester) async {
    final app = AppState();
    app.contacts = [
      contact('riley'),
      contact('chatty companion', advType: advTypeChat, key: keyOf(3)),
    ];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    await tester.tap(find.text('Show all contacts'));
    await tester.pump();

    expect(find.text('chatty companion'), findsOneWidget);
    expect(find.text('Show repeaters only'), findsOneWidget);
  });

  testWidgets('favorites and reachable repeaters sort to the top',
      (tester) async {
    final app = AppState();
    app.contacts = [
      contact('zeta', key: keyOf(1), hops: -1),
      contact('alpha', key: keyOf(2), hops: 2),
      contact('favorite far', key: keyOf(3), hops: -1, favorite: true),
      contact('favorite near', key: keyOf(4), favorite: true),
      contact('bravo', key: keyOf(5)),
      contact('chatty companion', key: keyOf(6), advType: advTypeChat),
    ];

    // Enough room for every row to be built by the lazy list.
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    expect(_visibleNames(tester), [
      'favorite near',
      'favorite far',
      'bravo',
      'alpha',
      'zeta',
    ]);
    expect(find.text('favorite, direct'), findsOneWidget);
    expect(find.text('favorite, no saved route'), findsOneWidget);
    expect(find.text('chatty companion'), findsNothing);
  });

  testWidgets('search filters by name or public key', (tester) async {
    final app = AppState();
    app.contacts = [
      contact('riley', key: keyOf(1)),
      contact('harper', key: keyOf(2)),
    ];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('repeater-search')), 'HAR');
    await tester.pump();
    expect(_visibleNames(tester), ['harper']);

    // Clearing the search restores the sorted full list.
    await tester.enterText(find.byKey(const Key('repeater-search')), '');
    await tester.pump();
    expect(_visibleNames(tester), ['harper', 'riley']);

    final keyPrefix = bytesToHex(keyOf(2)).substring(0, 8);
    await tester.enterText(
        find.byKey(const Key('repeater-search')), keyPrefix.toUpperCase());
    await tester.pump();
    expect(_visibleNames(tester), ['harper']);
  });

  testWidgets('contacts with the same name have a stable order',
      (tester) async {
    final app = AppState();
    app.contacts = [
      contact('same', key: keyOf(8)),
      contact('same', key: keyOf(9)),
    ];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    await tester.tap(find.byType(ListTile).first);
    await tester.pump();
    expect(app.target!.publicKeyHex, bytesToHex(keyOf(9)));
  });

  testWidgets('an unmatched search explains how to add a node', (tester) async {
    final app = AppState();
    app.contacts = [contact('riley')];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('repeater-search')), 'nobody');
    await tester.pump();

    expect(find.text('riley'), findsNothing);
    expect(find.textContaining('No repeaters match'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('riley'), findsOneWidget);
  });
}

/// Names of the contact rows currently visible in the repeater tab.
List<String> _visibleNames(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((tile) => (tile.title! as Text).data!)
    .toList();

/// A distinct 32-byte key for a fixture contact.
List<int> keyOf(int seed) =>
    List<int>.generate(32, (i) => (seed * 31 + i) & 0xFF);
