// The frozen `ota net` CLI contract (fork firmware, OnlineOtaCore.cpp).
// The line shape is fixed; anything else means "not an online fetch build"
// or a hand-corrupted reply, and parsers return null.

/// Phase of the observer's direct download.
enum WifiNetPhase { idle, wifi, clock, asset, verify, ready, error }

/// Parsed `ota net` line:
/// `net=<phase> ver=<version> sha=<8hex> got=<n> size=<n> err=<n>`.
class WifiNetStatus {
  const WifiNetStatus({
    required this.phase,
    required this.version,
    required this.shaPrefix,
    required this.received,
    required this.size,
    required this.err,
  });

  final WifiNetPhase phase;
  final String version;

  /// First 4 bytes of the expected image's SHA-256, as 8 hex chars.
  final String shaPrefix;
  final int received;
  final int size;
  final int err;

  bool get ok => err == 0;

  static final _line = RegExp(
      r'^net=(\w+) ver=(\S*) sha=([0-9a-fA-F]{8}) got=(\d+) size=(\d+) err=(\d+)$');

  /// Parse the frozen line. Returns null for anything else.
  static WifiNetStatus? parse(String reply) {
    final match = _line.firstMatch(reply.trim());
    if (match == null) return null;
    final phase = switch (match.group(1)) {
      'idle' => WifiNetPhase.idle,
      'wifi' => WifiNetPhase.wifi,
      'clock' => WifiNetPhase.clock,
      'asset' => WifiNetPhase.asset,
      'verify' => WifiNetPhase.verify,
      'ready' => WifiNetPhase.ready,
      'error' => WifiNetPhase.error,
      _ => null,
    };
    if (phase == null) return null;
    return WifiNetStatus(
      phase: phase,
      version: match.group(2)!,
      shaPrefix: match.group(3)!.toLowerCase(),
      received: int.parse(match.group(4)!),
      size: int.parse(match.group(5)!),
      err: int.parse(match.group(6)!),
    );
  }
}
