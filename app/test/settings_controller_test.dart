import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/repeater_cache_store.dart';
import 'package:meshcore_repeater_manager/services/settings_controller.dart';
import 'package:repeater_core/repeater_core.dart';

Contact _contact() =>
    Contact(publicKey: Uint8List.fromList(List.filled(32, 2)));

Future<(SettingsController, Directory, List<String>)> _setup({
  required Map<String, String> nodeValues,
  List<String> failures = const [],
}) async {
  final dir = Directory.systemTemp.createTempSync('settings_ctrl_test');
  final cache = RepeaterCacheStore(File('${dir.path}/cache.json'));
  await cache.load();
  final commands = <String>[];
  final cli = CliService(
    exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
      commands.add(command);
      if (command.startsWith('get ')) {
        final key = command.substring(4);
        return nodeValues.containsKey(key)
            ? '> ${nodeValues[key]}'
            : 'Err - unknown key';
      }
      final key = command.split(' ')[1];
      if (failures.contains(key)) return 'Err - refused';
      return command.contains('guest.password')
          ? 'OK, reboot required'
          : '> ok';
    },
    binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async =>
        throw const RepeaterRequestException('not used'),
  );
  return (SettingsController(_contact(), cli, cache), dir, commands);
}

void main() {
  test('displayed value prefers a draft over the cached value', () async {
    final (ctrl, dir, _) = await _setup(nodeValues: {'tx': '20'});
    addTearDown(() => dir.deleteSync(recursive: true));
    await ctrl.refresh(['tx']);
    expect(ctrl.displayedValue('tx'), '20');
    ctrl.setDraft('tx', '22');
    expect(ctrl.displayedValue('tx'), '22');
    expect(ctrl.hasChanges, isTrue);
    ctrl.discard('tx');
    expect(ctrl.hasChanges, isFalse);
  });

  test('a refresh writes remote source values into the cache', () async {
    final (ctrl, dir, commands) = await _setup(nodeValues: {'tx': '20'});
    addTearDown(() => dir.deleteSync(recursive: true));
    await ctrl.refresh(['tx']);
    expect(commands, ['get tx']);
    expect(ctrl.cache.read('tx')!.source, CacheSource.remote);
    expect(ctrl.cache.read('tx')!.value, '20');
  });

  test('a failed read marks the cached value stale', () async {
    final (ctrl, dir, _) = await _setup(nodeValues: {});
    addTearDown(() => dir.deleteSync(recursive: true));
    await ctrl.cache.write('tx', '18');
    await ctrl.refresh(['tx']);
    expect(ctrl.cache.read('tx')!.isStale, isTrue);
    expect(ctrl.cache.read('tx')!.value, '18');
  });

  test('save applies valid drafts and clears them', () async {
    final (ctrl, dir, commands) = await _setup(nodeValues: {'tx': '20'});
    addTearDown(() => dir.deleteSync(recursive: true));
    ctrl.setDraft('tx', '22');
    final result = await ctrl.save();
    expect(result.ok, isTrue);
    expect(commands, ['set tx 22']);
    expect(ctrl.hasChanges, isFalse);
    expect(ctrl.cache.read('tx')!.source, CacheSource.localEdit);
    expect(ctrl.cache.read('tx')!.value, '22');
  });

  test('a refused key stays dirty and other keys still land', () async {
    final (ctrl, dir, _) =
        await _setup(nodeValues: {}, failures: ['flood.max']);
    addTearDown(() => dir.deleteSync(recursive: true));
    ctrl.setDraft('tx', '20');
    ctrl.setDraft('flood.max', '999');
    final result = await ctrl.save();
    expect(result.ok, isFalse);
    expect(result.failedKeys, ['flood.max']);
    expect(ctrl.dirtyKeys, {'flood.max'});
    expect(ctrl.cache.read('flood.max')!.isStale, isTrue);
  });

  test('a reboot reply is surfaced as a reboot-needed outcome', () async {
    final (ctrl, dir, _) = await _setup(nodeValues: {});
    addTearDown(() => dir.deleteSync(recursive: true));
    ctrl.setDraft('guest.password', 'secret');
    final result = await ctrl.save();
    expect(result.rebootNeeded, isTrue);
    expect(result.results['guest.password']!.kind, CliReplyKind.rebootNeeded);
  });

  test('validation errors block the whole batch', () async {
    final (ctrl, dir, commands) = await _setup(nodeValues: {});
    addTearDown(() => dir.deleteSync(recursive: true));
    ctrl.setDraft('tx', '99'); // above the max
    final result = await ctrl.save();
    expect(result.ok, isFalse);
    expect(ctrl.errorFor('tx'), contains('at most'));
    expect(commands, isEmpty);
  });
}
