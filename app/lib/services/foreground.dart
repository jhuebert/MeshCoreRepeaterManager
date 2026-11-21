import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../main.dart' show transferServiceEntry;

/// Foreground service wrapper for long-running operations. Keeps the process
/// alive while the screen is off; the work itself runs in the main isolate.
/// Android/iOS only. Desktop runs in-process with the window open.
/// Callers normally go through `BackgroundOperationGuard` so overlapping
/// operations share one service instead of stopping each other.
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

  static Future<void> start(
    String notificationText, {
    String title = 'MeshCoreRepeaterManager: background work',
  }) async {
    if (!supported) return;
    if (_isAndroid) {
      // POST_NOTIFICATIONS is dangerous on API 33+. The plugin does not ask
      // on its own; without a grant the ongoing notification is hidden in the
      // shade and the operator cannot see that the transfer is still running.
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: 1001,
      // Match the manifest's declared type on Android 14+.
      serviceTypes:
          _isAndroid ? [ForegroundServiceTypes.connectedDevice] : null,
      notificationTitle: title,
      notificationText: notificationText,
      callback: transferServiceEntry,
    );
    if (result is ServiceRequestFailure) {
      // A missing notification permission or a denied foreground-service
      // grant must not silently kill the update; the screen shows the error.
      throw Exception('foreground service failed to start: ${result.error}');
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
