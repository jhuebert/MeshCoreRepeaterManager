import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/radio_plan.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'review_screen.dart';

/// Step 5: where the transfer runs.
///
/// The live mesh stays untouched in a temporary-preset or radio2 transfer;
/// both are zero-hop because nothing else is tuned there. The private preset
/// starts from the repeater's own radio settings, which work in every region,
/// and the screen explains what will be changed and restored. Transfer time
/// is deliberately not guessed here: comparison starts after Start.
/// In live-mesh mode it also carries the optional direct path override.
class RadioSettingsScreen extends StatefulWidget {
  const RadioSettingsScreen({super.key});

  @override
  State<RadioSettingsScreen> createState() => _RadioSettingsScreenState();
}

class _RadioSettingsScreenState extends State<RadioSettingsScreen> {
  static const _bandwidths = <int>[
    7800,
    10400,
    15600,
    20800,
    31250,
    41700,
    62500,
    125000,
    250000,
    500000,
  ];

  late OtaMethod _method;
  late RadioMode _mode;
  late final TextEditingController _frequency;
  late final TextEditingController _route;
  late int _bandwidthHz;
  late int _spreadingFactor;
  late int _codingRate;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _method = app.otaMethod;
    _mode = app.radioPlan.mode;
    final suggested =
        app.radioPlan.preset ?? app.suggestedRadioPreset() ?? app.livePreset;
    _frequency = TextEditingController(
        text: suggested == null ? '' : _fmt(suggested.frequencyMhz));
    _route = TextEditingController(text: app.manualRoutePath);
    _bandwidthHz = suggested?.bandwidthHz ?? 125000;
    _spreadingFactor = suggested?.spreadingFactor ?? 7;
    _codingRate = suggested?.codingRate ?? 5;
  }

  @override
  void dispose() {
    _frequency.dispose();
    _route.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final live = app.livePreset;
    final plan = _planFromFields(app);
    final usesRadio = _method == OtaMethod.lora;
    final problem = usesRadio ? plan.error(primary: live) : null;
    final routeInvalid = usesRadio &&
        _mode == RadioMode.liveMesh &&
        app.manualRouteError != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Radio settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 5, label: 'Radio settings'),
          const SectionHeader('How the update reaches the repeater'),
          RadioGroup<OtaMethod>(
            groupValue: _method,
            onChanged: (value) => setState(() => _method = value ?? _method),
            child: Column(
              children: [
                _methodTile(
                  OtaMethod.lora,
                  'Over the mesh',
                  'Send the image on the channel chosen below.',
                ),
                if (app.wifiUploadSupported)
                  _methodTile(
                    OtaMethod.wifi,
                    app.wifiMode == WifiUploadMode.lan
                        ? 'Over WiFi, your network'
                        : 'Over WiFi, repeater hotspot',
                    app.wifiMode == WifiUploadMode.lan
                        ? 'The repeater serves the update page on its WiFi '
                            'address. This device must be on the same network.'
                        : 'The repeater opens a MeshCore-OTA network. Join it '
                            'on this device, then upload directly. ESP32 only.',
                  ),
                if (app.onlineFetchSupported)
                  _methodTile(
                    OtaMethod.onlineFetch,
                    'Download on the repeater',
                    'The repeater fetches the chosen version itself. Needs an '
                        'observer build and WiFi credentials on the repeater.',
                  ),
              ],
            ),
          ),
          if (!usesRadio) ...[
            const SectionHeader('This update'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _method == OtaMethod.wifi
                    ? 'The radio plan below does not apply. The upload goes '
                        'over WiFi and the repeater reboots when it finishes.'
                    : 'The radio plan below does not apply. The repeater '
                        'downloads and verifies the image before you commit it.',
                style: const TextStyle(
                    color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
              ),
            ),
            if (_method == OtaMethod.onlineFetch) ...[
              const SizedBox(height: 8),
              InfoRow(
                  label: 'Version',
                  value: app.selectedVersion ?? 'not chosen',
                  mono: false),
              InfoRow(
                  label: 'SHA-256',
                  value: app.selectedSha256 ?? 'not available',
                  mono: false),
            ],
          ],
          if (usesRadio) ...[
            const SectionHeader('Where the update runs'),
            RadioGroup<RadioMode>(
              groupValue: _mode,
              onChanged: (value) => setState(() => _mode = value ?? _mode),
              child: Column(
                children: [
                  _modeTile(
                    RadioMode.liveMesh,
                    'Live mesh',
                    live == null
                        ? 'Use the normal mesh channel and the route the companion has.'
                        : 'Normal mesh channel (${live.label}) and the saved DIRECT route.',
                  ),
                  _modeTile(
                    RadioMode.tempRadio,
                    'Temporary private channel',
                    'Move the repeater and the companion to a private preset for the '
                        'transfer, then put both back. The channel renews itself '
                        'during the update. Zero-hop: no relay is there.',
                  ),
                  _modeTile(
                    RadioMode.radio2,
                    'The repeater\'s second preset',
                    'Keep the live mesh on its channel and send the transfer on the '
                        'repeater\'s radio2 preset. Zero-hop on the secondary. '
                        'The repeater shares the radio with the live mesh.',
                  ),
                ],
              ),
            ),
            if (_mode == RadioMode.liveMesh) ...[
              const SectionHeader('Direct path'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                child: TextField(
                  controller: _route,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Direct path override (optional)',
                    hintText: 'c0ff, c0c0',
                    helperText:
                        'Comma-separated hash hops. Empty keeps the saved route.',
                    errorText: app.manualRouteError,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: app.setManualRoutePath,
                ),
              ),
            ],
            if (_mode != RadioMode.liveMesh) ...[
              const SectionHeader('Private preset'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (live != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text(
                              'Live preset: ${live.label}. The private preset must '
                              'stay clear of it${_mode == RadioMode.radio2 ? ' (the second preset must use a different band)' : ''}.',
                              style: const TextStyle(
                                  color: OtaTheme.textMuted,
                                  fontSize: 11,
                                  height: 1.4),
                            ),
                          ),
                        if (_usesExistingRadio2(app)) ...[
                          Text(
                            'Using the repeater\'s current radio2 preset: '
                            '${app.radio2Preset!.label}. The node\'s radio2 '
                            'configuration is left unchanged.',
                            style: const TextStyle(
                                color: OtaTheme.accent, fontSize: 12),
                          ),
                        ] else ...[
                          TextField(
                            controller: _frequency,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.]')),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Frequency (MHz)',
                              isDense: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<int>(
                            key: ValueKey('bw$_bandwidthHz'),
                            initialValue: _bandwidthHz,
                            decoration: const InputDecoration(
                              labelText: 'Bandwidth (kHz)',
                              isDense: true,
                            ),
                            items: [
                              for (final hz in _bandwidthItems())
                                DropdownMenuItem(
                                    value: hz, child: Text(_fmt(hz / 1000))),
                            ],
                            onChanged: (v) => setState(
                                () => _bandwidthHz = v ?? _bandwidthHz),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  key: ValueKey('sf$_spreadingFactor'),
                                  initialValue: _spreadingFactor,
                                  decoration: const InputDecoration(
                                    labelText: 'Spreading factor',
                                    isDense: true,
                                  ),
                                  items: [
                                    for (var sf = 5; sf <= 12; sf++)
                                      DropdownMenuItem(
                                          value: sf, child: Text('SF$sf')),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _spreadingFactor = v ?? 7),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  key: ValueKey('cr$_codingRate'),
                                  initialValue: _codingRate,
                                  decoration: const InputDecoration(
                                    labelText: 'Coding rate',
                                    isDense: true,
                                  ),
                                  items: [
                                    for (var cr = 5; cr <= 8; cr++)
                                      DropdownMenuItem(
                                          value: cr, child: Text('4/$cr')),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _codingRate = v ?? 5),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Preset: ${_presetFromFields(app).label}',
                            style: const TextStyle(
                                color: OtaTheme.textMuted, fontSize: 11),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Started from the repeater’s own settings. Change '
                            'them here if you need to.',
                            style: TextStyle(
                                color: OtaTheme.textMuted, fontSize: 11),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'The repeater keeps the private channel on for '
                          '${RadioPlan.tempRadioChunkMinutes}-minute chunks and '
                          'renews it automatically while the update runs.',
                          style: const TextStyle(
                              color: OtaTheme.textMuted,
                              fontSize: 11,
                              height: 1.4),
                        ),
                        if (_mode == RadioMode.tempRadio &&
                            app.radio2Enabled == true) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'The repeater\'s radio2 is paused while the private '
                            'channel is in use, and restored afterwards.',
                            style: TextStyle(
                                color: OtaTheme.warn,
                                fontSize: 11,
                                height: 1.4),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (_mode == RadioMode.radio2) _radio2Note(app),
            ],
          ],
          if (problem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text(
                problem,
                style: const TextStyle(color: OtaTheme.bad, fontSize: 12),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'A low battery still pauses the transfer. The repeater checks '
              'the image before it can boot.',
              style: TextStyle(
                  color: OtaTheme.textMuted, fontSize: 11, height: 1.45),
            ),
          ),
        ],
      ),
      bottomNavigationBar: WizardFooter(
        label: 'Review',
        onPressed: problem != null || routeInvalid
            ? null
            : () => _saveAndContinue(app, plan),
        hint: routeInvalid ? 'Fix the direct path override above.' : null,
      ),
    );
  }

  Widget _methodTile(
    OtaMethod method,
    String title,
    String subtitle,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Card(
        color: _method == method ? OtaTheme.surfaceHigh : null,
        child: RadioListTile<OtaMethod>(
          value: method,
          title: Text(title),
          subtitle: Text(subtitle,
              style: const TextStyle(
                  color: OtaTheme.textMuted, fontSize: 11, height: 1.35)),
        ),
      ),
    );
  }

  Widget _modeTile(
    RadioMode mode,
    String title,
    String subtitle,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Card(
        color: _mode == mode ? OtaTheme.surfaceHigh : null,
        child: RadioListTile<RadioMode>(
          value: mode,
          title: Text(title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(subtitle,
                  style: const TextStyle(
                      color: OtaTheme.textMuted, fontSize: 11, height: 1.35)),
            ],
          ),
        ),
      ),
    );
  }

  bool _usesExistingRadio2(AppState app) =>
      _mode == RadioMode.radio2 &&
      app.radio2Enabled == true &&
      app.radio2Preset != null;

  Widget _radio2Note(AppState app) {
    final enabled = app.radio2Enabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(
        enabled == true && app.radio2Preset != null
            ? 'radio2 is already enabled on this node and uses the preset shown '
                'above. The app will not change the node\'s radio2 configuration.'
            : enabled == true
                ? 'radio2 is already enabled, but the node did not report its '
                    'preset. Enter the secondary preset it already uses; the app '
                    'will not change the node\'s radio2 configuration.'
                : enabled == false
                    ? 'radio2 is off. The app enables it for the update with these '
                        'settings and turns it off again afterwards.'
                    : 'The node did not report a radio2 state. If radio2 is already '
                        'enabled, enter its existing secondary preset. The app will '
                        'not change it either way.',
        style: TextStyle(
          color: enabled == true ? OtaTheme.warn : OtaTheme.textMuted,
          fontSize: 11,
          height: 1.45,
        ),
      ),
    );
  }

  List<int> _bandwidthItems() {
    final values = [..._bandwidths];
    if (!values.contains(_bandwidthHz)) values.add(_bandwidthHz);
    values.sort();
    return values;
  }

  LoRaPreset _presetFromFields(AppState app) {
    if (_usesExistingRadio2(app)) return app.radio2Preset!;
    final mhz = double.tryParse(_frequency.text.trim()) ?? 0;
    return LoRaPreset(
      frequencyHz: (mhz * 1e6).round(),
      bandwidthHz: _bandwidthHz,
      spreadingFactor: _spreadingFactor,
      codingRate: _codingRate,
    );
  }

  RadioPlan _planFromFields(AppState app) => RadioPlan(
        mode: _mode,
        preset: _mode == RadioMode.liveMesh ? null : _presetFromFields(app),
      );

  void _saveAndContinue(AppState app, RadioPlan plan) {
    app.setOtaMethod(_method);
    app.setRadioMode(_mode);
    if (_mode != RadioMode.liveMesh) {
      app.setRadioPreset(_presetFromFields(app));
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ReviewScreen()),
    );
  }

  static String _fmt(double value) {
    var text = value.toStringAsFixed(3);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
    return text;
  }
}
