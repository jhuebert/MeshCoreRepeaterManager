import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// Sends a fleet script as one plain group text packet. The PSK is held in
/// memory only for this session; it is never cached or logged.
class FleetSender {
  FleetSender({
    required this.link,
    required this.pskHex,
    this.senderName = 'Manager',
  });

  final RadioLink link;
  final String pskHex;
  final String senderName;

  bool get hasKey => RegExp(r'^([0-9a-fA-F]{2}){16}$|^([0-9a-fA-F]{2}){32}$')
      .hasMatch(pskHex.trim());

  Future<void> send(String script) async {
    if (!hasKey) {
      throw const FormatException(
          'Enter a 16 or 32 byte fleet PSK in hex before sending');
    }
    final packet = PacketBuilder.createGroupText(
      channel: Channel(name: 'fleet', secret: hexToBytes(pskHex.trim())),
      message: script,
      senderName: senderName,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      maxContentLength: maxGroupTextContentOverCompanion,
    );
    await link.sendRawPacket(packet.writeTo());
  }
}
