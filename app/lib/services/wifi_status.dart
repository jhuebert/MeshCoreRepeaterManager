/// Read-only WiFi facts from an observer repeater's admin CLI.
///
/// `get wifi.status` is answered only by observer builds:
/// `wifi connected ip:192.0.2.10 rssi:-58`, or
/// `wifi disconnected ip:0.0.0.0 rssi:0`. `get mqtt.status` carries the same
/// fact as `wifi:up` / `wifi:down`. Nothing here starts WiFi or opens a page.
enum WifiLinkState { connected, disconnected, unknown }

WifiLinkState parseWifiStatus(String? reply) {
  if (reply == null || reply.trim().isEmpty) return WifiLinkState.unknown;
  final lower = reply.toLowerCase();
  if (lower.contains('disconnected') || lower.contains('wifi:down')) {
    return WifiLinkState.disconnected;
  }
  if (lower.contains('connected') || lower.contains('wifi:up')) {
    return WifiLinkState.connected;
  }
  return WifiLinkState.unknown;
}

/// The stored network name, or null when none is configured. The password is
/// never read by the app.
String? parseWifiSsid(String? reply) {
  if (reply == null) return null;
  final value = reply.trim();
  if (value.isEmpty || value.toLowerCase() == 'not set') return null;
  return value;
}
