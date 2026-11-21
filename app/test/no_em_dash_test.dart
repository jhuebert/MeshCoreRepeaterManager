import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UI copy uses short sentences, colons and commas. The em dash is banned in
/// every user facing string; this guard scans string literals in the shipped
/// source so a future screen cannot reintroduce one. Comments are prose and
/// are ignored, as are test descriptions in this file.
void main() {
  test('no em dash in user facing strings', () {
    final root = Directory('lib');
    final offenders = <String>[];
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      final code = _withoutComments(source);
      // _withoutComments keeps newlines and string boundaries, so line
      // numbers in the stripped text match the source file.
      for (var i = 0, line = 1; i < code.length; i++) {
        if (code.codeUnitAt(i) == 0x2014) offenders.add('${entity.path}:$line');
        if (code.codeUnitAt(i) == 0x0A) line++;
      }
    }
    expect(offenders, isEmpty,
        reason: 'em dash found in string literals: ${offenders.join(', ')}');
  });
}

/// Replace comments with spaces while preserving every string literal and all
/// newlines. Dart's `//`, `///`, `/* */` and string forms are handled; this is
/// intentionally a small scanner, not a full parser.
String _withoutComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      out.write('  ');
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        out.write(src[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i < src.length) {
        out.write('  ');
        i += 2;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      final triple = i + 2 < src.length && src[i + 1] == c && src[i + 2] == c;
      final width = triple ? 3 : 1;
      out.write(src.substring(i, i + width));
      i += width;
      while (i < src.length) {
        if (src[i] == r'\' && i + 1 < src.length) {
          out.write(src.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (triple &&
            src[i] == c &&
            i + 2 < src.length &&
            src[i + 1] == c &&
            src[i + 2] == c) {
          out.write(src.substring(i, i + 3));
          i += 3;
          break;
        }
        if (!triple && src[i] == c) {
          out.write(c);
          i++;
          break;
        }
        out.write(src[i]);
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
