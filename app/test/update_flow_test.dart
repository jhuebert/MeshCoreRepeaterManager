import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/radio_plan.dart';
import 'package:meshcore_repeater_manager/services/resume_store.dart';
import 'package:meshcore_repeater_manager/services/update_flow.dart';
import 'package:ota_core/ota_core.dart';

import 'support.dart';

/// A fake companion with a fork-firmware repeater behind it, speaking real
/// companion frames and the fork's OTA op interpreter. Exercises the app's
/// whole OTA path: login → probe → stage → wire transfer → ready → apply →
/// post-reboot verify. Stateful like the real node, including SHA-gated
/// apply.
class _RebootReplyLostClient extends CompanionClient {
  _RebootReplyLostClient(super.link);

  @override
  Future<String> remoteCli(Contact target, String command,
      {Duration timeout = const Duration(seconds: 45)}) async {
    if (command == 'ota apply' || command == 'ota rollback') {
      throw CompanionTimeoutException('reboot raced the CLI reply');
    }
    return super.remoteCli(target, command, timeout: timeout);
  }
}

/// Drops the first `ota apply` request entirely (no reply, no apply), then
/// behaves normally — models a lost command on a busy mesh.
class _LostFirstApplyClient extends CompanionClient {
  _LostFirstApplyClient(super.link);

  int applyCalls = 0;

  @override
  Future<String> remoteCli(Contact target, String command,
      {Duration timeout = const Duration(seconds: 45)}) async {
    if (command == 'ota apply') {
      applyCalls++;
      if (applyCalls == 1) {
        throw CompanionTimeoutException('apply request was lost');
      }
    }
    return super.remoteCli(target, command, timeout: timeout);
  }
}

class _FakeCompanion {
  _FakeCompanion() {
    _running = _pattern(0x11, 8192);
    _previousImage = Uint8List(0);
  }

  /// The repeater's contact record as known by the companion.
  final Contact target = Contact(
    publicKey: Uint8List.fromList(
        List<int>.generate(32, (i) => (0x30 + i * 3) & 0xFF)),
    name: 'tower-1',
    advType: advTypeRepeater,
  );

  late Uint8List _running;
  Uint8List? _staging;
  String _nodeVersion = 'v1.17.0';
  String? _previousVersion;
  Uint8List _previousImage = Uint8List(0);

  // arm state (what `ota stage` registers)
  bool _armValid = false;
  int _armSize = 0;
  List<int> _armSha = const [];
  int _armToken = 0;

  /// Test seam: override the target id the fake node reports in OP_INFO;
  /// 0 = report the Xiao_S3_WIO_repeater id (the default).
  int infoTargetOverride = 0;

  /// Test seam: drop OP_INFO requests silently (pre-handshake firmware).
  bool infoSilent = false;

  /// Test seam: keep `ota status` reporting staging (SHA verify pending) for
  /// this many reads before flipping to ready — models the commit race.
  int readyPollsDelay = 0;

  /// Test seam: have `ota status` answer with an unparseable reply this many
  /// times, then answer normally.
  int garbageStatusReads = 0;

  /// Test seam: make the `ota status` CLI throw (link failure), ignoring
  /// [garbageStatusReads].
  bool statusCommandThrows = false;

  /// Test seam: refuse every `ota stage` arm (e.g. the inactive slot is too
  /// small for this image).
  bool stageRefused = false;

  /// Test seam: advertise the new capability API and answer its ops.
  bool advertiseNewOps = false;
  bool pingSilent = false;
  int _sessionId = 0; // minted at OP_START, like the firmware

  /// Test seam: abort() invocations.
  int abortCount = 0;

  /// Test seam: observe `tempradio` arm/restore commands.
  final List<String> tempradioCommands = <String>[];

  /// Number of OP_STAGED_HASH requests answered, including refusals.
  int stagedHashQueries = 0;

  /// Reply to the read-only radio2 status query used during probe.
  String radio2StatusReply = 'off; preset=0,0,0,0';

  bool get isStaging => _staging != null;

  // op-interpreter state
  int _expect = 1;
  int _written = 0;
  int _size = 0;
  List<int> _expectedSha = const [];
  bool _ready = false;

  /// err= code for the CLI replies; 4 = SHA gate refused the staged image.
  int _error = 0;

  /// Test seam: leave the node in a stranded partial staging.
  void forceStaging({int size = 1452512, int off = 933485}) {
    _staging = Uint8List(size);
    _size = size;
    _written = off;
    _expect = 5086;
    _ready = false;
    _error = 0;
  }

  /// Test seam: leave the node holding [bytes] as its staged prefix.
  void setStagedBytes(Uint8List bytes) {
    _staging = Uint8List.fromList(bytes);
    _size = bytes.length;
    _written = bytes.length;
    _expect = 2;
    _ready = false;
    _error = 0;
  }

  /// Test seam: leave the node holding a verified staging nobody applied.
  void forceReady() {
    _staging = Uint8List(100);
    _size = 100;
    _written = 100;
    _expect = 2;
    _ready = true;
    _error = 0;
  }

  final FakeDeviceLink link = FakeDeviceLink(snr: 6.0, rssi: -70);

  Uint8List get stagedImage => Uint8List.sublistView(_staging!, 0, _written);
  String get nodeVersion => _nodeVersion;

  static Uint8List _pattern(int seed, int length) => Uint8List.fromList(
      List<int>.generate(length, (i) => (i * seed + 17) & 0xFF));

  void debugSetRunning(Uint8List image) => setRunningForTest(image);

  Future<void> boot() async {
    await link.connect();
    link.frameHandler = _onCommandFrame;
    link.binaryRequestHandler = _onBinaryRequest;
  }

  void setRunningForTest(Uint8List image) {
    _running = Uint8List.fromList(image);
  }

