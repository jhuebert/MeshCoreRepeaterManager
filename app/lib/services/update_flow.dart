import 'dart:async';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';

/// Errors from the update flow, with the device's own reply when there is one.
class UpdateFlowException implements Exception {
  UpdateFlowException(this.message, {this.deviceReply});

  final String message;

  /// The `Err - ...` line the device produced, when applicable.
  final String? deviceReply;

  @override
  String toString() =>
      deviceReply == null ? message : '$message ($deviceReply)';
}

/// Orchestrates one over-the-air update: login → probe → stage → transfer →
/// apply → post-reboot verification. App-side "all intelligence": it picks
/// images and transfer parameters; the node only applies ops and SHA-256s.
///
/// The repeater never reboots until the operator confirms the staged image
/// passed its SHA gate (`ota apply`), and a failed health check flips back
/// automatically in the fork firmware.
class UpdateFlow {
  UpdateFlow({required this.client, required this.link, this.onLog});

  final CompanionClient client;
  final RadioLink link;

  /// Receives one-line traces of recovery decisions (e.g. a stranded
  /// staging being cleared); the app wires it to its log view.
  final void Function(String message)? onLog;

  /// Login (admin) and read `ota status`. Throws with the device's reply on
  /// failure; returns null when the node rejected admin (or the firmware
  /// does not speak the ota CLI at all — e.g. pre-fork stock firmware).
  Future<OtaStatus?> probe(Contact target, String password) async {
    final login = await client.login(target, password);
    if (!login.ok) {
      throw UpdateFlowException('login rejected');
    }
    if (!login.isAdmin) {
      throw UpdateFlowException('logged in, but not as admin: OTA needs admin');
    }
    final reply = await _cli(target, 'ota status');
    return OtaStatus.parse(reply);
  }

  /// Best-effort `OP_INFO` handshake. Returns null when the node does not
  /// answer (e.g. firmware older than the handshake) — the caller treats
  /// null as "unknown, proceed". Sign-in uses the short default so a node
  /// without the handshake cannot stall the wizard; callers that genuinely
  /// need the target id can wait longer with [timeout].
  Future<OtaNodeInfo?> tryNodeInfo(Contact target,
      {Duration timeout = const Duration(seconds: 2)}) async {
    try {
      return await queryNodeInfo(link, target, timeout: timeout);
    } catch (_) {
      return null;
    }
  }

  /// Best-effort `OP_STATUS` query: the structured counterpart of `ota status`
  /// that also carries the session id, upload position and capability bits.
  /// Null when the node does not implement the op or the reply is lost.
  Future<OtaNodeStatus?> nodeStatus(Contact target,
      {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      return await queryNodeStatus(link, target, timeout: timeout);
    } catch (_) {
      return null;
    }
  }

  /// Echo a small payload over the op path to check the live REQ/RESPONSE
  /// route before committing to a transfer. Null on timeout/unsupported.
  Future<Uint8List?> ping(Contact target,
      {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      return await pingNode(link, target, timeout: timeout);
    } catch (_) {
      return null;
    }
  }

  /// `ota status`, or null when the node does not answer with the frozen
  /// reply (pre-OTA firmware, link failure).
  Future<OtaStatus?> status(Contact target) async {
    try {
      return OtaStatus.parse(await _cli(target, 'ota status'));
    } catch (_) {
      return null;
    }
  }

