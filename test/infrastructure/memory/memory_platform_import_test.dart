import 'dart:io';

import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart'
    show JsonlFilesystemStreamStorage;
import 'package:domovoy/infrastructure/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('memory storage factory uses conditional native and web adapters', () {
    final factory = File(
      'lib/infrastructure/memory/jsonl/jsonl_memory_storage_factory.dart',
    ).readAsStringSync();
    final io = File(
      'lib/infrastructure/memory/jsonl/jsonl_memory_storage_factory_io.dart',
    ).readAsStringSync();
    final web = File(
      'lib/infrastructure/memory/jsonl/jsonl_memory_storage_factory_web.dart',
    ).readAsStringSync();
    final unsupported = File(
      'lib/infrastructure/memory/jsonl/jsonl_memory_storage_factory_unsupported.dart',
    ).readAsStringSync();

    expect(factory, contains('if (dart.library.io)'));
    expect(factory, contains('if (dart.library.js_interop)'));
    expect(io, contains('JsonlFilesystemStreamStorage'));
    expect(io, contains('memory-jsonl-v1'));
    expect(web, contains('JsonlBrowserStreamStorage'));
    expect(web, contains('ru.kotdath.domovoy.memory-jsonl-v1'));
    expect(unsupported, contains('UnsupportedError'));
  });

  test('memory namespace is independent from agent and project streams', () {
    expect(
      'memory-jsonl-v1',
      isNot(JsonlFilesystemStreamStorage.storageDirectoryName),
    );
    expect(
      'memory-jsonl-v1',
      isNot(JsonlFilesystemStreamStorage.projectStorageDirectoryName),
    );

    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final storage = createPlatformMemoryJsonlStreamStorage();
      expect(storage, isA<JsonlFilesystemStreamStorage>());
      expect(
        (storage as JsonlFilesystemStreamStorage).namespaceDirectoryName,
        'memory-jsonl-v1',
      );
    }
  });

  test('memory infrastructure contains no test doubles', () {
    final files = Directory('lib/infrastructure/memory')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('Fake')), reason: file.path);
    }
  });
}
