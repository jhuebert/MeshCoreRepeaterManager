import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'firmware_screen.dart';

/// Step 3: prove the app may administer the node, and read its capabilities.
///
/// A password is optional. The repeater treats a blank login as "is this key
/// already an admin on my list?", so a companion that is already an admin
/// needs no password at all — the field says so instead of refusing an
/// empty value.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _password;

  @override
  void initState() {
    super.initState();
    _password =
        TextEditingController(text: context.read<AppState>().adminPassword);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      // Board detection needs the catalog's environment names; fetch it now
      // so the picker's board is already known on the next screen.
      if (app.catalog == null && !app.catalogLoading) app.loadCatalog();
      app.refreshLibrary();
    });
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.target;
    final status = app.nodeStatus;
    final board = app.detectedBoard;
    final radio2 = app.radio2Enabled;
    final canWifiOnly =
        status == null && app.wifiOnlyMode && app.wifiUploadSupported;

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 3, label: 'Sign in'),
          const SectionHeader('Target'),
          InfoRow(
            label: 'Node',
            value: target == null
                ? '(none chosen)'
                : (target.name.isNotEmpty ? target.name : '(unnamed)'),
            mono: false,
          ),
          InfoRow(
            label: 'Status',
            value: status == null
                ? 'not checked yet'
                : (status.running.isEmpty ? 'checked' : 'signed in'),
            mono: false,
          ),
          if (status == null) ...[
            const SectionHeader('Admin login'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Sign in to read the repeater’s firmware state and '
                        'allow an update.',
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Admin password (optional)',
                          isDense: true,
                          helperText:
                              'Leave blank if this companion is already an '
                              'admin on the repeater.',
                          helperMaxLines: 2,
                        ),
                        onChanged: (v) => app.adminPassword = v,
                        onSubmitted: (_) => _check(app),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (app.probeError != null) ErrorBanner(app.probeError!),
          if (status == null && app.boardReply != null)
            InfoRow(label: 'Board', value: app.boardReply!, mono: false),
          if (status != null) ...[
            const SectionHeader('Node status'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Column(
                  children: [
                    InfoRow(label: 'Firmware', value: status.running),
                    InfoRow(label: 'State', value: status.state.name),
                    InfoRow(
                        label: 'Board',
                        value: board ??
                            (app.nodeInfo == null
                                ? 'unknown'
                                : 'custom build. Import the image on the '
                                    'next step'),
                        mono: board != null),
                    if (radio2 != null)
                      InfoRow(
                        label: 'radio2',
                        value: radio2 ? 'enabled' : 'off',
                        mono: false,
                      ),
                    if (!status.ok)
                      InfoRow(
                          label: 'Last error',
                          value: 'err=${status.err}',
                          mono: false),
                  ],
                ),
              ),
            ),
            if (board == null && app.nodeInfo != null)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'This repeater runs a custom build the app does not know. '
                  'Import the image you want to install on the next step.',
                  style: TextStyle(
                      color: OtaTheme.warn, fontSize: 12, height: 1.45),
                ),
              ),
          ],
        ],
      ),
      bottomNavigationBar: WizardFooter(
        label: status == null
            ? (canWifiOnly ? 'WiFi update' : 'Sign in')
            : 'Choose firmware',
        busy: app.probing,
        onPressed: status == null
            ? (app.probing || target == null ? null : () => _check(app))
            : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FirmwareScreen()),
                ),
        hint: status == null && target == null
            ? 'Pick a repeater first.'
            : canWifiOnly
                ? 'This firmware uses the built-in WiFi update page.'
                : null,
      ),
    );
  }

  Future<void> _check(AppState app) async {
    FocusScope.of(context).unfocus();
    await app.probe();
    if (!mounted) return;
    if (app.nodeStatus != null ||
        (app.wifiOnlyMode && app.wifiUploadSupported)) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const FirmwareScreen()),
      );
    }
  }
}
