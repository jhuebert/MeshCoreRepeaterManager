import 'package:flutter/material.dart';

import '../screens/connect_screen.dart';
import '../screens/firmware_screen.dart';
import '../screens/management/acl_screen.dart';
import '../screens/management/browser_screen.dart';
import '../screens/management/charts_screen.dart';
import '../screens/management/cli_screen.dart';
import '../screens/management/filter_rule_editor_screen.dart';
import '../screens/management/filter_screen.dart';
import '../screens/management/fleet_screen.dart';
import '../screens/management/audit_log_screen.dart';
import '../screens/management/diagnostics_screen.dart';
import '../screens/management/fork_extras_screen.dart';
import '../screens/management/identity_key_screen.dart';
import '../screens/management/mqtt_screen.dart';
import '../screens/management/operations_screen.dart';
import '../screens/management/wifi_ota_screen.dart';
import '../screens/management/neighbors_screen.dart';
import '../screens/management/settings_screen.dart';
import '../screens/management/status_screen.dart';

/// Named entry points for activities pushed from the shell. The update keeps
/// its own in-activity wizard navigation; this only opens the activity.
class AppRoutes {
  static const update = '/update';
  static const library = '/library';
  static const status = '/status';
  static const settings = '/settings';
  static const browser = '/browser';
  static const cli = '/cli';
  static const acl = '/acl';
  static const neighbors = '/neighbors';
  static const stats = '/stats';
  static const filter = '/filter';
  static const filterEditor = '/filter-editor';
  static const fleet = '/fleet';
  static const mqtt = '/mqtt';
  static const wifiOta = '/wifi-ota';
  static const extras = '/extras';
  static const operations = '/operations';
  static const diagnostics = '/diagnostics';
  static const audit = '/audit';
  static const identity = '/identity';
}

Route<dynamic>? generateRoute(RouteSettings settings) =>
    switch (settings.name) {
      AppRoutes.update => MaterialPageRoute(
          builder: (_) => const ConnectScreen(), settings: settings),
      AppRoutes.library => MaterialPageRoute(
          builder: (_) => const FirmwareScreen(updateMode: false),
          settings: settings),
      AppRoutes.status => MaterialPageRoute(
          builder: (_) => const RepeaterStatusScreen(), settings: settings),
      AppRoutes.settings => MaterialPageRoute(
          builder: (_) => const RepeaterSettingsScreen(), settings: settings),
      AppRoutes.browser => MaterialPageRoute(
          builder: (_) => const SettingBrowserScreen(), settings: settings),
      AppRoutes.cli => MaterialPageRoute(
          builder: (_) => const CliScreen(), settings: settings),
      AppRoutes.acl => MaterialPageRoute(
          builder: (_) => const AdminAclScreen(), settings: settings),
      AppRoutes.neighbors => MaterialPageRoute(
          builder: (_) => const NeighborsScreen(), settings: settings),
      AppRoutes.stats => MaterialPageRoute(
          builder: (_) => const StatsChartsScreen(), settings: settings),
      AppRoutes.filter => MaterialPageRoute(
          builder: (_) => const FilterScreen(), settings: settings),
      AppRoutes.filterEditor => MaterialPageRoute(
          builder: (_) => const FilterRuleEditorScreen(), settings: settings),
      AppRoutes.fleet => MaterialPageRoute(
          builder: (_) => const FleetScreen(), settings: settings),
      AppRoutes.mqtt => MaterialPageRoute(
          builder: (_) => const MqttScreen(), settings: settings),
      AppRoutes.wifiOta => MaterialPageRoute(
          builder: (_) => const WifiOtaScreen(), settings: settings),
      AppRoutes.extras => MaterialPageRoute(
          builder: (_) => const ForkExtrasScreen(), settings: settings),
      AppRoutes.operations => MaterialPageRoute(
          builder: (_) => const OperationsScreen(), settings: settings),
      AppRoutes.diagnostics => MaterialPageRoute(
          builder: (_) => const DiagnosticsScreen(), settings: settings),
      AppRoutes.audit => MaterialPageRoute(
          builder: (_) => const AuditLogScreen(), settings: settings),
      AppRoutes.identity => MaterialPageRoute(
          builder: (_) => const IdentityKeyScreen(), settings: settings),
      _ => null,
    };
