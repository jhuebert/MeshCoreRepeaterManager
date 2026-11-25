import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path/path.dart' as p;

/// Pseudo-environment for a `.bin` whose name does not carry a build
/// environment (a custom build, or the file a node already runs). The image's
/// SHA-256 is its identity; the node's own reported target id is what an
/// update is armed for.
const customEnvironment = 'custom';

/// One image in the offline library.
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.fileName,
    required this.env,
    required this.version,
    required this.origin,
    required this.size,
    required this.sha256,
    required this.added,
  });

  /// The file stem. Release images use their SHA-256; imports hash the file
  /// name together with the bytes so two files with identical content can
  /// still appear as two rows in the Imported tab.
  final String id;
  final String fileName;

  final String env;
  final String version;

  /// 'github' | 'import' — anything not 'github' is a local import.
  final String origin;

  final int size;
  final String sha256;
  final DateTime added;
}

/// Persistent local firmware library. Every entry is `<id>.bin` plus an
/// `<id>.json` sidecar with env/version/origin metadata. Images land here only
/// from an explicit download or an explicit .bin import; nothing is uploaded
/// implicitly. The matchers below are legacy helpers retained for their tests:
/// the app no longer needs a local image to compute a diff, so no delta-base
/// lookup has a production caller.
class FirmwareLibrary {
  FirmwareLibrary(this.directory);

  final Directory directory;

  /// `<appSupport>/ota_library`.
  static Future<FirmwareLibrary> open(Directory supportDir) async {
    final dir = Directory(p.join(supportDir.path, 'ota_library'));
    await dir.create(recursive: true);
    return FirmwareLibrary(dir);
  }

  Future<List<LibraryEntry>> list() async {
    final out = <LibraryEntry>[];
    if (!await directory.exists()) return out;
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final entry = await _readEntry(file);
      if (entry != null) out.add(entry);
    }
    out.sort((a, b) => b.added.compareTo(a.added));
    return out;
  }

  /// Legacy matcher: finds an entry whose SHA-256 is [runningSha256] (the
  /// `OP_INFO` handshake's full SHA-256). The app has no production caller:
  /// the repeater hashes its own image for the diff, so no local base is used.
  /// Retained for the library tests.
  Future<LibraryEntry?> findBaseForSha(List<int> runningSha256) async {
    final id = bytesToHex(runningSha256);
    for (final entry in await list()) {
      if (entry.sha256 == id) return entry;
    }
    return null;
  }

  /// Find a saved image whose SHA-256 starts with [shaPrefix]. `ota status`
  /// reports only the first 16 hex characters (8 bytes) of the running image
  /// hash; a byte match identifies the node's running build even when OP_INFO
  /// never answered. All-zero means "the node could not hash its image".
  Future<LibraryEntry?> findByShaPrefix(String shaPrefix) async {
    final prefix = shaPrefix.trim().toLowerCase();
    if (prefix.length < 16 || RegExp(r'[^0-9a-f]').hasMatch(prefix)) {
      return null;
    }
    if (prefix.replaceAll('0', '').isEmpty) return null;
    for (final entry in await list()) {
      if (entry.sha256.toLowerCase().startsWith(prefix)) return entry;
    }
    return null;
  }

  /// As [findByShaPrefix], but only when the matching image has a board name.
  /// A hash match against a renamed `.bin` tells us the running bytes, not
  /// which build environment produced them, so it cannot name a target id.
  Future<LibraryEntry?> findByShaPrefixWithBoard(String shaPrefix) async {
    final entry = await findByShaPrefix(shaPrefix);
    if (entry == null) return null;
    if (entry.env == customEnvironment || entry.env == 'unknown') return null;
    return entry;
  }

  /// Legacy matcher: finds an entry with the same env and [runningVersion]
  /// stamp. Unused by the app since the repeater started hashing its own
  /// running image for the comparison. Retained for the library tests.
  Future<LibraryEntry?> findBaseFor(
      {required String env, required String runningVersion}) async {
    for (final entry in await list()) {
      if (entry.env == env && entry.version == runningVersion) return entry;
    }
    return null;
  }

  Future<LibraryEntry> importBytes(
    Uint8List bytes, {
    required String env,
    required String version,
    required String origin,
    String? fileName,
  }) async {
    final sha = sha256.convert(bytes).toString();
    final name = fileName ?? '$env-$version.bin';
    // Releases are identified by content so the same version is saved once.
    // Imports are identified by the file as well: importing a second .bin
    // with identical bytes must not silently replace the first one.
    final id = origin == 'github'
        ? sha
        : sha256.convert(utf8.encode('$name|$sha')).toString();
    final binFile = File(p.join(directory.path, '$id.bin'));
    if (!await binFile.exists()) {
      await binFile.writeAsBytes(bytes, flush: true);
    }
    final entry = LibraryEntry(
      id: id,
      fileName: name,
      env: env,
      version: version,
      origin: origin,
      size: bytes.length,
      sha256: sha,
      added: DateTime.now(),
    );
    await _writeEntry(entry);
    return entry;
  }

  Future<Uint8List> read(LibraryEntry entry) =>
      File(p.join(directory.path, '${entry.id}.bin')).readAsBytes();

  Future<void> delete(LibraryEntry entry) async {
    await _deleteQuietly(File(p.join(directory.path, '${entry.id}.bin')));
    await _deleteQuietly(File(p.join(directory.path, '${entry.id}.json')));
  }

  // --- internals -----------------------------------------------------------

  Future<LibraryEntry?> _readEntry(File jsonFile) async {
    try {
      final e =
          jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
      final id = p.basenameWithoutExtension(jsonFile.path);
      final binFile = File(p.join(directory.path, '$id.bin'));
      if (!await binFile.exists()) return null; // orphaned sidecar
      return LibraryEntry(
        id: id,
        fileName: e['fileName'] as String? ?? '$id.bin',
        env: e['env'] as String? ?? 'unknown',
        version: e['version'] as String? ?? 'unknown',
        origin: e['origin'] as String? ?? 'unknown',
        size: (e['size'] as num?)?.toInt() ?? (await binFile.length()),
        sha256: e['sha256'] as String? ?? id,
        added: DateTime.tryParse(e['added'] as String? ?? '') ??
            (await binFile.lastModified()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeEntry(LibraryEntry entry) async {
    final json = {
      'fileName': entry.fileName,
      'env': entry.env,
      'version': entry.version,
      'origin': entry.origin,
      'size': entry.size,
      'sha256': entry.sha256,
      'added': entry.added.toIso8601String(),
    };
    await File(p.join(directory.path, '${entry.id}.json'))
        .writeAsString(jsonEncode(json), flush: true);
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }
}
