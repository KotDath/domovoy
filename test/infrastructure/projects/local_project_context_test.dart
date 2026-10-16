import 'dart:convert';
import 'dart:io';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/infrastructure/projects/context/local_project_context_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory repo;
  final project = ProjectId('local-project');
  final token = CancellationSource().token;
  Future<void> git(List<String> args) async {
    final result = await Process.run('git', ['-C', repo.path, ...args]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('project-context-');
    repo = await Directory('${temp.path}/repo').create();
    await git(['init', '-b', 'feature/docs/context']);
    await git(['config', 'user.email', 'test@example.invalid']);
    await git(['config', 'user.name', 'Test']);
    await File(
      '${repo.path}/README.md',
    ).writeAsString('# Real project\nOriginal readme');
    await Directory('${repo.path}/docs/nested').create(recursive: true);
    await File(
      '${repo.path}/docs/nested/api.rst',
    ).writeAsString('Actual API documentation');
    await File('${repo.path}/docs/.env').writeAsString('NEVER INCLUDE');
    await Directory(
      '${repo.path}/assets/rag_demo/docs',
    ).create(recursive: true);
    await File(
      '${repo.path}/assets/rag_demo/docs/README.md',
    ).writeAsString('EXAMPLE COPY, NOT PROJECT DOCS');
    await Directory(
      '${repo.path}/node_modules/pkg/docs',
    ).create(recursive: true);
    await File(
      '${repo.path}/node_modules/pkg/docs/README.md',
    ).writeAsString('DEPENDENCY');
    await File(
      '${repo.path}/docs/credentials.md',
    ).writeAsString('Credential architecture documentation');
    await Directory('${repo.path}/lib').create();
    await File(
      '${repo.path}/lib/credentials.dart',
    ).writeAsString('abstract class CredentialResolver {}');
    await git([
      'add',
      'README.md',
      'docs/nested/api.rst',
      'docs/credentials.md',
      'lib/credentials.dart',
    ]);
    await git(['commit', '-m', 'docs: baseline']);
  });
  tearDown(() => temp.delete(recursive: true));
  LocalProjectContextService service() =>
      LocalProjectContextService(resolveRoot: (_) async => repo.path);

  test(
    'real documentation, paths and content revisions refresh without secret/cache/link leakage',
    () async {
      await Link(
        '${repo.path}/docs/linked.md',
      ).create('${repo.path}/README.md');
      final before = await service().scanDocumentation(project, token);
      expect(before.map((d) => d.source), [
        'README.md',
        'docs/credentials.md',
        'docs/nested/api.rst',
      ]);
      expect(before.first.sourceRevision, 'sha256:${before.first.revision}');
      await File('${repo.path}/README.md').writeAsString('Changed');
      final after = await service().scanDocumentation(project, token);
      expect(after.first.id, before.first.id);
      expect(after.first.revision, isNot(before.first.revision));
      await File('${repo.path}/docs/nested/api.rst').delete();
      expect(await service().scanDocumentation(project, token), hasLength(2));
      final cancelled = CancellationSource()..cancel();
      await expectLater(
        service().scanDocumentation(project, cancelled.token),
        throwsA(isA<RagCancelled>()),
      );
    },
  );
  test(
    'real HEAD branch with slashes, packed refs, detached and missing repository',
    () async {
      final first = await service().gitContext(project);
      expect(first.branch, 'feature/docs/context');
      expect(first.head.length, 40);
      await git(['pack-refs', '--all']);
      expect((await service().gitContext(project)).head, first.head);
      await git(['checkout', '--detach']);
      expect((await service().gitContext(project)).branch, isNull);
      await Directory('${repo.path}/.git').delete(recursive: true);
      await expectLater(service().gitContext(project), throwsFormatException);
    },
  );
  test('external gitfile and metadata symlinks fail closed', () async {
    await Directory('${repo.path}/.git').rename('${temp.path}/outside-git');
    await File('${repo.path}/.git').writeAsString('gitdir: ../outside-git');
    await expectLater(service().gitContext(project), throwsFormatException);
    await File('${repo.path}/.git').delete();
    await Link('${repo.path}/.git').create('${temp.path}/outside-git');
    await expectLater(service().gitContext(project), throwsFormatException);
  });
  test('safe internal gitfile pointer resolves genuine metadata', () async {
    await Directory('${repo.path}/.git').rename('${repo.path}/metadata');
    await File('${repo.path}/.git').writeAsString('gitdir: metadata');
    expect(
      (await service().gitContext(project)).branch,
      'feature/docs/context',
    );
  });
  test(
    'export helper produces importable genuine Git checkout; nonempty root rejects retry',
    () async {
      final archive = '${temp.path}/project.tar';
      final result = await Process.run('python3', [
        'tool/export_project.py',
        repo.path,
        archive,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final imported = await Directory('${temp.path}/imported').create();
      final importer = LocalProjectContextService(
        resolveRoot: (_) async => imported.path,
      );
      await importer.importArchive(
        project,
        await File(archive).readAsBytes(),
        token,
      );
      expect(
        (await importer.gitContext(project)).head,
        (await service().gitContext(project)).head,
      );
      expect(
        (await importer.scanDocumentation(project, token)).map((d) => d.source),
        ['README.md', 'docs/credentials.md', 'docs/nested/api.rst'],
      );
      expect(
        await File('${imported.path}/lib/credentials.dart').readAsString(),
        contains('CredentialResolver'),
      );
      final verify = await Process.run('git', [
        '-C',
        imported.path,
        'fsck',
        '--full',
      ]);
      expect(verify.exitCode, 0, reason: '${verify.stderr}');
      await expectLater(
        importer.importArchive(
          project,
          await File(archive).readAsBytes(),
          token,
        ),
        throwsStateError,
      );
    },
  );
  for (final path in [
    '../escape',
    '/absolute',
    'nested/../../escape',
    'C:/evil',
    'a\\evil',
    'a/./b',
    'dir/NUL.txt',
    'dir/name.',
  ]) {
    test('archive rejects unsafe path $path and leaves target empty', () async {
      final target = await Directory('${temp.path}/target').create();
      final importer = LocalProjectContextService(
        resolveRoot: (_) async => target.path,
      );
      await expectLater(
        importer.importArchive(project, tarEntry(path, 'payload'), token),
        throwsFormatException,
      );
      expect(await target.list().isEmpty, isTrue);
      expect(
        await temp
            .list()
            .where((f) => f.path.contains('.project-import-'))
            .isEmpty,
        isTrue,
      );
    });
  }
  test('links, size explosions and malformed checksum are rejected', () async {
    final target = await Directory('${temp.path}/target').create();
    final importer = LocalProjectContextService(
      resolveRoot: (_) async => target.path,
    );
    for (final bytes in [
      tarEntry('link', '', kind: '2'),
      tarEntry('big', '', declaredSize: 128 * 1024 * 1024),
      (tarEntry('file', 'x')..[0] = 0),
    ]) {
      await expectLater(
        importer.importArchive(project, bytes, token),
        throwsFormatException,
      );
    }
    expect(await target.list().isEmpty, isTrue);
  });
}

List<int> tarEntry(
  String name,
  String content, {
  String kind = '0',
  int? declaredSize,
}) {
  final bytes = List<int>.filled(2048, 0);
  void field(int at, String value) =>
      bytes.setRange(at, at + utf8.encode(value).length, utf8.encode(value));
  field(0, name);
  field(100, '0000644');
  field(108, '0000000');
  field(116, '0000000');
  field(
    124,
    (declaredSize ?? utf8.encode(content).length)
        .toRadixString(8)
        .padLeft(11, '0'),
  );
  field(136, '00000000000');
  field(148, '        ');
  field(156, kind);
  field(257, 'ustar');
  final sum = bytes.take(512).reduce((a, b) => a + b);
  field(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
  field(512, content);
  return bytes;
}
