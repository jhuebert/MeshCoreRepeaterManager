// Parsers and validators for the fork's smaller features. The reply shapes
// here were captured from a live v1.18.0-ota2 repeater.

class Radio2Status {
  const Radio2Status(this.enabled, this.preset);

  final bool enabled;
  final String? preset; // "freq,bw,sf,cr" as reported by the node

  static Radio2Status parse(String reply) {
    final lower = reply.trim().toLowerCase();
    final preset = RegExp(r'preset=([^;\s]+)').firstMatch(reply)?.group(1);
    return Radio2Status(lower.startsWith('on'), preset);
  }
}

class BatteryStatus {
  const BatteryStatus(this.milliVolts, this.gateOn, this.drops);

  final int milliVolts;
  final bool gateOn;
  final int drops;

  static BatteryStatus? parse(String reply) {
    final mv = RegExp(r'batt\s+(\d+)mv').firstMatch(reply.toLowerCase());
    if (mv == null) return null;
    final drops = RegExp(r'drops\s+(\d+)').firstMatch(reply.toLowerCase());
    return BatteryStatus(
      int.parse(mv.group(1)!),
      reply.toLowerCase().contains('gate on'),
      drops == null ? 0 : int.tryParse(drops.group(1)!) ?? 0,
    );
  }

  /// The fork accepts 1 to 10000 mV and requires resume above suspend.
  static String? validate(int suspend, int? resume) {
    if (suspend < 1 || suspend > 10000) return 'Use 1 to 10000 mV';
    if (resume != null) {
      if (resume < 1 || resume > 10000) return 'Use 1 to 10000 mV';
      if (resume <= suspend) return 'Resume must be above suspend';
    }
    return null;
  }
}

class MeshClockStatus {
  const MeshClockStatus(this.enabled, this.slots, this.minVotes, this.tolerance,
      this.minTolerance, this.nowUtc);

  final bool enabled;
  final int slots;
  final int minVotes;
  final int tolerance;
  final int minTolerance;
  final String? nowUtc;

  static MeshClockStatus? parse(String reply) {
    final text = reply.trim();
    final slotPair = RegExp(r'slots=(\d+)/(\d+)').firstMatch(text);
    final tolPair = RegExp(r'tol=(\d+)/(\d+)').firstMatch(text);
    if (slotPair == null || tolPair == null) return null;
    return MeshClockStatus(
      text.toLowerCase().startsWith('on'),
      int.parse(slotPair.group(1)!),
      int.parse(slotPair.group(2)!),
      int.parse(tolPair.group(1)!),
      int.parse(tolPair.group(2)!),
      RegExp(r'now=(\S+)').firstMatch(text)?.group(1),
    );
  }

  static String? validateSlots(int slots, int votes) {
    if (slots < 3 || slots > 33) return 'Slots must be 3 to 33';
    if (votes < 2 || votes > slots) return 'Votes must be 2 to $slots';
    return null;
  }

  static String? validateTolerance(int tolerance, int min) {
    if (tolerance < 1 || tolerance > 65535)
      return 'Tolerance must be 1 to 65535';
    if (min < 0 || min > 65535) return 'Minimum must be 0 to 65535';
    return null;
  }
}

class BotStatus {
  const BotStatus(this.enabled, this.name, this.channel);

  final bool enabled;
  final String name;
  final String channel;

  static BotStatus parse(String reply) {
    final text = reply.trim();
    final name = RegExp(r'name\s+([^,]+)').firstMatch(text)?.group(1)?.trim();
    final chan = RegExp(r'chan\s+([^,]+)').firstMatch(text)?.group(1)?.trim();
    return BotStatus(
      text.toLowerCase().startsWith('bot: on'),
      name ?? '(node)',
      chan ?? '(none)',
    );
  }

  static String? validateName(String name) {
    if (name.isEmpty || name.length > 16) return 'Use 1 to 16 characters';
    return null;
  }

  /// A channel is either a #name or 32/64 hex digits; the secret is never
  /// echoed after entry.
  static String? validateChannel(String value) {
    if (value == 'off' || RegExp(r'^#[^\s]{1,15}$').hasMatch(value)) {
      return null;
    }
    if (RegExp(r'^[0-9a-fA-F]{32}$|^[0-9a-fA-F]{64}$').hasMatch(value)) {
      return null;
    }
    return 'Use a #name, 32 or 64 hex digits, or off';
  }
}

class RxpsStatus {
  const RxpsStatus({
    required this.desired,
    required this.effective,
    required this.supported,
    required this.level,
    required this.preamble,
    required this.rxMicros,
    required this.sleepMicros,
  });

  final String desired;
  final String effective;
  final bool supported;
  final int level;
  final int preamble;
  final int rxMicros;
  final int sleepMicros;

  static String? _field(String text, String key) =>
      RegExp('$key=([^,]+)').firstMatch(text)?.group(1);

  static RxpsStatus? parse(String reply) {
    final text = reply.replaceFirst(RegExp(r'^>\s*'), '').trim();
    if (!text.contains('desired=')) return null;
    return RxpsStatus(
      desired: _field(text, 'desired') ?? 'off',
      effective: _field(text, 'effective') ?? 'unknown',
      supported: (_field(text, 'supported') ?? 'no') == 'yes',
      level: int.tryParse(_field(text, 'level') ?? '') ?? 0,
      preamble: int.tryParse(_field(text, 'preamble') ?? '') ?? 0,
      rxMicros: int.tryParse(_field(text, 'rx') ?? '') ?? 0,
      sleepMicros: int.tryParse(_field(text, 'sleep') ?? '') ?? 0,
    );
  }

  /// RX power saving and radio2 are mutually exclusive on the node.
  static String? validateRadio2Conflict(bool radio2Enabled) =>
      radio2Enabled ? 'Turn radio2 off before enabling power saving' : null;

  static String? validateLevel(int level) =>
      (level < 1 || level > 10) ? 'Level must be 1 to 10' : null;

  static String? validatePreamble(int bits) =>
      (bits != 0 && bits != 16 && bits != 32)
          ? 'Preamble must be 0, 16 or 32 bits'
          : null;
}

const cpuFrequencies = <int>[40, 80, 160, 240];
