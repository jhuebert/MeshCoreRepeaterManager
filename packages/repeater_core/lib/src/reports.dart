import 'dart:typed_data';

/// Client-side mirrors of the stock repeater's binary reports. The firmware is
/// the fixed contract; these codecs only read what it already returns.

/// One ACL row: a 6-byte public-key prefix and a permission byte whose lower
/// two bits are the role (0 deleted, 1 read-only, 2 read-write, 3 admin).
class AclEntry {
  const AclEntry(this.prefix, this.permissions);

  final Uint8List prefix;
  final int permissions;

  int get role => permissions & 0x03;
  String get roleLabel => switch (role) {
        1 => 'Read only',
        2 => 'Read and write',
        3 => 'Admin',
        _ => 'Guest',
      };
  String get prefixHex =>
      prefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Request data for `REQ_TYPE_GET_ACCESS_LIST` (after the request type byte).
const accessListRequest = <int>[0, 0];

/// Parse ACL rows. Entries are 7 bytes; a zero permission byte marks the end
/// (deleted entries and zero padding both read as zero).
List<AclEntry> parseAccessList(Uint8List payload) {
  final out = <AclEntry>[];
  for (var o = 0; o + 7 <= payload.length; o += 7) {
    final permissions = payload[o + 6];
    if (permissions == 0) break;
    out.add(
        AclEntry(Uint8List.fromList(payload.sublist(o, o + 6)), permissions));
  }
  return out;
}

enum NeighborOrder { newest, oldest, strongest, weakest }

extension NeighborOrderX on NeighborOrder {
  int get wireValue => switch (this) {
        NeighborOrder.newest => 0,
        NeighborOrder.oldest => 1,
        NeighborOrder.strongest => 2,
        NeighborOrder.weakest => 3,
      };
  String get label => switch (this) {
        NeighborOrder.newest => 'Newest first',
        NeighborOrder.oldest => 'Oldest first',
        NeighborOrder.strongest => 'Strongest first',
        NeighborOrder.weakest => 'Weakest first',
      };
}

/// Build request data for `REQ_TYPE_GET_NEIGHBOURS`, version 0. The four random
/// bytes make each query unique on air; the caller supplies them.
Uint8List buildNeighboursRequest({
  int count = 16,
  int offset = 0,
  NeighborOrder order = NeighborOrder.newest,
  int prefixLength = 6,
  int nonce = 0,
}) {
  final w = ByteData(11);
  w.setUint8(0, 0); // request version
  w.setUint8(1, count.clamp(0, 255));
  w.setUint16(2, offset.clamp(0, 65535), Endian.little);
  w.setUint8(4, order.wireValue);
  w.setUint8(5, prefixLength.clamp(0, 32));
  w.setUint32(6, nonce, Endian.little);
  return w.buffer.asUint8List();
}

class Neighbor {
  const Neighbor(this.prefix, this.heardSecondsAgo, this.snr);

  final Uint8List prefix;
  final int heardSecondsAgo;
  final double snr;

  String get prefixHex =>
      prefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class NeighborPage {
  const NeighborPage(this.total, this.entries);

  final int total;
  final List<Neighbor> entries;
}

/// Parse a neighbours report. [prefixLength] must be the length asked for.
NeighborPage parseNeighbours(Uint8List payload, {required int prefixLength}) {
  if (payload.length < 4) return const NeighborPage(0, []);
  final r = ByteData.sublistView(payload);
  final total = r.getUint16(0, Endian.little);
  final resultCount = r.getUint16(2, Endian.little);
  final entrySize = prefixLength + 4 + 1;
  final out = <Neighbor>[];
  var o = 4;
  for (var i = 0; i < resultCount && o + entrySize <= payload.length; i++) {
    final prefix = Uint8List.fromList(payload.sublist(o, o + prefixLength));
    o += prefixLength;
    final heard = r.getUint32(o, Endian.little);
    o += 4;
    // NeighbourInfo.snr is signed, multiplied by 4 on air.
    final snr = payload[o].toSigned(8) / 4;
    o += 1;
    out.add(Neighbor(prefix, heard, snr));
  }
  return NeighborPage(total, out);
}

class OwnerInfo {
  const OwnerInfo(this.version, this.name, this.owner);

  final String version;
  final String name;
  final String owner;

  factory OwnerInfo.parse(Uint8List payload) {
    final end = payload.indexOf(0);
    final text =
        String.fromCharCodes(end < 0 ? payload : payload.sublist(0, end));
    final parts = text.split('\n');
    return OwnerInfo(
      parts.isNotEmpty ? parts[0] : '',
      parts.length > 1 ? parts[1] : '',
      parts.length > 2 ? parts.sublist(2).join('\n') : '',
    );
  }
}
