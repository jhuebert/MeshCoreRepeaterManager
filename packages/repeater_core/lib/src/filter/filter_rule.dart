// Filter rule model and the CLI text contract from FILTER.md.

import 'dart:convert';

import 'dialect.dart';

class FilterRule {
  const FilterRule({
    this.index = 0,
    this.enabled = true,
    this.action = 'drop',
    this.types = const [],
    this.route,
    this.hops,
    this.len,
    this.snr,
    this.path,
    this.hsize = const [],
    this.channels = const [],
    this.chanhash,
    this.regions = const [],
    this.sender,
    this.text,
    this.prob,
    this.throttle,
    this.hits = 0,
    this.pass = 0,
    this.air = 0,
  });

  final int index;
  final bool enabled;
  final String action;
  final List<String> types;
  final String? route;
  final String? hops;
  final String? len;
  final String? snr;
  final String? path;
  final List<int> hsize;
  final List<String> channels;
  final String? chanhash;
  final List<String> regions;
  final String? sender;
  final String? text;
  final int? prob;
  final int? throttle;
  final int hits;
  final int pass;
  final int air;

  /// A compact condition summary for the rule list.
  String get summary {
    final parts = <String>[
      if (!enabled) 'disabled',
      action,
      ...conditions.map((e) => '${e.key}=${e.value}'),
    ];
    return parts.join(' ');
  }

  List<({String key, String value})> get conditions => [
        if (types.isNotEmpty) (key: 'type', value: types.join(',')),
        if (route != null) (key: 'route', value: route!),
        if (hops != null) (key: 'hops', value: hops!),
        if (len != null) (key: 'len', value: len!),
        if (snr != null) (key: 'snr', value: snr!),
        if (path != null) (key: 'path', value: path!),
        if (hsize.isNotEmpty) (key: 'hsize', value: hsize.join(',')),
        if (channels.isNotEmpty) (key: 'chan', value: channels.join(',')),
        if (chanhash != null) (key: 'chanhash', value: chanhash!),
        if (regions.isNotEmpty) (key: 'region', value: regions.join(',')),
        if (sender != null) (key: 'sender', value: sender!),
        if (text != null) (key: 'text', value: text!),
        if (prob != null) (key: 'prob', value: '$prob'),
        if (throttle != null) (key: 'throttle', value: '$throttle'),
      ];

  FilterRule copyWith({
    int? index,
    bool? enabled,
    String? action,
    List<String>? types,
    String? route,
    String? hops,
    String? len,
    String? snr,
    String? path,
    List<int>? hsize,
    List<String>? channels,
    String? chanhash,
    List<String>? regions,
    String? sender,
    String? text,
    int? prob,
    int? throttle,
    int? hits,
    int? pass,
    int? air,
  }) =>
      FilterRule(
        index: index ?? this.index,
        enabled: enabled ?? this.enabled,
        action: action ?? this.action,
        types: types ?? this.types,
        route: route ?? this.route,
        hops: hops ?? this.hops,
        len: len ?? this.len,
        snr: snr ?? this.snr,
        path: path ?? this.path,
        hsize: hsize ?? this.hsize,
        channels: channels ?? this.channels,
        chanhash: chanhash ?? this.chanhash,
        regions: regions ?? this.regions,
        sender: sender ?? this.sender,
        text: text ?? this.text,
        prob: prob ?? this.prob,
        throttle: throttle ?? this.throttle,
        hits: hits ?? this.hits,
        pass: pass ?? this.pass,
        air: air ?? this.air,
      );

  Map<String, Object?> toJson() => {
        'schema': 1,
        'index': index,
        'enabled': enabled,
        'action': action,
        'types': types,
        'route': route,
        'hops': hops,
        'len': len,
        'snr': snr,
        'path': path,
        'hsize': hsize,
        'channels': channels,
        'chanhash': chanhash,
        'regions': regions,
        'sender': sender,
        'text': text,
        'prob': prob,
        'throttle': throttle,
      };

