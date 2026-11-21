// Dart mirror of the fork's PatternMatch / TinyRegex dialect. The firmware is
// the authority; these helpers validate what `filter add` would accept and
// give an advisory dry run. No firmware source is changed here.

/// Add-time limits from PacketFilterConfig.h.
class FilterLimits {
  static const senderPatternBytes = 32; // includes the NUL terminator
  static const textPatternBytes = 64;
  static const maxAlternatives = 8;
  static const maxRegexSymbols = 30; // TinyRegex MAX_REGEXP_OBJECTS
  static const maxClassChars = 40; // TinyRegex MAX_CHAR_CLASS_LEN
  static const defaultStepBudget = 5000;
}

class PatternIssue {
  const PatternIssue(this.message, {this.fixable = true});

  final String message;
  final bool fixable;
}

/// Split on top-level `|`. Escapes and `[...]` classes hold literal pipes.
/// Returns null when a `[` is never closed.
List<String>? splitAlternatives(String pattern) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var inClass = false;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == r'\') {
      buffer.write(c);
      if (i + 1 < pattern.length) buffer.write(pattern[++i]);
      continue;
    }
    if (inClass) {
      buffer.write(c);
      if (c == ']') inClass = false;
      continue;
    }
    if (c == '[') {
      inClass = true;
      buffer.write(c);
      continue;
    }
    if (c == '|') {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(c);
  }
  if (inClass) return null;
  parts.add(buffer.toString());
  return parts;
}

/// The structural checks `patternValid()` performs, plus the engine's own
/// size limits. Returns a list of rejections; empty means the firmware's
/// `filter add` would accept the pattern.
List<PatternIssue> validatePattern(String pattern, {required bool sender}) {
  final issues = <PatternIssue>[];
  final maxBytes =
      sender ? FilterLimits.senderPatternBytes : FilterLimits.textPatternBytes;
  if (pattern.length >= maxBytes) {
    issues.add(PatternIssue('Too long: at most ${maxBytes - 1} characters.',
        fixable: false));
  }
  final alts = splitAlternatives(pattern);
  if (alts == null) {
    issues.add(const PatternIssue('Unclosed character class.'));
    return issues;
  }
  if (alts.length > FilterLimits.maxAlternatives) {
    issues.add(PatternIssue(
        'Too many alternatives (max ${FilterLimits.maxAlternatives}).',
        fixable: false));
  }
  for (final alt in alts) {
    if (alt.isEmpty) {
      issues
          .add(const PatternIssue('An empty alternative matches everything.'));
      continue;
    }
    final symbols = _symbolCount(alt);
    if (symbols == null) {
      issues.add(const PatternIssue('Trailing backslash or unclosed class.'));
    } else if (symbols > FilterLimits.maxRegexSymbols) {
      issues.add(PatternIssue(
          'Too many regex symbols (max ${FilterLimits.maxRegexSymbols}).'));
    }
  }
  return issues;
}

/// Count TinyRegex symbols, mirroring re_compile's rejections.
int? _symbolCount(String alt) {
  var count = 0;
  var i = 0;
  while (i < alt.length) {
    final c = alt[i];
    if (c == r'\') {
      if (i + 1 >= alt.length) return null;
      i += 2;
    } else if (c == '[') {
      var classLen = 0;
      i++;
      if (i < alt.length && alt[i] == '^') i++;
      if (i >= alt.length) return null;
      var closed = false;
      while (i < alt.length) {
        if (alt[i] == ']') {
          closed = true;
          i++;
          break;
        }
        if (alt[i] == r'\') {
          if (i + 1 >= alt.length) return null;
          i += 2;
        } else {
          i++;
        }
        classLen++;
        if (classLen > FilterLimits.maxClassChars) return null;
      }
      if (!closed) return null;
    } else {
      i++;
    }
    count++;
    if (count > FilterLimits.maxRegexSymbols) return count;
  }
  return count;
}

/// Translate one alternative into a Dart RegExp source with the same meaning
/// for the dialect's supported subset. Dialect parentheses and `\n`/`\t` are
/// literals, unlike in PCRE.
String toDartAlternative(String alt) {
  final out = StringBuffer();
  var i = 0;
  while (i < alt.length) {
    final c = alt[i];
    if (c == r'\') {
      if (i + 1 >= alt.length) {
        out.write(r'\\');
        break;
      }
      final next = alt[i + 1];
      if ('sSwWdD'.contains(next)) {
        out.write('\\$next');
      } else if (next == 'n' || next == 't') {
        // The firmware treats \n and \t as the literal letters.
        out.write(next);
      } else {
        out.write(RegExp.escape(next));
      }
      i += 2;
      continue;
    }
    if (c == '[') {
      final end = alt.indexOf(']', i + 1);
      if (end < 0) {
        out.write(RegExp.escape(c));
        i++;
        continue;
      }
      out.write(alt.substring(i, end + 1));
      i = end + 1;
      continue;
    }
    if (r'.^$*+?'.contains(c)) {
      out.write(c);
    } else {
      // '(' ')' '{' '}' and '|' are ordinary characters in this dialect.
      out.write(RegExp.escape(c));
    }
    i++;
  }
  return out.toString();
}

class DryRunResult {
  const DryRunResult(this.matched, this.aborted);

  final bool matched;
  final bool aborted;
}

/// Advisory evaluation: first matching alternative wins, like the firmware.
/// A pattern whose estimated backtracking cost exceeds the step budget is
/// reported as aborted (the firmware fails open in that case).
DryRunResult dryRun(String pattern, String subject) {
  final alts = splitAlternatives(pattern) ?? const <String>[];
  final cost = estimateStepCost(pattern);
  if (cost > FilterLimits.defaultStepBudget) {
    return const DryRunResult(false, true);
  }
  for (final alt in alts) {
    if (alt.isEmpty) continue; // skipped at evaluation time
    final source = toDartAlternative(alt);
    try {
      if (RegExp(source).hasMatch(subject)) {
        return DryRunResult(true, false);
      }
    } on FormatException {
      continue; // broken branch: firmware skips it too
    }
  }
  return const DryRunResult(false, false);
}

/// Rough upper bound on backtracking steps. Nested repetition such as `.*.*`
/// can exhaust the firmware budget and fail open; this flags it for the UI.
int estimateStepCost(String pattern) {
  var quantifiers = 0;
  var nested = 0;
  var previousWasQuantifier = false;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '*' || c == '+') {
      quantifiers++;
      if (previousWasQuantifier) nested++;
      previousWasQuantifier = true;
    } else if (c == '?') {
      previousWasQuantifier = true;
    } else {
      previousWasQuantifier = false;
    }
  }
  // Each extra quantifier multiplies the search space. A repeated `.*` or
  // `.+` in particular can exhaust the firmware's step budget and fail open.
  final dotRepetition = pattern.contains('.*') || pattern.contains('.+');
  final exponent = quantifiers * 4 + nested * 4 + (dotRepetition ? 8 : 0);
  return 1 << exponent.clamp(0, 30);
}
