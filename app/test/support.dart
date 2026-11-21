import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/firmware_library.dart';
import 'package:meshcore_repeater_manager/services/github_source.dart';
import 'package:meshcore_repeater_manager/theme.dart';
import 'package:repeater_core/repeater_core.dart';

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
  String running = 'v1.1.0-rc5-cd72e1a2',
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
  String runningVersion = 'v1.1.0-rc5-cd72e1a2',
  Uint8List? runningSha256,
  int slotSize = 3342336,
}) =>
    OtaNodeInfo(
      wireVersion: otaWireVersion,
      targetId: targetId,
      slotSize: slotSize,
      maxLiteral: 173,
      features: otaFeatDelta | otaFeatApply | otaFeatBlockHash,
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
      name: '$env-$version-filter-abc1234.bin',
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
      name: tag,
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

/// A CLI service with canned replies, so management widget tests never touch
/// a companion, a platform plugin or a real binary request.
CliService fakeCli({
  Map<String, String> replies = const {},
  List<String>? commands,
  RepeaterStatus? status,
  List<AclEntry>? acl,
  NeighborPage? neighbours,
  OwnerInfo? owner,
}) {
  final seen = commands ?? <String>[];
  final reportStatus = status ??
      RepeaterStatus(
        batteryMilliVolts: 4100,
        txQueueLength: 0,
        noiseFloor: -118,
        lastRssi: -70,
        packetsReceived: 120,
        packetsSent: 90,
        totalAirTimeSecs: 30,
        uptimeSecs: 7200,
        sentFlood: 1,
        sentDirect: 2,
        recvFlood: 3,
        recvDirect: 4,
        errorEvents: 0,
        lastSnr: 6.0,
        directDuplicates: 0,
        floodDuplicates: 0,
        rxAirTimeSecs: 10,
        recvErrors: 0,
        fetchedAt: DateTime.utc(2026, 11, 21),
      );
  final reportAcl = acl ?? <AclEntry>[];
  final reportNeighbours = neighbours ?? const NeighborPage(0, []);
  final reportOwner = owner ?? const OwnerInfo('v1.18.0', 'Roof', 'Jason');

  return CliService(
    exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
      seen.add(command);
      return replies[command] ?? '> ok';
    },
    binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async =>
        _statusBytes(reportStatus),
    rawBinary: (_, type,
        {data = const [], timeout = const Duration(seconds: 10)}) async {
      seen.add('req:${type.toRadixString(16)}');
      switch (type) {
        case 0x05:
          return _aclBytes(reportAcl);
        case 0x06:
          return _neighbourBytes(reportNeighbours);
        case 0x07:
          return Uint8List.fromList([
            ...'${reportOwner.version}\n${reportOwner.name}\n${reportOwner.owner}'
                .codeUnits,
            0,
            0,
          ]);
        default:
          return Uint8List(0);
      }
    },
  );
}

Uint8List _statusBytes(RepeaterStatus s) {
  final b = ByteData(RepeaterStatus.reportLength);
  var o = 0;
  void u16(int v) {
    b.setUint16(o, v, Endian.little);
    o += 2;
  }

  void u32(int v) {
    b.setUint32(o, v, Endian.little);
    o += 4;
  }

  u16(s.batteryMilliVolts);
  u16(s.txQueueLength);
  b.setInt16(o, s.noiseFloor, Endian.little);
  o += 2;
  b.setInt16(o, s.lastRssi, Endian.little);
  o += 2;
  u32(s.packetsReceived);
  u32(s.packetsSent);
  u32(s.totalAirTimeSecs);
  u32(s.uptimeSecs);
  for (final v in [s.sentFlood, s.sentDirect, s.recvFlood, s.recvDirect]) {
    u32(v);
  }
  u16(s.errorEvents);
  b.setInt16(o, (s.lastSnr * 4).round(), Endian.little);
  o += 2;
  u16(s.directDuplicates);
  u16(s.floodDuplicates);
  u32(s.rxAirTimeSecs);
  u32(s.recvErrors);
  return b.buffer.asUint8List();
}

Uint8List _aclBytes(List<AclEntry> entries) {
  final out = <int>[];
  for (final e in entries) {
    out.addAll(e.prefix);
    out.add(e.permissions);
  }
  out.addAll([0, 0, 0]);
  return Uint8List.fromList(out);
}

Uint8List _neighbourBytes(NeighborPage page) {
  final b = ByteData(4 + page.entries.length * (6 + 5));
  b.setUint16(0, page.total, Endian.little);
  b.setUint16(2, page.entries.length, Endian.little);
  var o = 4;
  for (final n in page.entries) {
    final prefix = n.prefix.length == 6
        ? n.prefix
        : Uint8List.fromList(
            [...n.prefix, ...List.filled(6 - n.prefix.length, 0)]);
    for (final x in prefix) {
      b.setUint8(o++, x);
    }
    b.setUint32(o, n.heardSecondsAgo, Endian.little);
    o += 4;
    b.setInt8(o++, (n.snr * 4).round());
  }
  return b.buffer.asUint8List();
}

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
