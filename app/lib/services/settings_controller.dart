import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:repeater_core/repeater_core.dart';

import 'cli_service.dart';
import 'repeater_cache_store.dart';

/// Outcome of one batch save. A key whose reply was lost is kept dirty so it
/// can be retried without re-sending the ones that landed.
class SettingsSaveResult {
  const SettingsSaveResult(this.results, this.failedKeys, this.rebootNeeded);

  final Map<String, CliReply> results;
  final List<String> failedKeys;
  final bool rebootNeeded;

  bool get ok => failedKeys.isEmpty;
}

/// Cache-first settings state with per-key drafts and batch save. Opening a
/// screen reads only the cache; the caller chooses when to refresh from the
/// repeater. Pure app service, no Flutter imports.
class SettingsController {
  SettingsController(this.target, this.cli, this.cache);

  final Contact target;
  final CliService cli;
  final RepeaterCacheStore cache;

  final Map<String, String> _drafts = {};
  final Map<String, String?> _errors = {};
  bool saving = false;

  String? draftFor(String key) => _drafts[key];
  String? errorFor(String key) => _errors[key];
  bool get hasChanges => _drafts.isNotEmpty;
  Set<String> get dirtyKeys => _drafts.keys.toSet();

  /// The current value: an unsaved edit, else the last known cached value.
  String? displayedValue(String key) {
    if (_drafts.containsKey(key)) return _drafts[key];
    final cached = cache.read(key);
    return cached?.value?.toString();
  }

  void setDraft(String key, String value) {
    _drafts[key] = value;
    _errors[key] = settingFor(key)?.validate(value);
  }

  void discard(String key) {
    _drafts.remove(key);
    _errors.remove(key);
  }

  void discardAll() {
    _drafts.clear();
    _errors.clear();
  }

  bool get hasValidationErrors => _errors.values.any((e) => e != null);

  /// Refresh selected keys from the node, one exchange each. A lost or failed
  /// read leaves the cached value in place and marks it stale.
  Future<void> refresh(Iterable<String> keys) async {
    for (final key in keys) {
      final reply = await cli.read(target, 'get $key');
      if (reply.ok) {
        await cache.write(key, reply.value, source: CacheSource.remote);
      } else {
        await cache.markStale(key);
      }
    }
  }

  /// Apply all valid drafts. Cached values are updated optimistically and
  /// rolled back to stale on a refusal or a lost reply.
  Future<SettingsSaveResult> save() async {
    if (saving || _drafts.isEmpty) {
      return const SettingsSaveResult({}, [], false);
    }
    for (final entry in _drafts.entries) {
      _errors[entry.key] = settingFor(entry.key)?.validate(entry.value);
    }
    if (hasValidationErrors) {
      return SettingsSaveResult({}, _drafts.keys.toList(), false);
    }

    saving = true;
    final values = Map<String, String>.from(_drafts);
    try {
      final results =
          await cli.saveSettings(target, values, family: 'settings');
      final failed = <String>[];
      var reboot = false;
      for (final entry in results.entries) {
        final reply = entry.value;
        if (reply.ok) {
          await cache.write(entry.key, values[entry.key]!,
              source: CacheSource.localEdit);
          _drafts.remove(entry.key);
          _errors.remove(entry.key);
          if (reply.kind == CliReplyKind.rebootNeeded) reboot = true;
        } else {
          // Keep what we knew, or remember the attempted value as stale when
          // this key had never been read. Either way the UI can offer a retry.
          if (cache.read(entry.key) != null) {
            await cache.markStale(entry.key);
          } else {
            await cache.write(entry.key, values[entry.key]!,
                source: CacheSource.stale);
          }
          failed.add(entry.key);
        }
      }
      return SettingsSaveResult(results, failed, reboot);
    } finally {
      saving = false;
    }
  }
}
