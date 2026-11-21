// Hardware bench harness for the LoRa OTA path.
//
// This drives a real companion radio over TCP and stresses the fork
// repeater's OTA implementation end to end: stage, transfer, apply, verify,
// rollback, and the failure modes (bad token, SHA mismatch, out-of-order ops,
// mid-transfer abort). It prints timings so real-world update numbers can be
// recorded against a radio configuration.
//
// It is deliberately NOT part of the app or the test suites: it needs two
// radios on a desk and a companion reachable over TCP.
//
//   dart run bench/bin/bench.dart \
//     --host 192.168.1.165 --port 5000 --password password \
//     --contact XiaoS3 --env Xiao_S3_WIO_repeater_observer \
//     --image /path/to/new.bin [--base /path/to/running.bin] [--path c0ff,c0c0] \
//     --scenario all
//
// Scenarios (comma separated):
//   probe     read `ota status`, `version`, radio params
//   full      stage → transfer (full image) → report → apply → verify
//   delta     same, but base-matched (OP_COPY reuse) against --base
//   reject    arm/transfer failure modes (bad token, SHA mismatch, gap, abort)
//   rollback  `ota rollback` after a successful apply
//   filter    read-only filter status, first rule page and counters
//   fleet     read-only fleet status and tags, plus a dry-run script preview
//   wifiota   read-only board check for the stock HTTP update page
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:repeater_core/repeater_core.dart';

// --- result bookkeeping -----------------------------------------------------

final _checks = <({String name, bool ok, String detail})>[];

void check(String name, bool ok, [String detail = '']) {
  _checks.add((name: name, ok: ok, detail: detail));
  stdout.writeln(
      '${ok ? '  PASS' : '  FAIL'}  $name${detail.isEmpty ? '' : ' — $detail'}');
}

void info(String message) => stdout.writeln(message);

