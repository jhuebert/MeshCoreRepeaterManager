import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/firmware_library.dart';
import 'package:meshcore_repeater_manager/services/resume_store.dart';

ResumePlan _plan({required String version, required String imageSha256}) =>
    ResumePlan(
      createdAt: 1,
      targetPublicKeyHex: '00',
      targetName: 'XiaoS3',
      imageSha256: imageSha256,
      imageSize: 64,
      version: version,
      targetId: 1,
      runningSha256: '22',
      frames: List<Uint8List>.filled(2, Uint8List(2)),
      radioMode: 0,
      radioPreset: null,
      radioDurationMinutes: 10,
      enabledRadio2ForUpdate: false,
      manualRoutePath: '',
      transportKind: 'tcp',
      tcpHost: '127.0.0.1',
      tcpPort: 5000,
      bleDeviceId: null,
    );

void main() {
  late Directory dir;
  late FirmwareLibrary lib;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('library_naming_cleanup_test');
    lib = await FirmwareLibrary.open(dir);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('removes only old-named entries and is idempotent', () async {
    final staleBytes = Uint8List.fromList(List<int>.filled(64, 1));
    final currentBytes = Uint8List.fromList(List<int>.filled(64, 2));
    final importBytes = Uint8List.fromList(List<int>.filled(64, 3));
    final stale = await lib.importBytes(
      staleBytes,
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4-filter-d1ebd2f',
      origin: 'github',
      fileName: 'Xiao_S3_WIO_repeater-v1.18.0-r4-filter-d1ebd2f.bin',
    );
    final current = await lib.importBytes(
      currentBytes,
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4',
      origin: 'github',
      fileName: 'Xiao_S3_WIO_repeater-v1.18.0-r4.bin',
    );
    final imported = await lib.importBytes(
      importBytes,
      env: 'custom',
      version: 'my-build',
      origin: 'import',
      fileName: 'my-build.bin',
    );
    final settings = File('${dir.path}/ota_settings.json');
    await settings.writeAsString('{"offline":true}');

    final removed = await cleanRetiredLibraryEntries(lib);

    expect(removed.map((e) => e.id), [stale.id]);
    expect(
      (await lib.list()).map((e) => e.id),
      containsAll([current.id, imported.id]),
    );
    expect((await lib.list()).map((e) => e.id), isNot(contains(stale.id)));
    expect(
        await File('${lib.directory.path}/${stale.id}.bin').exists(), isFalse);
    expect(
        await File('${lib.directory.path}/${stale.id}.json').exists(), isFalse);
    expect(await settings.readAsString(), '{"offline":true}');

    expect(await cleanRetiredLibraryEntries(lib), isEmpty);
    expect(await lib.list(), hasLength(2));
  });

  test(
    'startup cleanup keeps the offline flag and drops a dangling resume',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'app_init_naming_test',
      );
      addTearDown(() async => support.delete(recursive: true));
      final supportLib = await FirmwareLibrary.open(support);
      final staleBytes = Uint8List.fromList(List<int>.filled(64, 6));
      final keptBytes = Uint8List.fromList(List<int>.filled(64, 7));
      final stale = await supportLib.importBytes(
        staleBytes,
        env: 'Xiao_S3_WIO_repeater',
        version: 'v1.18.0-r4-filter-d1ebd2f',
        origin: 'github',
        fileName: 'Xiao_S3_WIO_repeater-v1.18.0-r4-filter-d1ebd2f.bin',
      );
      final kept = await supportLib.importBytes(
        keptBytes,
        env: 'custom',
        version: 'my-build',
        origin: 'import',
        fileName: 'my-build.bin',
      );
      await File('${support.path}/ota_settings.json')
          .writeAsString('{"offline":true}');
      final resumeFile = File('${support.path}/ota_resume.bin');
      await ResumeStore(resumeFile)
          .save(_plan(version: 'v1.18.0-r4', imageSha256: stale.sha256));

      final app = AppState();
      app.applicationSupportDirectory = () async => support;
      await app.initServices();

      expect(app.offlineMode, isTrue);
      expect(app.libraryEntries.map((e) => e.id), [kept.id]);
      expect(app.resumePlan, isNull);
      expect(await resumeFile.exists(), isFalse);

      // A second launch is a no-op and never reintroduces the offline flag.
      await app.initServices();
      expect(app.libraryEntries.map((e) => e.id), [kept.id]);
      expect(app.offlineMode, isTrue);
    },
  );

  test(
    'a resume is cleared only when it used or points at a removed image',
    () async {
      final bytes = Uint8List.fromList(List<int>.filled(64, 4));
      final stale = await lib.importBytes(
        bytes,
        env: 'Xiao_S3_WIO_repeater',
        version: 'v1.18.0-r4-filter-d1ebd2f',
        origin: 'github',
        fileName: 'Xiao_S3_WIO_repeater-v1.18.0-r4-filter-d1ebd2f.bin',
      );
      final removed = await cleanRetiredLibraryEntries(lib);

      expect(
        resumeNeedsClearing(
          _plan(version: 'v1.18.0-r4', imageSha256: stale.sha256),
          removed,
        ),
        isTrue,
        reason: 'the saved image was just deleted',
      );
      expect(
        resumeNeedsClearing(
          _plan(version: 'filter-v1.18.0-r4', imageSha256: '11'),
          removed,
        ),
        isTrue,
        reason: 'the saved version label uses retired naming',
      );
      expect(
        resumeNeedsClearing(
          _plan(version: 'v1.18.0-r4', imageSha256: '11'),
          removed,
        ),
        isFalse,
      );
    },
  );

  test(
    'the SHA-256 identity of an entry is unchanged by the cleanup',
    () async {
      final bytes = Uint8List.fromList(List<int>.filled(64, 5));
      final entry = await lib.importBytes(
        bytes,
        env: 'Xiao_S3_WIO_repeater',
        version: 'v1.18.0-r4',
        origin: 'github',
        fileName: 'Xiao_S3_WIO_repeater-v1.18.0-r4.bin',
      );
      await cleanRetiredLibraryEntries(lib);
      final remaining = (await lib.list()).single;
      expect(remaining.sha256, sha256.convert(bytes).toString());
      expect(remaining.id, entry.id);
      expect(await lib.read(remaining), bytes);
    },
  );
}
