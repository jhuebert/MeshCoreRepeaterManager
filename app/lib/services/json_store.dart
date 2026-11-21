import 'dart:convert';
import 'dart:io';

/// Thrown when a file was written by a newer schema than this app understands.
/// Callers surface it instead of overwriting data they cannot read.
class SchemaTooNewException implements Exception {
  const SchemaTooNewException(this.path, this.found, this.supported);

  final String path;
  final int found;
  final int supported;

  @override
  String toString() => 'Unsupported schema $found in $path (max $supported)';
}

/// Shared atomic, schema-versioned JSON file handling. Every persistent store
/// uses this so migrations and crash-safe writes behave the same way.
class VersionedJsonStore {
  VersionedJsonStore(
    this.file, {
    required this.schema,
    this.migrate,
  });

  final File file;
  final int schema;

  /// Receives the raw map and its stored schema (0 when absent). Returns the
  /// current shape; `schema` is added by [read].
  final Map<String, dynamic> Function(Map<String, dynamic> raw, int from)?
      migrate;

  Future<Map<String, dynamic>?> read() async {
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final raw = Map<String, dynamic>.from(decoded);
    final stored = raw['schema'] is int ? raw['schema'] as int : 0;
    if (stored > schema) {
      throw SchemaTooNewException(file.path, stored, schema);
    }
    if (stored == schema) return raw;
    final migrated = migrate?.call(raw, stored) ?? raw;
    return <String, dynamic>{...migrated, 'schema': schema};
  }

  /// Serialize writes to the same file. Two stores can legitimately write at once
  /// (a fleet job and its first ACK, or a queued job firing), and both would
  /// otherwise race on the shared `.tmp` rename.
  static final Map<String, Future<void>> _pendingWrites = {};

  Future<void> write(Map<String, dynamic> data) {
    final previous = _pendingWrites[file.path] ?? Future.value();
    final next = previous.then((_) async {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, dynamic>{...data, 'schema': schema}),
        flush: true,
      );
      await tmp.rename(file.path);
    });
    _pendingWrites[file.path] = next.catchError((_) {});
    return next;
  }
}