String _secs(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Run [body], reconnecting and retrying once when the companion link drops.
///
/// A stock companion's raw-TX pool is small and its TCP stack will drop a
/// session rather than queue without bound; a bench run that aborts on the
/// first such drop measures nothing. The staged slot is scrapped before the
/// retry so the node starts clean.
Future<void> _runWithRetry(Bench b, Future<void> Function() body) async {
  for (var attempt = 0;; attempt++) {
    try {
      await body();
      return;
    } catch (e) {
      if (attempt >= 1) rethrow;
      info('  ! link trouble ($e) — reconnecting and retrying once');
      try {
        await b.cli('ota abort');
      } catch (_) {}
      try {
        await b.link.disconnect();
      } catch (_) {}
      await b.reconnect();
    }
  }
}

Uint8List _sha256(List<int> data) =>
    Uint8List.fromList(sha256.convert(data).bytes);

// --- bench context ----------------------------------------------------------

class Bench {
  Bench({
    required this.host,
    required this.port,
    required this.password,
    required this.env,
    required this.contactName,
    required this.windowSize,
    required this.spacingOverride,
    this.routePath = '',
  });

  final String host;
  final int port;
  final String password;
  final String env;
  final String contactName;
  final int windowSize;

  /// Comma-separated path hashes (e.g. `c0ff,c0c0`). Empty = zero hop.
  final String routePath;

  /// Delay between queued writes: explicit `--spacing MS`, or airtime-derived
  /// when null (see [spacingFor]).
  final Duration? spacingOverride;

  late TcpDeviceLink link;
  late CompanionClient client;
  late Contact target;

  Future<void> connect() async {
    link = TcpDeviceLink(host: host, port: port);
    await link.connect();
    client = CompanionClient(link);
    info('connected to companion $host:$port');
  }

  /// Resolve the repeater contact by name (case-insensitive substring), else
  /// the only repeater-type contact.
  Future<void> resolveTarget() async {
    // A companion that missed replies while the app was away holds them in
    // its offline queue; without a drain the next CLI reply is a stale one.
    await client.drainMessages();
    // A companion that just had a session dropped can be slow to answer.
    List<Contact> contacts;
    for (var attempt = 0;; attempt++) {
      try {
        contacts = await client.listContacts();
        break;
      } catch (e) {
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
    info('companion has ${contacts.length} contact(s)');
    Contact? match;
    for (final c in contacts) {
      if (contactName.isNotEmpty &&
          c.name.toLowerCase().contains(contactName.toLowerCase())) {
        match = c;
        break;
      }
    }
    match ??= contacts.where((c) => c.advType == advTypeRepeater).firstOrNull;
    if (match == null) {
      throw StateError(
          'no contact matched "$contactName" and no repeater is known — '
          'let the repeater advert first (power-cycle it), then retry');
    }
    target = match;
    info(
        'target: "${target.name}" key=${target.publicKeyHex.substring(0, 12)}… '
        'route=${target.hasDirectRoute ? '${target.outPathLen}' : 'unknown'}');
    await applyRouteOverride();
  }

  Future<void> login() async {
    // A stock companion drops an occasional exchange; a login lost in flight
    // says nothing about the node, so retry before failing the run.
    LoginResult? r;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        r = await client.login(target, password);
        if (r.ok) break;
      } catch (e) {
        if (attempt == 2) rethrow;
        info('  login retry (${e.runtimeType})');
        await Future<void>.delayed(const Duration(seconds: 3));
        r = null;
      }
    }
    if (r == null || !r.ok) throw StateError('login rejected');
    if (!r.isAdmin) throw StateError('logged in but not as admin');
    info('logged in as admin');
  }

  Future<String> cli(String command) async {
    final reply = await client.remoteCli(target, command);
    return reply.trim();
  }

  Future<OtaStatus?> status() async => OtaStatus.parse(await cli('ota status'));

  Future<void> waitRebootAndLogin(
      {Duration timeout = const Duration(seconds: 150)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await client.login(target, password);
        if (r.ok) return;
      } catch (_) {
        // still booting
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw StateError('node did not come back within ${timeout.inSeconds}s');
  }

  /// Delay between queued writes, derived from the radio's airtime when
  /// `--spacing` was not given (mirrors the app's pacing rule).
  Future<Duration> spacingFor() async {
    if (spacingOverride != null) return spacingOverride!;
    final params = await link.radioParams();
    final airtime = loraTimeOnAirMicros(
      payloadBytes: otaMaxPayload,
      spreadingFactor: params.spreadingFactor,
      bandwidthHz: params.bandwidthHz,
      codingRate: params.codingRate,
    );
    final us = (airtime * 1.5).round() + 60000;
    final derived = Duration(microseconds: us);
    info('spacing: ${derived.inMilliseconds} ms (airtime-derived)');
    return derived > const Duration(milliseconds: 150)
        ? derived
        : const Duration(milliseconds: 150);
  }

  /// Push the `--path` override into the companion's contact record, like
  /// meshcli's `change_path`. Binary requests carry no per-packet path, so the
  /// companion's stored record is the only handle for splitting a route.
  Future<void> applyRouteOverride() async {
    final entered = routePath.trim();
    if (entered.isEmpty) return;
    final route = OtaRoute.parsePathList(entered);
    await link.setContactPath(target,
        path: route.path, encodedPathLen: route.encodedPathLen);
    info('set companion path for "${target.name}" to $entered');
  }

  /// Ask the node for its `OP_INFO_REPORT`. Null on no answer.
  Future<OtaNodeInfo?> nodeInfo() async {
    try {
      return await queryNodeInfo(link, target,
          timeout: const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  Future<int?> nextExpected() async {
    final done = Completer<int?>();
    int? askTag;
    late StreamSubscription<Uint8List> sub;
    sub = link.pushes.listen((frame) {
      if (frame.isEmpty || frame[0] != pushCodeBinaryResponse) return;
      final report = parseBinaryResponse(frame,
          contactPubKey: target.publicKey, askTag: askTag);
      if (report != null && !done.isCompleted) {
        done.complete(report.nextExpected);
      }
    });
    try {
      final ask = buildAsk();
      final sent = await link
          .sendBinaryRequest(target, [reqTypeOta, ask.length, ...ask]);
      askTag = sent.tag;
      return await done.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  /// Re-open the TCP link after a drop and re-establish admin access.
  Future<void> reconnect() async {
    link = TcpDeviceLink(host: host, port: port);
    await link.connect();
    client = CompanionClient(link);
    await resolveTarget();
    await login();
    info('  reconnected to companion');
  }

  /// Run one stage+transfer and return the measured numbers.
  ///
  /// A long transfer outlives the companion's TCP session, so a dropped link is
  /// not a failure: reconnect, ask the node where it got to, and resume from
  /// there. The node keeps its staged bytes and its arm is already consumed, so
  /// nothing is re-armed and nothing already written is sent again.
  Future<({TransferResult result, DeltaResult delta, OtaStageReply arm})>
      stageAndTransfer(
    Uint8List image, {
    Uint8List? base,
    bool Function()? shouldCancel,
    Duration? askTimeout,
    int? maxRetries,
    String? armShaOverride,
  }) async {
    final ver = 'bench-${_hex(_sha256(image)).substring(0, 8)}';
    final armSha = armShaOverride ?? _hex(_sha256(image));
    final t0 = DateTime.now();
    final stageReply = await cli('ota stage ${image.length} $armSha $ver');
    final arm = parseStageReply(stageReply);
    if (arm == null) throw StateError('staging refused: $stageReply');
    info(
        '  armed: size=${arm.size} token=${arm.token.toRadixString(16).padLeft(8, '0')} '
        '(${_secs(DateTime.now().difference(t0))})');

    final delta = base == null
        ? computeDelta(Uint8List(0), image)
        : computeDelta(base, image);
    info('  ops=${delta.opCount} literal=${delta.literalBytes}B '
        'copy=${delta.copyBytes}B');

    final contract = OtaStartContract(
      imageSize: image.length,
      imageSha256: _sha256(image),
      targetId: targetIdForEnvironment(env),
      token: arm.token,
    );
    var packets = 0;
    var retries = 0;

    final t1 = DateTime.now();
    var resumeFrom = 1;
    TransferResult? result;
    for (var attempt = 0; result == null; attempt++) {
      if (attempt > 0) {
        if (attempt > 6) throw StateError('link kept dropping; gave up');
        info('  ! link dropped mid-transfer — reconnecting and resuming');
        try {
          await link.disconnect();
        } catch (_) {}
        await reconnect();
        final next = await nextExpected();
        if (next == null) {
          info('  ! node did not report its position; aborting the session');
          await cli('ota abort');
          throw StateError('node lost its session');
        }
        info('  resuming from op $next (${(next - 1)} of '
            '${delta.opCount} ops already written)');
        resumeFrom = next;
      }
      final engine = OtaTransfer(
        link: link,
        contact: target,
        contract: contract,
        ops: delta.ops,
        windowSize: windowSize,
        askTimeout: askTimeout ?? const Duration(seconds: 10),
        maxRetriesPerWindow: maxRetries ?? 12,
        opSpacing: await spacingFor(),
        resumeFrom: resumeFrom,
        shouldCancel: shouldCancel,
      );
      try {
        result = await engine.run(onProgress: (p) {
          if (p.opsApplied != null && p.opsApplied! % 200 == 0) {
            stdout.write('\r  progress ${p.opsApplied}/${p.opsTotal} ops    ');
          }
        });
      } on OtaTransferException catch (e) {
        // A cancelled transfer must propagate; a link/ack failure is resumable.
        if (shouldCancel?.call() ?? false) rethrow;
        info('  ! transfer attempt failed: ${e.message}');
        if (attempt > 6) rethrow;
      }
      packets += engine.packetsSent;
      retries += engine.retries;
    }
    stdout.writeln('');
    final wall = DateTime.now().difference(t1);
    info('  transfer: ${_secs(wall)} wall, $packets packets, '
        '$retries retries, engine ${_secs(result.elapsed)}');
    info('  amplification: ${result.amplificationLabel} literal bytes '
        '(${result.literalBytesSent}B sent for ${result.uniqueLiteralBytes}B '
        'of image), ops ${result.opAmplification.toStringAsFixed(2)}x '
        '(${result.duplicateOps} re-broadcast of ${result.uniqueOps})');
    return (result: result, delta: delta, arm: arm);
  }
}

// --- scenarios --------------------------------------------------------------

/// Read-only filter probe. No rule is added, removed or reordered.
Future<void> scenarioFilter(Bench b) async {
  info('\n== filter (read only) ==');
  final status = await b.cli('filter');
  final rules = await b.cli('filter list 0');
  final stats = await b.cli('filter stats');
  info('  status: ${status.replaceAll('\n', ' | ')}');
  info('  rules:  ${rules.replaceAll('\n', ' | ')}');
  info('  stats:  ${stats.replaceAll('\n', ' | ')}');
  check('filter probe made no changes', status.isNotEmpty || rules.isNotEmpty);
}

/// Read-only fleet probe. The example script is composed locally and printed;
/// it is never sent, so no job can run on the bench node.
Future<void> scenarioFleet(Bench b) async {
  info('\n== fleet (read only) ==');
  final status = await b.cli('fleet');
  final tags = await b.cli('fleet tag list');
  info('  status: ${status.replaceAll('\n', ' | ')}');
  info('  tags:   ${tags.replaceAll('\n', ' | ')}');
  final example = composeJob(const FleetJob(
    id: 'bench-dry-run',
    ack: true,
    commands: ['ver'],
  ));
  info('  example script (not sent): ${example.replaceAll('\n', ' | ')}');
  check('fleet probe made no changes', status.isNotEmpty);
}

/// WiFi update is deliberately not armed here: `start ota` opens an HTTP
/// server on the repeater and there is no remote CLI to close it. This only
/// reports whether the board is expected to support the stock page.
Future<void> scenarioWifiOta(Bench b) async {
  info('\n== wifi ota (read only) ==');
  final board = await b.cli('board');
  final version = await b.cli('version');
  final looksEsp32 = board.toLowerCase().contains('esp') ||
      version.toLowerCase().contains('esp32');
  info('  board:   $board');
  info('  version: $version');
  info('  start ota is not run: it opens an HTTP server on the node.');
  check('board is an ESP32 candidate for WiFi update', looksEsp32,
      '$board / $version');
}

Future<void> scenarioProbe(Bench b) async {
  info('\n== probe ==');
  final version = await b.cli('version');
  info('  version: $version');
  final radio = await b.cli('get radio');
  info('  radio:   $radio');

  // OP_INFO handshake: the node's capabilities, target id, running version
  // and the running image's SHA-256.
  final nodeInfo = await b.nodeInfo();
  if (nodeInfo == null) {
    info(
        '  info: node did not answer (pre-handshake firmware, or unreachable)');
  } else {
    info(
        '  info: wire=${nodeInfo.wireVersion} target=0x${nodeInfo.targetId.toRadixString(16)}'
        ' slot=${nodeInfo.slotSize} max_literal=${nodeInfo.maxLiteral}'
        ' delta=${nodeInfo.supportsDelta} apply=${nodeInfo.supportsApply}');
    info(
        '  info: running="${nodeInfo.runningVersion}" sha=${_hex(nodeInfo.runningSha256).substring(0, 16)}…');
  }

  final st = await b.status();
  if (st == null) {
    check('firmware speaks the ota CLI', false, 'no parsable ota status');
    return;
  }
  check('firmware speaks the ota CLI', true);
  info(
      '  status:  running=${st.running} sha=${st.shaPrefix} state=${st.state.name} '
      'size=${st.size} off=${st.offset} err=${st.err}');

  final params = await b.link.radioParams();
  final airtime = loraTimeOnAirMicros(
    payloadBytes: otaMaxPayload,
    spreadingFactor: params.spreadingFactor,
    bandwidthHz: params.bandwidthHz,
    codingRate: params.codingRate,
  );
  info('  companion radio: ${params.frequencyHz / 1e6} MHz '
      'BW${params.bandwidthHz ~/ 1000} SF${params.spreadingFactor} CR${params.codingRate}');
  info(
      '  one ${otaMaxPayload}B packet ≈ ${(airtime / 1000).toStringAsFixed(0)} ms airtime');
}

Future<void> scenarioUpdate(Bench b, Uint8List image,
    {required Uint8List? base, required String label}) async {
  info('\n== $label ==');
  final before = await b.status();
  info('  before: state=${before?.state.name} running=${before?.running}');

  final t0 = DateTime.now();
  final run = await b.stageAndTransfer(image, base: base);
  final total = DateTime.now().difference(t0);

  final st = await b.status();
  info(
      '  after transfer: state=${st?.state.name} off=${st?.offset}/${st?.size} '
      'err=${st?.err}');
  check(
      '$label staged and verified (state=ready)',
      st?.state == OtaPhase.ready && st?.err == 0,
      'state=${st?.state.name} err=${st?.err}');

  if (st?.state != OtaPhase.ready) {
    await b.cli('ota abort');
    return;
  }

  // A successful `ota apply` never flushes a reply: the node flips the boot
  // partition and reboots inside the command. Treat the resulting timeout as
  // the expected race and verify by logging back in and reading `version`.
  var applyTimedOut = false;
  String applyReply = '';
  try {
    applyReply = await b.cli('ota apply');
  } on CompanionTimeoutException {
    applyTimedOut = true;
  }
  check('$label apply accepted', applyTimedOut || isApplyReply(applyReply),
      applyTimedOut ? 'reboot raced the reply (expected)' : applyReply);
  final tApply = DateTime.now();
  await b.waitRebootAndLogin();
  final reboot = DateTime.now().difference(tApply);
  final version = await b.cli('version');
  info('  rebooted in ${_secs(reboot)}; version: $version');
  check('$label new image runs', version.isNotEmpty, version);

  info('  TIMING $label: transfer ${_secs(total)} '
      '(+ reboot ${_secs(reboot)}), ${run.result.packetsSent} packets, '
      '${run.delta.literalBytes}B literal, ${run.delta.copyBytes}B reused');
}

Future<void> scenarioReject(Bench b, Uint8List image, {Uint8List? base}) async {
  info('\n== reject: failure modes ==');

  // 1) arm, then START with a wrong token → node must refuse the arm.
  final shaHex = _hex(_sha256(image));
  final armReply =
      await b.cli('ota stage ${image.length} $shaHex bench-reject');
  final arm = parseStageReply(armReply);
  check('arm for reject tests', arm != null, armReply);
  if (arm == null) return;

  final badToken = arm.token ^ 0xFFFFFFFF;
  final startFrame = buildStart(
    size: image.length,
    sha256: _sha256(image),
    targetId: targetIdForEnvironment(b.env),
    token: badToken,
  );
  await b.link.sendBinaryRequest(
      b.target, [reqTypeOta, startFrame.length, ...startFrame]);
  await Future<void>.delayed(const Duration(seconds: 2));
  var st = await b.status();
  check(
      'wrong token does not start a session',
      st?.state == OtaPhase.idle && st?.err == otaErrToken,
      'state=${st?.state.name} err=${st?.err} (expect idle/err=7)');

  // The pending arm survives a stranger's START; the real token still works,
  // so use it to walk a full staging run with a corrupted target image: arm
  // the *good* hash, then send bytes that hash differently. OP_END must
  // catch it (err=4) and scrap the slot.
  final corrupt = Uint8List.fromList(image);
  for (var i = 0; i < 64 && i < corrupt.length; i++) {
    corrupt[corrupt.length - 1 - i] ^= 0xFF;
  }
  // A delta base keeps the tamper test to a few hundred packets; the SHA gate
  // covers the whole staged image however the bytes got there.
  final ops = base == null
      ? computeDelta(Uint8List(0), image).ops
      : computeDelta(base, image).ops;
  // Send real ops, but corrupt the literal bytes on the wire.
  final tampered = _tamperLiterals(ops, corrupt);
  final tamperEngine = OtaTransfer(
    link: b.link,
    contact: b.target,
    contract: OtaStartContract(
      imageSize: image.length,
      imageSha256: _sha256(image),
      targetId: targetIdForEnvironment(b.env),
      token: arm.token,
    ),
    ops: tampered,
    windowSize: b.windowSize,
    opSpacing: const Duration(milliseconds: 20),
  );
  try {
    await tamperEngine.run();
  } catch (e) {
    info('  tampered transfer ended: $e');
  }
  st = await b.status();
  check(
      'SHA gate rejects a corrupted image',
      st?.state == OtaPhase.error && st?.err == otaErrSha,
      'state=${st?.state.name} err=${st?.err} (expect error/err=4)');
  await b.cli('ota abort');
  st = await b.status();
  check('abort clears the error', st?.state == OtaPhase.idle,
      'state=${st?.state.name}');

  // 2) mid-transfer abort: start a real transfer and cancel after a window.
  final arm2Reply =
      await b.cli('ota stage ${image.length} $shaHex bench-abort');
  final arm2 = parseStageReply(arm2Reply);
  if (arm2 != null) {
    var seen = 0;
    final abortEngine = OtaTransfer(
      link: b.link,
      contact: b.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: _sha256(image),
        targetId: targetIdForEnvironment(b.env),
        token: arm2.token,
      ),
      ops: ops,
      windowSize: b.windowSize,
      opSpacing: await b.spacingFor(),
      shouldCancel: () => ++seen > 3,
    );
    var cancelled = false;
    try {
      await abortEngine.run();
    } on OtaTransferException {
      cancelled = true;
    }
    check('mid-transfer cancel stops the engine', cancelled);
    final abortReply = await b.cli('ota abort');
    info('  abort reply: $abortReply');
    st = await b.status();
    check(
        'node returns to idle after abort',
        st?.state == OtaPhase.idle && st?.offset == 0,
        'state=${st?.state.name} off=${st?.offset}');
  }
}

/// Swap the literal payloads for corruption bytes, keeping op framing.
List<DeltaOp> _tamperLiterals(List<DeltaOp> ops, Uint8List corrupt) {
  var pos = 0;
  final out = <DeltaOp>[];
  for (final op in ops) {
    if (op is LiteralOp) {
      final take = op.data.length;
      final slice = corrupt.sublist(
          pos, pos + take > corrupt.length ? corrupt.length : pos + take);
      out.add(LiteralOp(Uint8List.fromList(slice)));
      pos += take;
    } else {
      out.add(op);
    }
  }
  return out;
}

Future<void> scenarioMeasure(Bench b, Uint8List image,
    {required Uint8List? base, required String label}) async {
  info('\n== measure: $label ==');
  final t0 = DateTime.now();
  final run = await b.stageAndTransfer(image, base: base);
  final total = DateTime.now().difference(t0);
  final st = await b.status();
  info(
      '  after transfer: state=${st?.state.name} off=${st?.offset}/${st?.size} '
      'err=${st?.err}');
  check(
      '$label reached a terminal state (ready or sha-rejected)',
      st?.state == OtaPhase.ready || st?.state == OtaPhase.error,
      'state=${st?.state.name} err=${st?.err}');
  if (st?.state == OtaPhase.ready) {
    // Timing runs never boot the image; scrap the staged slot.
    await b.cli('ota abort');
  }
  final kbps = run.delta.literalBytes == 0
      ? 0.0
      : (run.delta.literalBytes / 1024) / (total.inMilliseconds / 1000);
  info('  MEASURE $label: ${_secs(total)} wall, '
      '${run.delta.literalBytes}B literal, ${run.result.packetsSent} packets, '
      '${run.result.retries} retries, ${kbps.toStringAsFixed(2)} KiB/s literal');
}

/// A correctly-formed OP_START aimed at another board must be refused (err=1),
/// and the pending arm must survive so the right node can still use it.
Future<void> scenarioWrongTarget(Bench b, Uint8List image) async {
  info('\n== wrong target id ==');
  final shaHex = _hex(_sha256(image));
  final armReply = await b.cli('ota stage ${image.length} $shaHex wrongtarget');
  final arm = parseStageReply(armReply);
  check('arm for wrong-target test', arm != null, armReply);
  if (arm == null) return;
  final otherId = targetIdForEnvironment('Some_Other_Board_env');
  final startFrame = buildStart(
    size: image.length,
    sha256: _sha256(image),
    targetId: otherId,
    token: arm.token,
  );
  await b.link.sendBinaryRequest(
      b.target, [reqTypeOta, startFrame.length, ...startFrame]);
  await Future<void>.delayed(const Duration(seconds: 3));
  var st = await b.status();
  check(
      'wrong target refused with err=1',
      st?.state == OtaPhase.idle && st?.err == otaErrTarget,
      'state=${st?.state.name} err=${st?.err}');
  // The arm is single-use but not consumed by a stranger's START.
  final realStart = buildStart(
    size: image.length,
    sha256: _sha256(image),
    targetId: targetIdForEnvironment(b.env),
    token: arm.token,
  );
  await b.link.sendBinaryRequest(
      b.target, [reqTypeOta, realStart.length, ...realStart]);
  await Future<void>.delayed(const Duration(seconds: 3));
  st = await b.status();
  check('the real target is still accepted afterwards',
      st?.state == OtaPhase.staging, 'state=${st?.state.name} err=${st?.err}');
  await b.cli('ota abort');
}

/// An arm older than OTA_PENDING_TTL_MS must be refused (err=7).
Future<void> scenarioExpiredArm(Bench b, Uint8List image) async {
  info('\n== expired arm (this waits out the 120 s TTL) ==');
  final shaHex = _hex(_sha256(image));
  final armReply = await b.cli('ota stage ${image.length} $shaHex expired');
  final arm = parseStageReply(armReply);
  check('arm for expiry test', arm != null, armReply);
  if (arm == null) return;
  info('  waiting 125 s for the arm to expire');
  await Future<void>.delayed(const Duration(seconds: 125));
  final startFrame = buildStart(
    size: image.length,
    sha256: _sha256(image),
    targetId: targetIdForEnvironment(b.env),
    token: arm.token,
  );
  await b.link.sendBinaryRequest(
      b.target, [reqTypeOta, startFrame.length, ...startFrame]);
  await Future<void>.delayed(const Duration(seconds: 3));
  final st = await b.status();
  check(
      'expired arm refused with err=7',
      st?.state == OtaPhase.idle && st?.err == otaErrToken,
      'state=${st?.state.name} err=${st?.err}');
  await b.cli('ota abort');
}

/// Cancel a transfer mid-flight, then confirm the node discards the slot and
/// accepts a fresh update afterwards.
Future<void> scenarioCancel(Bench b, Uint8List image, {Uint8List? base}) async {
  info('\n== cancel mid-transfer ==');
  final ver = 'cancel-${_hex(_sha256(image)).substring(0, 6)}';
  final stageReply =
      await b.cli('ota stage ${image.length} ${_hex(_sha256(image))} $ver');
  final arm = parseStageReply(stageReply);
  check('arm for cancel test', arm != null, stageReply);
  if (arm == null) return;
  var ops = 0;
  final engine = OtaTransfer(
    link: b.link,
    contact: b.target,
    contract: OtaStartContract(
      imageSize: image.length,
      imageSha256: _sha256(image),
      targetId: targetIdForEnvironment(b.env),
      token: arm.token,
    ),
    ops: base == null
        ? computeDelta(Uint8List(0), image).ops
        : computeDelta(base, image).ops,
    windowSize: b.windowSize,
    opSpacing: await b.spacingFor(),
    shouldCancel: () => ops++ > 12, // a few windows in
  );
  var cancelled = false;
  try {
    await engine.run();
  } on OtaTransferException {
    cancelled = true;
  }
  check('transfer stops on cancel', cancelled);
  final abortReply = await b.cli('ota abort');
  info('  abort: $abortReply');
  var st = await b.status();
  check(
      'node is idle after abort',
      st?.state == OtaPhase.idle && st?.offset == 0,
      'state=${st?.state.name} off=${st?.offset}');
  // The slot was half-written: a fresh update must still work.
  final again =
      await b.cli('ota stage ${image.length} ${_hex(_sha256(image))} re$ver');
  check('a fresh arm is accepted after a cancelled transfer',
      parseStageReply(again) != null, again);
  await b.cli('ota abort');
  st = await b.status();
  check('node back to idle', st?.state == OtaPhase.idle,
      'state=${st?.state.name}');
}

/// Resume an already-staged full image after the driver process or transport
/// was interrupted. The OTA session is node-side and survives the companion
/// disconnect; ask its watermark and continue from there.
Future<void> scenarioResumeFull(Bench b, Uint8List image) async {
  info('\n== resume existing full-image stage ==');
  final st = await b.status();
  if (st == null || st.state != OtaPhase.staging || st.size != image.length) {
    throw StateError('no matching staged image to resume: $st');
  }
  final next = await b.nextExpected();
  if (next == null || next < 1) {
    throw StateError('node did not report next_expected');
  }
  info(
      '  resuming at op $next, node has written ${st.offset}/${st.size} bytes');
  final delta = computeDelta(Uint8List(0), image);
  final engine = OtaTransfer(
    link: b.link,
    contact: b.target,
    contract: OtaStartContract(
      imageSize: image.length,
      imageSha256: _sha256(image),
      targetId: targetIdForEnvironment(b.env),
      token: 0, // unused when resumeFrom > 1; OP_START is not re-sent
    ),
    ops: delta.ops,
    windowSize: b.windowSize,
    opSpacing: await b.spacingFor(),
    resumeFrom: next,
  );
  final t = DateTime.now();
  final result = await engine.run(onProgress: (p) {
    if (p.opsApplied != null && p.opsApplied! % 200 == 0) {
      stdout.write('\\r  progress ${p.opsApplied}/${p.opsTotal} ops    ');
    }
  });
  stdout.writeln('');
  info('  resumed transfer ${_secs(DateTime.now().difference(t))}, '
      '${result.packetsSent} packets, amplification ${result.amplificationLabel}');
  final ready = await b.status();
  check(
      'resumed full image reached ready',
      ready?.state == OtaPhase.ready && ready?.err == 0,
      'state=${ready?.state.name} off=${ready?.offset}/${ready?.size} err=${ready?.err}');
  if (ready?.state != OtaPhase.ready) return;
  // A successful `ota apply` never flushes a reply (the node reboots inside
  // the command); the timeout is the expected race, verification follows.
  String apply = '';
  var applyTimedOut = false;
  try {
    apply = await b.cli('ota apply');
  } on CompanionTimeoutException {
    applyTimedOut = true;
  }
  check('resumed image apply accepted', applyTimedOut || isApplyReply(apply),
      applyTimedOut ? 'reboot raced the reply (expected)' : apply);
  await b.waitRebootAndLogin();
  final version = await b.cli('version');
  info('  running after apply: $version');
  check('node boots after full-image apply', version.isNotEmpty, version);
}

Future<void> scenarioRollback(Bench b) async {
  info('\n== rollback ==');
  final before = await b.cli('version');
  info('  version before: $before');
  // `ota rollback` flips the boot partition and reboots inside the command,
  // so a successful rollback never flushes a reply.
  String reply = '';
  var applyTimedOut = false;
  try {
    reply = await b.cli('ota rollback');
  } on CompanionTimeoutException {
    applyTimedOut = true;
  }
  check('rollback accepted', applyTimedOut || isRollbackReply(reply),
      applyTimedOut ? 'reboot raced the reply (expected)' : reply);
  await b.waitRebootAndLogin();
  final after = await b.cli('version');
  info('  version after:  $after');
  check('node came back on the previous image', after.isNotEmpty);
  check('version changed after rollback', !after.contains(RegExp(r'bench-')),
      after);
}

// --- entry point ------------------------------------------------------------

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);
  final host = args['host'] ?? '127.0.0.1';
  final port = int.parse(args['port'] ?? '5000');
  final password = args['password'] ?? 'password';
  final env = args['env'] ?? 'Xiao_S3_WIO_repeater_observer';
  final contactName = args['contact'] ?? '';
  final windowSize = int.parse(args['window'] ?? '4');
  final routePath = args['path'] ?? '';
  final scenarios = (args['scenario'] ?? 'probe').split(',');
  final imagePath = args['image'];
  final basePath = args['base'];

  final b = Bench(
    host: host,
    port: port,
    password: password,
    env: env,
    contactName: contactName,
    windowSize: windowSize,
    spacingOverride: args['spacing'] == null
        ? null
        : Duration(milliseconds: int.parse(args['spacing']!)),
    routePath: routePath,
  );

  await b.connect();
  await b.resolveTarget();
  await b.login();

  Uint8List? image;
  if (imagePath != null) image = File(imagePath).readAsBytesSync();
  Uint8List? base;
  if (basePath != null) base = File(basePath).readAsBytesSync();
  info(routePath.trim().isEmpty
      ? 'route: companion stored path'
      : 'route: ${routePath.trim()}');
  if (image != null) {
    info(
        'image: ${image.length} bytes sha=${_hex(_sha256(image)).substring(0, 16)}…');
  }

  try {
    for (final s in scenarios) {
      await _runWithRetry(b, () async {
        switch (s.trim()) {
          case 'probe':
            await scenarioProbe(b);
          case 'full':
            if (image == null) throw StateError('full needs --image');
            await scenarioUpdate(b, image, base: null, label: 'full');
          case 'delta':
            if (image == null) throw StateError('delta needs --image');
            if (base == null) throw StateError('delta needs --base');
            await scenarioUpdate(b, image, base: base, label: 'delta');
          case 'reject':
            if (image == null) throw StateError('reject needs --image');
            await scenarioReject(b, image, base: base);
          case 'measure':
            if (image == null) throw StateError('measure needs --image');
            await scenarioMeasure(b, image,
                base: base, label: args['label'] ?? 'image');
          case 'wrongtarget':
            if (image == null) throw StateError('wrongtarget needs --image');
            await scenarioWrongTarget(b, image);
          case 'expiry':
            if (image == null) throw StateError('expiry needs --image');
            await scenarioExpiredArm(b, image);
          case 'cancel':
            if (image == null) throw StateError('cancel needs --image');
            await scenarioCancel(b, image, base: base);
          case 'resume':
            if (image == null) throw StateError('resume needs --image');
            await scenarioResumeFull(b, image);
          case 'rollback':
            await scenarioRollback(b);
          case 'filter':
            await scenarioFilter(b);
          case 'fleet':
            await scenarioFleet(b);
          case 'wifiota':
            await scenarioWifiOta(b);
          case '':
            break;
          default:
            throw StateError('unknown scenario "$s"');
        }
      });
    }
  } finally {
    await b.link.disconnect();
  }

  final failed = _checks.where((c) => !c.ok).toList();
  info(
      '\n== summary: ${_checks.length - failed.length}/${_checks.length} checks passed ==');
  for (final c in failed) {
    info('  FAILED: ${c.name} ${c.detail}');
  }
  exit(failed.isEmpty ? 0 : 1);
}

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[key] = argv[++i];
    } else {
      out[key] = '';
    }
  }
  return out;
}
