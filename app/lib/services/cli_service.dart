import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:repeater_core/repeater_core.dart';

import 'management_audit_store.dart';

/// The text of a CLI reply and what it means. A timed-out exchange has an
/// empty [text] and kind `unknown`: it must be re-read, never reported as a
/// successful write.
class CliReply {
  const CliReply(this.text, this.kind);

  final String text;
  final CliReplyKind kind;

  String get value => getReplyValue(text);
  bool get ok => kind == CliReplyKind.ok || kind == CliReplyKind.rebootNeeded;
}

/// Function shapes matched by `CompanionClient.remoteCli` and
/// `RepeaterReqClient.request`, so this service needs no adapter classes and
/// tests can inject pure fakes.
typedef CliExchange = Future<String> Function(
  Contact target,
  String command, {
  Duration timeout,
});

typedef BinaryExchange = Future<Uint8List> Function(
  Contact target,
  int reqType, {
  List<int> data,
  required int exactLength,
  Duration timeout,
});

typedef RawBinaryExchange = Future<Uint8List> Function(
  Contact target,
  int reqType, {
  List<int> data,
  Duration timeout,
});

/// Owns every management exchange with the repeater. The companion client is
/// not concurrency-safe, so CLI and binary requests share one queue.
class CliService {
  CliService({
    required this.exchange,
    required this.binary,
    this.rawBinary,
    this.audit,
    this.repeaterKeyHex,
  });

  final CliExchange exchange;
  final BinaryExchange binary;
  final RawBinaryExchange? rawBinary;
  final ManagementAuditStore? audit;
  String? repeaterKeyHex;

  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Idempotent reads get one retry after a lost reply. A second loss is
  /// reported as unknown rather than guessed.
  Future<CliReply> read(
    Contact target,
    String command, {
    Duration timeout = const Duration(seconds: 45),
    bool retry = true,
  }) =>
      _serial(() async {
        for (var attempt = 0; attempt < (retry ? 2 : 1); attempt++) {
          try {
            final text = await exchange(target, command, timeout: timeout);
            return CliReply(text, classifyCliReply(text));
          } on CompanionTimeoutException catch (e) {
            if (attempt == 1) return CliReply(e.message, CliReplyKind.unknown);
          } on CompanionException catch (e) {
            return CliReply(e.message, CliReplyKind.error);
          }
        }
        return const CliReply('', CliReplyKind.unknown);
      });

  /// A write is always audited, including when its reply was lost. [family]
  /// groups commands in the audit log (settings, radio, access, ...).
  Future<CliReply> write(
    Contact target,
    String command, {
    required String family,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final reply = await read(target, command, timeout: timeout, retry: false);
    final outcome = switch (reply.kind) {
      CliReplyKind.ok => AuditOutcome.ok,
      CliReplyKind.rebootNeeded => AuditOutcome.rebootNeeded,
      CliReplyKind.error => AuditOutcome.error,
      CliReplyKind.unknown => AuditOutcome.unknown,
    };
    await audit?.record(
      command,
      repeaterKeyHex: repeaterKeyHex ?? target.publicKeyHex,
      family: family,
      replyKind: reply.kind.name,
      outcome: outcome,
    );
    return reply;
  }

  /// Apply several `set` commands in order, returning a per-key result so a
  /// partial failure can be retried without repeating the whole batch.
  Future<Map<String, CliReply>> saveSettings(
    Contact target,
    Map<String, String> values, {
    required String family,
  }) async {
    final results = <String, CliReply>{};
    for (final entry in values.entries) {
      results[entry.key] = await write(
          target, 'set ${entry.key} ${entry.value}',
          family: family);
    }
    return results;
  }

  /// One binary REQ instead of a dozen CLI `get` calls.
  Future<RepeaterStatus?> status(
    Contact target, {
    Duration timeout = const Duration(seconds: 10),
  }) =>
      _serial(() async {
        try {
          final payload = await binary(
            target,
            reqTypeGetStatus,
            exactLength: RepeaterStatus.reportLength,
            timeout: timeout,
          );
          return parseStatusReport(payload);
        } on RepeaterRequestException {
          return null;
        }
      });

  Future<Uint8List?> _raw(
    Contact target,
    int reqType,
    List<int> data, {
    Duration timeout = const Duration(seconds: 10),
  }) =>
      _serial(() async {
        try {
          return await rawBinary!(target, reqType,
              data: data, timeout: timeout);
        } on RepeaterRequestException {
          return null;
        }
      });

  Future<List<AclEntry>?> accessList(Contact target) async {
    final payload = await _raw(target, 0x05, accessListRequest);
    return payload == null ? null : parseAccessList(payload);
  }

  Future<NeighborPage?> neighbours(
    Contact target, {
    int count = 16,
    int offset = 0,
    NeighborOrder order = NeighborOrder.newest,
    int prefixLength = 6,
  }) async {
    final request = buildNeighboursRequest(
      count: count,
      offset: offset,
      order: order,
      prefixLength: prefixLength,
      nonce: DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF,
    );
    final payload = await _raw(target, 0x06, request);
    return payload == null
        ? null
        : parseNeighbours(payload, prefixLength: prefixLength);
  }

  Future<OwnerInfo?> owner(Contact target) async {
    final payload = await _raw(target, 0x07, const []);
    return payload == null ? null : OwnerInfo.parse(payload);
  }
}
