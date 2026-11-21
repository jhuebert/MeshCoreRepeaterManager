import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wifi_ota_core/wifi_ota_core.dart';

import '../../app_state.dart';
import '../../services/background_guard.dart';
import '../../services/cli_service.dart';
import '../../services/wifi_connector.dart';
import '../../services/wifi_ota_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Stock ESP32 WiFi update through the built-in AsyncElegantOTA page. The page
/// has no password, so the app warns before arming it. Verification is a
/// re-login and version read, never a claim based on the upload alone.
class WifiOtaScreen extends StatefulWidget {
  const WifiOtaScreen({
    super.key,
    this.cli,
    this.client,
    this.image,
    this.version,
    this.verify,
    this.connector,
    this.reconnect,
    this.guard,
  });

  final CliService? cli;
  final WifiOtaClient? client;
  final Uint8List? image;
  final String? version;

  /// Test seam for the post-upload verification. In production this re-logs
  /// in over the companion and reads `ver`.
  final Future<String?> Function()? verify;

  /// How the app tries to join the repeater's softAP before the HTTP upload.
  /// Injected so widget tests never touch OS network tooling.
  final WifiConnector? connector;

  /// Reconnect the companion after a network switch. Defaults to AppState.
  final Future<void> Function()? reconnect;

  /// Foreground ownership seam for tests. Defaults to AppState's guard.
  final BackgroundOperationGuard? guard;

  @override
  State<WifiOtaScreen> createState() => _WifiOtaScreenState();
}

enum _Phase { idle, preflight, ready, uploading, verifying, done, failed }

class _WifiOtaScreenState extends State<WifiOtaScreen> {
  _Phase _phase = _Phase.idle;
  Uri? _url;
  WifiIdentity? _identity;
  double _progress = 0;
  String? _problem;
  String? _verifiedVersion;
  bool _needJoin = false;
  bool _joinAttempted = false;
  String? _joinMessage;

  WifiOtaService? _service() {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    if (cli == null || app.target == null) return null;
    return WifiOtaService(cli, app.target!,
        client: widget.client ?? WifiOtaClient());
  }

