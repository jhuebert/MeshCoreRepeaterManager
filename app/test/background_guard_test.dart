import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/background_guard.dart';

void main() {
  test('the first reason starts the service and the last stops it', () async {
    final starts = <(String, String)>[];
    final texts = <String>[];
    var stops = 0;
    final guard = BackgroundOperationGuard(
      start: (text, title) async => starts.add((text, title)),
      update: (text) async => texts.add(text),
      stop: () async => stops++,
    );

    expect(guard.active, isFalse);
    await guard.acquire('ota', 'Updating Roof', text: 'Preparing');
    expect(guard.active, isTrue);
    expect(guard.label, 'Updating Roof');
    expect(starts, [('Preparing', 'Updating Roof')]);

    await guard.acquire('ack:job', 'Collecting replies');
    expect(starts, hasLength(1)); // overlapping reasons share one service
    await guard.update('3 replies');
    expect(texts, ['3 replies']);

    await guard.release('ota');
    expect(stops, 0);
    await guard.release('ack:job');
    expect(stops, 1);
    expect(guard.active, isFalse);
    expect(guard.label, isNull);
  });

  test('a refused start leaves no reason and can be retried', () async {
    var attempts = 0;
    final guard = BackgroundOperationGuard(
      start: (_, __) async {
        attempts++;
        throw StateError('denied');
      },
      stop: () async => throw StateError('must not stop'),
    );

    await expectLater(
        guard.acquire('wifi', 'Uploading'), throwsA(isA<StateError>()));
    expect(guard.active, isFalse);
    expect(guard.reasons, isEmpty);

    // A later attempt is allowed to try again from a clean state.
    await expectLater(
        guard.acquire('wifi', 'Uploading'), throwsA(isA<StateError>()));
    expect(attempts, 2);
    await guard.release('wifi'); // unknown reason is a no-op
  });

  test('duplicate acquire and unknown release are no-ops', () async {
    var starts = 0;
    final guard = BackgroundOperationGuard(
      start: (_, __) async => starts++,
      stop: () async => starts--,
    );
    await guard.acquire('job', 'One');
    await guard.acquire('job', 'Two');
    expect(guard.reasons, {'job'});
    expect(guard.label, 'One');
    expect(starts, 1);
    await guard.release('other');
    expect(starts, 1);
    await guard.release('job');
    expect(starts, 0);
  });

  test('screen-on follows the first acquire and last release', () async {
    final calls = <bool>[];
    final guard = BackgroundOperationGuard(
      start: (_, __) async {},
      stop: () async {},
      setScreenOn: (enabled) async => calls.add(enabled),
    );
    await guard.acquire('ota', 'Updating', keepScreenOn: true);
    await guard.acquire('ack', 'Collecting', keepScreenOn: true);
    expect(calls, [true]);
    await guard.release('ota');
    expect(calls, [true]);
    await guard.release('ack');
    expect(calls, [true, false]);
  });

  test('notification updates are ignored when idle and never throw', () async {
    final texts = <String>[];
    final guard = BackgroundOperationGuard(
      start: (_, __) async {},
      update: (text) async {
        texts.add(text);
        throw StateError('plugin gone');
      },
      stop: () async {},
    );
    await guard.update('ignored');
    expect(texts, isEmpty);
    await guard.acquire('job', 'Working');
    await guard.update('still here'); // swallowed
    expect(texts, ['still here']);
    await guard.releaseAll();
    expect(guard.active, isFalse);
  });
}