  /// Ask the node which op sequence it expects next. This is the authority for
  /// a resumed transfer: the node applies ops strictly in order, so everything
  /// below this number has already been committed and must not be sent again.
  /// Returns null when the node did not answer (no live staging session, or a
  /// lost reply).
  Future<int?> nextExpected(Contact target) async {
    final done = Completer<int?>();
    int? askTag;
    late StreamSubscription<Uint8List> sub;
    sub = link.pushes.listen((frame) {
      if (frame.isEmpty || frame[0] != pushCodeBinaryResponse) return;
      final report = parseBinaryResponse(frame,
          contactPubKey: target.publicKey,
          askTag: askTag,
          exactLength: otaReportLen);
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

  /// Clear a stranded staging so the next arm can take effect.
  ///
  /// A previous attempt that died mid-transfer leaves the node in
  /// `staging` with a partial image, and `OP_START` refuses to replace it
  /// ("a busy session keeps its place") — so every later arm is silently
  /// refused and every op is dropped as out-of-order. `ready` is a
  /// verified image nobody applied; there is no UI to apply a stale one
  /// later, so a fresh arm must clear it too rather than "verify" and
  /// apply the wrong image. Returns what it found (null when the node is
  /// clean or did not answer).
  Future<OtaPhase?> clearStaleStaging(Contact target) async {
    final s = await status(target);
    if (s == null) return null;
    if (s.state == OtaPhase.staging || s.state == OtaPhase.ready) {
      onLog?.call(s.state == OtaPhase.ready
          ? 'discarding a verified staging that was never applied'
          : 'clearing a stranded partial staging (off=${s.offset} of ${s.size} bytes)');
      await abortQuietly(target);
    }
    return s.state;
  }

  /// Arm the node with the exact image to stage. Returns the parsed arm
  /// contract (size + token) to hand to the transfer.
  ///
  /// When [expectedTargetId] is set, the node is first asked for its
  /// capabilities: a definitive board mismatch aborts *before* a pending arm
  /// is registered. A node that does not answer `OP_INFO` is treated as
  /// unknown and the arm proceeds as before (the SHA gate catches it later).
  Future<OtaStageReply> stage(
    Contact target,
    Uint8List image, {
    required String version,
    int? expectedTargetId,
  }) async {
    await clearStaleStaging(target);
    if (expectedTargetId != null) {
      final info = await tryNodeInfo(target);
      if (info != null && info.targetId != expectedTargetId) {
        throw UpdateFlowException(
            'node is board ${info.targetId.toRadixString(16).padLeft(8, '0')}…, '
            'image is for ${expectedTargetId.toRadixString(16).padLeft(8, '0')}…');
      }
    }
    final sha = sha256.convert(image).toString();
    final reply = await _cli(target, 'ota stage ${image.length} $sha $version');
    final parsed = parseStageReply(reply);
    if (parsed == null) {
      throw UpdateFlowException('staging was refused', deviceReply: reply);
    }
    return parsed;
  }

  /// Run the op-stream transfer against an armed node.
  ///
  /// The ops ride inside binary requests (`CMD_SEND_BINARY_REQ`): the
  /// companion encrypts them as ordinary REQ datagrams and routes them to
  /// [target] using its stored contact record. A hand-built [route] (the
  /// review screen's path override) has no per-packet field to ride, so it is
  /// pushed into the companion as the contact's path first: like `change_path`
  /// in meshcli — and takes effect for this and later sessions until the
  /// companion's record is changed again.
  Future<TransferResult> transfer({
    required Contact target,
    required OtaStartContract contract,
    required List<DeltaOp> ops,
    required OtaRoute route,
    void Function(TransferProgress)? onProgress,
    // Awaited between windows (e.g. renewing the repeater's tempradio window).
    Future<void> Function()? onWindowBoundary,
    int windowSize = 12,
    WireOps? wireOps,
    int resumeFrom = 1,
    // Overrides the airtime-derived pacing (tests, or a caller that already
    // knows better).
    Duration? opSpacing,
    bool Function()? shouldCancel,
  }) async {
    if (route.manual) {
      try {
        await link.setContactPath(target,
            path: route.path, encodedPathLen: route.encodedPathLen);
      } catch (e) {
        throw UpdateFlowException(
            'could not set the manual path on the companion: $e');
      }
    }
    final spacing = opSpacing ?? await _pacing();
    final engine = OtaTransfer(
      link: link,
      contact: target,
      contract: contract,
      ops: ops,
      prebuiltOps: wireOps,
      resumeFrom: resumeFrom,
      windowSize: windowSize,
      askTimeout: const Duration(seconds: 10),
      maxRetriesPerWindow: 12,
      // Pace to the radio, not to the companion's queue. One maximum-size
      // packet of airtime plus a short commit margin is enough; on hardware
      // tighter spacing travelled faster without costing extra re-sends.
      opSpacing: spacing,
      // One cheap ask after the window covers the tail's commit; a longer
      // settle just adds latency to every window.
      askSettle: const Duration(milliseconds: 100),
      shouldCancel: shouldCancel,
    );
    final result = await engine.run(
      onProgress: onProgress,
      onWindowBoundary: onWindowBoundary,
    );
    return result;
  }

  /// Delay between queued ops, derived from the radio's airtime.
  ///
  /// A full-size op frame occupies the channel for its whole airtime, and the
  /// node then commits it to flash. Queueing faster than that merely builds a
  /// backlog of ops the node has not written yet, which the window report then
  /// reads as "missing" — so every window gets re-broadcast. Falls back to a
  /// safe constant when the radio parameters are unavailable.
  Future<Duration> _pacing() async {
    const fallback = Duration(milliseconds: 150);
    try {
      final p = await link.radioParams();
      final airtime = loraTimeOnAirMicros(
        payloadBytes: otaMaxPayload,
        spreadingFactor: p.spreadingFactor,
        bandwidthHz: p.bandwidthHz,
        codingRate: p.codingRate,
      );
      final us = airtime.round() + 60000; // airtime + commit margin
      final candidate = Duration(microseconds: us);
      return candidate > fallback ? candidate : fallback;
    } catch (_) {
      return fallback;
    }
  }

  /// After the transfer, poll `ota status` until the node reports ready.
  ///
  /// The SHA-256 verification at OP_END runs inside the node and is not
  /// instant: a single read right after the transfer can catch the node
  /// still in staging (err=0, off=size), which is a commit race, not a
  /// failure. Poll until ready, a definite error, or the deadline passes.
  Future<OtaStatus> awaitReady(Contact target,
      {Duration timeout = const Duration(seconds: 60),
      Duration interval = const Duration(milliseconds: 500)}) async {
    final deadline = DateTime.now().add(timeout);
    for (;;) {
      final reply = await _cli(target, 'ota status');
      final status = OtaStatus.parse(reply);
      if (status == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw UpdateFlowException('unparseable ota status',
              deviceReply: reply);
        }
        await Future<void>.delayed(interval);
        continue;
      }
      switch (status.state) {
        case OtaPhase.ready:
          return status;
        case OtaPhase.error:
        case OtaPhase.unsupported:
          throw UpdateFlowException(
            'the staged image did not pass verification (${otaErrLabel(status.err)})',
            deviceReply: reply,
          );
        default:
          if (DateTime.now().isAfter(deadline)) {
            throw UpdateFlowException(
              'the node did not finish verifying the staged image in time',
              deviceReply: reply,
            );
          }
          await Future<void>.delayed(interval);
      }
    }
  }

  /// `ota apply` — boot the verified image. The node reboots; the app link
  /// to the companion is unaffected.
  ///
  /// Returns true only for an explicit acknowledgement. A timed-out reply is
  /// reported as false (not thrown) so the caller can consult `ota status`:
  /// the node may have applied and rebooted, or the request may never have
  /// arrived. A textual Err reply is a definite refusal and throws.
  Future<bool> apply(Contact target) async {
    String reply;
    try {
      reply = await _cli(target, 'ota apply');
    } catch (_) {
      return false;
    }
    if (!isApplyReply(reply)) {
      throw UpdateFlowException('apply refused', deviceReply: reply);
    }
    return true;
  }

  /// Cancel a staged update and scrape the staging slot.
  Future<void> abort(Contact target) => _cli(target, 'ota abort');

  /// Roll back to the previous partition. The node reboots.
  Future<void> rollback(Contact target) async {
    String reply;
    try {
      reply = await _cli(target, 'ota rollback');
    } catch (_) {
      // The rollback command reboots the node too; the reply can be lost for
      // the same reason as `ota apply`. The caller verifies that it came back.
      return;
    }
    if (!isRollbackReply(reply)) {
      throw UpdateFlowException('rollback refused', deviceReply: reply);
    }
  }

  /// Drop the armed staging state on the node and leave it idle.
  Future<void> abortQuietly(Contact target) async {
    try {
      await abort(target);
    } catch (_) {}
  }

  /// After an apply/rollback reboot, re-login and poll `version` until its
  /// version token equals [expectedVersion] (e.g. `v1.18.0-r4`) or the timeout
  /// expires. The CLI appends `(Build: ...)`; comparing whole tokens avoids a
  /// short stamp matching a longer one.
  ///
  /// Returns true when the new firmware answered. False means the node is
  /// still on the old partition — either the boot health check flipped it
  /// back or the image is broken; the UI says so honestly.
  Future<bool> awaitVersion(
    Contact target,
    String password,
    String expectedVersion, {
    Uint8List? expectedImageSha256,
    Duration timeout = const Duration(seconds: 120),
    Duration interval = const Duration(seconds: 3),
    void Function()? onTick,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final expectedPrefix = expectedImageSha256 == null
        ? null
        : bytesToHex(expectedImageSha256.sublist(0, 8));
    while (DateTime.now().isBefore(deadline)) {
      onTick?.call();
      try {
        // The rebooted node forgets the login; sign back in before asking.
        final login = await client.login(target, password);
        if (login.ok) {
          if (expectedPrefix != null) {
            final s = await status(target);
            if (s != null &&
                s.shaPrefix != '0000000000000000' &&
                s.shaPrefix.toLowerCase() == expectedPrefix) {
              return true;
            }
            // A mismatch means the node booted a different image (it may
            // still roll back); all-zeros means it cannot report — either
            // way, the version string is the fallback below.
          }
          final v = (await client.remoteCli(target, 'version')).trim();
          final token = v.split(RegExp(r'\s+')).first;
          if (token == expectedVersion) return true;
        }
      } catch (_) {
        // Still booting — keep polling.
      }
      await Future<void>.delayed(interval);
    }
    return false;
  }

  /// Poll after an apply attempt until the node gives a definitive answer.
  ///
  /// Unlike [awaitVersion], this distinguishes "still holding the verified
  /// staging" from "back on the old image", so an unacknowledged apply can be
  /// retried without uploading the image again. A hash match is still the
  /// only result that counts as verified.
  Future<ApplyOutcome> awaitApplyOutcome(
    Contact target,
    String password,
    String expectedVersion, {
    Uint8List? expectedImageSha256,
    required int expectedSize,
    Duration timeout = const Duration(seconds: 30),
    Duration interval = const Duration(seconds: 3),
    void Function()? onTick,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final expectedPrefix = expectedImageSha256 == null
        ? ''
        : bytesToHex(expectedImageSha256.sublist(0, 8));
    while (DateTime.now().isBefore(deadline)) {
      onTick?.call();
      try {
        final login = await client.login(target, password);
        if (login.ok) {
          final verdict = classifyApplyOutcome(
            await status(target),
            expectedShaPrefix: expectedPrefix,
            expectedSize: expectedSize,
          );
          if (verdict != ApplyOutcome.unknown) return verdict;
          // Old firmware may not parse `ota status`; a version match is a
          // weaker but still explicit answer.
          final v = (await client.remoteCli(target, 'version')).trim();
          if (v.contains(expectedVersion)) return ApplyOutcome.verified;
        }
      } catch (_) {
        // Still booting — keep polling.
      }
      await Future<void>.delayed(interval);
    }
    return ApplyOutcome.unknown;
  }

  Future<String> _cli(Contact target, String command) =>
      client.remoteCli(target, command);
}
