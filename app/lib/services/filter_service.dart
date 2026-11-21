import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:repeater_core/repeater_core.dart';

import 'cli_service.dart';

/// All filter CLI exchanges, parsed into models. Reads are idempotent and
/// retry once; writes go through the audited CLI service.
class FilterService {
  FilterService(this.cli, this.target);

  final CliService cli;
  final Contact target;

  Future<FilterStatus?> status() async {
    final reply = await cli.read(target, 'filter');
    if (!reply.ok) return null;
    return FilterStatus.parse(reply.text);
  }

  /// Read every page. A listing cut for space ends with `...`; the parser
  /// supplies the next index so nothing is silently truncated.
  Future<List<FilterRule>> allRules() async {
    final rules = <FilterRule>[];
    var start = 0;
    for (var page = 0; page < 16; page++) {
      final reply = await cli.read(target, 'filter list $start');
      if (!reply.ok) break;
      final parsed = parseFilterList(reply.text);
      rules.addAll(parsed.rules);
      final next = parsed.nextIndex;
      if (next == null || next <= start) break;
      start = next;
    }
    return rules;
  }

  Future<FilterStats?> stats() async {
    final reply = await cli.read(target, 'filter stats');
    if (!reply.ok) return null;
    return FilterStats.parse(reply.text);
  }

  Future<CliReply> write(String command) =>
      cli.write(target, command, family: 'filter');
}
