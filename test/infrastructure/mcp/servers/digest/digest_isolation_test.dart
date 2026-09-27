import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('digest server stays independent of other local servers', () {
    final files = Directory('lib/infrastructure/mcp/servers/digest')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final forbidden in <String>[
        'servers/arxiv',
        'servers/library',
        'servers/automation',
        'ArxivClient',
        'ArxivMcpServerFactory',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
    }
  });

  test('digest server owns no transport, filesystem or secret store', () {
    final files = Directory('lib/infrastructure/mcp/servers/digest')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final forbidden in <String>[
        "import 'dart:io'",
        'package:http',
        'package:flutter/',
        'flutter_secure_storage',
        'path_provider',
        'mcp_sdk_connection',
        'mcp_host_manager',
        'SecretVault',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
    }
  });

  test('digest barrel exports the composition surface for B9', () {
    final barrel = File(
      'lib/infrastructure/mcp/servers/digest/digest.dart',
    ).readAsStringSync();
    for (final module in <String>[
      'digest_failure',
      'digest_limits',
      'digest_mcp_server',
      'digest_model_pin',
      'digest_synthesizer',
    ]) {
      expect(barrel, contains("export '$module.dart';"));
    }
  });
}
