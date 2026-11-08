// lib/core must stay pure Dart so the CLI can use it: no Flutter imports.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/core has no Flutter imports', () {
    for (final f in Directory('lib/core').listSync().whereType<File>()) {
      final src = f.readAsStringSync();
      expect(src.contains("package:flutter"), isFalse, reason: f.path);
      expect(src.contains("package:dled/"), isFalse, reason: '${f.path}: use relative imports');
    }
  });
}
