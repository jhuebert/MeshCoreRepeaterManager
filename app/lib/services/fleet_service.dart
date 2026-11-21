import 'package:mesh_protocol/mesh_protocol.dart';

import 'cli_service.dart';

/// Fleet configuration on one repeater. The PSK is never read back: the
/// firmware only reports the derived channel hash.
class FleetService {
  FleetService(this.cli, this.target);

  final CliService cli;
  final Contact target;

  Future<String?> status() async {
    final reply = await cli.read(target, 'fleet');
    return reply.ok ? reply.text : null;
  }

  Future<List<String>> tags() async {
    final reply = await cli.read(target, 'fleet tag list');
    if (!reply.ok) return const [];
    final text = reply.value.trim();
    if (text.isEmpty || text.startsWith('(none)')) return const [];
    final list = text.replaceFirst(RegExp(r'^tags:\s*'), '');
    return list.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  }

  Future<CliReply> write(String command) =>
      cli.write(target, command, family: 'fleet');

  /// Report whether a job ran on this node. Used for a single-node check, not
  /// as a substitute for per-node ACKs.
  Future<bool?> seen(String key) async {
    final reply = await cli.read(target, 'fleet seen $key');
    if (!reply.ok) return null;
    return reply.text.toLowerCase().contains('seen');
  }
}
