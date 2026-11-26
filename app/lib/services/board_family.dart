// Read-only board identification for stock repeaters.
//
// Stock firmware has no OTA capability handshake and no WiFi status CLI. Its
// `board` reply is the manufacturer name, which can be matched against the
// build environments the app already knows from releases and its library.
// Only app-slot `.bin` assets (ESP32 OTA targets) are in that set, so a match
// is the strongest read-only signal available without starting the update
// page. No match means "unknown" and the WiFi option stays hidden.

/// Known environments that are not ESP32 OTA targets. Some catalogs carry
/// experimental images for other families; never infer WiFi support from
/// those.
const _nonEsp32Markers = <String>['nrf52', 'rp2040', 'stm32', 'espnow'];

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// The known environment matching [boardReply], or null when none matches.
String? esp32EnvironmentForBoard(
    String boardReply, Iterable<String> knownEnvironments) {
  final board = _normalize(boardReply);
  if (board.isEmpty) return null;
  for (final env in knownEnvironments) {
    final lower = env.toLowerCase();
    if (_nonEsp32Markers.any(lower.contains)) continue;
    final normalized = _normalize(env);
    if (normalized.isEmpty) continue;
    if (normalized == board ||
        normalized.contains(board) ||
        board.contains(normalized)) {
      return env;
    }
  }
  return null;
}
