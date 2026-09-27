import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final files = Directory('lib/infrastructure/mcp/servers/library')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('library server stays independent of other local servers', () {
    expect(files, isNotEmpty);
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final forbidden in <String>[
        'servers/arxiv',
        'servers/digest',
        'servers/automation',
        'ArxivMcpServerFactory',
        'DigestMcpServerFactory',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
    }
  });

  test('library server owns no transport, HTTP client or secret store', () {
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final forbidden in <String>[
        "import 'dart:io'",
        'package:http',
        'package:flutter/',
        'flutter_secure_storage',
        'mcp_sdk_connection',
        'mcp_host_manager',
        'SecretVault',
        'Directory(',
        'File(',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
      if (!file.path.endsWith('library_storage_factory_io.dart')) {
        expect(source, isNot(contains('path_provider')), reason: file.path);
      }
    }
  });

  test('library barrel exports the composition surface for B9', () {
    final barrel = File(
      'lib/infrastructure/mcp/servers/library/library.dart',
    ).readAsStringSync();
    for (final module in <String>[
      'library_envelope',
      'library_failure',
      'library_jsonl_store',
      'library_limits',
      'library_mcp_server',
      'library_replay',
      'library_storage_factory',
      'library_storage_namespace',
    ]) {
      expect(barrel, contains("export '$module.dart';"));
    }
  });
}
