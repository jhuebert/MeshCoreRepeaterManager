import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../services/repeater_cache_store.dart';
import '../../services/settings_controller.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Curated stock settings. The registry drives sections and validation, so the
/// generic browser and fleet scripts cannot drift from this screen.
class RepeaterSettingsScreen extends StatefulWidget {
  const RepeaterSettingsScreen({super.key, this.cli, this.cache});

  final CliService? cli;
  final RepeaterCacheStore? cache;

  @override
  State<RepeaterSettingsScreen> createState() => _RepeaterSettingsScreenState();
}

class _RepeaterSettingsScreenState extends State<RepeaterSettingsScreen> {
  SettingsController? _ctrl;
  bool _busy = false;
  String? _banner;
  bool _rebootNeeded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    final cache = widget.cache ?? app.cacheForTarget();
    final target = app.target;
    if (cli == null || cache == null || target == null) return;
    setState(() => _ctrl = SettingsController(target, cli, cache));
    await cache.load();
    if (mounted) setState(() {});
  }

  Future<void> _refreshSection(String section) async {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    setState(() => _busy = true);
    await ctrl.refresh(settingsIn(section).map((s) => s.key));
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    setState(() {
      _busy = true;
      _banner = null;
      _rebootNeeded = false;
    });
    final result = await ctrl.save();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _rebootNeeded = result.rebootNeeded;
      if (result.ok) {
        _banner = result.rebootNeeded
            ? 'Saved. Reboot the repeater for some changes to take effect.'
            : 'Saved.';
      } else {
        _banner = 'Could not save: ${result.failedKeys.join(', ')}. '
            'Those values stayed unchanged; try again.';
      }
    });
  }

  Future<bool> _guardBack() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.hasChanges) return true;
    if (!mounted) return false;
    final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('Your unsaved changes will be lost.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Keep editing')),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Discard')),
            ],
          ),
        ) ??
        false;
    if (leave) ctrl.discardAll();
    return leave;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    return PopScope<Object?>(
      canPop: ctrl == null || !ctrl.hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || ctrl == null || !ctrl.hasChanges) return;
        final navigator = Navigator.of(context);
        if (await _guardBack()) navigator.pop();
      },
      child: ManagementScaffold(
        title: 'Settings',
        refreshing: _busy,
        actions: [
          if (ctrl != null && ctrl.hasChanges)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: () => setState(() => ctrl.discardAll()),
                child: const Text('Discard'),
              ),
            ),
        ],
        children: [
          if (_banner != null) InfoBanner(_banner!),
          if (_rebootNeeded)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text('A reboot is needed for some changes.',
                  style: TextStyle(color: OtaTheme.warn, fontSize: 12)),
            ),
          if (ctrl == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Connect and choose a repeater first.',
                  style: TextStyle(color: OtaTheme.textMuted)),
            )
          else
            for (final section in stockSections) ...[
              SectionHeader(section),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _refreshSection(section),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh section'),
                ),
              ),
              for (final spec in settingsIn(section))
                SettingField(
                  key: Key(spec.key),
                  label: spec.label,
                  value: ctrl.displayedValue(spec.key),
                  input: spec.input,
                  choices: spec.choices,
                  help: spec.help,
                  error: ctrl.errorFor(spec.key),
                  onChanged: (v) => setState(() => ctrl.setDraft(spec.key, v)),
                ),
            ],
          if (ctrl != null && ctrl.hasChanges)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
              child: FilledButton.icon(
                onPressed: _busy || ctrl.hasValidationErrors ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save'),
              ),
            ),
        ],
      ),
    );
  }
}

/// A neutral notice that is not an error banner.
class InfoBanner extends StatelessWidget {
  const InfoBanner(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: OtaTheme.accent, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message,
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
            ),
          ],
        ),
      );
}