  Future<void> _start() async {
    final service = _service();
    if (service == null) return;
    setState(() {
      _phase = _Phase.preflight;
      _problem = null;
      _joinAttempted = false;
      _needJoin = false;
      _joinMessage = null;
    });
    try {
      final url = await service.startOta();
      if (!mounted) return;
      setState(() => _url = url);
      await _loadIdentity(service, url);
    } on WifiOtaException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _problem = e.friendly;
        });
      }
    }
  }

  /// Read the update page identity. If it is unreachable, the node has opened
  /// its softAP and the operator must be connected to it first.
  Future<void> _loadIdentity(WifiOtaService service, Uri url) async {
    try {
      final identity = await service.identity(url);
      if (!identity.isEsp32) {
        throw const WifiOtaException(
            'This board does not report ESP32. WiFi update is for ESP32 only.');
      }
      if (!mounted) return;
      setState(() {
        _identity = identity;
        _needJoin = false;
        _phase = _Phase.ready;
      });
    } on WifiIdentityUnreachable {
      if (!mounted) return;
      setState(() {
        _needJoin = true;
        _phase = _Phase.preflight;
      });
      if (!_joinAttempted) {
        _joinAttempted = true;
        await _attemptJoin();
      }
    }
  }

  Future<void> _attemptJoin() async {
    final app = context.read<AppState>();
    final reconnect = widget.reconnect ?? app.reconnect;
    final connector = widget.connector ?? const ManualWifiConnector();
    final result = await connector.join('MeshCore-OTA');
    if (!mounted) return;
    if (result == WifiJoinResult.joined) {
      setState(() =>
          _joinMessage = 'Joined MeshCore-OTA. Reconnecting the companion.');
      await reconnect();
      final service = _service();
      final url = _url;
      if (service != null && url != null) await _loadIdentity(service, url);
      return;
    }
    setState(() => _joinMessage = result == WifiJoinResult.denied
        ? 'The system refused the join. Join MeshCore-OTA in your device '
            'settings, then tap Continue.'
        : 'This device cannot join a network for you. Join MeshCore-OTA in '
            'your device settings, then tap Continue.');
  }

  Future<void> _continueAfterJoin() async {
    final service = _service();
    final url = _url;
    if (service == null || url == null) return;
    setState(() => _phase = _Phase.preflight);
    await _loadIdentity(service, url);
  }

  Future<void> _upload() async {
    final app = context.read<AppState>();
    final guard = widget.guard ?? app.backgroundGuard;
    final service = _service();
    final image = widget.image ?? app.selectedImage;
    final url = _url;
    if (service == null || image == null || url == null) return;
    try {
      await guard.acquire(
        'wifi-ota',
        'Updating over WiFi',
        text: 'Uploading firmware over WiFi',
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _problem = 'The upload could not keep running in the background: $e';
        });
      }
      return;
    }
    setState(() {
      _phase = _Phase.uploading;
      _progress = 0;
      _problem = null;
    });
    try {
      await service.upload(
        base: url,
        image: image,
        md5Hex: imageMd5(image),
        filename:
            '${widget.version ?? app.selectedDisplayVersion ?? 'firmware'}.bin'
                .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_'),
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() => _progress = total == 0 ? 0 : sent / total);
        },
      );
      await _verify();
    } on WifiOtaException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _problem = e.friendly;
        });
      }
    } finally {
      await guard.release('wifi-ota');
    }
  }

  Future<void> _verify() async {
    if (!mounted) return;
    setState(() => _phase = _Phase.verifying);
    if (widget.verify != null) {
      final version = await widget.verify!();
      if (!mounted) return;
      setState(() {
        _verifiedVersion = version;
        _phase = version == null ? _Phase.failed : _Phase.done;
        if (version == null) {
          _problem = 'The repeater did not answer. Outcome unknown until it '
              'reboots and can be reached again.';
        }
      });
      return;
    }
    final app = context.read<AppState>();
    final target = app.target;
    final client = app.connection.client;
    if (target == null || client == null) return;
    // The node reboots itself after a successful upload. Re-login and read
    // the version; a lost reply stays unknown.
    await Future<void>.delayed(const Duration(seconds: 3));
    String? version;
    try {
      final login = await client.login(target, app.adminPassword);
      if (login.ok) {
        final reply = await client.remoteCli(target, 'ver');
        version = reply.trim();
      }
    } catch (_) {
      version = null;
    }
    if (!mounted) return;
    setState(() {
      _verifiedVersion = version;
      _phase = version == null ? _Phase.failed : _Phase.done;
      if (version == null) {
        _problem = 'The repeater did not answer. Outcome unknown until it '
            'reboots and can be reached again.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image ?? context.watch<AppState>().selectedImage;
    return ManagementScaffold(
      title: 'WiFi update',
      refreshing: _phase == _Phase.preflight || _phase == _Phase.verifying,
      footer: switch (_phase) {
        _Phase.idle => FilledButton.icon(
            onPressed: image == null ? null : _start,
            icon: const Icon(Icons.wifi),
            label: const Text('Start')),
        _Phase.preflight when _needJoin => FilledButton.icon(
            onPressed: _continueAfterJoin,
            icon: const Icon(Icons.wifi_find),
            label: const Text('Continue')),
        _Phase.ready => FilledButton.icon(
            onPressed: _upload,
            icon: const Icon(Icons.upload_file),
            label: const Text('Upload')),
        _Phase.done => FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check),
            label: const Text('Done')),
        _Phase.failed => FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry')),
        _ => const SizedBox.shrink(),
      },
      children: [
        if (_problem != null) ErrorBanner(_problem!),
        if (_needJoin) ...[
          const SectionHeader('Connect to the update network'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
                _joinMessage ??
                    'The update page was not reachable. Join MeshCore-OTA and '
                        'tap Continue.',
                style: const TextStyle(color: OtaTheme.warn, fontSize: 12)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              'This network has no password. Joining it can drop the '
              'companion link; the app reconnects automatically when it can.',
              style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
            ),
          ),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Uses the repeater’s built-in update page over your LAN. It works '
            'on ESP32 only and has no password, so keep it on a trusted '
            'network.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        InfoRow(
            label: 'Image',
            value: image == null
                ? 'Choose a firmware first'
                : formatBytes(image.length)),
        if (_phase == _Phase.uploading) ...[
          const SectionHeader('Upload'),
          LinearProgressIndicator(value: _progress),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text('${(_progress * 100).round()}%',
                style: const TextStyle(fontSize: 12)),
          ),
        ],
        if (_url != null) ...[
          const SectionHeader('Update page'),
          InfoRow(label: 'Address', value: _url.toString()),
          InfoRow(label: 'Hardware', value: _identity?.hardware ?? 'unknown'),
          InfoRow(label: 'Identity', value: _identity?.id ?? 'unknown'),
        ],
        if (_phase == _Phase.ready)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'The update page is open and has no password. Upload only over '
              'a network you trust.',
              style: TextStyle(color: OtaTheme.warn, fontSize: 12),
            ),
          ),
        if (_phase == _Phase.done)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: InfoRow(
                label: 'Version after reboot',
                value: _verifiedVersion ?? 'unknown'),
          ),
        const SectionHeader('If the repeater opened a hotspot'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(
              labelText: 'Network to join manually',
              border: OutlineInputBorder(),
            ),
            enabled: false,
            controller: TextEditingController(text: 'MeshCore-OTA'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(
            'Join MeshCore-OTA in your device settings, then come back here '
            'and tap Start. Programmatic joining is not available on this '
            'device.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }
}