  void _onCommandFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    switch (frame[0]) {
      case cmdAppStart:
        _pushSelfInfo();
        break;
      case cmdGetContacts:
        _pushContacts();
        break;
      case cmdSendLogin:
        _pushLoginOk();
        break;
      case cmdSendTxtMsg:
        _enqueueCliReply(_decodeCliCommand(frame));
        break;
      case cmdSyncNextMessage:
        _pushNextMessage();
        break;
    }
  }

  // --- companion side ------------------------------------------------------

  /// `RESP_CODE_SELF_INFO`, in the field order [ParsedSelfInfo.parse] reads.
  void _pushSelfInfo() {
    final w = BufferWriter();
    w.writeByte(respCodeSelfInfo);
    w.writeByte(advTypeRepeater);
    w.writeByte(20); // tx power dBm
    w.writeByte(22); // max tx power dBm
    w.writeBytes(target.publicKey);
    w.writeInt32Le(0); // latitude
    w.writeInt32Le(0); // longitude
    w.writeByte(0); // multi_acks
    w.writeByte(0); // advert_loc_policy
    w.writeByte(0); // telemetry
    w.writeByte(0); // manual_add_contacts
    w.writeUInt32Le(910525); // frequency, kHz
    w.writeUInt32Le(62500); // bandwidth, Hz
    w.writeByte(7); // spreading factor
    w.writeByte(5); // coding rate
    w.writeCString('bench-companion', 32);
    link.simulatePush(w.toBytes());
  }

  void _pushContacts() {
    link.simulatePush(Uint8List.fromList([respCodeContactsStart, 1, 0, 0, 0]));
    link.simulatePush(Uint8List.fromList(
        [respCodeContact, ...target.toCompanionFrameBody()]));
    link.simulatePush(Uint8List.fromList([respCodeEndOfContacts, 0, 0, 0, 0]));
  }

  void _pushLoginOk() {
    // [PUSH_CODE_LOGIN_SUCCESS, is_admin=1, prefix(6), ...]
    link.simulatePush(Uint8List.fromList([
      pushCodeLoginSuccess,
      1,
      ...target.publicKey.sublist(0, 6),
      0,
      0,
      0,
      0,
      7,
      14
    ]));
  }

  String _decodeCliCommand(Uint8List frame) {
    // [cmd, txt_type, attempt, ts(4), prefix(6), text..., 0]
    const textStart = 1 + 1 + 1 + 4 + 6;
    final end = frame.indexOf(0, textStart);
    return String.fromCharCodes(
        end >= 0 ? frame.sublist(textStart, end) : frame.sublist(textStart));
  }

  String? _pendingReply;

  void _enqueueCliReply(String command) {
    if (statusCommandThrows && command == 'ota status') {
      // The companion answers the CLI request with an error frame; the
      // caller sees the failure exactly as a refused/timeout CLI would
      // surface it.
      link.simulatePush(Uint8List.fromList([respCodeErr, 0x01]));
      return;
    }
    _pendingReply = _cliReply(command);
    link.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));
  }

  void _pushNextMessage() {
    final reply = _pendingReply;
    _pendingReply = null;
    if (reply == null) {
      link.simulatePush(Uint8List.fromList([respCodeNoMoreMessages]));
      return;
    }
    final w = BufferWriter();
    w.writeByte(respCodeContactMsgRecvV3);
    w.writeByte(6); // snr
    w.writeByte(0);
    w.writeByte(0);
    w.writeBytes(target.publicKey.sublist(0, 6));
    w.writeByte(0xFF);
    w.writeByte(txtTypeCliData);
    w.writeUInt32Le(1700000000);
    w.writeBytes([...reply.codeUnits, 0]);
    link.simulatePush(w.toBytes());
  }

  // --- the repeater: ota CLI + op interpreter ------------------------------

  String _runningSha16() => sha256
      .convert(_running)
      .bytes
      .sublist(0, 8)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  String _state() {
    if (_error != 0) return 'error';
    if (_ready) {
      if (readyPollsDelay > 0) {
        readyPollsDelay--;
        if (_written > 0) return 'staging';
      }
      return 'ready';
    }
    if (_written > 0) return 'staging';
    return 'idle';
  }

  String _cliReply(String command) {
    if (command == 'ota status') {
      if (garbageStatusReads > 0) {
        garbageStatusReads--;
        return 'Err - unknown command';
      }
      return 'running=$_nodeVersion sha=${_runningSha16()} state=${_state()} '
          'size=$_size off=$_written err=$_error';
    }
    if (command == 'version') return '$_nodeVersion (Build: Nov 11 2026)';
    if (command == 'radio2 status') return radio2StatusReply;
    if (command.startsWith('tempradio ')) {
      tempradioCommands.add(command);
      return 'OK - temp params for ${command.split(',').last} mins';
    }
    if (command == 'ota abort') {
      abortCount++;
      _resetStaging();
      return 'OK - aborted';
    }
    if (command.startsWith('ota stage ')) {
      if (stageRefused) return 'Err - image is larger than the inactive slot';
      final parts = command.split(' ');
      // ota stage <size> <sha256hex> <ver>
      final size = int.tryParse(parts.length > 2 ? parts[2] : '');
      if (size == null || parts.length < 4) {
        return 'Err - size must be 1..2147483647';
      }
      final shaHex = parts[3];
      if (shaHex.length != 64) return 'Err - sha256 must be 64 hex chars';
      _armValid = true;
      _armSize = size;
      _armSha = _hexToBytes(shaHex);
      _armToken = 0xDEADBEEF;
      return 'OK - staging armed (size=$size) token=deadbeef';
    }
    if (command == 'ota apply') {
      if (!_ready) return 'Err - no verified staging (see ota status)';
      _previousImage = Uint8List.fromList(_running);
      _previousVersion = _nodeVersion;
      _running = Uint8List.fromList(_staging!);
      _nodeVersion = 'v1.18.0-r4';
      _resetStaging();
      return 'OK - applied; rebooting';
    }
    if (command == 'ota rollback') {
      if (_previousImage.isNotEmpty) {
        _running = _previousImage;
        _nodeVersion = _previousVersion ?? _nodeVersion;
        _previousImage = Uint8List(0);
        _previousVersion = null;
      }
      _resetStaging();
      return 'OK - rolling back; rebooting';
    }
    return 'Err - unknown command';
  }

  void _resetStaging() {
    _staging = null;
    _written = 0;
    _size = 0;
    _expect = 1;
    _ready = false;
    _error = 0;
    _armValid = false;
  }

  static List<int> _hexToBytes(String hex) => List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));

  Future<void> _onBinaryRequest(
      Contact contact, List<int> reqData, int tag) async {
    if (reqData.length < 2 || reqData[0] != reqTypeOta) return;
    final flen = reqData[1];
    if (reqData.length < 2 + flen) return;
    final frame = Uint8List.fromList(reqData.sublist(2, 2 + flen));
    for (final response in _handleOtaFrame(frame)) {
      link.simulatePush(Uint8List.fromList([
        pushCodeBinaryResponse,
        0, // reserved
        ...contact.publicKey.sublist(0, 6),
        tag & 0xFF,
        (tag >> 8) & 0xFF,
        (tag >> 16) & 0xFF,
        (tag >> 24) & 0xFF,
        ...response,
      ]));
    }
  }

  Uint8List _handleInfoRequest() {
    // Canned node matching the Xiao_S3_WIO_repeater target id the flow
    // tests select.
    const maxLiteral = 173; // OTA_MAX_LITERAL in the firmware
    final sha = sha256.convert(_running).bytes;
    final body = <int>[
      otaWireVersion,
      ..._le32(infoTargetOverride != 0 ? infoTargetOverride : _targetIdForTest),
      ..._le32(0x200000), // slot size
      ..._le16(maxLiteral),
      ..._le32(otaFeatDelta |
          otaFeatApply |
          (advertiseNewOps
              ? otaFeatStagedHash | otaFeatStatus | otaFeatPing
              : 0)),
      ..._padded32(utf8.encode(_nodeVersion)),
      ...sha,
    ];
    return buildOp(otaOpInfoReport, body: body);
  }

  Uint8List _handleStatusRequest() {
    final body = <int>[
      otaWireVersion,
      ..._le32(_targetIdForTest),
      ..._le32(0x200000),
      ..._le16(173),
      ..._le32(otaFeatDelta |
          otaFeatApply |
          otaFeatStagedHash |
          otaFeatStatus |
          otaFeatPing),
      ..._padded32(utf8.encode(_nodeVersion)),
      ...Uint8List(32),
      ..._le32(_sessionId), // zero until OP_START
      _ready ? otaStateReady : (_stagingArmed ? otaStateStaging : otaStateIdle),
      _error,
      ..._le32(_size),
      ..._le32(_written),
      ..._le16(_expect),
      otaCodecDeflate,
      0,
      0, // no extension TLVs
    ];
    return buildOp(otaOpStatusReport, body: body);
  }

  Uint8List? _handleStagedHash(Uint8List req) {
    if (req.isEmpty || _staging == null) return null;
    stagedHashQueries++;
    final count = req[0];
    // A four-range report is too large for the companion's radio payload once
    // its tag/public-key prefix is added, so it never arrives.
    if (count == 0 || count > 2 || req.length != 1 + 8 * count) return null;
    final out = <int>[..._le32(_written), count];
    for (var i = 0; i < count; i++) {
      final off = _le32At(req, 1 + i * 8);
      final len = _le32At(req, 5 + i * 8);
      out.addAll(_le32(off));
      // Match the firmware: one range is at most 32 KB and 4-byte aligned.
      if (len == 0 || len > 32768 || (len & 3) != 0 || off + len > _written) {
        out.add(1);
        out.addAll(List<int>.filled(32, 0));
      } else {
        out.add(0);
        out.addAll(sha256.convert(_staging!.sublist(off, off + len)).bytes);
      }
    }
    return buildOp(otaOpStagedHashReport, body: out);
  }

  static int _le32At(List<int> p, int at) =>
      p[at] | (p[at + 1] << 8) | (p[at + 2] << 16) | (p[at + 3] << 24);

  static List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

  static List<int> _le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  static List<int> _padded32(List<int> bytes) {
    final out = Uint8List(32);
    out.setRange(0, bytes.length > 32 ? 32 : bytes.length, bytes);
    return out;
  }

  static const int _targetIdForTest = 0x9F19BCD1; // Xiao_S3_WIO_repeater

  List<Uint8List> _handleOtaFrame(Uint8List frame) {
    final body = unwrapFrame(frame);
    if (body == null) return const [];
    final op = body[2];

    if (op == otaOpInfo) return infoSilent ? const [] : [_handleInfoRequest()];
    if (op == otaOpStatus) return [_handleStatusRequest()];
    if (op == otaOpPing) {
      if (pingSilent) return const [];
      return [buildOp(otaOpPingReport, body: body.sublist(3))];
    }
    if (op == otaOpStagedHash) {
      final report = _handleStagedHash(body.sublist(3));
      return report == null ? const [] : [report];
    }

    if (op == otaOpAsk) {
      if (!_stagingArmed) return const [];
      return [
        buildOp(otaOpReport, body: [_expect & 0xFF, (_expect >> 8) & 0xFF])
      ];
    }

    if (op == otaOpStart) {
      if (body.length < 5 + 44 || body[3] != 0) return const [];
      final bd = ByteData.sublistView(body, 5);
      final size = bd.getUint32(0, Endian.little);
      final sha = body.sublist(9, 41);
      final targetId = bd.getUint32(36, Endian.little);
      final token = bd.getUint32(40, Endian.big);
      if (targetId != targetIdForEnvironment('Xiao_S3_WIO_repeater')) {
        return const [];
      }
      if (!_armValid ||
          token != _armToken ||
          size != _armSize ||
          !_bytesEqual(sha, _armSha)) {
        return const []; // rejected, silently dropped like the firmware
      }
      _armValid = false;
      _sessionId = 0x5EED1234;
      _staging = Uint8List(size);
      _written = 0;
      _size = size;
      _expectedSha = List<int>.from(sha);
      _expect = 1;
      _ready = false;
      return const [];
    }

    if (!_stagingArmed) return const [];
    final seq = body[3] | (body[4] << 8);
    if (seq != _expect) return const [];

    if (op == otaOpLiteral) {
      final len = body[5] | (body[6] << 8);
      if (_staging == null) return const [];
      if (body.length < 7 + len || _written + len > _size) return const [];
      _staging!.setRange(_written, _written + len, body.sublist(7, 7 + len));
      _written += len;
      _expect++;
      return const [];
    }
    if (op == otaOpCopy) {
      final bd = ByteData.sublistView(body, 5);
      final baseOffset = bd.getUint32(0, Endian.little);
      final len = bd.getUint16(4, Endian.little);
      if (_staging == null) return const [];
      if (baseOffset + len > _running.length || _written + len > _size) {
        return const [];
      }
      _staging!.setRange(_written, _written + len,
          _running.sublist(baseOffset, baseOffset + len));
      _written += len;
      _expect++;
      return const [];
    }
    if (op == otaOpEnd) {
      if (_staging == null) return const [];
      final digest = sha256.convert(_staging!.sublist(0, _written)).bytes;
      _ready = _bytesEqual(digest, _expectedSha);
      if (!_ready) _error = 4;
      return const [];
    }
    return const [];
  }

  bool get _stagingArmed => _staging != null;

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

