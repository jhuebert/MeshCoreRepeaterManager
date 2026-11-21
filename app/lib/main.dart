import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'shell/app_shell.dart';
import 'shell/routes.dart';
import 'theme.dart';

/// Entry point. Long-running work (LoRa transfers, fleet jobs, ACK windows and
/// WiFi uploads) holds a foreground service so the app survives screen-off.
/// The stub callback below never runs; work stays in the main isolate.
@pragma('vm:entry-point')
void transferServiceEntry() {}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'meshcore_repeater_manager_transfer',
      channelName: 'Background operations',
      channelDescription:
          'Keeps firmware transfers, fleet jobs and WiFi uploads alive while the screen is off.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
      // TCP companions are common here; keep the Wi-Fi on screen-off too.
      allowWifiLock: true,
    ),
  );
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..initServices(),
      child: const MeshCoreRepeaterManagerApp(),
    ),
  );
}

class MeshCoreRepeaterManagerApp extends StatelessWidget {
  const MeshCoreRepeaterManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshCoreRepeaterManager',
      debugShowCheckedModeBanner: false,
      theme: OtaTheme.dark,
      home: const AppShell(),
      onGenerateRoute: generateRoute,
    );
  }
}
