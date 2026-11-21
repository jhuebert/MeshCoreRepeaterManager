// Fleet script and ACK codecs, mirroring FLEET.md. The firmware executes the
// script with its own privileges; the app only composes and parses text.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// One job is exactly one group text message.
class FleetJob {
  const FleetJob({
    required this.id,
    this.tags = const [],
    this.ack = false,
    this.ackErrOnly = false,
    this.at,
    this.commands = const [],
    this.delayMs,
  });

  final String id;
  final List<String> tags;
  final bool ack;
  final bool ackErrOnly;
  final int? at;

  /// Command lines, with optional `!delay <ms>` lines between them.
  final List<String> commands;

  /// Optional inter-line delay applied as `!delay` between commands.
  final int? delayMs;

  static const byteLimit = 157; // group text over the companion
  static const maxTags = 8;
  static const maxDelayMs = 300000;

  String? validate() {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,32}$').hasMatch(id)) {
      return 'The job id needs 1 to 32 letters, digits, dot, _ or -';
    }
    if (tags.length > maxTags) return 'At most $maxTags tags';
    for (final tag in tags) {
      if (!RegExp(r'^[A-Za-z0-9._-]{1,32}$').hasMatch(tag)) {
        return 'Invalid tag: $tag';
      }
    }
    if (ackErrOnly && !ack) return 'Error-only ACK needs ACK enabled';
    if (commands.isEmpty) return 'Add at least one command';
    if (commands.first.trim().startsWith('!delay')) {
      return 'Put a command before !delay';
    }
    for (final line in commands) {
      final trimmed = line.trim();
      if (trimmed.startsWith('!')) {
        final delay = RegExp(r'^!delay\s+(\d+)$').firstMatch(trimmed);
        if (delay == null) return 'Unknown directive: $trimmed';
        final ms = int.tryParse(delay.group(1)!) ?? 0;
        if (ms < 1 || ms > maxDelayMs) {
          return 'Delay must be 1 to $maxDelayMs ms';
        }
      }
    }
    if (delayMs != null && (delayMs! < 1 || delayMs! > maxDelayMs)) {
      return 'Delay must be 1 to $maxDelayMs ms';
    }
    return null;
  }
}

/// Compose the exact script text. Validates first and throws on bad input so
/// the app cannot send an unparsable job.
String composeJob(FleetJob job) {
  final error = job.validate();
  if (error != null) throw ArgumentError(error);
  final lines = <String>['!id ${job.id}'];
  if (job.tags.isNotEmpty) lines.add('!tags ${job.tags.join(',')}');
  if (job.ack) lines.add(job.ackErrOnly ? '!ack err' : '!ack');
  if (job.at != null) lines.add('!at ${job.at}');
  final delay = job.delayMs;
  for (var i = 0; i < job.commands.length; i++) {
    if (delay != null) lines.add('!delay $delay');
    lines.add(job.commands[i]);
  }
  return lines.join('\n');
}

int scriptBytes(String script) => utf8.encode(script).length;

String generateJobId(DateTime now) =>
    'job-${now.toUtc().toIso8601String().replaceAll(RegExp(r'[-:TZ.]'), '').substring(0, 14)}';

class FleetAck {
  const FleetAck({
    required this.jobId,
    required this.sender,
    required this.output,
    required this.ok,
    required this.at,
  });

  final String jobId;
  final String sender;
  final String output;
  final bool ok;
  final DateTime at;

  factory FleetAck.parse({
    required String senderName,
    required String text,
    required DateTime at,
  }) {
    final trimmed = text.trim();
    // Both layouts occur: `key\n<reply>` and `key ran N ok` / `key ran N; err`.
    final firstLine = trimmed.split('\n').first.trim();
    final parts = firstLine.split(RegExp(r'\s+'));
    final key = parts.first;
    var ok = true;
    var output = trimmed.substring(key.length).trimLeft();
    final ran = RegExp(r'^ran\s+(\d+)(.*)$').firstMatch(output);
    if (ran != null) {
      final detail = ran.group(2)!.trim();
      ok = detail.isEmpty || detail == 'ok';
      output = detail;
    }
    if (output.length >= 3 && output.endsWith('...')) {
      output = '$output (reply was cut)';
    }
    final lower = output.toLowerCase();
    if (lower.startsWith('err') ||
        lower.startsWith('error') ||
        lower.contains('unknown command')) {
      ok = false;
    }
    return FleetAck(
        jobId: key, sender: senderName, output: output, ok: ok, at: at);
  }
}

/// An ACK is only valid for a job we actually sent.
bool ackMatches(FleetAck ack, String jobId) => ack.jobId == jobId;

/// A decrypted channel message as forwarded by the companion. The `text`
/// already includes the `SenderName: ` prefix.
class ChannelMessage {
  const ChannelMessage({
    required this.channelIndex,
    required this.txtType,
    required this.timestamp,
    required this.text,
  });

  final int channelIndex;
  final int txtType;
  final int timestamp;
  final String text;

  String? get senderName {
    final at = text.indexOf(': ');
    return at < 0 ? null : text.substring(0, at);
  }

  String get body {
    final at = text.indexOf(': ');
    return at < 0 ? text : text.substring(at + 2);
  }
}

/// Parse `RESP_CODE_CHANNEL_MSG_RECV(_V3)` frames from the companion.
ChannelMessage? parseChannelMessage(Uint8List frame) {
  if (frame.isEmpty) return null;
  final code = frame[0];
  var o = 1;
  if (code == respCodeChannelMsgRecvV3) {
    if (frame.length < 4) return null;
    o = 4; // snr + two reserved bytes
  } else if (code != respCodeChannelMsgRecv) {
    return null;
  }
  if (frame.length < o + 7) return null;
  final channelIndex = frame[o++];
  o++; // path length
  final txtType = frame[o++];
  final reader = ByteData.sublistView(frame);
  final timestamp = reader.getUint32(o, Endian.little);
  o += 4;
  final bytes = frame.sublist(o);
  final nul = bytes.indexOf(0);
  final payload = nul < 0 ? bytes : bytes.sublist(0, nul);
  return ChannelMessage(
    channelIndex: channelIndex,
    txtType: txtType,
    timestamp: timestamp,
    text: utf8.decode(payload, allowMalformed: true),
  );
}
