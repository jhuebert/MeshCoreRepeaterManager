import 'dart:typed_data';

import 'package:repeater_core/repeater_core.dart';

/// One job's per-repeater results. A repeater with no matching ACK inside the
/// window is shown as No reply, never silently dropped.
class FleetJobResult {
  FleetJobResult({
    required this.id,
    required this.script,
    required this.sentAt,
    this.tags = const [],
  });

  final String id;
  final String script;
  final DateTime sentAt;
  final List<String> tags;
  final Map<String, FleetAck> acks = {};

  Map<String, Object?> toJson() => {
        'schema': 1,
        'id': id,
        'script': script,
        'sentAt': sentAt.toIso8601String(),
        'tags': tags,
        'acks': acks.map((sender, ack) => MapEntry(sender, {
              'sender': ack.sender,
              'output': ack.output,
              'ok': ack.ok,
              'at': ack.at.toIso8601String(),
            })),
      };

  factory FleetJobResult.fromJson(Map<String, dynamic> json) {
    final result = FleetJobResult(
      id: json['id'] as String,
      script: json['script'] as String,
      sentAt: DateTime.tryParse(json['sentAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      tags:
          (json['tags'] as List? ?? const []).map((e) => e.toString()).toList(),
    );
    final raw = json['acks'] as Map? ?? const {};
    for (final entry in raw.entries) {
      final ack = Map<String, dynamic>.from(entry.value as Map);
      result.acks[entry.key.toString()] = FleetAck(
        jobId: result.id,
        sender: ack['sender'] as String? ?? entry.key.toString(),
        output: ack['output'] as String? ?? '',
        ok: ack['ok'] as bool? ?? false,
        at: DateTime.tryParse(ack['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    return result;
  }
}

/// Matches plain channel-text ACKs to jobs the app actually sent. Frames can
/// also arrive during the post-login drain of stale companion messages.
class AckCollector {
  final pending = <String, FleetJobResult>{};
  final history = <FleetJobResult>[];

  static const maxHistory = 100;

  void track(FleetJobResult result) {
    pending[result.id] = result;
    history.removeWhere((r) => r.id == result.id);
    history.insert(0, result);
    if (history.length > maxHistory) {
      history.removeRange(maxHistory, history.length);
    }
  }

  /// Returns true when a frame was a matching ACK.
  bool handleFrame(Uint8List frame) {
    final message = parseChannelMessage(frame);
    if (message == null || message.txtType != 0) return false;
    final sender = message.senderName;
    if (sender == null) return false;
    final ack = FleetAck.parse(
        senderName: sender, text: message.body, at: DateTime.now());
    final job = pending[ack.jobId];
    if (job == null) return false;
    job.acks[sender] = ack;
    return true;
  }

  /// Accept an ACK from a caller that already decoded the channel text.
  bool handleText(String senderName, String text) {
    final ack =
        FleetAck.parse(senderName: senderName, text: text, at: DateTime.now());
    final job = pending[ack.jobId];
    if (job == null) return false;
    job.acks[senderName] = ack;
    return true;
  }

  void forget(String id) => pending.remove(id);

  List<FleetJobResult> export() => List.unmodifiable(history);
}
