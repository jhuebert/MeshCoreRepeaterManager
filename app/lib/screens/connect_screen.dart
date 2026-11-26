import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/ble_device_link.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'firmware_screen.dart';
import 'resume_screen.dart';
import 'target_screen.dart';

/// Step 1: pick the companion the phone talks to. The companion is used as
/// a raw radio — the phone never speaks to the repeater directly.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  // flutter_blue_plus has implementations for Android, iOS, macOS and Linux.
  // Windows has none, so the Bluetooth option is hidden there.
  static final _supportsBle = Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;

  bool _scanning = false;
  String? _scanError;
  List<ScanResult> _results = const [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '5000');
  // TCP stays the default on desktop; Bluetooth is available as the other
  // segment wherever the plugin supports it.
  bool _tcpMode = !Platform.isAndroid && !Platform.isIOS;

  @override
  void dispose() {
    _scanSub?.cancel();
    if (_supportsBle && _scanning) {
      // Best effort; a failed stop must not surface as an unhandled error.
      unawaited(FlutterBluePlus.stopScan().catchError((_) {}));
    }
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
      _results = const [];
    });
    try {
      // On macOS the system Bluetooth permission is reported separately from
      // the platform exception a scan throws. Name it so the operator knows
      // whether to change System Settings or try again.
      final state = await FlutterBluePlus.adapterState.first;
      if (state == BluetoothAdapterState.unauthorized) {
        if (mounted) {
          setState(() => _scanError =
              'Bluetooth permission is off for this app. Allow it in System '
                  'Settings > Privacy & Security > Bluetooth, then restart the app.');
        }
        return;
      }
      if (state != BluetoothAdapterState.on) {
        if (mounted) {
          setState(() => _scanError = state == BluetoothAdapterState.off
              ? 'Bluetooth is off on this Mac. Turn it on, then scan again.'
              : 'Bluetooth is still starting up. Try again in a moment.');
        }
        return;
      }
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() => _results = results);
      });
      await FlutterBluePlus.startScan(
        withServices: [MeshCoreUuids.serviceGuid],
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      debugPrint('BLE scan failed: $e');
      if (!mounted) return;
      setState(() {
        _scanError =
            'Bluetooth is not available here. Use TCP / Wi-Fi instead.';
      });
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// A short, plain-language version of the transport's error. The raw
  /// socket/BLE message is useful in a log, not on this screen.
  String _friendlyConnectError(AppState app) {
    final raw = app.connectError ?? '';
    if (raw.startsWith('TCP')) {
      return 'No companion found there. Check the host and port, then try again.';
    }
    if (raw.startsWith('BLE')) {
      return 'Could not reach the companion by Bluetooth. Try again or use TCP.';
    }
    return raw;
  }

  /// Connect, then land the user on repeater selection without a second
  /// tap. The CTA to move forward in the wizard is the connection itself.
  Future<void> _connectAndContinue(
    BuildContext context,
    Future<void> Function() connect,
  ) async {
    await connect();
    if (!context.mounted) return;
    if (context.read<AppState>().connectionPhase != ConnectionPhase.connected) {
      return; // failure stays here and shows the error banner
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TargetScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.connectionPhase == ConnectionPhase.connected;

    return Scaffold(
      appBar: AppBar(title: const Text('Repeater Manager')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 1, label: 'Connect the companion'),
          const SectionHeader('Transport'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SegmentedButton<bool>(
              segments: <ButtonSegment<bool>>[
                if (_supportsBle)
                  const ButtonSegment(
                      value: false,
                      label: Text('Bluetooth'),
                      icon: Icon(Icons.bluetooth)),
                const ButtonSegment(
                    value: true,
                    label: Text('TCP / Wi-Fi'),
                    icon: Icon(Icons.wifi)),
              ],
              selected: {_tcpMode},
              onSelectionChanged: (s) => setState(() => _tcpMode = s.first),
            ),
          ),
          if (!connected)
            ...(_tcpMode
                ? _buildTcpCard(context, app)
                : _buildBleCard(context, app))
          else
            ..._buildConnectedCard(context, app),
          if (app.connectError != null) ErrorBanner(_friendlyConnectError(app)),
          if (app.resumePlan != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.restore, color: OtaTheme.warn),
                  title: const Text('Unfinished update'),
                  subtitle: Text(
                    '${app.resumePlan!.targetName.isEmpty ? 'Repeater' : app.resumePlan!.targetName} '
                    '→ ${app.resumePlan!.version}. Continue without '
                    're-uploading what already arrived.',
                    style: const TextStyle(
                        color: OtaTheme.textMuted, fontSize: 11),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      color: OtaTheme.textMuted),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ResumeScreen()),
                  ),
                ),
              ),
            ),
          const SectionHeader('Firmware'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined,
                    color: OtaTheme.accent),
                title: const Text('Firmware library'),
                subtitle: const Text(
                  'Download versions for offline use, import a .bin, or '
                  'delete what you no longer need.',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                ),
                trailing:
                    const Icon(Icons.chevron_right, color: OtaTheme.textMuted),
                onTap: () async {
                  await app.refreshLibrary();
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            const FirmwareScreen(updateMode: false)),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBleCard(BuildContext context, AppState app) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bluetooth_searching,
                        color: OtaTheme.accent),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Pair with the companion',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (_scanning)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_scanError != null) ...[
                  Text(_scanError!,
                      style:
                          const TextStyle(color: OtaTheme.bad, fontSize: 12)),
                  const SizedBox(height: 8),
                ],
                if (_results.isEmpty && !_scanning)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'Nothing found yet. Tap Scan. The companion must be '
                      'powered and nearby.',
                      style: TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
                    ),
                  ),
                for (final result in _results)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: OtaTheme.surfaceHigh,
                      child: Icon(Icons.cell_tower,
                          color: OtaTheme.accent, size: 20),
                    ),
                    title: Text(bleCompanionDisplayName(result)),
                    subtitle: Text(
                      result.device.remoteId.toString(),
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 11),
                    ),
                    trailing: const Icon(Icons.link, color: OtaTheme.textMuted),
                    onTap: app.connectionPhase == ConnectionPhase.connecting
                        ? null
                        : () {
                            FocusScope.of(context).unfocus();
                            _connectAndContinue(
                              context,
                              () => app.connectBle(result.device),
                            );
                          },
                  ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _scanning ? null : _startScan,
                  icon: const Icon(Icons.search),
                  label: Text(_scanning ? 'Scanning…' : 'Scan'),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildTcpCard(BuildContext context, AppState app) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Icon(Icons.wifi, color: OtaTheme.accent),
                    SizedBox(width: 10),
                    Text(
                      'TCP companion',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'The companion on this network, by host and port.',
                  style: TextStyle(
                      color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hostController,
                        decoration: const InputDecoration(labelText: 'Host'),
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _portController,
                        decoration: const InputDecoration(labelText: 'Port'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: app.connectionPhase == ConnectionPhase.connecting
                      ? null
                      : () {
                          final host = _hostController.text.trim();
                          final port =
                              int.tryParse(_portController.text.trim()) ?? 5000;
                          if (host.isEmpty) return;
                          FocusScope.of(context).unfocus();
                          _connectAndContinue(
                            context,
                            () => app.connectTcp(host: host, port: port),
                          );
                        },
                  icon: app.connectionPhase == ConnectionPhase.connecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF1A1203),
                          ),
                        )
                      : const Icon(playIcon),
                  label: Text(app.connectionPhase == ConnectionPhase.connecting
                      ? 'Connecting…'
                      : 'Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildConnectedCard(BuildContext context, AppState app) {
    return [
      const SectionHeader('Connected'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: OtaTheme.ok),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        app.companionName.isNotEmpty
                            ? app.companionName
                            : 'Companion',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    TextButton(
                      onPressed: () => app.disconnect(),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${app.contacts.length} contacts known to the companion.',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                // Normally never shown: connecting lands on the repeater step
                // by itself. It is the way forward when the user comes back
                // here from the wizard.
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TargetScreen()),
                  ),
                  icon: const Icon(nextIcon),
                  label: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}
