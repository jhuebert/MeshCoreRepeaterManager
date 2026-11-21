import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// A binary request got no usable reply. The outcome is unknown: the node may
/// still have acted, so callers must never turn this into a success.
class RepeaterRequestException implements Exception {
  const RepeaterRequestException(this.message);

  final String message;

  @override
  String toString() => 'RepeaterRequestException: $message';
}

/// Candidate `(tag, payload)` layouts from a `PUSH_CODE_BINARY_RESPONSE`.
///
/// Both companion layouts are accepted: `[8C][00][tag(4)][payload…]` and
/// `[8C][00][pubkey_prefix(6)][tag(4)][payload…]`. With no CRC to frame
/// variable-length reports, a matching pubkey prefix decides the order: a
/// genuine tag-first frame almost never begins with our contact's prefix.
List<({int tag, Uint8List payload})> _binaryCandidates(
  Uint8List frame,
  Uint8List contactPubKey, {
  int? askTag,
}) {
  if (frame.isEmpty || frame[0] != pushCodeBinaryResponse) return const [];
  var prefixMatches = contactPubKey.length >= 6;
  for (var i = 0; i < 6 && prefixMatches; i++) {
    prefixMatches = frame.length > 2 + i && frame[2 + i] == contactPubKey[i];
  }
  final tagsAt = prefixMatches ? const [8, 2] : const [2, 8];
  final out = <({int tag, Uint8List payload})>[];
  for (final tagAt in tagsAt) {
    if (tagAt == 8 && !prefixMatches) continue;
    if (frame.length < tagAt + 8) continue;
    final tag = frame[tagAt] |
        (frame[tagAt + 1] << 8) |
        (frame[tagAt + 2] << 16) |
        (frame[tagAt + 3] << 24);
    if (askTag != null && tag != askTag) continue;
    out.add((tag: tag, payload: Uint8List.fromList(frame.sublist(tagAt + 4))));
  }
  return out;
}

/// Extract a fixed-length report, ignoring the crypto layer's zero padding.
Uint8List? binaryResponsePayload(
  Uint8List frame,
  Uint8List contactPubKey, {
  int? askTag,
  required int exactLength,
}) {
  for (final c in _binaryCandidates(frame, contactPubKey, askTag: askTag)) {
    if (c.payload.length >= exactLength) {
      return Uint8List.fromList(c.payload.sublist(0, exactLength));
    }
  }
  return null;
}

/// Extract a variable-length report including its zero padding.
///
/// Codecs for ACL / neighbours / owner info determine the real length from
/// the report's own counts or NUL terminator, so a CRC would be ambiguous.
Uint8List? binaryResponseRaw(
  Uint8List frame,
  Uint8List contactPubKey, {
  int? askTag,
}) {
  final candidates = _binaryCandidates(frame, contactPubKey, askTag: askTag);
  return candidates.isEmpty ? null : candidates.first.payload;
}

/// Sends `[reqType][data…]` through `CMD_SEND_BINARY_REQ` and waits for the
/// tagged response. Pure Dart: the caller owns serialization of exchanges.
class RepeaterReqClient {
  RepeaterReqClient(this.link);

  final RadioLink link;

  Future<Uint8List?> _exchange(
    Contact contact,
    int reqType,
    List<int> data, {
    required Uint8List? Function(Uint8List frame, int? askTag) extract,
    required Duration timeout,
  }) async {
    final done = Completer<Uint8List?>();
    int? askTag;
    late final StreamSubscription<Uint8List> sub;
    sub = link.pushes.listen((frame) {
      if (done.isCompleted) return;
      final payload = extract(frame, askTag);
      if (payload != null) done.complete(payload);
    });
    try {
      final sent = await link.sendBinaryRequest(contact, [reqType, ...data]);
      askTag = sent.tag;
      return await done.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }

  /// Fixed-length report (for example the 56-byte status struct).
  Future<Uint8List> request(
    Contact contact,
    int reqType, {
    List<int> data = const [],
    required int exactLength,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final payload = await _exchange(
      contact,
      reqType,
      data,
      extract: (frame, tag) => binaryResponsePayload(
        frame,
        contact.publicKey,
        askTag: tag,
        exactLength: exactLength,
      ),
      timeout: timeout,
    );
    if (payload == null) {
      throw RepeaterRequestException(
          'no reply to request 0x${reqType.toRadixString(16)}');
    }
    return payload;
  }

  /// Variable-length report; the codec trims padding using its own framing.
  Future<Uint8List> requestRaw(
    Contact contact,
    int reqType, {
    List<int> data = const [],
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final payload = await _exchange(
      contact,
      reqType,
      data,
      extract: (frame, tag) => binaryResponseRaw(
        frame,
        contact.publicKey,
        askTag: tag,
      ),
      timeout: timeout,
    );
    if (payload == null) {
      throw RepeaterRequestException(
          'no reply to request 0x${reqType.toRadixString(16)}');
    }
    return payload;
  }
}
