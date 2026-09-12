import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conditional storage sources keep platform imports isolated', () {
    final coreSources = Directory('lib/core/agents')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in coreSources) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains("import 'dart:io'")), reason: file.path);
      expect(source, isNot(contains('shared_preferences')), reason: file.path);
      expect(source, isNot(contains('path_provider')), reason: file.path);
    }

    final shared = File(
      'lib/infrastructure/agents/jsonl/jsonl_stream_storage_factory.dart',
    ).readAsStringSync();
    final native = File(
      'lib/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart',
    ).readAsStringSync();
    final browser = File(
      'lib/infrastructure/agents/jsonl/jsonl_stream_storage_web.dart',
    ).readAsStringSync();
    final barrel = File(
      'lib/infrastructure/agents/jsonl/jsonl.dart',
    ).readAsStringSync();

    expect(shared, contains('if (dart.library.io)'));
    expect(shared, contains('if (dart.library.js_interop)'));
    expect(shared, isNot(contains("import 'dart:io'")));
    expect(shared, isNot(contains('shared_preferences')));
    expect(native, contains("import 'dart:io'"));
    expect(native, isNot(contains('shared_preferences')));
    expect(browser, contains('shared_preferences'));
    expect(browser, isNot(contains("import 'dart:io'")));
    expect(barrel, isNot(contains("export 'jsonl_stream_storage_io.dart'")));
    expect(barrel, isNot(contains("export 'jsonl_stream_storage_web.dart'")));
  });
}
