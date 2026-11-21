import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import '../services/ble_device_link.dart';

/// Link state shown by the connection indicator in the app shell.
enum ConnectionPhase { disconnected, connecting, connected }

/// Owns the companion link for the whole app, not for one screen. Screens read
/// the connection from here so navigation never tears it down.
class ConnectionController extends ChangeNotifier {
  ConnectionController({
    this.tcpLinkFactory,
    this.clientFactory,
  });

  /// Test seams, also exposed through `AppState` for existing tests.
  RadioLink Function(String host, int port)? tcpLinkFactory;
  CompanionClient Function(RadioLink link)? clientFactory;

  String transportKind = 'ble';
  String tcpHost = '127.0.0.1';
  int tcpPort = defaultCompanionPort;
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String? _connectError;
  String _companionName = '';

  RadioLink? _link;
  CompanionClient? _client;
  String? _bleDeviceId;

  /// Called once after a new link is adopted, before the phase becomes
  /// connected. The app uses it to build its CLI flow and read companion facts.
  Future<void> Function(RadioLink link)? onAdopt;

  /// Called when a link is dropped, including before a reconnect attempt.
  Future<void> Function()? onLost;

  /// Diagnostic hook for messages that belong to neither a CLI reply nor a
  /// pending fleet job.
  void Function(String message)? onUnexpectedMessage;

  /// Drained frames are offered here before being dropped, so a late fleet ACK
  /// can still be matched to a pending job.
  void Function(Uint8List frame)? onDrainedFrame;

  RadioLink? get link => _link;
  CompanionClient? get client => _client;
  String? get bleDeviceId => _bleDeviceId;
  ConnectionPhase get phase => _phase;
  String? get connectError => _connectError;
  String get companionName => _companionName;
  bool get isConnected => _phase == ConnectionPhase.connected;

  /// The last endpoint, for reconnect after a transport drop.
  String? get lastEndpoint =>
      transportKind == 'tcp' ? '$tcpHost:$tcpPort' : _bleDeviceId;

  set phase(ConnectionPhase value) {
    if (_phase == value) return;
    _phase = value;
    notifyListeners();
  }

  set connectError(String? value) {
    _connectError = value;
    notifyListeners();
  }

  set companionName(String value) {
    _companionName = value;
    notifyListeners();
  }

  Future<void> connectBle(BluetoothDevice device) => _connect(() async {
        transportKind = 'ble';
        _bleDeviceId = device.remoteId.str;
        connectError = null;
        final ble = BleDeviceLink(device: device);
        await ble.connect();
        return ble;
      });

  Future<void> connectTcp({
    required String host,
    required int port,
  }) =>
      _connect(() async {
        transportKind = 'tcp';
        tcpHost = host;
        tcpPort = port;
        connectError = null;
        final tcp = tcpLinkFactory?.call(host, port) ??
            TcpDeviceLink(host: host, port: port);
        await tcp.connect();
        return tcp;
      });

  /// Install a link without the full connect and drain lifecycle. Widget tests
  /// use this so a fake link never waits on platform timers in the fake-async
  /// zone; production always goes through [connectTcp] or BLE.
  @visibleForTesting
  void attachForTest(RadioLink link, CompanionClient client) {
    _link = link;
    _client = client;
    phase = ConnectionPhase.connected;
  }

  Future<void> _connect(Future<RadioLink> Function() build) async {
    await disconnect();
    phase = ConnectionPhase.connecting;
    try {
      final link = await build();
      _link = link;
      _client = clientFactory?.call(link) ??
          CompanionClient(link, onUnexpectedMessage: (m) {
            onUnexpectedMessage?.call(
                'unrelated msg from ${bytesToHex(m.senderPrefix)}: ${m.text}');
          });
      await onAdopt?.call(link);
      phase = ConnectionPhase.connected;
    } catch (e) {
      _link = null;
      _client = null;
      phase = ConnectionPhase.disconnected;
      connectError = '${transportKind.toUpperCase()} connect failed: $e';
    }
    notifyListeners();
  }

  /// Reconnect over the last successful endpoint. The caller re-logs in and
  /// drains stale replies before issuing any management command.
  Future<void> reconnect() async {
    if (transportKind == 'tcp') {
      await connectTcp(host: tcpHost, port: tcpPort);
    } else if (_bleDeviceId != null) {
      await connectBle(BluetoothDevice.fromId(_bleDeviceId!));
    }
  }

  /// Drop queued replies from before a login or reconnect. Frames may be
  /// inspected first so a late fleet ACK is not lost.
  Future<int> drainAfterLogin({
    void Function(Uint8List frame)? onFrame,
  }) =>
      _client?.drainMessages(onFrame: (frame) {
        onDrainedFrame?.call(frame);
        onFrame?.call(frame);
      }) ??
      Future.value(0);

  Future<void> disconnect() async {
    final hadLink = _link != null;
    try {
      await _link?.disconnect();
    } catch (_) {}
    _link = null;
    _client = null;
    // Keep the last endpoint so reconnect() can reuse it after a drop.
    phase = ConnectionPhase.disconnected;
    if (hadLink) await onLost?.call();
    notifyListeners();
  }
}
