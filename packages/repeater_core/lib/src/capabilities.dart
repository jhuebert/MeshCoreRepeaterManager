// Read-only firmware identification. A stock repeater and a fork repeater
// accept many of the same commands, so the app probes before it renders
// management controls. An unanswered probe is "not confirmed", never
// "unsupported".

enum FirmwareKind { stock, fork, unknown }

enum CapabilityConfidence { confirmed, tentative, unknown }

/// Per-probe result. Only read-only probes are ever sent.
enum ProbeVerdict { forkPositive, stockNegative, unknown }

/// The compact probe set. Each entry is one read-only CLI exchange.
const coreProbes = <String>[
  'ota status',
  'filter',
  'fleet',
  'radio2 status',
  'get mqtt.status',
];

const extraProbes = <String>[
  'battery',
  'clock mesh',
  'bot',
  'get cpu.freq',
  'get radio.rxps',
];

/// Classify one reply. Stock firmware has distinctive negative answers
/// (`Unknown command`, `??: key` for unknown `get` keys); the fork intercepts
/// the same commands and prints its own usage or status lines.
ProbeVerdict classifyProbe(String probe, String reply) {
  final text = reply.trim();
  if (text.isEmpty) return ProbeVerdict.unknown;
  final lower = text.toLowerCase();
  if (lower.contains('unknown command') ||
      (lower.startsWith('??') && probe.startsWith('get '))) {
    return ProbeVerdict.stockNegative;
  }
  final positive = switch (probe) {
    'ota status' => lower.contains('running=') && lower.contains('sha='),
    // The fork answers bare `filter` with its status line, not usage text.
    'filter' => lower.contains('usage') ||
        (lower.contains('rules ') && lower.contains('chans ')),
    'fleet' => lower.contains('usage') || lower.contains('chan'),
    'radio2 status' => lower.startsWith('on') ||
        lower.startsWith('off') ||
        lower.contains('preset='),
    'get mqtt.status' => lower.contains('wifi:') || lower.contains('mqtt '),
    'battery' => lower.contains('batt') || lower.contains('gate'),
    'clock mesh' => lower.contains('slots') ||
        lower.contains('samples') ||
        lower.startsWith('on') ||
        lower.startsWith('off'),
    'bot' => lower.startsWith('bot'),
    // The reply is a bare value such as `> 80`, with no unit word.
    'get cpu.freq' => lower.contains('mhz') ||
        lower.contains('default') ||
        RegExp(r'^>\s*\d+').hasMatch(text),
    'get radio.rxps' =>
      lower.contains('desired') || lower.contains('effective'),
    _ => false,
  };
  return positive ? ProbeVerdict.forkPositive : ProbeVerdict.unknown;
}

/// Cached identification of one repeater. Unknown means "not confirmed yet".
class RepeaterCapabilities {
  const RepeaterCapabilities({
    this.firmwareKind = FirmwareKind.unknown,
    this.confidence = CapabilityConfidence.unknown,
    this.ota = false,
    this.otaFeatures = 0,
    this.filter = false,
    this.fleet = false,
    this.mqtt = false,
    this.radio2 = false,
    this.batteryGate = false,
    this.meshClock = false,
    this.bot = false,
    this.powerProfile = false,
    this.region = false,
    this.gps = false,
    this.sensors = false,
    this.bridge = false,
    this.detectedAt,
    this.evidence = const {},
  });

  final FirmwareKind firmwareKind;
  final CapabilityConfidence confidence;
  final bool ota;
  final int otaFeatures;
  final bool filter;
  final bool fleet;
  final bool mqtt;
  final bool radio2;
  final bool batteryGate;
  final bool meshClock;
  final bool bot;
  final bool powerProfile;
  final bool region;
  final bool gps;
  final bool sensors;
  final bool bridge;
  final DateTime? detectedAt;

  /// Probe name to the raw reply that decided it. Kept so the "Identify
  /// firmware" action can show its work.
  final Map<String, String> evidence;

  bool supports(String feature) => switch (feature) {
        'ota' => ota,
        'filter' => filter,
        'fleet' => fleet,
        'mqtt' => mqtt,
        'radio2' => radio2,
        'batteryGate' => batteryGate,
        'meshClock' => meshClock,
        'bot' => bot,
        'powerProfile' => powerProfile,
        'region' => region,
        'gps' => gps,
        'sensors' => sensors,
        'bridge' => bridge,
        _ => false,
      };

