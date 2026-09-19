import 'dart:io';

import 'package:domovoy/infrastructure/projects/platform_projects.dart';
import 'package:domovoy/infrastructure/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('project core stays free of dart:io and grant payloads', () {
    final files = Directory('lib/core/projects')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains("import 'dart:io'")), reason: file.path);
      expect(source, isNot(contains('path_provider')), reason: file.path);
    }
  });

  test('web factory does not export native Project storage', () {
    final factory = File(
      'lib/infrastructure/projects/jsonl/jsonl_project_storage_factory.dart',
    ).readAsStringSync();
    final web = File(
      'lib/infrastructure/projects/jsonl/jsonl_project_storage_factory_web.dart',
    ).readAsStringSync();
    expect(factory, contains('if (dart.library.io)'));
    expect(factory, contains('if (dart.library.js_interop)'));
    expect(web, contains('=> null'));
  });

  test('native production composition contains no test doubles', () {
    final source = File(
      'lib/infrastructure/projects/platform_projects_io.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('FakeDesktopFilesystem')));
    expect(source, isNot(contains('ScriptedProjectDirectoryPicker')));
    expect(source, isNot(contains('InMemoryProjectDirectoryGrantStore')));
    expect(source, isNot(contains('FakeMacosSecurityScopeBroker')));
    expect(source, isNot(contains('FakeMobileSandbox')));
    expect(source, contains('IoMobileProjectSandbox'));

    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final stack = createPlatformProjectStack();
      final provisioner = stack.provisioner;
      expect(provisioner, isA<DesktopProjectRootProvisioner>());
      final desktop = provisioner as DesktopProjectRootProvisioner;
      expect(desktop.filesystem, isA<IoDesktopFilesystem>());
      expect(desktop.picker, isA<NativeProjectDirectoryPicker>());
      expect(stack.grants, isA<FileProjectDirectoryGrantStore>());
    }
  });

  test('macOS production channel implements durable security scope', () {
    final source = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();
    expect(source, contains('project_security_scope'));
    expect(source, contains('.withSecurityScope'));
    expect(source, contains('startAccessingSecurityScopedResource'));
    expect(source, contains('bookmarkDataIsStale'));
  });
}
