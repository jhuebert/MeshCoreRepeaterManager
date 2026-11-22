import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../main.dart' show transferServiceEntry;

/// Foreground service wrapper for the LoRa transfer. Keeps the process
/// alive while the screen is off; the work itself runs in the main isolate.
/// Android/iOS only — desktop runs the transfer in-process (keep the window
/// open).
class TransferForegroundService {
  static const _screenChannel =
      MethodChannel('org.huebert.meshcorepeatermanager/screen');

  /// Host-platform check, overridable in tests. Widget tests run on a Linux
  /// host where `defaultTargetPlatform` is Android by default; using the real
  /// host here keeps plugin calls out of them.
  static bool Function() isSupported =
      () => Platform.isAndroid || Platform.isIOS;

  static bool get supported => isSupported();

  static bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  static Future<void> start(String notificationText) async {
    if (!supported) return;
    if (_isAndroid) {
      // POST_NOTIFICATIONS is dangerous on API 33+. The plugin does not ask
      // on its own; without a grant the ongoing notification is hidden in the
      // shade and the operator cannot see that the transfer is still running.
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final result = await _withoutResponseCheck(
      () => FlutterForegroundTask.startService(
        serviceId: 1001,
        // Match the manifest's declared type on Android 14+.
        serviceTypes:
            _isAndroid ? [ForegroundServiceTypes.connectedDevice] : null,
        notificationTitle: 'MeshCoreRepeaterManager: firmware update',
        notificationText: notificationText,
        callback: transferServiceEntry,
      ),
    );
    if (result is ServiceRequestFailure) {
      if (result.error is ServiceAlreadyStartedException) {
        // A service left over from another operation (or a prior session)
        // already keeps the app alive, so there is nothing to start.
        return;
      }
      // A denied foreground-service grant must not silently kill the update;
      // the screen shows the error. Real failures (e.g. a background start
      // the OS refuses) are thrown synchronously by the platform call and
      // still arrive here.
      throw Exception('foreground service failed to start: ${result.error}');
    }
  }

  /// Runs a foreground-service request without the plugin's built-in
  /// "response check": a 100 ms method-channel poll for up to five seconds.
  /// That poll runs on the Android main thread and can contend with the
  /// service's own `onStartCommand`, so a service that *does* start is
  /// misreported as a `ServiceTimeoutException` (plugin issue #382). Skipping it keeps
  /// the native start (and its synchronous errors) while dropping the false
  /// timeout. The flag is restored in `finally` so other plugin calls are
  /// unaffected.
  ///
  /// The plugin marks this flag `@visibleForTesting`, but toggling it around
  /// the start call is the plugin's own workaround for that false timeout;
  /// it is not used to fake any state in this app.
  static Future<ServiceRequestResult> _withoutResponseCheck(
    Future<ServiceRequestResult> Function() request,
  ) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final previous = FlutterForegroundTask.skipServiceResponseCheck;
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterForegroundTask.skipServiceResponseCheck = true;
    try {
      return await request();
    } finally {
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterForegroundTask.skipServiceResponseCheck = previous;
    }
  }

  /// Called as the op count advances. The notification otherwise stays at
  /// "Preparing update" for the whole transfer, with no way to tell it is
  /// still alive from the home screen.
  static Future<void> update(String text) async {
    if (!supported) return;
    try {
      await FlutterForegroundTask.updateService(notificationText: text);
    } catch (_) {
      // A notification update is cosmetic; never fail the transfer for it.
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // Sibling of start(): a service that never started must not throw here.
    }
  }

  /// Keep the screen on while the app is in the foreground during a transfer.
  /// Android uses a window flag (no wake-lock permission needed, and it is
  /// released automatically when the activity window goes away). Other
  /// platforms are no-ops.
  static Future<void> setScreenOn(bool enabled) async {
    if (!supported || !_isAndroid) return;
    try {
      await _screenChannel.invokeMethod<bool>('setScreenOn', {
        'enabled': enabled,
      });
    } catch (_) {
      // A host that does not implement the channel must not block an update.
    }
  }
}
