import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/secret_store.dart';

void main() {
  test('the default backend is in memory and can be loaded', () async {
    final store = SecretStore();
    await store.load();
    expect(store.available, isTrue);
    expect(store.isRemembered(SecretField.fleetPsk), isFalse);
  });

  test('only the eligible fields can be remembered', () {
    expect(SecretField.values.map((e) => e.storageKey), contains('fleet.psk'));
    expect(SecretField.values.map((e) => e.storageKey),
        contains('mqtt1.password'));
    expect(SecretField.values.map((e) => e.storageKey),
        isNot(contains('wifi.pwd')));
    expect(SecretField.values.map((e) => e.storageKey),
        isNot(contains('admin.password')));
    expect(SecretField.values.map((e) => e.storageKey),
        isNot(contains('guest.password')));
  });

  test('a remembered secret survives a new store instance', () async {
    final backend = MemorySecretBackend();
    final first = SecretStore(backend: backend);
    await first.load();
    expect(first.available, isTrue);
    await first.remember(SecretField.fleetPsk, 'aabb');
    expect(first.isRemembered(SecretField.fleetPsk), isTrue);

    final second = SecretStore(backend: backend);
    await second.load();
    expect(second.isRemembered(SecretField.fleetPsk), isTrue);
    expect(await second.resolve(SecretField.fleetPsk, 'session'), 'aabb');
    expect(
        await second.resolve(SecretField.mqtt1Password, 'session'), 'session');
  });

  test('forget removes the value and the opt-in', () async {
    final backend = MemorySecretBackend();
    final store = SecretStore(backend: backend);
    await store.load();
    await store.remember(SecretField.mqtt2Token, 'token');
    expect(await backend.read('mqtt2.token'), 'token');
    await store.forget(SecretField.mqtt2Token);
    expect(store.isRemembered(SecretField.mqtt2Token), isFalse);
    expect(await backend.read('mqtt2.token'), isNull);
  });

  test('unavailable platforms keep values in session only', () async {
    final backend = MemorySecretBackend();
    final store = SecretStore(backend: backend, unavailable: true);
    await store.load();
    expect(store.available, isFalse);
    await store.remember(SecretField.fleetPsk, 'secret');
    expect(store.isRemembered(SecretField.fleetPsk), isFalse);
    expect(await backend.read('fleet.psk'), isNull);
    await store.forgetAll();
    expect(store.isRemembered(SecretField.fleetPsk), isFalse);
  });

  test('listeners are notified on opt-in changes', () async {
    final store = SecretStore(backend: MemorySecretBackend());
    await store.load();
    var notified = 0;
    store.addListener(() => notified++);
    await store.remember(SecretField.fleetPsk, 'key');
    await store.forget(SecretField.fleetPsk);
    expect(notified, 2);
  });
}
