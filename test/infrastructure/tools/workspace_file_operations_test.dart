import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/infrastructure/projects/context/portable_file_mode_io.dart';
import 'package:domovoy/infrastructure/tools/local_workspace_executor_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory root;
  late LocalWorkspaceToolExecutor executor;
  late CancellationSource cancellation;
  final project = ProjectId('files');
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('domovoy-file-operations-');
    root = await Directory('${temp.path}/project').create();
    executor = LocalWorkspaceToolExecutor(resolveRoot: (_) async => root.path);
    cancellation = CancellationSource();
  });
  tearDown(() => temp.delete(recursive: true));
  Future<File> save(String path, String content) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  Future<ToolExecutionResult> call(
    String name,
    Map<String, Object?> args, {
    ToolExecutionLiveness? liveness,
  }) => executor.execute(
    ToolInvocation(
      callId: 'call',
      name: name,
      arguments: args,
      projectId: project,
    ),
    cancellation: cancellation.token,
    liveness: liveness ?? _Live(),
  );
  Map<String, Object?> output(ToolExecutionResult result) {
    expect(result.success, true, reason: result.errorMessage);
    return result.output as Map<String, Object?>;
  }

  test(
    'portable discovery sorts, filters, pages and searches multiple files',
    () async {
      await save('README.md', 'Uses Token\n');
      await save('lib/a.dart', 'before\nclass Token {}\nafter\n');
      await save('lib/nested/b.dart', 'final token = Token();\n');
      await save('.gitignore', 'lib/\n');
      final listing = output(await call('ls', {'limit': 1}));
      expect((listing['entries'] as List).first, {
        'path': '.gitignore',
        'type': 'file',
      });
      expect(listing['nextOffset'], 1);
      expect(output(await call('ls', {'offset': 1, 'limit': 1}))['entries'], [
        {'path': 'README.md', 'type': 'file'},
      ]);
      final found = output(await call('find', {'pattern': '**/*.dart'}));
      expect(found['entries'], ['lib/a.dart', 'lib/nested/b.dart']);
      final first = output(
        await call('grep', {
          'pattern': 'token',
          'literal': true,
          'ignoreCase': true,
          'limit': 2,
          'context': 1,
        }),
      );
      expect((first['matches'] as List).map((e) => (e as Map)['path']), [
        'README.md',
        'lib/a.dart',
      ]);
      expect(first['nextOffset'], 2);
      final second = output(
        await call('grep', {'pattern': 'Token', 'offset': 2}),
      );
      expect((second['matches'] as List).single, {
        'path': 'lib/nested/b.dart',
        'line': 1,
        'text': 'final token = Token();',
      });
      expect(second['truncated'], false);
      expect(
        output(
          await call('find', {'path': 'lib', 'pattern': '*.dart'}),
        )['entries'],
        ['lib/a.dart', 'lib/nested/b.dart'],
      );
    },
  );

  test(
    'excludes concrete credentials and VCS but keeps ordinary source and docs',
    () async {
      for (final path in [
        '.git/config',
        '.env',
        '.env.local',
        '.aws/credentials',
        '.config/gh/hosts.yml',
        'secrets.json',
      ]) {
        await save(path, 'private token');
        expect((await call('read', {'path': path})).success, false);
        expect(
          (await call('write', {'path': path, 'content': 'replace'})).success,
          false,
        );
      }
      for (final path in [
        'lib/credentials.dart',
        'docs/secret-management.md',
      ]) {
        await save(path, 'public token');
      }
      final found = output(
        await call('grep', {'pattern': 'token', 'literal': true}),
      );
      expect((found['matches'] as List).map((e) => (e as Map)['path']), [
        'docs/secret-management.md',
        'lib/credentials.dart',
      ]);
      expect(found['skipped'], greaterThan(0));
      expect(await File('${root.path}/.env').readAsString(), 'private token');
    },
  );

  test(
    'cache directory exclusions do not hide ordinary source files with the same name',
    () async {
      await save('scripts/build', 'ordinary build source');
      await save('build/cache.txt', 'generated');
      expect(
        output(await call('read', {'path': 'scripts/build'}))['content'],
        'ordinary build source',
      );
      expect(output(await call('find', {'pattern': '*'}))['entries'], [
        'scripts/build',
      ]);
      expect((await call('ls', {'path': 'build'})).success, false);
      expect(
        (await call('write', {
          'path': 'build/other.txt',
          'content': 'bad',
        })).success,
        false,
      );
    },
  );

  test(
    'rejects path escapes, file/parent symlinks, invalid arguments and regex',
    () async {
      final outside = await File(
        '${temp.path}/outside.txt',
      ).writeAsString('intact');
      await Link('${root.path}/link').create(temp.path);
      for (final path in [
        '../outside.txt',
        '/etc/passwd',
        'a/../b',
        'a\\b',
        'link/outside.txt',
        'NUL.txt',
        'dir/COM1.log',
        'a./b',
        'a /file',
        'file?.txt',
      ]) {
        for (final tool in ['read', 'write', 'find', 'grep']) {
          expect(
            (await call(tool, {
              'path': path,
              'pattern': '*',
              'content': 'bad',
            })).success,
            false,
            reason: '$tool $path',
          );
        }
      }
      final skipped = output(await call('find', {'pattern': '*'}));
      expect(skipped['entries'], isEmpty);
      expect(skipped['warnings'], contains('Symbolic links skipped.'));
      expect(await outside.readAsString(), 'intact');
      for (final args in [
        {'pattern': r'(a+)+$'},
        {'pattern': 'a|b'},
        {'pattern': '[invalid'},
        {'pattern': 'x', 'limit': 501},
        {'pattern': 'x', 'offset': -1},
      ]) {
        expect((await call('grep', args)).success, false);
      }
      expect((await call('find', {'pattern': '{a,b}'})).success, false);
      expect((await call('ls', {'path': 'missing'})).success, false);
    },
  );

  test(
    'binary/large files skipped honestly, UTF-8 and regex line numbers work',
    () async {
      await save('small.txt', 'начало\nТокен 42\nконец');
      await save('binary.bin', 'x\u0000x');
      await save('large.txt', 'x' * (1024 * 1024 + 1));
      final matches = output(await call('grep', {'pattern': r'^Токен \d+$'}));
      expect((matches['matches'] as List).single, {
        'path': 'small.txt',
        'line': 2,
        'text': 'Токен 42',
      });
      expect(matches['skipped'], 2);
      expect(matches['warnings'], hasLength(2));
      expect(
        output(
          await call('grep', {'pattern': 'missing', 'literal': true}),
        )['matches'],
        isEmpty,
      );
    },
  );

  test(
    'real write/edit preserve unrelated bytes and Unix execute bits, exact change and no-op',
    () async {
      const original = '#!/bin/sh\r\necho old\r\n# unrelated café\r\n';
      final file = await save('run.sh', original);
      if (!Platform.isWindows) {
        applyPortablePermissionBits(file.path, 0x1e8); // 0750
      }
      final read = output(await call('read', {'path': 'run.sh'}));
      final edited = output(
        await call('edit', {
          'path': 'run.sh',
          'expectedRevision': read['revision'],
          'edits': [
            {'oldText': 'echo old', 'newText': 'echo new'},
          ],
        }),
      );
      final expected = original.replaceFirst('echo old', 'echo new');
      expect(await file.readAsString(), expected);
      expect(edited['change'], {
        'path': 'run.sh',
        'kind': 'modified',
        'before': original,
        'after': expected,
      });
      if (!Platform.isWindows) expect((await file.stat()).mode & 0x1ff, 0x1e8);
      expect(
        (output(
              await call('write', {
                'path': 'run.sh',
                'expectedContent': expected,
                'content': expected,
              }),
            )['change']
            as Map)['kind'],
        'unchanged',
      );
      final created = output(
        await call('write', {'path': 'docs/note.md', 'content': 'saved\n'}),
      );
      expect(created['change'], {
        'path': 'docs/note.md',
        'kind': 'created',
        'before': null,
        'after': 'saved\n',
      });
      expect(await File('${root.path}/docs/note.md').readAsString(), 'saved\n');
      expect(
        (await root.list(recursive: true).toList()).where(
          (f) => f.path.contains('.domovoy-save-'),
        ),
        isEmpty,
      );
    },
  );

  test('UTF-8 BOM remains in read revision and exact saved bytes', () async {
    const before = '\uFEFFalpha\r\nbeta\r\n';
    final file = await save('bom.txt', before);
    final initialBytes = await file.readAsBytes();
    final read = output(await call('read', {'path': 'bom.txt'}));
    expect((read['content'] as String).startsWith('\uFEFF'), true);
    final changed = output(
      await call('edit', {
        'path': 'bom.txt',
        'expectedRevision': read['revision'],
        'edits': [
          {'oldText': 'beta', 'newText': 'BETA'},
        ],
      }),
    );
    expect((changed['change'] as Map)['before'], before);
    expect((await file.readAsBytes()).take(3), initialBytes.take(3));
    final afterRead = output(await call('read', {'path': 'bom.txt'}));
    expect(
      (await call('write', {
        'path': 'bom.txt',
        'expectedRevision': afterRead['revision'],
        'content': '\uFEFFalpha\r\nBETA\r\n',
      })).success,
      true,
    );
    expect(await file.readAsBytes(), [
      0xef,
      0xbb,
      0xbf,
      ...'alpha\r\nBETA\r\n'.codeUnits,
    ]);
  });

  test(
    'blind overwrite, stale revision, overlaps and missing exact text cannot clobber files',
    () async {
      final file = await save('existing.txt', 'alpha beta gamma');
      final read = output(await call('read', {'path': 'existing.txt'}));
      expect(
        (await call('write', {
          'path': 'existing.txt',
          'content': 'overwrite',
        })).success,
        false,
      );
      await file.writeAsString('alpha beta gamma external');
      expect(
        (await call('write', {
          'path': 'existing.txt',
          'expectedRevision': read['revision'],
          'content': 'overwrite',
        })).success,
        false,
      );
      expect(
        (await call('edit', {
          'path': 'existing.txt',
          'expectedRevision': read['revision'],
          'edits': [
            {'oldText': 'alpha', 'newText': 'A'},
          ],
        })).success,
        false,
      );
      for (final edits in [
        [
          {'oldText': 'alpha beta', 'newText': 'A'},
          {'oldText': 'beta', 'newText': 'B'},
        ],
        [
          {'oldText': 'absent', 'newText': 'A'},
        ],
      ]) {
        expect(
          (await call('edit', {
            'path': 'existing.txt',
            'edits': edits,
          })).success,
          false,
        );
      }
      expect(await file.readAsString(), 'alpha beta gamma external');
      final current = output(await call('read', {'path': 'existing.txt'}));
      expect(
        (await call('write', {
          'path': 'existing.txt',
          'expectedRevision': current['revision'],
          'content': 'guarded',
        })).success,
        true,
      );
      expect(await file.readAsString(), 'guarded');
      expect(
        (await call('write', {
          'path': 'missing.txt',
          'expectedRevision': current['revision'],
          'content': 'bad',
        })).success,
        false,
      );
    },
  );

  test(
    'late conflict, revocation, project root change and cancellation fail before commit; prior saves persist',
    () async {
      await call('write', {'path': 'saved.md', 'content': 'prior save'});
      final file = await save('later.md', 'before');
      for (final reason in ['conflict', 'revoke', 'switch', 'cancel']) {
        await file.writeAsString('before');
        var checks = 0;
        executor = LocalWorkspaceToolExecutor(
          resolveRoot: (_) async => root.path,
          resolveWritableRoot: (_) async {
            if (++checks > 1) {
              if (reason == 'conflict') await file.writeAsString('external');
              if (reason == 'revoke') {
                throw const FileSystemException('revoked');
              }
              if (reason == 'switch') return temp.path;
              if (reason == 'cancel') cancellation.cancel();
            }
            return root.path;
          },
        );
        final result = await call('edit', {
          'path': 'later.md',
          'edits': [
            {'oldText': 'before', 'newText': 'after'},
          ],
        });
        expect(result.success, false, reason: reason);
        expect(
          await file.readAsString(),
          reason == 'conflict' ? 'external' : 'before',
        );
        expect(
          await File('${root.path}/saved.md').readAsString(),
          'prior save',
        );
        cancellation = CancellationSource();
      }
    },
  );

  test(
    'two projects and simultaneous guarded writes never share a destination or clobber a newer revision',
    () async {
      final second = await Directory('${temp.path}/second').create();
      executor = LocalWorkspaceToolExecutor(
        resolveRoot: (id) async => id == project ? root.path : second.path,
      );
      await call('write', {'path': 'same.txt', 'content': 'first project'});
      final secondResult = await executor.execute(
        ToolInvocation(
          callId: 'second',
          name: 'write',
          arguments: {'path': 'same.txt', 'content': 'second project'},
          projectId: ProjectId('second'),
        ),
        cancellation: cancellation.token,
        liveness: _Live(),
      );
      expect(secondResult.success, true);
      expect(
        await File('${root.path}/same.txt').readAsString(),
        'first project',
      );
      expect(
        await File('${second.path}/same.txt').readAsString(),
        'second project',
      );
      final read = output(await call('read', {'path': 'same.txt'}));
      final results = await Future.wait([
        call('write', {
          'path': 'same.txt',
          'content': 'winner',
          'expectedRevision': read['revision'],
        }),
        call('write', {
          'path': 'same.txt',
          'content': 'stale overwrite',
          'expectedRevision': read['revision'],
        }),
      ]);
      expect(results.where((r) => r.success), hasLength(1));
      expect(results.where((r) => !r.success), hasLength(1));
      expect(await File('${root.path}/same.txt').readAsString(), 'winner');
      expect(
        await File('${second.path}/same.txt').readAsString(),
        'second project',
      );
    },
  );

  test(
    'cancellation during traversal stops work; size and depth bounds are observable',
    () async {
      for (var i = 0; i < 20; i++) {
        await save('dir/$i.md', 'token');
      }
      final result = await call('grep', {
        'pattern': 'token',
      }, liveness: _Live(onProgress: cancellation.cancel));
      expect(result.success, false);
      expect(result.errorMessage, contains('cancelled'));
      cancellation = CancellationSource();
      await save('${List.filled(34, 'deep').join('/')}/end.txt', 'x');
      expect(
        output(await call('find', {'pattern': '*'}))['warnings'],
        contains('32 directory depth limit; narrow path.'),
      );
      expect(
        (await call('write', {
          'path': 'huge.md',
          'content': 'x' * (128 * 1024 + 1),
        })).success,
        false,
      );
      expect(await File('${root.path}/huge.md').exists(), false);
    },
  );
}

final class _Live implements ToolExecutionLiveness {
  _Live({this.onProgress});
  final void Function()? onProgress;
  @override
  void reportProgress({String? detail}) => onProgress?.call();
}
