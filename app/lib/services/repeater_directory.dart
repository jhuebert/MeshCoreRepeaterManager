import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:repeater_core/repeater_core.dart';

import 'json_store.dart';
import 'repeater_cache_store.dart';

/// A locally saved repeater. No secrets live here: the admin password is
/// session-only and cached settings never include credentials.
class RepeaterProfile {
  const RepeaterProfile({
    required this.publicKeyHex,
    this.name = '',
    this.tags = const [],
    this.lastSeen,
    this.notes = '',
    this.batteryChemistry = '',
    this.capabilities,
  });

  final String publicKeyHex;
  final String name;
  final List<String> tags;
  final DateTime? lastSeen;
  final String notes;
  final String batteryChemistry;
  final RepeaterCapabilities? capabilities;

  RepeaterProfile copyWith({
    String? publicKeyHex,
    String? name,
    List<String>? tags,
    DateTime? lastSeen,
    String? notes,
    String? batteryChemistry,
    RepeaterCapabilities? capabilities,
  }) =>
      RepeaterProfile(
        publicKeyHex: publicKeyHex ?? this.publicKeyHex,
        name: name ?? this.name,
        tags: tags ?? this.tags,
        lastSeen: lastSeen ?? this.lastSeen,
        notes: notes ?? this.notes,
        batteryChemistry: batteryChemistry ?? this.batteryChemistry,
        capabilities: capabilities ?? this.capabilities,
      );

  Map<String, dynamic> toJson() => {
        'publicKeyHex': publicKeyHex,
        'name': name,
        'tags': tags,
        'lastSeen': lastSeen?.toIso8601String(),
        'notes': notes,
        'batteryChemistry': batteryChemistry,
        'capabilities': capabilities?.toJson(),
      };

  factory RepeaterProfile.fromJson(Map<String, dynamic> json) =>
      RepeaterProfile(
        publicKeyHex: json['publicKeyHex'] as String,
        name: json['name'] as String? ?? '',
        tags: (json['tags'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        lastSeen: json['lastSeen'] == null
            ? null
            : DateTime.tryParse(json['lastSeen'] as String),
        notes: json['notes'] as String? ?? '',
        batteryChemistry: json['batteryChemistry'] as String? ?? '',
        capabilities: json['capabilities'] == null
            ? null
            : RepeaterCapabilities.fromJson(
                Map<String, dynamic>.from(json['capabilities'] as Map)),
      );
}

/// Saved repeaters and their per-repeater cache folders. Public keys are
/// hashed for directory names so a key never appears in a file path.
class RepeaterDirectory {
  RepeaterDirectory(this.root);

  final Directory root;
  late final VersionedJsonStore _index = VersionedJsonStore(
    File('${root.path}/index.json'),
    schema: 1,
    migrate: _migrateIndex,
  );
  List<RepeaterProfile> _profiles = [];
  Map<String, dynamic> _extra = {};

  Future<void> load() async {
    final data = await _index.read() ?? const <String, dynamic>{};
    _profiles = ((data['profiles'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => RepeaterProfile.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    _extra = Map<String, dynamic>.from(data)..remove('profiles');
  }

  List<RepeaterProfile> get profiles => List.unmodifiable(_profiles);

  RepeaterProfile? get(String publicKeyHex) {
    final key = publicKeyHex.toLowerCase();
    for (final p in _profiles) {
      if (p.publicKeyHex.toLowerCase() == key) return p;
    }
    return null;
  }

  Future<void> upsert(RepeaterProfile profile) async {
    final key = profile.publicKeyHex.toLowerCase();
    final at = profile.lastSeen ?? DateTime.now();
    final stored = profile.copyWith(lastSeen: at);
    _profiles.removeWhere((p) => p.publicKeyHex.toLowerCase() == key);
    _profiles.add(stored);
    await _persist();
    await folderFor(stored.publicKeyHex).create(recursive: true);
    await _profileFile(stored.publicKeyHex)
        .writeAsString(jsonEncode(stored.toJson()), flush: true);
  }

  Future<void> remove(String publicKeyHex) async {
    final key = publicKeyHex.toLowerCase();
    _profiles.removeWhere((p) => p.publicKeyHex.toLowerCase() == key);
    await _persist();
    final dir = folderFor(publicKeyHex);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  RepeaterCacheStore cacheFor(String publicKeyHex) =>
      RepeaterCacheStore(File('${folderFor(publicKeyHex).path}/cache.json'));

  Directory folderFor(String publicKeyHex) =>
      Directory('${root.path}/${_idFor(publicKeyHex)}');

  File _profileFile(String publicKeyHex) =>
      File('${folderFor(publicKeyHex).path}/profile.json');

  /// After `set prv.key` the node has a new identity. Move its folder and
  /// index entry in one operation and leave a pending record so a crash before
  /// the rename can be detected and resumed.
  Future<void> migrateIdentity(String oldHex, String newHex) async {
    await _persist(pending: {
      'old': oldHex,
      'new': newHex,
      'at': DateTime.now().toIso8601String(),
    });
    final oldDir = folderFor(oldHex);
    final newDir = folderFor(newHex);
    if (oldDir.path != newDir.path && oldDir.existsSync()) {
      await newDir.parent.create(recursive: true);
      if (newDir.existsSync()) await newDir.delete(recursive: true);
      await oldDir.rename(newDir.path);
    }
    final profile = get(oldHex);
    if (profile != null) {
      final moved = profile.copyWith(publicKeyHex: newHex);
      _profiles.removeWhere((p) => p.publicKeyHex == profile.publicKeyHex);
      _profiles.add(moved);
      await folderFor(newHex).create(recursive: true);
      await _profileFile(newHex)
          .writeAsString(jsonEncode(moved.toJson()), flush: true);
    }
    _extra.remove('pendingIdentity');
    await _persist();
  }

  Map<String, dynamic>? get pendingIdentity =>
      _extra['pendingIdentity'] as Map<String, dynamic>?;

  /// Finish an identity change interrupted between writing the pending record
  /// and updating the index/folder. The migration is idempotent, so replaying
  /// it is safe even if the folder was already moved. Returns the new key when
  /// a migration was resumed, otherwise null.
  Future<String?> resumePendingIdentity() async {
    final pending = pendingIdentity;
    if (pending == null) return null;
    final old = pending['old']?.toString();
    final next = pending['new']?.toString();
    if (old == null || next == null || old.isEmpty || next.isEmpty) {
      await clearPendingIdentity();
      return null;
    }
    await migrateIdentity(old, next);
    return next;
  }

  Future<void> clearPendingIdentity() async {
    _extra.remove('pendingIdentity');
    await _persist();
  }

  Future<void> _persist({Map<String, dynamic>? pending}) async {
    if (pending != null) _extra['pendingIdentity'] = pending;
    await _index.write({
      'profiles': _profiles.map((p) => p.toJson()).toList(),
      ..._extra,
    });
  }

  static String _idFor(String publicKeyHex) => sha256
      .convert(utf8.encode(publicKeyHex.toLowerCase()))
      .bytes
      .take(4)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  Map<String, dynamic> _migrateIndex(Map<String, dynamic> raw, int from) {
    // Schema 0 was a bare list of profiles.
    final old = raw['profiles'] ?? raw;
    final list = old is List ? old : const [];
    return {
      'profiles': list
          .whereType<Map>()
          .map((e) =>
              RepeaterProfile.fromJson(Map<String, dynamic>.from(e)).toJson())
          .toList(),
    };
  }
}
