import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/projects/project_context.dart';

/// Read-only desktop capability for actual loose or packed authorized ODBs.
/// No checkout, repack, network, shell, hooks or replacement objects are used.
final class HostGitObjectVerifier implements ProjectGitObjectVerifier {
  const HostGitObjectVerifier({
    this.timeout = const Duration(seconds: 30),
    this.maxOutputBytes = 1024 * 1024,
  });

  final Duration timeout;
  final int maxOutputBytes;

  Future<bool> _inWorkspace(String root, String directory) async {
    if (p.equals(root, directory) || p.isWithin(root, directory)) return true;
    // Filesystem identity also covers case aliases and Windows short names.
    for (var current = directory; ; current = p.dirname(current)) {
      if (await FileSystemEntity.identical(root, current)) return true;
      if (p.equals(current, p.dirname(current))) return false;
    }
  }

  Future<String> _gitExecutable(String root) async {
    final names = Platform.isWindows
        ? const ['git.exe', 'git.com']
        : const ['git'];
    for (var entry in (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      if (Platform.isWindows &&
          entry.length >= 2 &&
          entry.startsWith('"') &&
          entry.endsWith('"')) {
        entry = entry.substring(1, entry.length - 1);
      }
      // Never make a PATH entry absolute relative to the selected workspace.
      if (!p.isAbsolute(entry) || p.isRootRelative(entry)) continue;
      try {
        final directory = await Directory(entry).resolveSymbolicLinks();
        if (await _inWorkspace(root, p.normalize(entry)) ||
            await _inWorkspace(root, directory)) {
          continue;
        }
        for (final name in names) {
          try {
            final executable = await File(
              p.join(directory, name),
            ).resolveSymbolicLinks();
            if (await _inWorkspace(root, p.dirname(executable))) continue;
            final stat = await File(executable).stat();
            if (stat.type != FileSystemEntityType.file) continue;
            if (Platform.isWindows) {
              // Batch wrappers require a shell; only native executables qualify.
              if (!{
                '.exe',
                '.com',
              }.contains(p.extension(executable).toLowerCase())) {
                continue;
              }
            } else if (stat.mode & 0x49 == 0) {
              continue;
            }
            return executable;
          } on FileSystemException {
            // Broken/inaccessible candidate: continue with the next host entry.
          }
        }
      } on FileSystemException {
        // Missing/inaccessible directory: never fall back to the workspace.
      }
    }
    throw const FormatException(
      'No trusted absolute host Git executable found',
    );
  }

  @override
  Future<void> verify({
    required String root,
    required String gitDirectory,
    required String commonDirectory,
    required String head,
  }) async {
    final executable = await _gitExecutable(root);
    Future<void> safe(String path) async {
      if (!p.isWithin(root, path) ||
          await FileSystemEntity.isLink(path) ||
          await File(path).resolveSymbolicLinks() != path) {
        throw const FormatException('Unsafe host Git metadata path');
      }
    }

    // Git must not follow alternates, promisor remotes or filesystem links to
    // data outside this grant. Bound the preflight as well as the subprocess.
    var entries = 0;
    final deadline = DateTime.now().add(timeout);
    for (final path in {
      p.join(commonDirectory, 'objects'),
      p.join(commonDirectory, 'refs'),
      if (gitDirectory != commonDirectory) p.join(gitDirectory, 'refs'),
    }) {
      if (path == p.join(gitDirectory, 'refs') &&
          gitDirectory != commonDirectory &&
          !await Directory(path).exists()) {
        continue;
      }
      if (!await Directory(path).exists()) {
        throw const FormatException('Missing host Git object/ref directory');
      }
      await safe(path);
      await for (final entity in Directory(
        path,
      ).list(recursive: true, followLinks: false)) {
        if (++entries > 100000 || DateTime.now().isAfter(deadline)) {
          throw const FormatException('Host Git metadata exceeds scan limits');
        }
        await safe(entity.path);
        if (entity is! File && entity is! Directory) {
          throw const FormatException('Unsupported host Git metadata entry');
        }
        if ({
              'alternates',
              'http-alternates',
            }.contains(p.basename(entity.path)) ||
            entity.path.endsWith('.promisor')) {
          throw const FormatException(
            'External/partial Git objects unsupported',
          );
        }
      }
    }
    for (final directory in {gitDirectory, commonDirectory}) {
      for (final name in ['HEAD', 'packed-refs', 'shallow', 'commondir']) {
        final path = p.join(directory, name);
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await safe(path);
          if (await File(path).length() > 4 * 1024 * 1024) {
            throw const FormatException('Host Git metadata file too large');
          }
        }
      }
    }
    // Includes could read arbitrary host configuration; fsck settings could
    // suppress verification. Refuse those explicitly, rather than trusting them.
    for (final path in {
      p.join(commonDirectory, 'config'),
      p.join(gitDirectory, 'config.worktree'),
    }) {
      if (!await File(path).exists()) continue;
      await safe(path);
      if (await File(path).length() > 65536) {
        throw const FormatException('Host Git config too large');
      }
      final config = (await File(
        path,
      ).readAsString()).replaceFirst(RegExp(r'^\uFEFF'), '');
      if (RegExp(
        r'^\s*\[\s*(?:include|fsck)',
        caseSensitive: false,
        multiLine: true,
      ).hasMatch(config)) {
        throw const FormatException('Unsupported host Git verification config');
      }
    }
    final environment = <String, String>{
      for (final name in ['SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR'])
        name: ?Platform.environment[name],
      'PATH': p.dirname(executable),
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_SYSTEM': Platform.isWindows ? 'NUL' : '/dev/null',
      'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
      'GIT_NO_REPLACE_OBJECTS': '1',
      'GIT_NO_LAZY_FETCH': '1',
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_OPTIONAL_LOCKS': '0',
      'GIT_ATTR_NOSYSTEM': '1',
      'GIT_GRAFT_FILE': Platform.isWindows ? 'NUL' : '/dev/null',
      'LC_ALL': 'C',
    };
    final arguments = [
      '--no-replace-objects',
      '--git-dir=$gitDirectory',
      '--work-tree=$root',
      for (final config in [
        'core.hooksPath=${Platform.isWindows ? 'NUL' : '/dev/null'}',
        'core.fsmonitor=false',
        'core.commitGraph=false',
        'core.multiPackIndex=false',
        'protocol.allow=never',
        'maintenance.auto=false',
        'gc.auto=0',
        'credential.helper=',
      ]) ...['-c', config],
    ];
    await _run(
      executable,
      [
        ...arguments,
        'fsck',
        '--full',
        '--strict',
        '--no-reflogs',
        '--no-dangling',
        head,
      ],
      root,
      environment,
    );
    final current = await _run(
      executable,
      [...arguments, 'rev-parse', '--verify', 'HEAD^{commit}'],
      root,
      environment,
    );
    if (current.trim() != head) {
      throw const FormatException('Git HEAD changed during verification');
    }
  }

  Future<String> _run(
    String executable,
    List<String> arguments,
    String root,
    Map<String, String> environment,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: root,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    final output = BytesBuilder(copy: false);
    var count = 0;
    var exceeded = false;
    void receive(List<int> bytes, {required bool stdout}) {
      count += bytes.length;
      if (count > maxOutputBytes) {
        exceeded = true;
        process.kill(ProcessSignal.sigkill);
      } else if (stdout) {
        output.add(bytes);
      }
    }

    final out = process.stdout.listen((bytes) => receive(bytes, stdout: true));
    final err = process.stderr.listen((bytes) => receive(bytes, stdout: false));
    final drained = Future.wait([out.asFuture<void>(), err.asFuture<void>()]);
    try {
      final exit = await (() async {
        final exit = await process.exitCode;
        await drained;
        return exit;
      })().timeout(timeout);
      if (exceeded || exit != 0) {
        throw const FormatException(
          'Host Git verification failed or exceeded output limit',
        );
      }
      return utf8.decode(output.takeBytes());
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw const FormatException('Host Git verification timed out');
    } finally {
      await out.cancel();
      await err.cancel();
    }
  }
}
