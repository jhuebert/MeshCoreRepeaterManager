import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/firmware_library.dart';
import 'package:meshcore_repeater_manager/services/radio_plan.dart';

import 'support.dart';

const _board = 'Xiao_S3_WIO_repeater_observer';
final _targetId = targetIdForEnvironment(_board);

void main() {
  test('board detection maps the node target id back to a known environment',
      () {
    final app = AppState();
    app.catalog = catalog([
      release('v1.1.0-rc5', images: [
        asset(_board, 'v1.1.0-rc5'),
        asset('RAK_4631_repeater', 'v1.1.0-rc5'),
      ]),
    ]);
    app.nodeInfo = nodeInfo(targetId: _targetId);

    expect(app.knownEnvironments, contains(_board));
    expect(app.environmentForTargetId(_targetId), _board);
    expect(app.detectedBoard, _board);
    expect(app.environmentForTargetId(0x11111111), isNull);
  });

  test('changing target forgets the previous node facts', () {
    final app = AppState();
    app.nodeStatus = nodeStatus();
    app.nodeInfo = nodeInfo(targetId: _targetId);
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    app.radio2Enabled = true;
    app.manualRoutePath = 'c0ff';
    app.remoteDiff = remoteDiff();

    app.selectTarget(contact('other'));

    expect(app.target?.name, 'other');
    expect(app.nodeStatus, isNull);
    expect(app.nodeInfo, isNull);
    expect(app.nodePreset, isNull);
    expect(app.radio2Enabled, isNull);
    expect(app.remoteDiff, isNull);
    expect(app.manualRoutePath, isEmpty);
  });

  test('the version picker only ever offers the node-board image', () {
    final app = AppState();
    app.catalog = catalog([
      release('v1.1.0-rc5', images: [
        asset(_board, 'v1.1.0-rc5'),
        asset('RAK_4631_repeater', 'v1.1.0-rc5'),
      ]),
      release('v1.0.0-old', images: [
        asset('RAK_4631_repeater', 'v1.0.0-old'),
      ]),
    ]);

    final visible = app.visibleReleasesFor(_board);
    expect(visible.map((r) => r.tag), ['v1.1.0-rc5']);
    expect(app.assetForEnvironment(visible.single, _board)?.env, _board);
    expect(app.assetForEnvironment(visible.single, 'ARM_unknown'), isNull);
    app.nodeInfo = nodeInfo(targetId: _targetId);
    expect(visible.single.appImages.any((a) => a.env == 'RAK_4631_repeater'),
        isTrue);
    // Releases with no image for this board are hidden entirely.
    expect(app.visibleReleasesFor('RAK_4631_repeater').map((r) => r.tag),
        ['v1.1.0-rc5', 'v1.0.0-old']);
  });

  test('a cached asset is selected without any network access', () async {
    final app = AppState();
    final lib = FakeLibrary();
    final image = Uint8List.fromList(List.filled(96, 7));
    final entry = lib.addImage(image,
        env: _board, version: 'v1.1.0-rc5', fileName: '$_board-v1.1.0-rc5.bin');
    app.library = lib;
    app.libraryEntries = await lib.list();

    await app.selectAsset(asset(_board, 'v1.1.0-rc5'));

    expect(app.imageError, isNull);
    expect(app.selectedImage, image);
    expect(app.selectedLibraryEntry?.id, entry.id);
  });

  test('offline selection of an unsaved asset is refused', () async {
    final app = AppState();
    app.library = FakeLibrary();
    app.offlineMode = true;

    await app.selectAsset(asset(_board, 'v1.1.0-rc5'));
    expect(app.imageError, contains('offline'));
    expect(app.selectedImage, isNull);
  });

  test('an offline download is refused without touching the network', () async {
    final app = AppState();
    app.offlineMode = true;
    final saved = await app.downloadReleaseToLibrary(
      release('v1.1.0-rc5', images: [asset(_board, 'v1.1.0-rc5')]),
    );
    expect(saved, 0);
  });

  test('offline versions group by version and note completeness', () async {
    final app = AppState();
    final lib = FakeLibrary();
    lib.addImage(Uint8List.fromList(List.filled(16, 1)),
        env: _board, version: 'v1.1.0-rc5', fileName: '$_board-v1.1.0-rc5.bin');
    lib.addImage(Uint8List.fromList(List.filled(16, 2)),
        env: 'RAK_4631_repeater',
        version: 'v1.1.0-rc5',
        fileName: 'RAK_4631_repeater-v1.1.0-rc5.bin');
    lib.addImage(Uint8List.fromList(List.filled(16, 3)),
        env: _board, version: 'v1.1.0-rc4');
    app.library = lib;
    app.libraryEntries = await lib.list();
    app.catalog = catalog([
      release('v1.1.0-rc5', images: [
        asset(_board, 'v1.1.0-rc5'),
        asset('RAK_4631_repeater', 'v1.1.0-rc5'),
      ]),
      release('v1.1.0-rc4', images: [
        asset(_board, 'v1.1.0-rc4'),
        asset('RAK_4631_repeater', 'v1.1.0-rc4'),
      ]),
    ]);

    final versions = app.offlineVersions;
    expect(versions, hasLength(2));
    final rc5 = versions.firstWhere((v) => v.version == 'v1.1.0-rc5');
    expect(rc5.complete, isTrue);
    expect(rc5.known, isTrue);
    expect(rc5.entries, hasLength(2));
    final rc4 = versions.firstWhere((v) => v.version == 'v1.1.0-rc4');
    expect(rc4.complete, isFalse);
  });

  test('a library entry is matched by file name or by sha', () {
    final app = AppState();
    app.libraryEntries = [
      LibraryEntry(
        id: 'a' * 64,
        fileName: 'custom.bin',
        env: 'custom',
        version: 'custom',
        origin: 'import',
        size: 1,
        sha256: 'a' * 64,
        added: DateTime(2026),
      ),
    ];
    expect(
        app.libraryEntryForAsset(
            asset(_board, 'v1', sha256: 'a' * 64, size: 1)),
        isNotNull);
    expect(app.libraryEntryForAsset(asset(_board, 'v2', sha256: 'b' * 64)),
        isNull);
  });

  test('radio plan transitions suggest a preset and a duration', () {
    final app = AppState();
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );

    app.setRadioMode(RadioMode.tempRadio);
    expect(app.radioPlan.mode, RadioMode.tempRadio);
    expect(app.radioPlan.preset, isNotNull);
    expect(app.radioPlanProblem, isNull);

    app.setRadioPreset(const LoRaPreset(
      frequencyHz: 915000000,
      bandwidthHz: 125000,
      spreadingFactor: 9,
      codingRate: 5,
    ));
    expect(app.radioPlan.preset!.frequencyMhz, 915);

    app.setRadioMode(RadioMode.radio2);
    expect(app.radioPlan.mode, RadioMode.radio2);
  });

  test('selecting an update needs no local copy of the running image',
      () async {
    final app = AppState();
    final lib = FakeLibrary();
    final running = Uint8List.fromList(List.filled(64, 9));
    lib.addImage(running,
        env: 'custom',
        version: 'custom',
        fileName: 'my-build.bin',
        origin: 'import');
    final updateImage = Uint8List.fromList(List.filled(64, 4));
    final update = lib.addImage(updateImage,
        env: _board, version: 'v1.1.0-rc5', fileName: '$_board-v1.1.0-rc5.bin');
    app.library = lib;
    app.libraryEntries = await lib.list();
    app.nodeStatus = nodeStatus();
    app.nodeInfo = nodeInfo(
        runningSha256: Uint8List.fromList(sha256.convert(running).bytes));

    await app.selectLibraryEntryForUpdate(update);

    // The node is the diff oracle now — no local copy of the running image is
    // looked up, and a previous comparison cannot leak into this selection.
    expect(app.selectedLibraryEntry?.id, update.id);
    expect(app.remoteDiff, isNull);
  });

  test('selecting another image drops the previous comparison', () async {
    final app = AppState();
    final lib = FakeLibrary();
    final first = lib.addImage(Uint8List.fromList(List.filled(64, 4)),
        env: _board, version: 'v1.1.0-rc5', fileName: '$_board-v1.1.0-rc5.bin');
    final second = lib.addImage(Uint8List.fromList(List.filled(64, 5)),
        env: _board, version: 'v1.1.0-rc6', fileName: '$_board-v1.1.0-rc6.bin');
    app.library = lib;
    app.libraryEntries = await lib.list();
    app.remoteDiff = remoteDiff();

    await app.selectLibraryEntryForUpdate(second);

    expect(app.selectedLibraryEntry?.id, second.id);
    expect(app.remoteDiff, isNull);
    expect(first.id, isNot(second.id));
  });

  test('downloaded versions exclude imported bins', () async {
    final app = AppState();
    final lib = FakeLibrary();
    lib.addImage(Uint8List.fromList(List.filled(16, 1)),
        env: _board, version: 'v1.1.0-rc5', fileName: '$_board-v1.1.0-rc5.bin');
    lib.addImage(Uint8List.fromList(List.filled(16, 2)),
        env: 'custom',
        version: 'custom',
        fileName: 'mine.bin',
        origin: 'import');
    app.library = lib;
    app.libraryEntries = await lib.list();

    expect(app.offlineVersions.map((v) => v.version), ['v1.1.0-rc5']);
    expect(app.importedEntries.map((e) => e.fileName), ['mine.bin']);
  });

  test('deleting the selected image clears the comparison', () async {
    final app = AppState();
    final lib = FakeLibrary();
    final update = lib.addImage(Uint8List.fromList(List.filled(64, 4)),
        env: _board, version: 'v1.1.0-rc5', fileName: '$_board-v1.1.0-rc5.bin');
    app.library = lib;
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(update);
    app.remoteDiff = remoteDiff();

    await app.deleteLibraryEntries([update]);

    expect(app.libraryEntries, isEmpty);
    expect(app.selectedLibraryEntry, isNull);
    expect(app.selectedImage, isNull);
    expect(app.remoteDiff, isNull);
  });

  test('clearComparison drops a stale plan without touching the image',
      () async {
    final app = AppState();
    final lib = FakeLibrary();
    final update = lib.addImage(Uint8List.fromList(List.filled(64, 4)),
        env: _board, version: 'v1.1.0-rc5', fileName: '$_board-v1.1.0-rc5.bin');
    app.library = lib;
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(update);
    app.remoteDiff = remoteDiff();

    app.clearComparison();

    expect(app.remoteDiff, isNull);
    expect(app.selectedImage, isNotNull);
  });

  test('downloadAssetToLibrary refuses outside a connection', () async {
    final app = AppState();
    app.offlineMode = true;
    final saved = await app.downloadAssetToLibrary(asset(_board, 'v1.1.0-rc5'));
    expect(saved, 0);

    // Already saved: no network touched either.
    final lib = FakeLibrary();
    final target = asset(_board, 'v1.1.0-rc5');
    lib.addImage(Uint8List.fromList(List.filled(16, 7)),
        env: _board, version: 'v1.1.0-rc5', fileName: target.name);
    app.offlineMode = false;
    app.library = lib;
    app.libraryEntries = await lib.list();
    expect(await app.downloadAssetToLibrary(target), 0);
  });

  test('estimate label reports only the image size', () {
    final app = AppState();
    expect(app.estimateLabel(), 'size unknown');
  });

  estimateTests();
}

void estimateTests() {
  test('per-mode estimates scale with the mode and the preset', () async {
    final app = AppState();
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(Uint8List.fromList(List.filled(120000, 3)),
        env: _board, version: 'v1.1.0-rc5');
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(entry);

    final live = app.estimateSecondsForMode(RadioMode.liveMesh);
    final temp =
        app.estimateSecondsForMode(RadioMode.tempRadio, preset: app.nodePreset);
    final radio2 =
        app.estimateSecondsForMode(RadioMode.radio2, preset: app.nodePreset);

    // 120000 bytes / 132 per literal (the stock companion's frame limit),
    // +16 op frames, at ~1.5 s per op.
    expect(live, ((120000 / 132).ceil() + 16) * 1.5);
    expect(temp, live);
    expect(radio2, greaterThan(temp!));
    expect(radio2, closeTo(temp * RadioPlan.radio2DutyFactor, 2));
  });

  test('no image means no estimate', () {
    final app = AppState();
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    expect(app.estimateSecondsForPreset(app.nodePreset), isNull);
    expect(app.estimateSecondsForMode(RadioMode.liveMesh), isNull);
  });
}
