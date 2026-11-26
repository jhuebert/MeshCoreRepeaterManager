import 'dart:io';

/// Outcome of an attempted programmatic join. A denial or missing platform
/// support means the operator must join in system settings; it is never a
/// silent failure of the upload itself.
enum WifiJoinResult { joined, denied, unavailable }

abstract class WifiConnector {
  Future<bool> get supported;
  Future<WifiJoinResult> join(String ssid);
}

/// Always falls back to manual join. Used when the OS offers no supported
/// programmatic path (notably mobile platforms).
class ManualWifiConnector implements WifiConnector {
  const ManualWifiConnector();

  @override
  Future<bool> get supported async => false;

  @override
  Future<WifiJoinResult> join(String ssid) async => WifiJoinResult.unavailable;
}

typedef ProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

Future<ProcessResult> defaultProcessRunner(
        String executable, List<String> arguments) =>
    Process.run(executable, arguments);

/// Best-effort join through the desktop OS network tooling. The command is
/// deliberately narrow: it only ever connects to a named network and never
/// changes saved network configuration. Where the OS refuses, the caller shows
/// the manual-join screen instead of retrying in a loop.
class PlatformWifiConnector implements WifiConnector {
  PlatformWifiConnector({
    ProcessRunner? runner,
    bool? isLinux,
    bool? isMacOS,
    bool? isWindows,
  })  : runner = runner ?? defaultProcessRunner,
        _isLinux = isLinux ?? Platform.isLinux,
        _isMacOS = isMacOS ?? Platform.isMacOS,
        _isWindows = isWindows ?? Platform.isWindows;

  final ProcessRunner runner;
  final bool _isLinux;
  final bool _isMacOS;
  final bool _isWindows;

  @override
  Future<bool> get supported async => _isLinux || _isMacOS || _isWindows;

  @override
  Future<WifiJoinResult> join(String ssid) async {
    if (ssid.trim().isEmpty) return WifiJoinResult.denied;
    if (!await supported) return WifiJoinResult.unavailable;
    final (executable, arguments) = _command(ssid);
    try {
      final result = await runner(executable, arguments);
      return result.exitCode == 0
          ? WifiJoinResult.joined
          : WifiJoinResult.denied;
    } catch (_) {
      return WifiJoinResult.unavailable;
    }
  }

  (String, List<String>) _command(String ssid) {
    if (_isLinux) return ('nmcli', ['device', 'wifi', 'connect', ssid]);
    if (_isMacOS) {
      return ('networksetup', ['-setairportnetwork', 'en0', ssid]);
    }
    return ('netsh', ['wlan', 'connect', 'name="$ssid"']);
  }
}

class FakeWifiConnector implements WifiConnector {
  FakeWifiConnector({this.result = WifiJoinResult.joined});

  WifiJoinResult result;
  final List<String> joined = [];

  @override
  Future<bool> get supported async => true;

  @override
  Future<WifiJoinResult> join(String ssid) async {
    joined.add(ssid);
    return result;
  }
}
