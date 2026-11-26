// The frozen `ota` CLI contract (fork firmware, OtaUpdate.cpp). The line
// format here is frozen; parse failures mean "not an OTA firmware" or a
// hand-corrupted reply, and are surfaced as null by the parsers.

/// The phase reported by `ota status`.
enum OtaPhase { idle, staging, ready, error, unsupported }

/// Parsed `ota status` line:
/// `running=<ver> sha=<16hex> state=<...> size=<n> off=<n> err=<code>`
class OtaStatus {
  const OtaStatus({
    required this.running,
    required this.shaPrefix,
    required this.state,
    required this.size,
    required this.offset,
    required this.err,
  });

  final String running;

  /// First 8 bytes of the running image's SHA-256, as printed (16 lowercase
  /// hex chars). The full hash comes from the `OP_INFO` handshake.
  final String shaPrefix;

  final OtaPhase state;
  final int size;
  final int offset;
  final int err;

  bool get ok => err == 0;

  static final _line = RegExp(
      r'^running=(\S+) sha=([0-9a-fA-F]{16}) state=(\w+) size=(\d+) off=(\d+) err=(\d+)$');

  /// Parse the frozen line. Returns null when the reply is not the frozen
  /// `ota status` contract (e.g. a pre-OTA firmware's usage text).
  static OtaStatus? parse(String reply) {
    final match = _line.firstMatch(reply.trim());
    if (match == null) return null;
    final state = switch (match.group(3)) {
      'idle' => OtaPhase.idle,
      'staging' => OtaPhase.staging,
      'ready' => OtaPhase.ready,
      'error' => OtaPhase.error,
      'unsupported' => OtaPhase.unsupported,
      _ => null,
    };
    if (state == null) return null;
    return OtaStatus(
      running: match.group(1)!,
      shaPrefix: match.group(2)!.toLowerCase(),
      state: state,
      size: int.parse(match.group(4)!),
      offset: int.parse(match.group(5)!),
      err: int.parse(match.group(6)!),
    );
  }
}

/// What happened to an `ota apply` attempt.
///
/// A successful apply is proved only by the node reporting the sent image's
/// hash as its running image. A still-`ready` staged slot means the apply
/// command did not commit — which is recoverable without re-uploading.
enum ApplyOutcome {
  verified,
  stagedNotApplied,
  rolledBack,
  failed,
  unknown,
}

/// Classify an `ota status` reply taken after an apply attempt.
///
/// [expectedShaPrefix] is the first 8 bytes of the sent image, as 16 hex
/// chars; [expectedSize] is its length. `unknown` means the node has not
/// answered usefully yet and polling should continue.
ApplyOutcome classifyApplyOutcome(
  OtaStatus? status, {
  required String expectedShaPrefix,
  required int expectedSize,
}) {
  if (status == null) return ApplyOutcome.unknown;
  if (expectedShaPrefix.isNotEmpty &&
      status.shaPrefix.toLowerCase() == expectedShaPrefix.toLowerCase()) {
    return ApplyOutcome.verified;
  }
  if (status.ok &&
      status.state == OtaPhase.ready &&
      status.size == expectedSize) {
    return ApplyOutcome.stagedNotApplied;
  }
  if (!status.ok || status.state == OtaPhase.error) return ApplyOutcome.failed;
  return ApplyOutcome.rolledBack;
}

/// Error codes reported as `err=` in `ota status` (0 = OK).
const otaErrNone = 0;
const otaErrTarget = 1;
const otaErrBattery = 2;
const otaErrSlot = 3;
const otaErrSha = 4;
const otaErrIo = 5;
const otaErrBounds = 6;
const otaErrToken = 7;
const otaErrEnd = 8;
const otaErrCompress = 9;

/// Human labels for the `err=` codes (for display only).
String otaErrLabel(int err) => switch (err) {
      otaErrNone => 'OK',
      otaErrTarget => 'wrong target for this node',
      otaErrBattery => 'battery gate active; staging refused',
      otaErrSlot => 'no room / size rejected',
      otaErrSha => 'SHA-256 mismatch on the staged image',
      otaErrIo => 'flash read/write failed',
      otaErrBounds => 'op out of bounds',
      otaErrToken => 'arm token missing or rejected',
      otaErrEnd => 'esp_ota_end() failed after a clean verify',
      otaErrCompress => 'compressed literal stream failed',
      10 => 'online fetch configuration error',
      11 => 'the repeater could not join WiFi',
      12 => 'the repeater could not read the network clock',
      13 => 'a secure connection could not be opened',
      14 => 'the firmware download was refused',
      15 => 'the firmware download was incomplete',
      16 => 'the repeater ran out of memory',
      _ => 'unknown error $err',
    };

/// `OK - staging armed (size=<n>) token=<8hex>` parse result.
class OtaStageReply {
  const OtaStageReply({required this.size, required this.token});

  final int size;

  /// The arm token (4 bytes). Pass to the OP_START body.
  final int token;
}

final _stageLine =
    RegExp(r'^OK - staging armed \(size=(\d+)\) token=([0-9a-fA-F]{8})$');

/// Parse the `ota stage` success reply. Returns null when the reply is not
/// the success line (the device reports failures as `Err - ...`).
OtaStageReply? parseStageReply(String reply) {
  final match = _stageLine.firstMatch(reply.trim());
  if (match == null) return null;
  return OtaStageReply(
    size: int.parse(match.group(1)!),
    token: int.parse(match.group(2)!, radix: 16),
  );
}

/// `ota apply` accepted the staged image.
bool isApplyReply(String reply) =>
    reply.trim().toLowerCase().startsWith('ok - applied');

/// `ota rollback` accepted a partition flip back.
bool isRollbackReply(String reply) =>
    reply.trim().toLowerCase().startsWith('ok - rolling back');

/// `Err - ...` is the failure marker for every ota CLI command.
bool isCliErrorReply(String reply) =>
    reply.trim().toLowerCase().startsWith('err -');
