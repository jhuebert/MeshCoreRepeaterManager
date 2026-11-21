import 'package:flutter/foundation.dart';

import 'foreground.dart';

/// Ref-counted ownership of the foreground service. One long-running
/// operation acquires a named reason and releases it when done; the service
/// starts on the first reason and stops on the last, so a fleet ACK window, a
/// WiFi upload and an OTA transfer cannot stop each other.
///
/// A failed start leaves no reason behind and throws, so the caller can refuse
/// to begin the operation instead of running invisibly.
class BackgroundOperationGuard extends ChangeNotifier {
  BackgroundOperationGuard({
    Future<void> Function(String text, String title)? start,
    Future<void> Function(String text)? update,
    Future<void> Function()? stop,
    Future<void> Function(bool enabled)? setScreenOn,
  })  : _start = start ??
            ((text, title) =>
                TransferForegroundService.start(text, title: title)),
        _update = update ?? TransferForegroundService.update,
        _stop = stop ?? TransferForegroundService.stop,
        _setScreenOn = setScreenOn ?? TransferForegroundService.setScreenOn;

  final Future<void> Function(String text, String title) _start;
  final Future<void> Function(String text) _update;
  final Future<void> Function() _stop;
  final Future<void> Function(bool enabled) _setScreenOn;

  final Set<String> _reasons = {};
  String? _label;
  int _screenLocks = 0;

  Set<String> get reasons => Set.unmodifiable(_reasons);
  bool get active => _reasons.isNotEmpty;
  String? get label => _label;

  /// Begin an operation. [reason] must be unique for one operation instance.
  /// [label] becomes the ongoing notification title and [text] its first line.
  Future<void> acquire(
    String reason,
    String label, {
    String? text,
    bool keepScreenOn = false,
  }) async {
    if (_reasons.contains(reason)) return;
    if (_reasons.isEmpty) {
      // No reason is recorded until the service actually started. A refused
      // start must not leave the guard thinking it owns a service.
      await _start(text ?? label, label);
    }
    _reasons.add(reason);
    _label = label;
    if (keepScreenOn) {
      _screenLocks++;
      if (_screenLocks == 1) {
        try {
          await _setScreenOn(true);
        } catch (_) {
          // Screen-on is cosmetic; the operation continues without it.
        }
      }
    }
    notifyListeners();
  }

  /// End an operation. Stops the service only when no other reason remains.
  Future<void> release(String reason) async {
    if (!_reasons.remove(reason)) return;
    if (_reasons.isEmpty) {
      _label = null;
      await _stop();
      if (_screenLocks > 0) {
        _screenLocks = 0;
        try {
          await _setScreenOn(false);
        } catch (_) {
          // As above: never fail an operation while releasing a window flag.
        }
      }
    }
    notifyListeners();
  }

  /// Refresh the notification while an operation is active. Updates are
  /// cosmetic, so a failure is swallowed just as it is in [acquire].
  Future<void> update(String text) async {
    if (_reasons.isNotEmpty) {
      try {
        await _update(text);
      } catch (_) {
        // Ignore notification update failures.
      }
    }
  }

  /// Drop every reason, for example when the app is shutting a session down.
  Future<void> releaseAll() async {
    final reasons = List.of(_reasons);
    for (final reason in reasons) {
      await release(reason);
    }
  }
}
