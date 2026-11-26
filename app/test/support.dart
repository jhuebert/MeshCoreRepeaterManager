import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/firmware_library.dart';
import 'package:meshcore_repeater_manager/services/github_source.dart';
import 'package:meshcore_repeater_manager/theme.dart';

/// Shared fixtures for the app's widget tests. Screens bind to [AppState]
/// public fields, so a test can build any screen state without a companion.
Contact contact(String name,
    {int advType = advTypeRepeater, List<int>? key, int hops = 0}) {
  final publicKey = key == null
      ? Uint8List.fromList(List.generate(32, (i) => i + 1))
      : Uint8List.fromList(key);
  return Contact(
    publicKey: publicKey,
    name: name,
    advType: advType,
    outPathLen: hops,
    outPath: Uint8List(hops),
  );
}

OtaStatus nodeStatus({
  String running = 'v1.1.0-rc5',
  String shaPrefix = '2979666babcfc001',
  OtaPhase state = OtaPhase.idle,
  int size = 0,
  int offset = 0,
  int err = 0,
}) =>
    OtaStatus(
      running: running,
      shaPrefix: shaPrefix,
      state: state,
      size: size,
      offset: offset,
      err: err,
    );

OtaNodeInfo nodeInfo({
  int targetId = 0xba7783f9,
  String runningVersion = 'v1.1.0-rc5',
  Uint8List? runningSha256,
  int slotSize = 3342336,
  int? features,
}) =>
    OtaNodeInfo(
      wireVersion: otaWireVersion,
      targetId: targetId,
      slotSize: slotSize,
      maxLiteral: 173,
      features: features ?? (otaFeatDelta | otaFeatApply | otaFeatBlockHash),
      runningVersion: runningVersion,
      runningSha256: runningSha256 ?? Uint8List(32),
    );

/// A completed step-5 comparison. Tests set this instead of a local delta
/// base: the app no longer needs the old image on the device.
RemoteDiffResult remoteDiff({
  List<DeltaOp>? ops,
  int literalBytes = 64,
  int copyBytes = 960,
  int runningSize = 1024,
  int queries = 4,
  int shiftProbeBatches = 0,
  bool upToDate = false,
}) =>
    RemoteDiffResult(
      ops: ops ?? [LiteralOp(Uint8List(literalBytes))],
      literalBytes: literalBytes,
      copyBytes: copyBytes,
      node: RunningImageInfo(
        size: runningSize,
        segments: const [],
        sha256: Uint8List(32),
      ),
      queries: queries,
      rangesHashed: queries * 2,
      shiftProbeBatches: shiftProbeBatches,
      upToDate: upToDate,
    );

FirmwareAsset asset(String env, String version,
        {String? sha256, int size = 1449824}) =>
    FirmwareAsset(
      name: '$env-$version.bin',
      env: env,
      version: version,
      size: size,
      downloadUrl: 'https://example.invalid/$env-$version.bin',
      sha256: sha256,
    );

FirmwareRelease release(String tag,
        {required List<FirmwareAsset> images,
        DateTime? published,
        bool prerelease = false}) =>
    FirmwareRelease(
      tag: tag,
      name: 'Firmware $tag',
      prerelease: prerelease,
      publishedAt: (published ?? DateTime(2026, 11, 1)).toIso8601String(),
      appImages: images,
    );

Catalog catalog(List<FirmwareRelease> releases) => Catalog(
      releases: releases,
      fetchedAt: DateTime(2026, 11, 16),
      sumsAvailable: false,
      fromCache: false,
    );

/// A real on-disk library in a temp directory, so selection/delete paths run
/// against actual files.
Future<FirmwareLibrary> tempLibrary() async {
  final dir =
      await Directory.systemTemp.createTemp('meshcorepeatermanager_test_');
  return FirmwareLibrary.open(dir);
}

Widget wrap(AppState app, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
          theme: OtaTheme.dark, debugShowCheckedModeBanner: false, home: child),
    );

/// An in-memory library: widget tests drive the real selection/delete paths
/// without touching the filesystem (which a fake-async test would hang on).
class FakeLibrary extends FirmwareLibrary {
  FakeLibrary([List<LibraryEntry> entries = const []])
      : _entries = [...entries],
        super(Directory('/nonexistent-meshcorepeatermanager-library'));

  final List<LibraryEntry> _entries;
  final Map<String, Uint8List> _bytes = {};

  void add(LibraryEntry entry, [Uint8List? bytes]) {
    _entries.insert(0, entry);
    _bytes[entry.id] = bytes ?? Uint8List(entry.size);
  }

  /// Build and add an entry whose id is the SHA-256 of [bytes].
  LibraryEntry addImage(
    Uint8List bytes, {
    required String env,
    required String version,
    String? fileName,
    String origin = 'github',
  }) {
    final sha = sha256.convert(bytes).toString();
    final entry = LibraryEntry(
      id: sha,
      fileName: fileName ?? '$env-$version.bin',
      env: env,
      version: version,
      origin: origin,
      size: bytes.length,
      sha256: sha,
      added: DateTime.now(),
    );
    add(entry, bytes);
    return entry;
  }

  @override
  Future<List<LibraryEntry>> list() async => List.of(_entries);

  @override
  Future<Uint8List> read(LibraryEntry entry) async =>
      _bytes[entry.id] ?? Uint8List(entry.size);

  @override
  Future<void> delete(LibraryEntry entry) async => _entries.remove(entry);

  @override
  Future<LibraryEntry> importBytes(
    Uint8List bytes, {
    required String env,
    required String version,
    required String origin,
    String? fileName,
  }) async =>
      addImage(bytes,
          env: env, version: version, origin: origin, fileName: fileName);
}
