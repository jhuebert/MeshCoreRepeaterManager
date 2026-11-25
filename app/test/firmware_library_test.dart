import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/firmware_library.dart';

Uint8List _bytes(int seed, int length) => Uint8List.fromList(
    List<int>.generate(length, (i) => (i * seed + 11) & 0xFF));

void main() {
  late Directory dir;
  late FirmwareLibrary library;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('library_test');
    library = FirmwareLibrary(dir);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('open creates ota_library under the support directory', () async {
    final opened = await FirmwareLibrary.open(dir);
    expect(await opened.directory.exists(), isTrue);
    expect(opened.directory.path, endsWith('ota_library'));
  });

  test('a running-image SHA prefix finds the board of a saved image', () async {
    final saved = await library.importBytes(
      _bytes(7, 400),
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.2.0',
      origin: 'github',
    );
    final prefix = saved.sha256.substring(0, 16);

    final match = await library.findByShaPrefixWithBoard(prefix);
    expect(match?.id, saved.id);
    expect(match?.env, 'Xiao_S3_WIO_repeater');

    // `ota status` uses an all-zero sha when the node cannot hash its image,
    // and a custom-named image cannot name a board either.
    expect(await library.findByShaPrefixWithBoard('0000000000000000'), isNull);
    expect(await library.findByShaPrefixWithBoard('zzzzzzzzzzzzzzzz'), isNull);

    final custom = await library.importBytes(
      _bytes(9, 400),
      env: customEnvironment,
      version: 'custom',
      origin: 'import',
      fileName: 'firmware.bin',
    );
    final customPrefix = custom.sha256.substring(0, 16);
    expect(await library.findByShaPrefixWithBoard(customPrefix), isNull);
    // The bytes are still identifiable — just not nameable as a board.
    expect((await library.findByShaPrefix(customPrefix))?.id, custom.id);
  });

  test('two imported files with identical bytes stay as two rows', () async {
    final bytes = _bytes(17, 400);
    final first = await library.importBytes(
      bytes,
      env: customEnvironment,
      version: 'custom',
      origin: 'import',
      fileName: 'first.bin',
    );
    final second = await library.importBytes(
      bytes,
      env: customEnvironment,
      version: 'custom',
      origin: 'import',
      fileName: 'second.bin',
    );

    expect(second.id, isNot(first.id));
    expect(second.sha256, first.sha256);
    final entries = await library.list();
    expect(entries.map((e) => e.fileName),
        containsAll(['first.bin', 'second.bin']));
    expect((await library.read(first)), equals(bytes));
    expect((await library.read(second)), equals(bytes));

    // Deleting one import leaves the other one intact.
    await library.delete(first);
    expect((await library.list()).single.fileName, 'second.bin');
  });

  test('importBytes synthesizes a file name from env and version', () async {
    final entry = await library.importBytes(
      _bytes(31, 400),
      env: 'RAK_4631_repeater',
      version: 'v1.2.0',
      origin: 'github',
    );
    expect(entry.fileName, 'RAK_4631_repeater-v1.2.0.bin');
  });

  test('a sidecar without a timestamp falls back to the bin mtime', () async {
    final image = _bytes(37, 400);
    final entry = await library.importBytes(
      image,
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.2.0',
      origin: 'github',
      fileName: 'ts.bin',
    );
    // Rewrite the sidecar without 'added'; list() must still yield the entry.
    final sidecar = File('${dir.path}/${entry.id}.json');
    final json =
        Map<String, dynamic>.from(jsonDecode(await sidecar.readAsString()));
    json.remove('added');
    await sidecar.writeAsString(jsonEncode(json));

    final entries = await library.list();
    expect(entries.single.fileName, 'ts.bin');
    expect(entries.single.added.isAfter(DateTime(2020)), isTrue);
  });

  test('import, list, read and delete roundtrip', () async {
    final image = _bytes(3, 5000);
    final entry = await library.importBytes(
      image,
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4',
      origin: 'github',
      fileName: 'Xiao_S3_WIO_repeater-v1.18.0-r4.bin',
    );
    expect(entry.size, image.length);
    expect(entry.sha256, sha256.convert(image).toString());

    final entries = await library.list();
    expect(entries, hasLength(1));
    expect(entries.single.env, 'Xiao_S3_WIO_repeater');
    expect(entries.single.version, 'v1.18.0-r4');

    final restored = await library.read(entries.single);
    expect(restored, image);

    await library.delete(entries.single);
    expect(await library.list(), isEmpty);
  });

  test('findBaseFor matches env + version stamp exactly', () async {
    final image = _bytes(5, 4000);
    await library.importBytes(
      image,
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4',
      origin: 'github',
      fileName: 'x.bin',
    );
    final hit = await library.findBaseFor(
      env: 'Xiao_S3_WIO_repeater',
      runningVersion: 'v1.18.0-r4',
    );
    expect(hit, isNotNull);

    expect(
      await library.findBaseFor(
          env: 'Xiao_S3_WIO_repeater',
          runningVersion: 'v1.18.0-dev.7'),
      isNull,
    );
    expect(
      await library.findBaseFor(
          env: 'RAK_4631_repeater',
          runningVersion: 'v1.18.0-r4'),
      isNull,
    );
  });

  test('findBaseForSha matches the running image by exact bytes', () async {
    final image = _bytes(7, 3000);
    final entry = await library.importBytes(
      image,
      env: 'Xiao_S3_WIO_repeater_observer',
      version: 'v1.18.0-r4',
      origin: 'github',
      fileName: 'x.bin',
    );
    final hit = await library.findBaseForSha(sha256.convert(image).bytes);
    expect(hit, isNotNull);
    expect(hit!.id, entry.id);
    // An image the library does not hold is no base at all.
    expect(await library.findBaseForSha(sha256.convert(_bytes(9, 8)).bytes),
        isNull);
  });
}
