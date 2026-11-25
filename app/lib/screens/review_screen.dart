import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/radio_plan.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'transfer_screen.dart';

/// Step 6: a summary of everything chosen, before anything goes on air. The
/// radio plan is chosen on the previous step; the exact comparison runs on the
/// transfer screen, after Start, on that same channel. Start boots nothing —
/// the transfer screen stages into the spare slot and the node only applies
/// anything on the final commit.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.target!;
    final status = app.nodeStatus;
    final imageBytes = app.selectedImage?.length ?? 0;
    final plan = app.radioPlan;
    final planProblem = app.radioPlanProblem;

    return Scaffold(
      appBar: AppBar(title: const Text('Review update')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 6, label: 'Review'),
          const SectionHeader('Companion'),
          InfoRow(
            label: 'Companion',
            value: app.companionName.isNotEmpty
                ? app.companionName
                : '(unnamed companion)',
            mono: false,
          ),
          InfoRow(
            label: 'Connected via',
            value: _connectionLabel(app),
            mono: false,
          ),
          const SectionHeader('Repeater'),
          InfoRow(
            label: 'Repeater',
            value: target.name.isNotEmpty ? target.name : '(unnamed)',
            mono: false,
          ),
          InfoRow(
            label: 'Board',
            value: app.detectedBoard ??
                (app.nodeInfo == null ? 'unknown' : 'custom build'),
            mono: app.detectedBoard != null,
          ),
          InfoRow(
            label: 'Current firmware',
            value: status?.running.isNotEmpty == true ? status!.running : '?',
          ),
          const SectionHeader('This update'),
          InfoRow(label: 'Update to', value: app.selectedVersion ?? '?'),
          InfoRow(
              label: 'Image size', value: formatBytes(imageBytes), mono: false),
          InfoRow(label: 'Radio', value: _radioLabel(app), mono: false),
          if (plan.mode == RadioMode.liveMesh &&
              !target.hasDirectRoute &&
              app.manualRoutePath.trim().isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                'No saved route to this repeater. It only hears requests by '
                'flooding. Set a direct path on the radio step, or use a '
                'private channel.',
                style:
                    TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
              ),
            ),
          const SectionHeader('Warnings'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '• The repeater pauses updates when its battery is low. Charge '
              'or power it first.\n'
              '• Keep the phone in range and the screen on for the whole '
              'transfer.',
              style:
                  TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
      bottomNavigationBar: WizardFooter(
        label: 'Start update',
        icon: playIcon,
        onPressed: planProblem != null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TransferScreen()),
                ),
        hint: planProblem,
      ),
    );
  }

  String _connectionLabel(AppState app) {
    if (app.transportKind == 'tcp') {
      return 'TCP: ${app.tcpHost}:${app.tcpPort}';
    }
    if (app.transportKind == 'ble') {
      return 'Bluetooth';
    }
    return 'Companion';
  }

  String _radioLabel(AppState app) {
    final plan = app.radioPlan;
    switch (plan.mode) {
      case RadioMode.liveMesh:
        final live = app.livePreset;
        final base = live == null ? 'Live mesh' : 'Live mesh (${live.label})';
        final route = app.manualRoutePath.trim();
        return route.isEmpty ? base : '$base, direct override $route';
      case RadioMode.tempRadio:
        return 'Temporary private channel, '
            '${plan.preset?.label ?? '?'} (renews automatically)';
      case RadioMode.radio2:
        return 'The repeater’s second preset, ${plan.preset?.label ?? '?'}';
    }
  }
}
