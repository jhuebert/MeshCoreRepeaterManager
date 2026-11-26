import 'package:flutter/material.dart';
import 'package:ota_core/ota_core.dart' show ApplyOutcome;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/foreground.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';

/// Final step: boot into the new image and prove it works. The node
/// rebooted into an image its hash gate approved; the boot health check
/// flips back if the LoRa radio is dead. The app adds the last mile:
/// re-login and confirm the image hash matches the one that was sent.
class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  bool _started = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A WiFi upload reboots the repeater itself. Verification already happened
    // on Transfer, so there is no apply step to run here.
    final method = context.read<AppState>().otaMethod;
    if (method == OtaMethod.wifi) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
  }

  /// A staged-but-uncommitted update is still verified on the node: retrying
  /// the apply needs no transfer and no new wizard run.
  Future<void> _retryApply() async {
    if (!mounted) return;
    setState(() {
      _started = false;
      _error = null;
    });
    await _apply();
  }

  Future<void> _apply() async {
    if (_started) return;
    _started = true;
    final app = context.read<AppState>();
    // Apply and verification can take a couple of minutes while the node
    // reboots. TransferScreen has already stopped its own guard by now.
    try {
      await TransferForegroundService.setScreenOn(true);
      await TransferForegroundService.start('Applying the new firmware');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    try {
      await app.applyAndVerify(expectedVersion: app.selectedVersion ?? '');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      await TransferForegroundService.setScreenOn(false);
      await TransferForegroundService.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final phase = app.updatePhase;
    final matched = app.verifyMatched;
    final partial = app.verificationLevel == VerificationLevel.versionOnly;
    final wifiUpload = app.otaMethod == OtaMethod.wifi;
    final stagedNotApplied =
        app.applyOutcome == ApplyOutcome.stagedNotApplied && !matched;

    return Scaffold(
      appBar: AppBar(title: const Text('Verify')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 8, label: 'Verify'),
          const SizedBox(height: 18),
          if (phase == UpdatePhase.applying || phase == UpdatePhase.verifying)
            const Column(
              children: [
                SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                Text(
                  'Node is rebooting into the new firmware…\n'
                  'Waiting for it to answer admin CLI again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: OtaTheme.textMuted, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          if (_error != null) ErrorBanner(_error!),
          if (phase == UpdatePhase.done || phase == UpdatePhase.failed) ...[
            Center(
              child: Icon(
                app.rolledBack
                    ? Icons.undo
                    : matched
                        ? Icons.check_circle
                        : Icons.warning_amber_rounded,
                size: 84,
                color: app.rolledBack
                    ? OtaTheme.warn
                    : matched
                        ? OtaTheme.ok
                        : OtaTheme.warn,
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                app.rolledBack
                    ? 'Rolled back to the previous firmware'
                    : matched
                        ? (partial ? 'Firmware updated' : 'Update verified')
                        : stagedNotApplied
                            ? 'Update not committed'
                            : 'New firmware did not come up',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  app.rolledBack
                      ? 'The repeater rebooted into the firmware it ran before '
                          'this update. Nothing was re-flashed.'
                      : matched
                          ? (partial
                              ? 'The repeater came back on the new version. '
                                  'This firmware cannot report an image hash, '
                                  'so this is a version match only.'
                              : 'The repeater came back on the new firmware. Its '
                                  'image matches the one that was sent. The update is '
                                  'complete.')
                          : stagedNotApplied
                              ? 'The repeater is still holding the verified image '
                                  'in its spare slot. The apply command did not get '
                                  'through. Nothing needs to be sent again.'
                              : 'The node is not running the expected image. Either it '
                                  'switched itself back to the previous firmware (the '
                                  'safe outcome), or the new image is broken. Check the '
                                  'node. You can roll back below.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: OtaTheme.textMuted, fontSize: 12.5, height: 1.5),
                ),
              ),
            ),
          ],
          if (stagedNotApplied && phase == UpdatePhase.failed) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: _retryApply,
                icon: const Icon(playIcon),
                label: const Text('Try again'),
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (!wifiUpload)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: OutlinedButton.icon(
                // A rollback while apply/verify is still deciding would race the
                // in-flight reboot: the outcome is not known yet.
                onPressed: phase == UpdatePhase.applying ||
                        phase == UpdatePhase.verifying
                    ? null
                    : () => _rollback(app),
                icon: const Icon(backIcon),
                label: const Text('Roll back'),
              ),
            ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              icon: const Icon(nextIcon),
              label: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rollback(AppState app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Roll back?'),
        content: const Text(
          'The repeater reboots into the previous firmware. Nothing is '
          're-flashed.',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep current firmware'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Roll back'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await TransferForegroundService.setScreenOn(true);
      await TransferForegroundService.start('Rolling the firmware back');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not keep the rollback in view: $e')),
        );
      }
      return;
    }
    try {
      await app.rollback();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rollback failed: $e')),
        );
      }
    } finally {
      await TransferForegroundService.setScreenOn(false);
      await TransferForegroundService.stop();
    }
  }
}
