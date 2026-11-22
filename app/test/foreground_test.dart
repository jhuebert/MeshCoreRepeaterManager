import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';

import 'package:meshcore_repeater_manager/services/foreground.dart';

class _FakeForegroundPlatform extends FlutterForegroundTaskPlatform {
  final List<String> calls = <String>[];
  List<ForegroundServiceTypes>? serviceTypes;
  bool failStart = false;
  bool running = false;
  // Simulates the dangling state flow that makes the plugin's poll time out.
  bool stuckState = false;
  bool? skipCheckDuringStart;

  @override
  Future<NotificationPermission> requestNotificationPermission() async {
    calls.add('permission');
    return NotificationPermission.granted;
  }

  @override
  Future<void> startService({
    required AndroidNotificationOptions androidNotificationOptions,
    required IOSNotificationOptions iosNotificationOptions,
    required ForegroundTaskOptions foregroundTaskOptions,
    int? serviceId,
    List<ForegroundServiceTypes>? serviceTypes,
    required String notificationTitle,
    required String notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {
    calls.add('start');
    skipCheckDuringStart = FlutterForegroundTask.skipServiceResponseCheck;
    this.serviceTypes = serviceTypes;
    if (failStart) throw StateError('denied');
    if (!stuckState) running = true;
  }

  @override
  Future<void> updateService({
    ForegroundTaskOptions? foregroundTaskOptions,
    String? notificationTitle,
    String? notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {
    calls.add('update');
  }

  @override
  Future<void> stopService() async {
    calls.add('stop');
    running = false;
  }

  @override
  Future<bool> get isRunningService async => stuckState ? false : running;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the foreground service is a no-op off mobile', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    TransferForegroundService.isSupported = () => false;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TransferForegroundService.isSupported = () => true;
    });
    expect(TransferForegroundService.supported, isFalse);
    await TransferForegroundService.start('testing');
    await TransferForegroundService.update('testing');
    await TransferForegroundService.stop();
    await TransferForegroundService.setScreenOn(true);
  });

  group('on Android', () {
    late _FakeForegroundPlatform platform;
    late List<MethodCall> screenCalls;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TransferForegroundService.isSupported = () => true;
      platform = _FakeForegroundPlatform();
      FlutterForegroundTask.resetStatic();
      FlutterForegroundTaskPlatform.instance = platform;
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'test',
          channelName: 'test',
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
        ),
      );
      screenCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('org.huebert.meshcorepeatermanager/screen'),
        (call) async {
          screenCalls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('org.huebert.meshcorepeatermanager/screen'),
              null);
      FlutterForegroundTask.resetStatic();
    });

    test('start asks for notifications and declares the connected-device type',
        () async {
      await TransferForegroundService.start('Preparing update');
      await TransferForegroundService.update('12 of 40 ops');
      await TransferForegroundService.stop();

      expect(platform.calls, ['permission', 'start', 'update', 'stop']);
      expect(platform.serviceTypes, [ForegroundServiceTypes.connectedDevice]);
    });

    test('start skips the flaky response poll and restores the flag', () async {
      await TransferForegroundService.start('Preparing update');

      expect(platform.skipCheckDuringStart, isTrue);
      expect(FlutterForegroundTask.skipServiceResponseCheck, isFalse);
    });

    test('a stuck service-state poll does not fail the start', () async {
      // Without skipping the plugin's poll this hangs for five seconds and
      // throws ServiceTimeoutException, which used to block the whole update.
      platform.stuckState = true;
      await TransferForegroundService.start('Preparing update');

      expect(platform.calls, contains('start'));
    });

    test('an already-running service counts as a success', () async {
      platform.running = true;
      await TransferForegroundService.start('Preparing update');
      expect(FlutterForegroundTask.skipServiceResponseCheck, isFalse);
    });

    test('a refused start is surfaced to the caller', () async {
      platform.failStart = true;
      await expectLater(
        TransferForegroundService.start('Preparing update'),
        throwsA(isA<Exception>()),
      );
      expect(FlutterForegroundTask.skipServiceResponseCheck, isFalse);
    });

    test('screen-on is sent to the activity channel', () async {
      await TransferForegroundService.setScreenOn(true);
      await TransferForegroundService.setScreenOn(false);

      expect(screenCalls.map((c) => c.method), ['setScreenOn', 'setScreenOn']);
      expect(screenCalls.first.arguments['enabled'], isTrue);
      expect(screenCalls.last.arguments['enabled'], isFalse);
    });
  });
}
