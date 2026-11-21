// Translate common PCRE into the fork's smaller dialect. Every lossy change
// is reported so the editor can show it before anything is sent.

import 'dialect.dart';

class Translation {
  const Translation(this.result, this.warnings, this.supported);

  final String result;
  final List<String> warnings;
  final bool supported;

  bool get changed => warnings.isNotEmpty;
}

Translation translateRegex(String input) {
  final warnings = <String>[];
  var out = input;
  var supported = true;

  // Constructs the dialect cannot express at all.
  if (RegExp(r'\(\?:|\(\?=|\(\?!|\(\?i|\(\?P|\\\\[1-9]').hasMatch(out)) {
    warnings.add('Groups, lookaround, flags and backreferences are not '
        'supported. Rewrite the pattern by hand.');
    supported = false;
  }

  // \b has no exact translation; offer intent-based rewrites.
  if (out.contains(r'\b')) {
    warnings.add(r'Word boundaries are not supported. Try ^, $, \s or \w '
        'based on what you want to match.');
    supported = false;
  }

  // The firmware reads \n and \t as the literal letters, so map them to its
  // whitespace class and say so.
  if (out.contains(r'\n') || out.contains(r'\t')) {
    out = out.replaceAll(RegExp(r'\\[nt]'), r'\s');
    warnings.add('\\n and \\t match the literal letters on the repeater; '
        'they were changed to \\s (any whitespace).');
  }

  // Lazy quantifiers are not a thing here; greedy is the only behaviour.
  final beforeLazy = out;
  out = out.replaceAllMapped(RegExp(r'([.*+])\?'), (m) => m.group(1)!);
  if (out != beforeLazy) {
    warnings.add('Lazy quantifiers are not supported; the translated pattern '
        'matches greedily.');
  }

  // Bounded repetition expands into literals and optional literals.
  out = out.replaceAllMapped(
    RegExp(r'(.)\{(\d+)(?:,(\d*))?\}'),
    (m) {
      final char = m.group(1)!;
      final min = int.tryParse(m.group(2) ?? '') ?? 0;
      final maxText = m.group(3);
      if (maxText == null) return char * min; // {n}
      final max = maxText.isEmpty ? null : int.tryParse(maxText);
      if (max == null) return '${char * min}+'; // {n,}
      final bounded = max < min ? min : max;
      final fixed = char * min;
      final optional = List.generate(bounded - min, (_) => '$char?').join();
      return '$fixed$optional';
    },
  );
  if (out.contains('{')) {
    warnings.add('Bounded quantifiers were expanded; check the result.');
    out = out.replaceAllMapped(RegExp(r'[{}]'), (m) => '\\${m.group(0)}');
  }

  // A whole-pattern group with alternatives becomes top-level alternatives;
  // anchors are copied to every branch because they bind per alternative.
  final whole = RegExp(r'^(\^?)\(([^()]+)\)(\$?)$').firstMatch(out);
  if (whole != null && whole.group(2)!.contains('|')) {
    final prefix = whole.group(1)!;
    final suffix = whole.group(3)!;
    out = whole
        .group(2)!
        .split('|')
        .map((part) => '$prefix$part$suffix')
        .join('|');
    warnings.add('Groups were split into top-level alternatives; anchors '
        'were copied to each branch.');
  } else if (whole != null) {
    out = '${whole.group(1)}${whole.group(2)}${whole.group(3)}';
    warnings.add('Parentheses around a single value were removed; they are '
        'ordinary characters on the repeater.');
  }

  // Any remaining pipe inside parentheses cannot be represented.
  if (out.contains('(') || out.contains(')')) {
    warnings.add('Parentheses are literal characters in this dialect. Move '
        'alternatives to the top level.');
    out = out.replaceAllMapped(RegExp(r'[()]'), (m) => '\\${m.group(0)}');
  }

  final alts = splitAlternatives(out);
  if (alts != null && alts.length > FilterLimits.maxAlternatives) {
    warnings.add('More than ${FilterLimits.maxAlternatives} alternatives. '
        'Split the rule into two rules.');
    supported = false;
  }

  return Translation(out, warnings, supported);
}
