import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/infrastructure/projects/context/local_project_context_io.dart';
import 'package:domovoy/infrastructure/projects/context/host_git_object_verifier_io.dart';
import 'package:domovoy/infrastructure/projects/context/portable_file_mode_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory repo;
  final project = ProjectId('local-project');
  final token = CancellationSource().token;
  Future<String> git(List<String> args) async {
    final result = await Process.run('git', ['-C', repo.path, ...args]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return '${result.stdout}'.trim();
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
    await Directory('${repo.path}/scripts').create();
    await File(
      '${repo.path}/scripts/build',
    ).writeAsString('#!/bin/sh\necho build');
    applyPortableFileMode('${repo.path}/scripts/build', executable: true);
    await git([
      'add',
      'README.md',
      'docs/nested/api.rst',
      'docs/credentials.md',
      'lib/credentials.dart',
      'scripts/build',
    ]);
    await git(['commit', '-m', 'docs: baseline']);
  });
  tearDown(() => temp.delete(recursive: true));
  LocalProjectContextService service() =>
      LocalProjectContextService(resolveRoot: (_) async => repo.path);
  LocalProjectContextService desktop({
    HostGitObjectVerifier verifier = const HostGitObjectVerifier(),
  }) => LocalProjectContextService(
    resolveRoot: (_) async => repo.path,
    selectGitVerifier: (_) async => verifier,
  );

  test(
    'direct desktop root preserves actual packed branch and current files',
    () async {
      final first = await desktop().gitContext(project);
      await git(['gc', '--prune=now']);
      expect((await desktop().gitContext(project)).head, first.head);
      await File(
        '${repo.path}/README.md',
      ).writeAsString('CURRENT DIRTY README');
      final beforeStatus = await git(['status', '--porcelain']);
      final packed = await desktop().gitContext(project);
      expect(packed.branch, 'feature/docs/context');
      expect(packed.head, await git(['rev-parse', 'HEAD']));
      expect(
        (await desktop().scanDocumentation(project, token)).first.text,
        'CURRENT DIRTY README',
      );
      expect(await git(['status', '--porcelain']), beforeStatus);
      await git(['switch', '-c', 'feature/current/branch']);
      expect(
        (await desktop().gitContext(project)).branch,
        'feature/current/branch',
      );
      await git(['checkout', '--detach']);
      expect((await desktop().gitContext(project)).branch, isNull);
      expect(await git(['status', '--porcelain']), beforeStatus);
    },
  );

  test(
    'ordinary packed clone works without export or metadata mutation',
    () async {
      final sourceHead = await git(['rev-parse', 'HEAD']);
      final cloned = '${temp.path}/ordinary-clone';
      final result = await Process.run('git', [
        'clone',
        '--no-local',
        repo.path,
        cloned,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        await Directory('$cloned/.git/objects/pack').list().isEmpty,
        isFalse,
      );
      repo = Directory(cloned);
      expect((await desktop().gitContext(project)).head, sourceHead);
      expect(
        (await desktop().gitContext(project)).branch,
        'feature/docs/context',
      );
      expect(await git(['status', '--porcelain']), isEmpty);
    },
  );

  test(
    'desktop rejects external ODB links and verification config includes',
    () async {
      await git(['config', 'include.path', '${temp.path}/outside-config']);
      await expectLater(desktop().gitContext(project), throwsFormatException);
      await git(['config', '--unset', 'include.path']);
      final config = File('${repo.path}/.git/config');
      final original = await config.readAsString();
      await config.writeAsString(
        '\ufeff[include]\npath = ${temp.path}/outside-config\n',
      );
      await expectLater(desktop().gitContext(project), throwsFormatException);
      await config.writeAsString(original);
      final alternate = File('${repo.path}/.git/objects/info/alternates');
      await alternate.parent.create(recursive: true);
      await alternate.writeAsString('${temp.path}/outside-objects');
      await expectLater(desktop().gitContext(project), throwsFormatException);
      await alternate.delete();
      await Link('${repo.path}/.git/objects/outside').create(temp.path);
      await expectLater(desktop().gitContext(project), throwsFormatException);
    },
  );

  test('desktop subprocess time and output are bounded', () async {
    await expectLater(
      desktop(
        verifier: const HostGitObjectVerifier(maxOutputBytes: 0),
      ).gitContext(project),
      throwsFormatException,
    );
    await expectLater(
      desktop(
        verifier: const HostGitObjectVerifier(timeout: Duration.zero),
      ).gitContext(project),
      throwsFormatException,
    );
  });

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
      await git(['gc', '--prune=now']);
      final sourceHead = await git(['rev-parse', 'HEAD']);
      // Native archive capability deliberately requires portable loose objects;
      // direct desktop roots use the injected real host verifier tested above.
      await expectLater(service().gitContext(project), throwsFormatException);
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
      expect((await importer.gitContext(project)).head, sourceHead);
      expect(
        (await importer.scanDocumentation(project, token)).map((d) => d.source),
        ['README.md', 'docs/credentials.md', 'docs/nested/api.rst'],
      );
      expect(
        await File('${imported.path}/lib/credentials.dart').readAsString(),
        contains('CredentialResolver'),
      );
      expect(
        await File('${imported.path}/scripts/build').readAsString(),
        contains('echo build'),
      );
      expect(
        (await File('${imported.path}/scripts/build').stat()).mode & 0x49,
        0x49,
      );
      final executed = await Process.run('${imported.path}/scripts/build', []);
      expect(executed.exitCode, 0);
      expect('${executed.stdout}'.trim(), 'build');
      final status = await Process.run('git', [
        '-C',
        imported.path,
        'status',
        '--porcelain',
        '--untracked-files=no',
      ]);
      expect(status.exitCode, 0);
      expect('${status.stdout}', isEmpty);
      expect(
        await Directory('${imported.path}/.git/objects/pack').exists(),
        isFalse,
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
  for (final secretPath in [
    '.env',
    'config/.env.production',
    'config/private.pem',
    'config/private.key',
    'credentials.json',
    'service-account.json',
    'store.jks',
    'store.keystore',
    'id_ed25519',
    '.netrc',
    '_netrc',
    '.git-credentials',
    '.npmrc',
    '.pypirc',
    '.pgpass',
    '.my.cnf',
    '.aws/credentials',
    '.docker/config.json',
    '.kube/config',
    '.config/gh/hosts.yml',
    '.azure/msal_token_cache.json',
  ]) {
    test(
      'export refuses tracked sensitive path $secretPath without publication or contents in errors',
      () async {
        const marker = 'SYNTHETIC_TEST_SECRET_NOT_A_CREDENTIAL';
        final file = File('${repo.path}/$secretPath');
        await file.parent.create(recursive: true);
        await file.writeAsString(marker);
        await git(['add', '-f', secretPath]);
        await git(['commit', '-m', 'test: sensitive-path fixture']);
        final archive = File('${temp.path}/refused.tar');
        final result = await Process.run('python3', [
          'tool/export_project.py',
          repo.path,
          archive.path,
        ]);
        expect(result.exitCode, isNot(0));
        expect('${result.stdout}${result.stderr}', contains('Export refused'));
        expect('${result.stdout}${result.stderr}', isNot(contains(marker)));
        expect(await archive.exists(), isFalse);
        expect(
          await File('${temp.path}/refused.provenance.json').exists(),
          isFalse,
        );
        await archive.writeAsString('preexisting archive must survive');
        final retry = await Process.run('python3', [
          'tool/export_project.py',
          repo.path,
          archive.path,
        ]);
        expect(retry.exitCode, isNot(0));
        expect(
          await archive.readAsString(),
          'preexisting archive must survive',
        );
      },
    );
  }
  for (final kind in ['symlink', 'dangling-symlink', 'regular']) {
    test(
      'provenance $kind collision refuses export without touching host data',
      () async {
        final outside = File('${temp.path}/outside.txt');
        if (kind != 'dangling-symlink') {
          await outside.writeAsString('HOST SENTINEL');
        }
        final path = '${repo.path}/PROJECT_PROVENANCE.json';
        if (kind == 'regular') {
          await File(path).writeAsString('PROJECT OWNED JSON');
        } else {
          await Link(path).create(outside.path);
        }
        await git(['add', 'PROJECT_PROVENANCE.json']);
        await git(['commit', '-m', 'test: provenance collision']);
        final archive = File('${temp.path}/collision.tar');
        final result = await Process.run('python3', [
          'tool/export_project.py',
          repo.path,
          archive.path,
        ]);
        expect(result.exitCode, isNot(0));
        expect(await archive.exists(), isFalse);
        expect(
          await File('${temp.path}/collision.provenance.json').exists(),
          isFalse,
        );
        if (kind == 'dangling-symlink') {
          expect(await outside.exists(), isFalse);
        } else {
          expect(await outside.readAsString(), 'HOST SENTINEL');
        }
        if (kind == 'regular') {
          expect(await File(path).readAsString(), 'PROJECT OWNED JSON');
        }
        expect(
          await git(['status', '--porcelain', '--untracked-files=no']),
          isEmpty,
        );
        await archive.writeAsString('EXISTING OUTPUT');
        final retry = await Process.run('python3', [
          'tool/export_project.py',
          repo.path,
          archive.path,
        ]);
        expect(retry.exitCode, isNot(0));
        expect(await archive.readAsString(), 'EXISTING OUTPUT');
      },
    );
  }
  for (final detached in [false, true]) {
    test(
      'exact zero-object Git fixture is rejected (${detached ? 'detached' : 'branch'})',
      () async {
        final target = await Directory('${temp.path}/zero-target').create();
        const oid = '0123456789012345678901234567890123456789';
        final files = <String, List<int>>{
          'README.md': utf8.encode('Synthetic zero-ODB fixture'),
          '.git/objects/': [],
          '.git/config': utf8.encode(
            '[core]\nrepositoryformatversion = 0\nbare = false\n',
          ),
          '.git/HEAD': utf8.encode(detached ? oid : 'ref: refs/heads/invented'),
          '.git/refs/heads/invented': utf8.encode(oid),
        };
        final importer = LocalProjectContextService(
          resolveRoot: (_) async => target.path,
          selectGitVerifier: (_) async =>
              throw StateError('Import must never use desktop capability'),
        );
        await expectLater(
          importer.importArchive(project, tarFiles(files), token),
          throwsFormatException,
        );
        expect(await target.list().isEmpty, isTrue);
      },
    );
  }
  for (final fault in [
    'missing-commit',
    'missing-tree',
    'missing-blob',
    'missing-parent',
    'corrupt-blob',
    'wrong-type',
    'wrong-size',
    'bomb',
  ]) {
    test('import rejects $fault before publishing the project', () async {
      final target = await Directory('${temp.path}/invalid-target').create();
      final importer = LocalProjectContextService(
        resolveRoot: (_) async => target.path,
      );
      await expectLater(
        importer.importArchive(project, gitArchiveFixture(fault), token),
        throwsFormatException,
      );
      expect(await target.list().isEmpty, isTrue);
    });
  }
  test(
    'Git context revalidates referenced object contents after import',
    () async {
      final target = await Directory('${temp.path}/verified-target').create();
      final importer = LocalProjectContextService(
        resolveRoot: (_) async => target.path,
      );
      final shallowTarget = await Directory(
        '${temp.path}/shallow-target',
      ).create();
      final shallowImporter = LocalProjectContextService(
        resolveRoot: (_) async => shallowTarget.path,
      );
      await shallowImporter.importArchive(
        project,
        gitArchiveFixture('shallow-parent'),
        token,
      );
      expect(
        (await shallowImporter.gitContext(project)).branch,
        'real-fixture',
      );
      await importer.importArchive(project, gitArchiveFixture(null), token);
      final context = await importer.gitContext(project);
      final object = File(
        '${target.path}/.git/objects/${context.head.substring(0, 2)}/${context.head.substring(2)}',
      );
      await object.writeAsBytes(
        ZLibEncoder().convert(utf8.encode('blob 0\u0000')),
      );
      await expectLater(importer.gitContext(project), throwsFormatException);
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
  return tarData(
    name,
    utf8.encode(content),
    kind: kind,
    declaredSize: declaredSize,
  );
}

List<int> tarData(
  String name,
  List<int> content, {
  String kind = '0',
  int? declaredSize,
}) {
  final bytes = List<int>.filled(
    512 + ((content.length + 511) ~/ 512) * 512 + 1024,
    0,
  );
  void field(int at, String value) =>
      bytes.setRange(at, at + utf8.encode(value).length, utf8.encode(value));
  field(0, name);
  field(100, '0000644');
  field(108, '0000000');
  field(116, '0000000');
  field(
    124,
    (declaredSize ?? content.length).toRadixString(8).padLeft(11, '0'),
  );
  field(136, '00000000000');
  field(148, '        ');
  field(156, kind);
  field(257, 'ustar');
  final sum = bytes.take(512).reduce((a, b) => a + b);
  field(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
  bytes.setRange(512, 512 + content.length, content);
  return bytes;
}

List<int> tarFiles(Map<String, List<int>> files) => [
  for (final entry in files.entries)
    ...(() {
      final encoded = tarData(
        entry.key,
        entry.value,
        kind: entry.key.endsWith('/') ? '5' : '0',
      );
      return encoded.sublist(0, encoded.length - 1024);
    })(),
  ...List<int>.filled(1024, 0),
];

List<int> gitArchiveFixture(String? fault) {
  final objects = <String, List<int>>{};
  String object(String type, List<int> payload, {int? declaredSize}) {
    final raw = [
      ...utf8.encode('$type ${declaredSize ?? payload.length}\u0000'),
      ...payload,
    ];
    final oid = sha1.convert(raw).toString();
    objects['.git/objects/${oid.substring(0, 2)}/${oid.substring(2)}'] =
        ZLibEncoder().convert(raw);
    return oid;
  }

  final payload = fault == 'bomb'
      ? List<int>.filled(32 * 1024 * 1024 + 1024, 65)
      : utf8.encode('Actual fixture content');
  final blob = object(
    fault == 'wrong-type' ? 'tree' : 'blob',
    payload,
    declaredSize: fault == 'wrong-size' ? 123456 : null,
  );
  List<int> binaryOid(String oid) => [
    for (var i = 0; i < oid.length; i += 2)
      int.parse(oid.substring(i, i + 2), radix: 16),
  ];
  final tree = object('tree', [
    ...utf8.encode('100644 README.md\u0000'),
    ...binaryOid(blob),
  ]);
  final commit = object(
    'commit',
    utf8.encode(
      'tree $tree\n${{'missing-parent', 'shallow-parent'}.contains(fault) ? 'parent 0123456789012345678901234567890123456789\n' : ''}author Test <test@example.invalid> 1 +0000\ncommitter Test <test@example.invalid> 1 +0000\n\nSynthetic test commit\n',
    ),
  );
  if (fault?.startsWith('missing-') == true) {
    final oid = fault == 'missing-commit'
        ? commit
        : fault == 'missing-tree'
        ? tree
        : blob;
    objects.remove('.git/objects/${oid.substring(0, 2)}/${oid.substring(2)}');
  }
  if (fault == 'corrupt-blob') {
    objects['.git/objects/${blob.substring(0, 2)}/${blob.substring(2)}'] =
        ZLibEncoder().convert(utf8.encode('blob 7\u0000corrupt'));
  }
  return tarFiles({
    'README.md': utf8.encode('Actual fixture content'),
    '.git/objects/': [],
    '.git/config': utf8.encode(
      '[core]\nrepositoryformatversion = 0\nbare = false\n',
    ),
    '.git/HEAD': utf8.encode('ref: refs/heads/real-fixture'),
    '.git/refs/heads/real-fixture': utf8.encode(commit),
    if (fault == 'shallow-parent') '.git/shallow': utf8.encode('$commit\n'),
    ...objects,
  });
}
