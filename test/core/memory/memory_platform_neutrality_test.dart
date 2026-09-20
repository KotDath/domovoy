import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('memory core stays platform-neutral and free of test doubles', () {
    final files = Directory('lib/core/memory')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains("import 'dart:io'")), reason: file.path);
      expect(source, isNot(contains("import 'dart:ui'")), reason: file.path);
      expect(source, isNot(contains('path_provider')), reason: file.path);
      expect(source, isNot(contains('package:flutter/')), reason: file.path);
      expect(source, isNot(contains('Fake')), reason: file.path);
    }
  });

  test('memory barrel exports the full domain surface', () {
    final barrel = File('lib/core/memory/memory.dart').readAsStringSync();
    for (final module in <String>[
      'candidate',
      'context',
      'enums',
      'entry',
      'errors',
      'ids',
      'repository',
      'service',
      'validation',
    ]) {
      expect(barrel, contains("export '$module.dart';"));
    }
  });
}
