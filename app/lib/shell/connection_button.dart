import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import 'connection_sheet.dart';

/// Connection state is a global concern, so the indicator lives in the shell's
/// top bar on every destination.
class ConnectionButton extends StatelessWidget {
  const ConnectionButton({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final (label, color) = switch (app.connectionPhase) {
      ConnectionPhase.connected => ('Connected', OtaTheme.ok),
      ConnectionPhase.connecting => ('Connecting', OtaTheme.warn),
      ConnectionPhase.disconnected => ('Offline', OtaTheme.textMuted),
    };
    return Tooltip(
      message: 'Connection: $label. Open connection details.',
      child: TextButton.icon(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => const ConnectionSheet(),
        ),
        icon: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        label: Text(label),
      ),
    );
  }
}
