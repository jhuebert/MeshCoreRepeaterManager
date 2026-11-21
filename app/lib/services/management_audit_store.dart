import 'dart:convert';
import 'dart:io';

import 'json_store.dart';

/// Outcome of a management write. A lost reply is `unknown`, never success.
enum AuditOutcome { ok, rebootNeeded, error, unknown }

class AuditEntry {
  const AuditEntry({
    required this.at,
    required this.repeaterKeyHex,
    required this.family,
    required this.command,
    required this.kind,
    required this.outcome,
  });

  final DateTime at;
  final String repeaterKeyHex;
  final String family;
  final String command;
  final String kind;
  final AuditOutcome outcome;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'repeaterKeyHex': repeaterKeyHex,
        'family': family,
        'command': command,
        'kind': kind,
        'outcome': outcome.name,
      };

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
        at: DateTime.tryParse(json['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        repeaterKeyHex: json['repeaterKeyHex'] as String? ?? '',
        family: json['family'] as String? ?? '',
        command: json['command'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        outcome:
            AuditOutcome.values.byName(json['outcome'] as String? ?? 'unknown'),
      );
}

/// Local-only, bounded log of management writes. Reads and single refreshes
/// are deliberately not recorded. Secrets are redacted before an entry is
/// stored, so export is safe to share.
class ManagementAuditStore {
  ManagementAuditStore(this.file, {this.persist = true});

  static const maxEntries = 1000;

  final File file;

  /// In-memory mode for widget tests; real I/O stalls the fake-async zone.
  final bool persist;
  late final VersionedJsonStore _store = VersionedJsonStore(
    file,
    schema: 1,
    migrate: (raw, from) => {'entries': raw['entries'] ?? const []},
  );
  List<AuditEntry> _entries = [];

  Future<void> load() async {
    if (!persist) return;
    final data = await _store.read() ?? const <String, dynamic>{};
    _entries = ((data['entries'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => AuditEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  List<AuditEntry> entries({String? repeaterKeyHex, int? limit}) {
    var out = _entries.reversed.toList();
    if (repeaterKeyHex != null) {
      final key = repeaterKeyHex.toLowerCase();
      out = out.where((e) => e.repeaterKeyHex.toLowerCase() == key).toList();
    }
    return limit == null ? out : out.take(limit).toList();
  }

  Future<void> record(
    String command, {
    required String repeaterKeyHex,
    required String family,
    required String replyKind,
    required AuditOutcome outcome,
    DateTime? at,
  }) async {
    _entries.add(AuditEntry(
      at: at ?? DateTime.now(),
      repeaterKeyHex: repeaterKeyHex,
      family: family,
      command: redactCommand(command),
      kind: replyKind,
      outcome: outcome,
    ));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    await _persist();
  }

  /// Export before old entries roll off. Already redacted at write time.
  String export() => const JsonEncoder.withIndent('  ')
      .convert(entries().map((e) => e.toJson()).toList());

  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }

  Future<void> _persist() async {
    if (!persist) return;
    await _store.write({
      'entries': _entries.map((e) => e.toJson()).toList(),
    });
  }

  /// Mask values of commands that carry credentials. Applied before anything
  /// reaches disk, so a later export cannot leak them.
  static String redactCommand(String command) {
    var out = command;
    final secretKeys = [
      'password',
      'guest.password',
      'wifi.pwd',
      'prv.key',
      'mqtt.password',
      'mqtt.token',
      'mqtt1.password',
      'mqtt1.token',
      'mqtt2.password',
      'mqtt2.token',
    ];
    for (final key in secretKeys) {
      final escaped = RegExp.escape(key);
      out = out.replaceAllMapped(
        RegExp('(set\\s+$escaped\\s+)(\\S+)', caseSensitive: false),
        (m) => '${m.group(1)}[redacted]',
      );
      out = out.replaceAllMapped(
        RegExp('(^|\\s)$escaped([= ]+)(\\S+)', caseSensitive: false),
        (m) => '${m.group(1)}$key${m.group(2)}[redacted]',
      );
    }
    return out;
  }
}