void main() {
  late _FakeCompanion fake;
  late UpdateFlow flow;

  setUp(() async {
    fake = _FakeCompanion();
    await fake.boot();
    flow = UpdateFlow(client: CompanionClient(fake.link), link: fake.link);
  });

  test('apply and rollback tolerate a lost reply from the reboot', () async {
    final rebootClient = _RebootReplyLostClient(fake.link);
    final rebootFlow = UpdateFlow(client: rebootClient, link: fake.link);
    await expectLater(rebootFlow.apply(fake.target), completes);
    await expectLater(rebootFlow.rollback(fake.target), completes);
  });

  test('apply reports whether the node acknowledged it', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final lost = _RebootReplyLostClient(fake.link);
    final lostFlow = UpdateFlow(client: lost, link: fake.link);
    expect(await lostFlow.apply(fake.target), isFalse);

    final image = _FakeCompanion._pattern(0x77, 120);
    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: Uint8List.fromList(sha256.convert(image).bytes),
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: computeDelta(Uint8List(0), image).ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero,
    );
    expect(await flow.apply(fake.target), isTrue);
  });

  test('awaitApplyOutcome reads the staged slot and the running hash',
      () async {
    const size = 100;
    final image = _FakeCompanion._pattern(0x88, size);
    final expected = Uint8List.fromList(sha256.convert(image).bytes);
    fake.setRunningForTest(Uint8List.fromList(List<int>.filled(size, 7)));
    fake.forceReady();
    expect(
        await flow.awaitApplyOutcome(fake.target, 'password', 'v',
            expectedImageSha256: expected, expectedSize: size),
        ApplyOutcome.stagedNotApplied);

    fake.setRunningForTest(image);
    expect(
        await flow.awaitApplyOutcome(fake.target, 'password', 'v',
            expectedImageSha256: expected, expectedSize: size),
        ApplyOutcome.verified);
  });

  test('probe logs in and parses ota status', () async {
    final status = await flow.probe(fake.target, 'hunter2');
    expect(status, isNotNull);
    expect(status!.running, 'v1.17.0');
    expect(status.state, OtaPhase.idle);
    expect(status.ok, isTrue);
  });

  test('nextExpected reads the node watermark after a reconnect', () async {
    fake.forceStaging();
    expect(await flow.nextExpected(fake.target), 5086);
  });

  test('nextExpected returns null when the node has no live staging', () async {
    expect(await flow.nextExpected(fake.target), isNull);
  });

  test('stage refuses a board that does not match the image', () async {
    const env = 'Xiao_S3_WIO_repeater';
    fake.infoTargetOverride = 0xDEADBEEF; // node is a "different board"
    final image = Uint8List.fromList(_FakeCompanion._pattern(0x5C, 32));
    await expectLater(
      flow.stage(fake.target, image,
          version: 'v1.18.0-r4', expectedTargetId: targetIdForEnvironment(env)),
      throwsA(isA<UpdateFlowException>()),
    );
    // The node was never asked to arm anything.
    final status = await flow.probe(fake.target, 'hunter2');
    expect(status!.state, OtaPhase.idle);
  });

  test('stage proceeds when the node does not answer OP_INFO (old firmware)',
      () async {
    const env = 'Xiao_S3_WIO_repeater';
    fake.infoSilent = true;
    final image = Uint8List.fromList(_FakeCompanion._pattern(0x5C, 32));
    final stage = await flow.stage(fake.target, image,
        version: 'v1.18.0-r4', expectedTargetId: targetIdForEnvironment(env));
    expect(stage.size, image.length);
  });

  test('stage with a matching board reports the parsed arm', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image = Uint8List.fromList(_FakeCompanion._pattern(0x5C, 32));
    final stage = await flow.stage(fake.target, image,
        version: 'v1.18.0-r4', expectedTargetId: targetIdForEnvironment(env));
    expect(stage.size, image.length);
    expect(stage.token, isNonZero);
  });

  test('pacing is derived from the radio and never below the floor', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image = Uint8List.fromList(_FakeCompanion._pattern(0x5C, 600));
    fake.setRunningForTest(image);
    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    final ops = computeDelta(Uint8List(0), image).ops;
    final sw = Stopwatch()..start();
    // No opSpacing override: the flow asks the link for radio params and paces
    // to a full-size packet's airtime (plus a commit margin), min 250 ms.
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: Uint8List.fromList(sha256.convert(image).bytes),
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
    );
    sw.stop();
    expect(fake.stagedImage, image);
    // Real pacing applied: the transfer cannot be instant.
    expect(sw.elapsedMilliseconds, greaterThan(200));
  });

  test('full pipeline: stage → transfer → ready → apply → verify', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final baseImage = _FakeCompanion._pattern(0x22, 8192);
    final image = Uint8List.fromList(baseImage);
    for (var i = 0; i < 100; i++) {
      image[(i * 7919) % image.length] ^= 0x5A;
    }
    fake.setRunningForTest(baseImage);

    // Stage through the real CLI path — the reply arms the fake node.
    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    expect(stage.token, 0xDEADBEEF);

    final ops = computeDelta(baseImage, image).ops;
    final result = await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: Uint8List.fromList(sha256.convert(image).bytes),
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero, // tests are not paced to a radio
    );
    expect(result.packetsSent, greaterThan(0));
    expect(fake.stagedImage, image);

    final ready = await flow.awaitReady(fake.target);
    expect(ready.state, OtaPhase.ready);

    await flow.apply(fake.target);
    expect(fake.nodeVersion, contains('v1.18.0-r4'));

    final verified =
        await flow.awaitVersion(fake.target, 'hunter2', 'v1.18.0-r4');
    expect(verified, isTrue);
  });

  group('awaitVersion', () {
    test('accepts a rebooted image whose version stamp did not change',
        () async {
      // A same-commit rebuild boots with a stamp identical to the image
      // it replaces — the string proves nothing. Only the running image's
      // SHA-256 can vouch for it.
      const env = 'Xiao_S3_WIO_repeater';
      final image = Uint8List.fromList(
          List<int>.generate(600, (i) => (i * 3 + 7) & 0xFF));
      final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');

      final ops = computeDelta(Uint8List(0), image).ops;
      final imageSha = Uint8List.fromList(sha256.convert(image).bytes);
      await flow.transfer(
        target: fake.target,
        contract: OtaStartContract(
          imageSize: image.length,
          imageSha256: imageSha,
          targetId: targetIdForEnvironment(env),
          token: stage.token,
        ),
        ops: ops,
        route: OtaRoute.zeroHop(),
        windowSize: 4,
        opSpacing: Duration.zero,
      );
      await flow.awaitReady(fake.target,
          interval: const Duration(milliseconds: 5));
      await flow.apply(fake.target);

      // A string that shares nothing with the applied stamp — only the
      // hash path can succeed.
      final ok = await flow.awaitVersion(
        fake.target,
        'hunter2',
        'a-stamp-that-matches-nothing',
        expectedImageSha256: Uint8List.fromList(sha256.convert(image).bytes),
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 20),
      );
      expect(ok, isTrue);
    });

    test('falls back to the version stamp when the running sha mismatches',
        () async {
      const env = 'Xiao_S3_WIO_repeater';
      final image = Uint8List.fromList(
          List<int>.generate(300, (i) => (i * 5 + 1) & 0xFF));
      final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
      final ops = computeDelta(Uint8List(0), image).ops;
      final imageSha = Uint8List.fromList(sha256.convert(image).bytes);
      await flow.transfer(
        target: fake.target,
        contract: OtaStartContract(
          imageSize: image.length,
          imageSha256: imageSha,
          targetId: targetIdForEnvironment(env),
          token: stage.token,
        ),
        ops: ops,
        route: OtaRoute.zeroHop(),
        windowSize: 4,
        opSpacing: Duration.zero,
      );
      await flow.awaitReady(fake.target,
          interval: const Duration(milliseconds: 5));
      await flow.apply(fake.target);

      // sha256 of a DIFFERENT image must still report true via the string.
      final other = Uint8List.fromList(List<int>.generate(32, (i) => 1));
      final ok = await flow.awaitVersion(
        fake.target,
        'hunter2',
        'v1.18.0-r4',
        expectedImageSha256: Uint8List.fromList(sha256.convert(other).bytes),
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 20),
      );
      expect(ok, isTrue);
    });

    test('falls back to the version stamp when status is unparseable',
        () async {
      fake.garbageStatusReads = 1 << 30;
      final ok = await flow.awaitVersion(
        fake.target,
        'hunter2',
        'v1.17.0', // the fake node's boot stamp
        expectedImageSha256: Uint8List(32),
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 20),
      );
      expect(ok, isTrue);
    });
  });

  test('awaitReady polls through a delayed ready after the SHA gate', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image =
        Uint8List.fromList(List<int>.generate(600, (i) => (i * 3 + 7) & 0xFF));

    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    final ops = computeDelta(Uint8List(0), image).ops;
    final imageSha = Uint8List.fromList(sha256.convert(image).bytes);
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: imageSha,
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero,
    );

    // The node needs two polls to finish the verify before reporting ready.
    fake.readyPollsDelay = 2;
    final ready = await flow.awaitReady(fake.target,
        interval: const Duration(milliseconds: 5));
    expect(ready.state, OtaPhase.ready);
  });

  test('awaitReady gives up when the node never reports ready', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image =
        Uint8List.fromList(List<int>.generate(600, (i) => (i * 3 + 7) & 0xFF));

    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    final ops = computeDelta(Uint8List(0), image).ops;
    final imageSha = Uint8List.fromList(sha256.convert(image).bytes);
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: imageSha,
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero,
    );

    // Keep status in staging forever by refusing every ready flip; the
    // deadline must trip.
    fake.readyPollsDelay = 1 << 30;
    await expectLater(
      flow.awaitReady(fake.target,
          timeout: const Duration(milliseconds: 100),
          interval: const Duration(milliseconds: 5)),
      throwsA(isA<UpdateFlowException>()
          .having((e) => e.message, 'message', contains('did not finish'))),
    );
  });

  test('awaitReady gives up when ota status never parses', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image =
        Uint8List.fromList(List<int>.generate(300, (i) => (i * 5 + 1) & 0xFF));

    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    final ops = computeDelta(Uint8List(0), image).ops;
    final imageSha = Uint8List.fromList(sha256.convert(image).bytes);
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: imageSha,
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero,
    );

    fake.garbageStatusReads = 1 << 30;
    await expectLater(
      flow.awaitReady(fake.target,
          timeout: const Duration(milliseconds: 100),
          interval: const Duration(milliseconds: 5)),
      throwsA(isA<UpdateFlowException>()
          .having((e) => e.message, 'message', contains('unparseable'))),
    );
  });

  group('clearStaleStaging', () {
    test('returns idle and does not abort a clean node', () async {
      expect(await flow.clearStaleStaging(fake.target), OtaPhase.idle);
      expect(fake.abortCount, 0);
    });

    test('clears a stranded partial staging', () async {
      fake.forceStaging(size: 1452512, off: 933485);
      final messages = <String>[];
      final loggingFlow = UpdateFlow(
          client: CompanionClient(fake.link),
          link: fake.link,
          onLog: messages.add);

      expect(
          await loggingFlow.clearStaleStaging(fake.target), OtaPhase.staging);
      expect(fake.abortCount, 1);
      expect(fake.isStaging, isFalse);
      expect(messages.single, contains('933485'));
    });

    test('clears a verified staging never applied', () async {
      fake.forceReady();
      expect(await flow.clearStaleStaging(fake.target), OtaPhase.ready);
      expect(fake.abortCount, 1);
      expect(fake.isStaging, isFalse);
    });

    test('leaves an errored node alone; the arm resets it', () async {
      const env = 'Xiao_S3_WIO_repeater';
      final wrongImage =
          Uint8List.fromList(List<int>.generate(120, (i) => 0xAA));
      final image = Uint8List.fromList(List<int>.generate(120, (i) => i));
      final stage =
          await flow.stage(fake.target, wrongImage, version: 'v1.18.0-r4');

      final ops = computeDelta(Uint8List(0), image).ops;
      final imageSha = Uint8List.fromList(sha256.convert(wrongImage).bytes);
      await flow.transfer(
        target: fake.target,
        contract: OtaStartContract(
          imageSize: image.length,
          imageSha256: imageSha,
          targetId: targetIdForEnvironment(env),
          token: stage.token,
        ),
        ops: ops,
        route: OtaRoute.zeroHop(),
        windowSize: 4,
        opSpacing: Duration.zero,
      );

      expect(await flow.clearStaleStaging(fake.target), OtaPhase.error);
      expect(fake.abortCount, 0);
    });

    test('returns null for an unparseable status', () async {
      fake.garbageStatusReads = 1 << 30;
      expect(await flow.clearStaleStaging(fake.target), isNull);
      expect(fake.abortCount, 0);
    });

    test('returns null when the CLI call fails', () async {
      fake.statusCommandThrows = true;
      expect(await flow.clearStaleStaging(fake.target), isNull);
      expect(fake.abortCount, 0);
    });

    test('stage clears a stranded staging before arming', () async {
      fake.forceStaging(size: 1452512, off: 933485);
      final image = Uint8List.fromList(List<int>.generate(60, (i) => i));
      final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
      expect(fake.abortCount, 1);
      expect(stage.size, image.length);
      expect(fake.isStaging, isFalse);
    });
  });

  test('awaitReady throws when the staged image fails the SHA gate', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image =
        Uint8List.fromList(List<int>.generate(600, (i) => (i * 3 + 7) & 0xFF));

    // Arm with a DIFFERENT image than what the ops carry — the END digest
    // then cannot match, and the node must report not-ready.
    final wrongImage = Uint8List.fromList(List<int>.generate(600, (i) => 0xAA));
    await flow.stage(fake.target, wrongImage, version: 'v1.18.0-r4');

    // Ops carry `image`: staged bytes != wrongImage → SHA mismatch at END.
    final ops = computeDelta(Uint8List(0), image).ops;
    final imageSha = Uint8List.fromList(sha256.convert(wrongImage).bytes);
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: imageSha,
        targetId: targetIdForEnvironment(env),
        token: 0xDEADBEEF,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero, // tests are not paced to a radio
    );
    expect(() => flow.awaitReady(fake.target),
        throwsA(isA<UpdateFlowException>()));
  });

  test('applyAndVerify proves a reboot onto an identically stamped image',
      () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image =
        Uint8List.fromList(List<int>.generate(400, (i) => (i * 7 + 3) & 0xFF));

    // Stage and transfer the image on the node first (as the transfer step
    // would have left it, ready to apply).
    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    final ops = computeDelta(Uint8List(0), image).ops;
    final imageSha = Uint8List.fromList(sha256.convert(image).bytes);
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: imageSha,
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero,
    );

    // Select the image in the app the way the wizard does, then commit.
    // The node's post-apply stamp shares nothing with the selected one —
    // verification has to key off the running image's SHA-256.
    final app = AppState();
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    app.target = fake.target;
    final entry = lib.addImage(image, env: env, version: 'v1.1.0-rc5');
    await app.selectLibraryEntryForUpdate(entry);

    await app.applyAndVerify(expectedVersion: 'a-stamp-that-matches-nothing');
    expect(app.updatePhase, UpdatePhase.done);
    expect(app.verifyMatched, isTrue);
  });

  test('a lost apply is retried while the verified staging is still ready',
      () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image =
        Uint8List.fromList(List<int>.generate(400, (i) => (i * 7 + 3) & 0xFF));
    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: Uint8List.fromList(sha256.convert(image).bytes),
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: computeDelta(Uint8List(0), image).ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero,
    );

    late _LostFirstApplyClient flaky;
    final app = AppState();
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    app.clientFactory = (link) => flaky = _LostFirstApplyClient(link);
    await app.connectTcp(host: 'unused', port: 0);
    app.target = fake.target;
    final entry = lib.addImage(image, env: env, version: 'v1.1.0');
    await app.selectLibraryEntryForUpdate(entry);

    await app.applyAndVerify(expectedVersion: 'a-stamp-that-matches-nothing');

    expect(flaky.applyCalls, 2);
    expect(app.updatePhase, UpdatePhase.done);
    expect(app.verifyMatched, isTrue);
    expect(app.applyOutcome, ApplyOutcome.verified);
    expect(app.log.any((l) => l.contains('retrying apply')), isTrue);
  });

  test('probe reads the node facts and the capability handshake', () async {
    final app = AppState();
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    // Board detection maps the node's target id back into the names the app
    // knows, so the environment has to be known to it.
    lib.addImage(Uint8List(16), env: 'Xiao_S3_WIO_repeater', version: 'v1.1.0');
    app.libraryEntries = await lib.list();
    app.selectTarget(fake.target);

    await app.probe();

    expect(app.probeError, isNull);
    expect(app.nodeStatus, isNotNull);
    expect(app.nodeInfo, isNotNull);
    expect(app.nodeInfo!.supportsDelta, isTrue);
    expect(app.detectedBoard, 'Xiao_S3_WIO_repeater');
    // The companion's own preset is adopted as the live mesh when the node
    // does not answer `get radio`.
    expect(app.companionPreset, isNotNull);
    expect(app.livePreset, isNotNull);
    expect(app.probing, isFalse);
  });

  test('probe reads the radio2 preset reported by the node', () async {
    fake.radio2StatusReply = 'on; at=primary; preset=915,125,9,5';
    final app = AppState();
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    lib.addImage(Uint8List(16), env: 'Xiao_S3_WIO_repeater', version: 'v1.1.0');
    app.libraryEntries = await lib.list();
    app.selectTarget(fake.target);

    await app.probe();

    expect(app.radio2Enabled, isTrue);
    expect(app.radio2Preset, isNotNull);
    expect(app.radio2Preset!.frequencyMhz, 915);
    expect(app.radio2Preset!.bandwidthKhz, 125);
    expect(app.radio2Preset!.spreadingFactor, 9);
    expect(app.radio2Preset!.codingRate, 5);
  });

  test('a refused arm leaves the update failed, not stuck staging', () async {
    final app = AppState();
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    fake.stageRefused = true;
    app.selectTarget(fake.target);
    await app.probe();
    final entry = lib.addImage(
      Uint8List.fromList(List<int>.generate(300, (i) => i & 0xFF)),
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4',
    );
    await app.selectLibraryEntryForUpdate(entry);
    // Step 5's comparison must be present before Start can arm anything.
    app.remoteDiff = remoteDiff();

    await expectLater(
      app.runUpdate(version: entry.version),
      throwsA(isA<UpdateFlowException>()),
    );
    // The transfer screen keys its footer off the phase: leaving it at
    // `staging` would show a dead Cancel button forever.
    expect(app.updatePhase, UpdatePhase.failed);
    expect(app.cancelRequested, isFalse);
  });

  test('nodeStatus and ping use the structured ops on the live link', () async {
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    final target = contact('tower');
    List<int> le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
    List<int> le32(int v) =>
        [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

    link.binaryRequestHandler = (c, req, tag) async {
      final frame = unwrapFrame(Uint8List.fromList(req.sublist(2, 2 + req[1])));
      if (frame == null) return;
      Uint8List? report;
      if (frame[2] == otaOpStatus) {
        report = buildOp(otaOpStatusReport, body: [
          otaWireVersion,
          ...le32(0x9F19BCD1),
          ...le32(0x200000),
          ...le16(173),
          ...le32(
              otaFeatDelta | otaFeatStatus | otaFeatPing | otaFeatStagedHash),
          ...Uint8List(32),
          ...Uint8List(32),
          ...le32(0x12345678), // session id
          otaStateStaging,
          0,
          ...le32(4096),
          ...le32(1024),
          ...le16(7),
          otaCodecDeflate,
          ...le16(0), // no TLVs
        ]);
      } else if (frame[2] == otaOpPing) {
        report = buildOp(otaOpPingReport, body: frame.sublist(3));
      }
      if (report == null) return;
      link.simulatePush(Uint8List.fromList([
        pushCodeBinaryResponse,
        0,
        ...le32(tag),
        ...report,
      ]));
    };

    final flow = UpdateFlow(client: CompanionClient(link), link: link);
    final status = await flow.nodeStatus(target);
    expect(status, isNotNull);
    expect(status!.sessionId, 0x12345678);
    expect(status.nextExpected, 7);
    expect(status.supportsCodec(otaCodecDeflate), isTrue);
    expect(await flow.ping(target), Uint8List.fromList([1, 2, 3, 4]));
  });

  test('the new capability API drives ping, session and codec choices',
      () async {
    const env = 'Xiao_S3_WIO_repeater';
    final base = _FakeCompanion._pattern(0x33, 4096);
    final image = Uint8List.fromList(base);
    image[10] ^= 0xFF;
    fake.setRunningForTest(base);
    fake.advertiseNewOps = true;

    final dir = await Directory.systemTemp.createTemp('new_api_test');
    final app = AppState();
    app.resumeStore = ResumeStore(File('${dir.path}/ota_resume.bin'));
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    final entry = lib.addImage(image, env: env, version: 'v1.18.0-r4');
    app.libraryEntries = await lib.list();
    app.selectTarget(fake.target);
    await app.probe();
    await app.selectLibraryEntryForUpdate(entry);
    // The fake node does not implement the block-hash oracle; supply the
    // same diff the real compare would produce, computed here.
    app.comparisonFactory =
        (img) async => remoteDiff(ops: computeDelta(base, img).ops);

    await app.runUpdate(version: entry.version);

    expect(app.updatePhase, UpdatePhase.readyToApply);
    expect(app.log.any((line) => line.contains('link check ok')), isTrue);
    expect(app.resumePlan?.sessionId, 0x5EED1234);
    // The staged prefix read back with OP_STAGED_HASH matches the saved image.
    expect(await app.verifyStagedPrefix(fake.target, image.length), isNull);
    // Oversized requests are refused locally without touching the radio.
    expect(await app.verifyStagedPrefix(fake.target, image.length + 1),
        contains('could not be checked'));
    await dir.delete(recursive: true);
  });

  test('staged prefix verification uses firmware-sized hash ranges', () async {
    const env = 'Xiao_S3_WIO_repeater';
    // Larger than four 32 KB firmware hash ranges, so the verification must
    // use more than one exchange. The old single-range query was always
    // refused, so every legitimate resume failed.
    final image = _FakeCompanion._pattern(0x44, 200000);
    fake.setStagedBytes(image);
    fake.stagedHashQueries = 0;

    final app = AppState();
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    final entry = lib.addImage(image, env: env, version: 'v1.18.0-r5');
    app.libraryEntries = await lib.list();
    app.selectTarget(fake.target);
    await app.probe();
    await app.selectLibraryEntryForUpdate(entry);

    expect(await app.verifyStagedPrefix(fake.target, image.length), isNull);
    expect(fake.stagedHashQueries, greaterThan(1));
  });

  test('a lost ping is advisory — the update still proceeds', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final base = _FakeCompanion._pattern(0x44, 512);
    final image = Uint8List.fromList(base);
    image[4] ^= 0xFF;
    fake.setRunningForTest(base);
    fake.advertiseNewOps = true;
    fake.pingSilent = true;

    final app = AppState();
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    final entry = lib.addImage(image, env: env, version: 'v1.18.0-r4');
    app.libraryEntries = await lib.list();
    app.selectTarget(fake.target);
    await app.probe();
    await app.selectLibraryEntryForUpdate(entry);
    // The fake node does not implement the block-hash oracle; supply the
    // same diff the real compare would produce, computed here.
    app.comparisonFactory =
        (img) async => remoteDiff(ops: computeDelta(base, img).ops);

    await app.runUpdate(version: entry.version);

    expect(app.updatePhase, UpdatePhase.readyToApply);
    expect(app.log.any((line) => line.contains('link check had no answer')),
        isTrue);
  });

  test('a temporary-channel update arms the node and tunes the companion',
      () async {
    const env = 'Xiao_S3_WIO_repeater';
    final base = _FakeCompanion._pattern(0x66, 4096);
    final image = Uint8List.fromList(base);
    image[10] ^= 0xFF;
    fake.setRunningForTest(base);
    fake.advertiseNewOps = true;

    final app = AppState();
    app.tempRadioRenewal.now = () => DateTime(2026, 11, 19, 12);
    final lib = FakeLibrary();
    app.library = lib;
    app.tcpLinkFactory = (_, __) => fake.link;
    await app.connectTcp(host: 'unused', port: 0);
    final entry = lib.addImage(image, env: env, version: 'v1.18.0-r4');
    app.libraryEntries = await lib.list();
    app.selectTarget(fake.target);
    await app.probe();
    await app.selectLibraryEntryForUpdate(entry);
    // The fake node does not implement the block-hash oracle; supply the
    // same diff the real compare would produce. Assert the channel was
    // already armed when comparison starts — its queries must not use the
    // live mesh.
    app.comparisonFactory = (img) async {
      expect(fake.tempradioCommands, hasLength(1));
      expect(fake.tempradioCommands.first,
          endsWith(',${RadioPlan.tempRadioChunkMinutes}'));
      expect(app.updatePhase, UpdatePhase.comparing);
      return remoteDiff(ops: computeDelta(base, img).ops);
    };
    app.radioPlan = RadioPlan(
      mode: RadioMode.tempRadio,
      preset: RadioPlan.suggestTempRadio(app.livePreset!),
    );

    await app.runUpdate(version: entry.version);

    expect(app.updatePhase, UpdatePhase.readyToApply);
    // One arm plus the short restore; no renewal inside a short transfer.
    expect(fake.tempradioCommands, hasLength(2));
    expect(fake.tempradioCommands.first,
        endsWith(',${RadioPlan.tempRadioChunkMinutes}'));
    expect(fake.tempradioCommands.last, endsWith(',1'));
    expect(
        app.log.any((l) => l.contains('temporary channel renewed')), isFalse);
    expect(fake.link.calls.contains('setRadioParams'), isTrue);
  });
}