  RepeaterCapabilities copyWithOtaFeatures(int features) =>
      RepeaterCapabilities(
        firmwareKind: firmwareKind,
        confidence: confidence,
        ota: ota,
        otaFeatures: features,
        filter: filter,
        fleet: fleet,
        mqtt: mqtt,
        radio2: radio2,
        batteryGate: batteryGate,
        meshClock: meshClock,
        bot: bot,
        powerProfile: powerProfile,
        region: region,
        gps: gps,
        sensors: sensors,
        bridge: bridge,
        detectedAt: detectedAt,
        evidence: evidence,
      );

  Map<String, Object?> toJson() => {
        'schema': 1,
        'firmwareKind': firmwareKind.name,
        'confidence': confidence.name,
        'ota': ota,
        'otaFeatures': otaFeatures,
        'filter': filter,
        'fleet': fleet,
        'mqtt': mqtt,
        'radio2': radio2,
        'batteryGate': batteryGate,
        'meshClock': meshClock,
        'bot': bot,
        'powerProfile': powerProfile,
        'region': region,
        'gps': gps,
        'sensors': sensors,
        'bridge': bridge,
        'detectedAt': detectedAt?.toIso8601String(),
        'evidence': evidence,
      };

  factory RepeaterCapabilities.fromJson(Map<String, dynamic> json) =>
      RepeaterCapabilities(
        firmwareKind: FirmwareKind.values
            .byName(json['firmwareKind'] as String? ?? 'unknown'),
        confidence: CapabilityConfidence.values
            .byName(json['confidence'] as String? ?? 'unknown'),
        ota: json['ota'] as bool? ?? false,
        otaFeatures: json['otaFeatures'] as int? ?? 0,
        filter: json['filter'] as bool? ?? false,
        fleet: json['fleet'] as bool? ?? false,
        mqtt: json['mqtt'] as bool? ?? false,
        radio2: json['radio2'] as bool? ?? false,
        batteryGate: json['batteryGate'] as bool? ?? false,
        meshClock: json['meshClock'] as bool? ?? false,
        bot: json['bot'] as bool? ?? false,
        powerProfile: json['powerProfile'] as bool? ?? false,
        region: json['region'] as bool? ?? false,
        gps: json['gps'] as bool? ?? false,
        sensors: json['sensors'] as bool? ?? false,
        bridge: json['bridge'] as bool? ?? false,
        detectedAt: json['detectedAt'] == null
            ? null
            : DateTime.parse(json['detectedAt'] as String),
        evidence: (json['evidence'] as Map? ?? const {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
      );
}

/// Turn a set of probe replies into a capability record.
///
/// [otaConfirmed] comes from the frozen `ota status` / OP_INFO handshake, which
/// is decisive on its own. Otherwise three positive probes confirm the fork,
/// two stock-negative probes confirm stock, and a single hit is only tentative.
RepeaterCapabilities detectCapabilities({
  required Map<String, String?> replies,
  bool otaConfirmed = false,
  DateTime? now,
}) {
  final positives = <String>[];
  final negatives = <String>[];
  final evidence = <String, String>{};
  replies.forEach((probe, reply) {
    if (reply == null || reply.trim().isEmpty) return;
    evidence[probe] = reply.trim();
    switch (classifyProbe(probe, reply)) {
      case ProbeVerdict.forkPositive:
        positives.add(probe);
      case ProbeVerdict.stockNegative:
        negatives.add(probe);
      case ProbeVerdict.unknown:
        break;
    }
  });

  final fork = otaConfirmed || positives.isNotEmpty;
  final stock = !fork && negatives.length >= 2;
  final kind = fork
      ? FirmwareKind.fork
      : stock
          ? FirmwareKind.stock
          : FirmwareKind.unknown;
  // A single hit is a tentative fork: the tile stays locked until the full
  // probe set agrees, but the direction is already known.
  final confirmed = otaConfirmed || positives.length >= 3 || stock;
  final confidence = confirmed
      ? CapabilityConfidence.confirmed
      : (positives.isNotEmpty || negatives.isNotEmpty)
          ? CapabilityConfidence.tentative
          : CapabilityConfidence.unknown;
  final extras = positives.toSet();

  return RepeaterCapabilities(
    firmwareKind: kind,
    confidence: confidence,
    ota: otaConfirmed || extras.contains('ota status'),
    filter: extras.contains('filter'),
    fleet: extras.contains('fleet'),
    mqtt: extras.contains('get mqtt.status'),
    radio2: extras.contains('radio2 status'),
    batteryGate: extras.contains('battery'),
    meshClock: extras.contains('clock mesh'),
    bot: extras.contains('bot'),
    powerProfile:
        extras.contains('get cpu.freq') || extras.contains('get radio.rxps'),
    detectedAt: now ?? DateTime.now(),
    evidence: evidence,
  );
}