  factory FilterRule.fromJson(Map<String, dynamic> json) => FilterRule(
        index: json['index'] as int? ?? 0,
        enabled: json['enabled'] as bool? ?? true,
        action: json['action'] as String? ?? 'drop',
        types: (json['types'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        route: json['route'] as String?,
        hops: json['hops'] as String?,
        len: json['len'] as String?,
        snr: json['snr'] as String?,
        path: json['path'] as String?,
        hsize: (json['hsize'] as List? ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        channels: (json['channels'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        chanhash: json['chanhash'] as String?,
        regions: (json['regions'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        sender: json['sender'] as String?,
        text: json['text'] as String?,
        prob: json['prob'] as int?,
        throttle: json['throttle'] as int?,
      );
}

/// Split a CLI tail on spaces, keeping double-quoted values together.
List<String> tokenizeCli(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') {
      quoted = !quoted;
      continue;
    }
    if (c == ' ' && !quoted) {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
      continue;
    }
    if (c == r'\' && quoted && i + 1 < text.length) {
      buf.write(text[++i]);
      continue;
    }
    buf.write(c);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

String _quote(String value) => value.contains(' ') ? '"$value"' : value;

/// Build the exact `filter add ...` command a rule would produce.
String ruleToAddCommand(FilterRule rule) {
  final parts = <String>['filter', 'add'];
  // `disabled` is a display state, not an add condition: add the rule, then
  // send `filter disable <idx>` when it should start disabled.
  if (rule.action != 'drop') parts.add(rule.action);
  for (final c in rule.conditions) {
    parts.add('${c.key}=${_quote(c.value)}');
  }
  return parts.join(' ');
}

/// Apply a `key=value` token to a rule. Used by both the list parser and the
/// editor's preview so they cannot drift.
FilterRule applyCondition(FilterRule rule, String token) {
  final at = token.indexOf('=');
  if (at < 0) {
    if (token == 'disabled') return rule.copyWith(enabled: false);
    if (token == 'drop' || token == 'forward') {
      return rule.copyWith(action: token);
    }
    return rule;
  }
  if (at == 0) return rule;
  final key = token.substring(0, at);
  final value = token.substring(at + 1);
  switch (key) {
    case 'type':
      return rule.copyWith(types: value.split(','));
    case 'route':
      return rule.copyWith(route: value);
    case 'hops':
      return rule.copyWith(hops: value);
    case 'len':
      return rule.copyWith(len: value);
    case 'snr':
      return rule.copyWith(snr: value);
    case 'path':
      return rule.copyWith(path: value);
    case 'hsize':
      return rule.copyWith(
          hsize: value.split(',').map(int.tryParse).whereType<int>().toList());
    case 'chan':
      return rule.copyWith(channels: value.split(','));
    case 'chanhash':
      return rule.copyWith(chanhash: value);
    case 'region':
      return rule.copyWith(regions: value.split(','));
    case 'sender':
      return rule.copyWith(sender: value);
    case 'text':
      return rule.copyWith(text: value);
    case 'prob':
      return rule.copyWith(prob: int.tryParse(value));
    case 'throttle':
      return rule.copyWith(throttle: int.tryParse(value));
    case 'hits':
      return rule.copyWith(hits: int.tryParse(value) ?? 0);
    case 'pass':
      return rule.copyWith(pass: int.tryParse(value) ?? 0);
    case 'air':
      return rule.copyWith(air: int.tryParse(value) ?? 0);
    default:
      if (value == 'drop' || value == 'forward' || value == 'logonly') {
        return rule.copyWith(action: value == 'logonly' ? 'forward' : value);
      }
      return rule;
  }
}

/// Parse one `filter list` / `filter get` line such as
/// `2: disabled drop chan=#test sender=^bob throttle=60`.
FilterRule? parseRuleLine(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) return null;
  final index = int.tryParse(line.substring(0, colon).trim());
  if (index == null) return null;
  var rule = FilterRule(index: index);
  for (final token in tokenizeCli(line.substring(colon + 1).trim())) {
    rule = applyCondition(rule, token);
  }
  return rule;
}

class FilterRulePage {
  const FilterRulePage(this.rules, this.nextIndex);

  final List<FilterRule> rules;

  /// Index to request next, or null when the listing was complete.
  final int? nextIndex;
}

/// Parse a whole `filter list` reply. A line of only `...` means more follows.
FilterRulePage parseFilterList(String reply) {
  final rules = <FilterRule>[];
  int? next;
  for (final line in reply.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed == '...') {
      next = rules.isEmpty ? 0 : rules.last.index + 1;
      continue;
    }
    final rule = parseRuleLine(trimmed);
    if (rule != null) rules.add(rule);
  }
  return FilterRulePage(rules, next);
}

/// Export a rule set as JSON with a schema marker. No secrets are involved.
String exportFilterRules(List<FilterRule> rules) =>
    const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'rules': rules.map((r) => r.toJson()).toList(),
    });

/// Export the same rule set as the exact `filter add` commands, one per line.
String exportFilterRulesAsCommands(List<FilterRule> rules) =>
    rules.map(ruleToAddCommand).join('\n');

/// Parse and validate an imported rule set. Returns the rules in listed order.
/// Throws [ArgumentError] with a user-facing reason instead of trusting input.
List<FilterRule> importFilterRules(String text) {
  Map<String, dynamic> decoded;
  try {
    final value = jsonDecode(text);
    if (value is! Map) throw const FormatException('not an object');
    decoded = Map<String, dynamic>.from(value);
  } on FormatException {
    throw ArgumentError('Use a rule set exported as JSON.');
  }
  final schema = decoded['schema'];
  if (schema is! int || schema > 1) {
    throw ArgumentError('Unsupported rule set version.');
  }
  final raw = decoded['rules'];
  if (raw is! List || raw.isEmpty) {
    throw ArgumentError('The rule set has no rules.');
  }
  if (raw.length > 32) {
    throw ArgumentError('The firmware accepts at most 32 rules.');
  }
  final rules = <FilterRule>[];
  for (final entry in raw) {
    if (entry is! Map) throw ArgumentError('A rule was not an object.');
    final rule = FilterRule.fromJson(Map<String, dynamic>.from(entry));
    final error = _validateImportedRule(rule);
    if (error != null) throw ArgumentError('Rule ${rule.index}: $error');
    rules.add(rule.copyWith(index: rules.length));
  }
  return rules;
}

String? _validateImportedRule(FilterRule rule) {
  if (rule.action != 'drop' && rule.action != 'forward') {
    return 'Unknown action ${rule.action}';
  }
  if ((rule.sender ?? '').isNotEmpty) {
    for (final issue in validatePattern(rule.sender!, sender: true)) {
      return issue.message;
    }
  }
  if ((rule.text ?? '').isNotEmpty) {
    for (final issue in validatePattern(rule.text!, sender: false)) {
      return issue.message;
    }
  }
  if (rule.prob != null && (rule.prob! < 1 || rule.prob! > 100)) {
    return 'Match percent must be 1 to 100';
  }
  if (rule.throttle != null && (rule.throttle! < 1 || rule.throttle! > 65535)) {
    return 'Throttle must be 1 to 65535 seconds';
  }
  return null;
}

class FilterStatus {
  const FilterStatus({
    required this.on,
    required this.rules,
    required this.maxRules,
    required this.channels,
    required this.maxChannels,
    required this.ratelimitHours,
    required this.cacheUsed,
    required this.maxCache,
    required this.limiterDrops,
    required this.regexAborts,
  });

  final bool on;
  final int rules;
  final int maxRules;
  final int channels;
  final int maxChannels;
  final int ratelimitHours;
  final int cacheUsed;
  final int maxCache;
  final int limiterDrops;
  final int regexAborts;

  static FilterStatus? parse(String reply) {
    final text = reply.trim().toLowerCase();
    if (!text.contains('rules ') || !text.contains('chans ')) return null;
    int after(String key) {
      final m = RegExp('$key\\s+(\\d+)').firstMatch(text);
      return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
    }

    final ruleParts = RegExp(r'rules\s+(\d+)/(\d+)').firstMatch(text);
    final chanParts = RegExp(r'chans\s+(\d+)/(\d+)').firstMatch(text);
    final cacheParts = RegExp(r'cache\s+(\d+)/(\d+)').firstMatch(text);
    return FilterStatus(
      on: text.startsWith('on'),
      rules: ruleParts == null ? 0 : int.tryParse(ruleParts.group(1)!) ?? 0,
      maxRules:
          ruleParts == null ? 32 : int.tryParse(ruleParts.group(2)!) ?? 32,
      channels: chanParts == null ? 0 : int.tryParse(chanParts.group(1)!) ?? 0,
      maxChannels:
          chanParts == null ? 32 : int.tryParse(chanParts.group(2)!) ?? 32,
      ratelimitHours: after('advert'),
      cacheUsed:
          cacheParts == null ? 0 : int.tryParse(cacheParts.group(1)!) ?? 0,
      maxCache:
          cacheParts == null ? 512 : int.tryParse(cacheParts.group(2)!) ?? 512,
      limiterDrops: after('limiter'),
      regexAborts: after('aborted'),
    );
  }
}

class FilterStats {
  const FilterStats(
      this.hits, this.limiterDrops, this.regexAborts, this.airtimeSaved);

  final Map<int, int> hits;
  final int limiterDrops;
  final int regexAborts;
  final int airtimeSaved;

  static FilterStats? parse(String reply) {
    final text = reply.trim().toLowerCase();
    if (!text.contains('limiter') && !text.contains('abort')) return null;
    int after(String key) {
      final m = RegExp('$key\\s+(\\d+)').firstMatch(text);
      return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
    }

    final hits = <int, int>{};
    for (final line in reply.split('\n')) {
      final m = RegExp(r'^\s*(\d+):.*hits=(\d+)').firstMatch(line);
      if (m != null) hits[int.parse(m.group(1)!)] = int.parse(m.group(2)!);
    }
    return FilterStats(
        hits, after('limiter'), after('aborted'), after('saved air'));
  }
}
