import 'package:repeater_core/repeater_core.dart';

/// Sends one settings change to a tag-defined group. There is deliberately no
/// per-repeater login or contact picker: the target is a group, not a node.
class BulkSettingsController {
  BulkSettingsController({
    required this.send,
    required this.audit,
  });

  final Future<void> Function(String script, String id) send;
  final Future<void> Function(String id, String script) audit;

  /// Build one job for all settings, or one job per setting with distinct ids
  /// so the actual reply for each setting comes back.
  List<FleetJob> build({
    required Map<String, String> values,
    required bool oneScriptPerSetting,
    required List<String> tags,
    required bool ack,
    int? at,
  }) {
    final lines = bulkSetLines(values);
    if (lines.isEmpty) return const [];
    final now = DateTime.now();
    if (!oneScriptPerSetting) {
      return [
        FleetJob(
          id: 'bulk-${_stamp(now)}',
          tags: tags,
          ack: ack,
          at: at,
          commands: lines,
        ),
      ];
    }
    var i = 0;
    return [
      for (final line in lines)
        FleetJob(
          id: 'bulk-${_stamp(now)}-${++i}',
          tags: tags,
          ack: ack,
          at: at,
          commands: [line],
        ),
    ];
  }

  Future<void> apply(Iterable<FleetJob> jobs) async {
    for (final job in jobs) {
      final script = composeJob(job);
      if (scriptBytes(script) > FleetJob.byteLimit) {
        throw ArgumentError('Script for ${job.id} exceeds the byte limit');
      }
      await audit(job.id, script);
      await send(script, job.id);
    }
  }

  static String _stamp(DateTime now) => now
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:T.]'), '')
      .substring(0, 14);
}
