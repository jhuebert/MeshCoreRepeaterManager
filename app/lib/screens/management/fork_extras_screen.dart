import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// The five smaller fork features on one screen: radio2, battery gate, mesh
/// clock, bot and the power profile. Values are read on refresh, never on open.
class ForkExtrasScreen extends StatefulWidget {
  const ForkExtrasScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<ForkExtrasScreen> createState() => _ForkExtrasScreenState();
}

class _ForkExtrasScreenState extends State<ForkExtrasScreen> {
  final _controllers = <String, TextEditingController>{};
  Radio2Status? _radio2;
  BatteryStatus? _battery;
  MeshClockStatus? _clock;
  BotStatus? _bot;
  RxpsStatus? _rxps;
  String? _cpuFreq;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    for (final key in [
      'radio2.preset',
      'radio2.timing',
      'radio2.policy',
      'battery.suspend',
      'battery.resume',
      'clock.slots',
      'clock.votes',
      'clock.tol',
      'clock.minTol',
      'bot.name',
      'bot.channel',
      'rxps.level',
      'rxps.preamble',
      'rxps.rx',
      'rxps.sleep',
    ]) {
      _controllers[key] = TextEditingController();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  CliService? _cli() => widget.cli ?? context.read<AppState>().managementCli();
  Contact? _target() => context.read<AppState>().target;
  String _text(String key) => _controllers[key]?.text.trim() ?? '';

  Future<void> _refresh() async {
    final cli = _cli();
    final target = _target();
    if (cli == null || target == null) return;
    setState(() => _busy = true);
    final radio2 = await cli.read(target, 'radio2 status');
    final battery = await cli.read(target, 'battery');
    final clock = await cli.read(target, 'clock mesh');
    final bot = await cli.read(target, 'bot');
    final rxps = await cli.read(target, 'get radio.rxps');
    final cpu = await cli.read(target, 'get cpu.freq');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _radio2 = Radio2Status.parse(radio2.text);
      _battery = BatteryStatus.parse(battery.text);
      _clock = MeshClockStatus.parse(clock.text);
      if (radio2.ok) {
        _bot = BotStatus.parse(bot.text);
      }
      _rxps = RxpsStatus.parse(rxps.text);
      _cpuFreq = cpu.ok ? cpu.value : null;
      final preset = _radio2?.preset;
      if (preset != null) _controllers['radio2.preset']!.text = preset;
      final suspend = _battery?.milliVolts;
      if (suspend != null && suspend > 0) {
        _controllers['battery.suspend']!.text = '$suspend';
      }
      if (_clock != null) {
        _controllers['clock.slots']!.text = '${_clock!.slots}';
        _controllers['clock.votes']!.text = '${_clock!.minVotes}';
        _controllers['clock.tol']!.text = '${_clock!.tolerance}';
        _controllers['clock.minTol']!.text = '${_clock!.minTolerance}';
      }
      if (_bot != null) {
        if (!_bot!.name.startsWith('(')) {
          _controllers['bot.name']!.text = _bot!.name;
        }
        if (!_bot!.channel.startsWith('(')) {
          // Never fill a channel secret back into the field after reading.
          _controllers['bot.channel']!.clear();
        }
      }
      if (_rxps != null) {
        _controllers['rxps.level']!.text = '${_rxps!.level}';
        _controllers['rxps.preamble']!.text = '${_rxps!.preamble}';
        _controllers['rxps.rx']!.text = '${_rxps!.rxMicros}';
        _controllers['rxps.sleep']!.text = '${_rxps!.sleepMicros}';
      }
      if (!radio2.ok && !battery.ok) {
        _problem = 'No answer from the repeater. Outcome unknown; try again.';
      }
    });
  }

  Future<void> _run(String command, {String? error}) async {
    if (error != null) {
      setState(() => _problem = error);
      return;
    }
    final cli = _cli();
    final target = _target();
    if (cli == null || target == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final reply = await cli.write(target, command, family: 'extras');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!reply.ok) {
        _problem = reply.kind == CliReplyKind.unknown
            ? 'No answer. Outcome unknown; refresh to check.'
            : reply.text;
      }
    });
    if (reply.ok) await _refresh();
  }

  Widget _field(String key, String label,
          {String? help, bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: TextField(
          key: Key(key),
          controller: _controllers[key],
          enabled: enabled,
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          autocorrect: false,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final clock = _clock;
    final battery = _battery;
    final radio2 = _radio2;
    final bot = _bot;
    final rxps = _rxps;
    return ManagementScaffold(
      title: 'Fork features',
      onRefresh: _refresh,
      refreshing: _busy,
      children: [
        if (_problem != null) ErrorBanner(_problem!),
        const SectionHeader('Radio2'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            radio2 == null
                ? 'Not read yet.'
                : '${radio2.enabled ? 'on' : 'off'}; preset '
                    '${radio2.preset ?? 'unknown'}',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        if (radio2?.enabled == true)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Enabled read only here. Change it on the node.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
          ),
        _field('radio2.preset', 'Preset f,bw,sf,cr',
            help: radio2?.enabled == true
                ? 'Already enabled: shown read only'
                : 'Must not overlap the live band',
            enabled: radio2?.enabled != true),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy || radio2?.enabled == true
                      ? null
                      : () => _run('radio2 ${_text('radio2.preset')}'),
                  child: const Text('Set preset'),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _run('radio2 off'),
                  child: const Text('Turn off'),
                ),
              ),
            ),
          ],
        ),
        _field('radio2.timing', 'Timing'),
        _field('radio2.policy', 'Policy'),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run('radio2 timing ${_text('radio2.timing')}'),
                  child: const Text('Set timing'),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run('radio2 policy ${_text('radio2.policy')}'),
                  child: const Text('Set policy'),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: _busy ? null : () => _run('radio2 advert both'),
            child: const Text('Advertise on both'),
          ),
        ),
        const SectionHeader('Battery gate'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            battery == null
                ? 'Not read yet.'
                : '${battery.milliVolts} mV; gate '
                    '${battery.gateOn ? 'on' : 'off'}; drops ${battery.drops}',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        _field('battery.suspend', 'Suspend mV'),
        _field('battery.resume', 'Resume mV'),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                            'battery ${_text('battery.suspend')} ${_text('battery.resume')}',
                            error: BatteryStatus.validate(
                              int.tryParse(_text('battery.suspend')) ?? 0,
                              int.tryParse(_text('battery.resume')),
                            ),
                          ),
                  child: const Text('Set gate'),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _run('battery off'),
                  child: const Text('Turn off'),
                ),
              ),
            ),
          ],
        ),
        const SectionHeader('Mesh clock'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            clock == null
                ? 'Not read yet.'
                : '${clock.enabled ? 'on' : 'off'}; slots ${clock.slots}/${clock.minVotes}; '
                    'tolerance ${clock.tolerance}/${clock.minTolerance}',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        _field('clock.slots', 'Slots'),
        _field('clock.votes', 'Minimum votes'),
        _field('clock.tol', 'Tolerance'),
        _field('clock.minTol', 'Minimum tolerance'),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _run('clock mesh on'),
                  child: const Text('Turn on'),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _run('clock mesh off'),
                  child: const Text('Turn off'),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                      'clock mesh slots ${_text('clock.slots')} ${_text('clock.votes')}',
                      error: MeshClockStatus.validateSlots(
                        int.tryParse(_text('clock.slots')) ?? 0,
                        int.tryParse(_text('clock.votes')) ?? 0,
                      ),
                    ),
            child: const Text('Apply slots'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                      'clock mesh tolerance ${_text('clock.tol')} ${_text('clock.minTol')}',
                      error: MeshClockStatus.validateTolerance(
                        int.tryParse(_text('clock.tol')) ?? 0,
                        int.tryParse(_text('clock.minTol')) ?? 0,
                      ),
                    ),
            child: const Text('Apply tolerance'),
          ),
        ),
        const SectionHeader('Bot'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            bot == null
                ? 'Not read yet.'
                : '${bot.enabled ? 'on' : 'off'}, name ${bot.name}',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        _field('bot.name', 'Bot name'),
        _field('bot.channel', 'Channel (#name, hex or off)',
            help: 'The channel secret is never shown again after entry'),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                            'bot name ${_text('bot.name')}',
                            error: BotStatus.validateName(_text('bot.name')),
                          ),
                  child: const Text('Set name'),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                            'bot chan ${_text('bot.channel')}',
                            error:
                                BotStatus.validateChannel(_text('bot.channel')),
                          ),
                  child: const Text('Set channel'),
                ),
              ),
            ),
          ],
        ),
        const SectionHeader('Power profile'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'CPU ${_cpuFreq ?? 'unknown'} MHz. RX power saving '
            '${rxps?.desired ?? 'unknown'}.',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButton<int>(
            value: cpuFrequencies.contains(int.tryParse(_cpuFreq ?? ''))
                ? int.parse(_cpuFreq!)
                : 80,
            items: [
              for (final f in cpuFrequencies)
                DropdownMenuItem(value: f, child: Text('$f MHz')),
            ],
            onChanged: _busy
                ? null
                : (v) => v == null ? null : _run('set cpu.freq $v'),
          ),
        ),
        _field('rxps.level', 'Level 1 to 10'),
        _field('rxps.preamble', 'Preamble 0, 16 or 32'),
        _field('rxps.rx', 'RX microseconds'),
        _field('rxps.sleep', 'Sleep microseconds'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                      'set radio.rxps on ${_text('rxps.level')} '
                      '${_text('rxps.preamble')} ${_text('rxps.rx')} '
                      '${_text('rxps.sleep')}',
                      error: RxpsStatus.validateRadio2Conflict(
                              radio2?.enabled ?? false) ??
                          RxpsStatus.validateLevel(
                              int.tryParse(_text('rxps.level')) ?? 0) ??
                          RxpsStatus.validatePreamble(
                              int.tryParse(_text('rxps.preamble')) ?? 0),
                    ),
            child: const Text('Enable power saving'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: _busy ? null : () => _run('set radio.rxps off'),
            child: const Text('Disable power saving'),
          ),
        ),
      ],
    );
  }
}
