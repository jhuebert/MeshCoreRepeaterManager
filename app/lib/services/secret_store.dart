import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secrets that may be remembered through explicit opt-in. The WiFi password
/// and admin/guest passwords are deliberately absent and can never be stored.
enum SecretField {
  fleetPsk('fleet.psk', 'Fleet channel key'),
  mqtt1Username('mqtt1.username', 'Broker 1 username'),
  mqtt1Password('mqtt1.password', 'Broker 1 password'),
  mqtt1Token('mqtt1.token', 'Broker 1 topic token'),
  mqtt2Username('mqtt2.username', 'Broker 2 username'),
  mqtt2Password('mqtt2.password', 'Broker 2 password'),
  mqtt2Token('mqtt2.token', 'Broker 2 topic token');

  const SecretField(this.storageKey, this.label);

  final String storageKey;
  final String label;
}

/// Look up an eligible secret by the same key the UI uses, for example
/// `mqtt1.password`. Returns null for fields that may never be remembered,
/// including the WiFi and admin/guest passwords.
SecretField? secretFieldForConfigKey(String key) {
  for (final field in SecretField.values) {
    if (field.storageKey == key) return field;
  }
  return null;
}

/// Backend seam so widget tests use an in-memory map and never load a plugin.
abstract class SecretBackend {
  Future<bool> get available;
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

// coverage:ignore-start
// Platform bound: covered by the plugin's own tests, never by app unit tests.
class SecureStorageBackend implements SecretBackend {
  SecureStorageBackend({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<bool> get available async {
    try {
      await _storage.read(key: 'availability_probe');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
// coverage:ignore-end

/// In-memory backend for tests and for platforms without secure storage, where
/// the opt-in is disabled and a value stays in the session only.
class MemorySecretBackend implements SecretBackend {
  final Map<String, String> _values = {};

  @override
  Future<bool> get available async => true;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Strictly opt-in storage for the small set of secrets the app may remember.
/// Every other secret stays in memory for the session and is never written.
/// The default backend is in memory; the app injects the platform backend at
/// startup, and tests inject [MemorySecretBackend] explicitly.
class SecretStore extends ChangeNotifier {
  SecretStore({SecretBackend? backend, bool unavailable = false})
      : backend = backend ?? MemorySecretBackend(),
        _forcedUnavailable = unavailable;

  final SecretBackend backend;
  final bool _forcedUnavailable;
  final Map<SecretField, bool> _remembered = {};

  bool _available = false;
  bool get available => _available;

  bool isRemembered(SecretField field) => _remembered[field] ?? false;

  Future<void> load() async {
    _available = !_forcedUnavailable && await backend.available;
    for (final field in SecretField.values) {
      final stored = _available ? await backend.read(field.storageKey) : null;
      _remembered[field] = stored != null;
    }
    notifyListeners();
  }

  /// A remembered value wins over the value typed this session.
  Future<String> resolve(SecretField field, String sessionValue) async {
    if (isRemembered(field)) {
      final stored = await backend.read(field.storageKey);
      if (stored != null) return stored;
    }
    return sessionValue;
  }

  Future<void> remember(SecretField field, String value) async {
    if (!_available || value.isEmpty) return;
    await backend.write(field.storageKey, value);
    _remembered[field] = true;
    notifyListeners();
  }

  Future<void> forget(SecretField field) async {
    if (!isRemembered(field)) return;
    await backend.delete(field.storageKey);
    _remembered[field] = false;
    notifyListeners();
  }

  Future<void> forgetAll() async {
    for (final field in SecretField.values) {
      if (isRemembered(field)) await backend.delete(field.storageKey);
    }
    _remembered.clear();
    notifyListeners();
  }
}
