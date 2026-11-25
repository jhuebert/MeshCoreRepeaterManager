import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ota_core/ota_core.dart' show TransferProgress;

import '../app_state.dart';
import '../services/foreground.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'resume_screen.dart';
import 'verify_screen.dart';

/// Step 8: the transfer itself. The node re-verifies the image when the
/// stream ends. Nothing boots until the operator commits.
class TransferScreen extends StatefulWidget {
  /// A resumed transfer keeps the staged bytes when cancelled; a fresh one
  /// discards them.
  const TransferScreen({super.key, this.resuming = false});

  final bool resuming;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  final _logController = ScrollController();
  bool _started = false;
  String? _error;
  bool _paused = false;
  bool _stopped = false;
  int? _lastNotifiedOps;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    // Keep the ancestor reference before disposal makes ancestor lookup
    // unsafe (the listener must be removed in dispose()).
    _app = context.read<AppState>();
    _app.addListener(_onAppChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _onAppChanged() {
    if (!mounted) return;
    final ops = _app.progress?.opsApplied;
    if (ops == null || ops == _lastNotifiedOps) return;
    _lastNotifiedOps = ops;
    final total = _app.progress?.opsTotal;
    unawaited(TransferForegroundService.update(
      total == null ? '$ops ops applied' : '$ops of $total ops applied',
    ));
  }

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    _logController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    final app = context.read<AppState>();
    final nodeName = app.target?.name ?? 'node';
    try {
      await TransferForegroundService.setScreenOn(true);
      await TransferForegroundService.start('Preparing update for $nodeName');
    } catch (e) {
      // The foreground service is what keeps a minutes-long transfer alive
      // when the operator goes Home. Continuing without it risks a dead
      // update, so refuse to start rather than fail silently later.
      await TransferForegroundService.setScreenOn(false);
      if (mounted) {
        setState(() =>
            _error = 'The update could not keep running in the background: $e');
      }
      return;
    }
    try {
      if (widget.resuming) {
        await app.resumeTransfer();
      } else {
        await app.runUpdate(version: app.selectedVersion ?? 'unknown');
      }
    } on UpdateComparisonCancelledException catch (_) {
      if (mounted) setState(() => _stopped = true);
    } on UpdatePausedException catch (_) {
      if (mounted) setState(() => _paused = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      await TransferForegroundService.setScreenOn(false);
      await TransferForegroundService.stop();
    }
  }

  /// Re-run the whole preparation after a stopped or failed comparison.
  /// runUpdate restored the radios on the way out, so this arms afresh.
  Future<void> _retry() async {
    if (!mounted) return;
    setState(() {
      _started = false;
      _stopped = false;
      _error = null;
    });
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final progress = app.progress;
    final phase = app.updatePhase;
    final target = app.target;
    final terminal = phase == UpdatePhase.upToDate;
    final fraction = terminal ? 1.0 : (progress?.fraction ?? 0.0);
    final totalBytes = app.remoteDiff?.literalBytes ??
        app.selectedImage?.length ??
        progress?.literalBytesSent ??
        0;

    // Auto-scroll the log.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logController.hasClients) {
        _logController.jumpTo(_logController.position.maxScrollExtent);
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Updating')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 7, label: 'Transfer'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              target == null
                  ? 'Updating…'
                  : 'Updating ${target.name.isNotEmpty ? target.name : 'the node'} to '
                      '${app.selectedVersion ?? '?'}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: fraction,
                          minHeight: 10,
                          backgroundColor: OtaTheme.surfaceHigh,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              OtaTheme.accent),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${(fraction * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  terminal
                      ? 'Already up to date. Nothing was staged.'
                      : progress == null
                          ? 'Getting ready…'
                          : '${formatBytes(progress.literalBytesSent)} / '
                              '${formatBytes(totalBytes < progress.literalBytesSent ? progress.literalBytesSent : totalBytes)} sent · '
                              '${progress.retries} re-sends'
                              '${_etaSuffix(progress)}',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          if (phase == UpdatePhase.comparing ||
              (app.compareProgress != null && app.remoteDiff == null)) ...[
            const SectionHeader('Comparing'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        app.compareProgress == null
                            ? 'Asking the repeater about its running image on '
                                'the channel you chose…'
                            : '${app.compareProgress!.queries} exchanges · '
                                '${_fmtBytes(app.compareProgress!.bytesReused)} '
                                'reused so far',
                        style: const TextStyle(
                            color: OtaTheme.textMuted,
                            fontSize: 12,
                            height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SectionHeader('Steps'),
          _stepRow(
            label: 'Compare with repeater',
            state: _stepDone(UpdatePhase.comparing, phase)
                ? _StepState.ok
                : phase == UpdatePhase.comparing
                    ? _StepState.active
                    : _StepState.pending,
          ),
          _stepRow(
            label: 'Stage image',
            state: _stepDone(UpdatePhase.staging, phase)
                ? _StepState.ok
                : phase == UpdatePhase.staging
                    ? _StepState.active
                    : _StepState.pending,
          ),
          _stepRow(
            label: 'Transfer',
            state: _stepDone(UpdatePhase.readyToApply, phase)
                ? _StepState.ok
                : phase == UpdatePhase.transferring
                    ? _StepState.active
                    : _StepState.pending,
            // A pie-style ring tracks the real op progress while transferring.
            value: phase == UpdatePhase.transferring ? fraction : null,
          ),
          _stepRow(
            label: 'Verify the image',
            state: _stepDone(UpdatePhase.readyToApply, phase)
                ? _StepState.ok
                : _StepState.pending,
          ),
          _stepRow(
            label: 'Commit update',
            state: _stepDone(UpdatePhase.verifying, phase)
                ? _StepState.ok
                : phase == UpdatePhase.applying ||
                        phase == UpdatePhase.readyToApply
                    ? _StepState.active
                    : _StepState.pending,
          ),
          if (_stopped) ...[
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: const [
                    Text('Comparison stopped',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    SizedBox(height: 8),
                    Text(
                      'Nothing was staged, and the radios were put back. '
                      'You can compare again from here.',
                      style: TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (phase == UpdatePhase.upToDate) ...[
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: const [
                    Text('Already up to date',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    SizedBox(height: 8),
                    Text(
                      'This repeater already runs exactly this image. Nothing '
                      'was staged or changed.',
                      style: TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_paused) ...[
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.pause_circle_outline,
                            color: OtaTheme.accent),
                        SizedBox(width: 10),
                        Text('Update paused',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'The repeater kept the part it already received, and '
                      'the firmware is still on this device. Nothing was '
                      'applied. Continue any time from the Connect screen. '
                      'Only the missing part will be sent.',
                      style: TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_error != null) ErrorBanner(_error!),
          if (phase == UpdatePhase.failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(backIcon),
                label: const Text('Back'),
              ),
            ),
          const SectionHeader('Log'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              height: 180,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: OtaTheme.surfaceHigh),
              ),
              child: Scrollbar(
                controller: _logController,
                child: ListView.builder(
                  controller: _logController,
                  itemCount: app.log.length,
                  itemBuilder: (context, index) => Text(
                    app.log[index],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: Color(0xFF9FE8B5),
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _buildFooter(context, app, phase),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context, AppState app, UpdatePhase phase) {
    if (_paused) {
      return FilledButton.icon(
        onPressed: () => Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ResumeScreen()),
          (route) => route.isFirst,
        ),
        icon: const Icon(playIcon),
        label: const Text('Continue update'),
      );
    }
    if (_stopped || app.compareError != null) {
      return FilledButton.icon(
        onPressed: _retry,
        icon: const Icon(playIcon),
        label: const Text('Compare again'),
      );
    }
    switch (phase) {
      case UpdatePhase.comparing:
        return OutlinedButton.icon(
          onPressed: app.stopComparison,
          icon: const Icon(stopIcon),
          label: const Text('Stop'),
        );
      case UpdatePhase.upToDate:
        return FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(backIcon),
          label: const Text('Back'),
        );
      case UpdatePhase.transferring:
      case UpdatePhase.staging:
      case UpdatePhase.probing:
        return OutlinedButton.icon(
          onPressed: () => context.read<AppState>().requestCancel(),
          icon: const Icon(pauseIcon),
          label: const Text('Pause'),
        );
      case UpdatePhase.readyToApply:
        return FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const VerifyScreen()),
          ),
          icon: const Icon(playIcon),
          label: const Text('Commit update'),
        );
      case UpdatePhase.done:
        return FilledButton.icon(
          onPressed: () => Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const VerifyScreen()),
            (route) => route.isFirst,
          ),
          icon: const Icon(nextIcon),
          label: const Text('See verification'),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _stepRow({
    required String label,
    required _StepState state,
    double? value,
  }) {
    final color = switch (state) {
      _StepState.pending => OtaTheme.textMuted,
      _StepState.active => OtaTheme.accent,
      _StepState.ok => OtaTheme.ok,
    };
    final indicator = switch (state) {
      _StepState.pending => const Icon(Icons.radio_button_unchecked, size: 18),
      _StepState.active => SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            value: value,
            strokeWidth: 2.5,
            color: OtaTheme.accent,
            backgroundColor: OtaTheme.surfaceHigh,
          ),
        ),
      _StepState.ok => const Icon(Icons.check_circle, size: 18),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          SizedBox(width: 18, height: 18, child: indicator),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: TextStyle(color: color, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  /// A step is done once the flow has moved past it. `failed` and `upToDate`
  /// sit after the normal steps in the enum but must not mark them all done.
  static bool _stepDone(UpdatePhase marker, UpdatePhase phase) {
    if (phase == UpdatePhase.upToDate) return marker == UpdatePhase.comparing;
    if (phase == UpdatePhase.failed || phase == UpdatePhase.idle) return false;
    return phase.index >= marker.index;
  }

  static String _fmtBytes(int value) => value >= 1024 * 1024
      ? '${(value / (1024 * 1024)).toStringAsFixed(2)} MB'
      : '${(value / 1024).toStringAsFixed(0)} KB';

  /// One short suffix on the same line as the sent and re-send counts.
  static String _etaSuffix(TransferProgress progress) {
    // On a resume the node's watermark includes work done before this run,
    // while elapsed starts at zero. Only ops applied since the resume may be
    // used to measure the rate, or the ETA assumes that prefix was instant.
    final applied = progress.opsThisRun ?? progress.opsApplied;
    if (applied == null || applied < 4 || progress.elapsed.inSeconds < 5) {
      return ' · Measuring time left…';
    }
    final rate = applied / progress.elapsed.inSeconds;
    final remainingOps = (progress.opsTotal - (progress.opsApplied ?? applied))
        .clamp(0, progress.opsTotal);
    final remaining = Duration(seconds: (remainingOps / rate).ceil());
    return ' · ${_etaText(remaining)} left';
  }

  static String _etaText(Duration d) {
    if (d.inMinutes < 2) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }
}

enum _StepState { pending, active, ok }
