import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/agents/agents.dart';
import '../../core/llm/cancellation.dart';
import '../../core/projects/enums.dart';
import '../../core/projects/ids.dart';
import '../../core/projects/policy.dart';
import '../../core/projects/record.dart';
import '../projects/grants/file_grant_store.dart';
import '../projects/project_platform_stack.dart';
import 'local_workspace_tools.dart';

typedef WorkspaceRootResolver = Future<String> Function(ProjectId projectId);

LocalWorkspaceTools createLocalWorkspaceTools(ProjectPlatformStack projects) {
  final registry = AgentToolRegistry();
  if (Platform.isIOS) {
    return LocalWorkspaceTools(registry: registry, enabled: const []);
  }
  final executor = LocalWorkspaceToolExecutor(
    resolveRoot: ProjectWorkspaceRootResolver(projects).resolve,
  );
  for (final descriptor in PiDefaultTools.descriptors) {
    registry.register(AgentTool(descriptor: descriptor, executor: executor));
  }
  return LocalWorkspaceTools(registry: registry, enabled: PiDefaultTools.ids);
}

/// Resolves a project's current local root on each invocation. A saved project
/// record or grant alone is insufficient: its access can be revoked or stale.
final class ProjectWorkspaceRootResolver {
  const ProjectWorkspaceRootResolver(this.projects);

  final ProjectPlatformStack projects;

  Future<String> resolve(ProjectId projectId) async {
    final record = await projects.repository.load(projectId);
    if (record == null || !record.isActive) {
      throw const FileSystemException('Project is not active.');
    }
    final root = record.root;
    if (root is AppSandboxRootReference) {
      final status = await projects.provisioner.revalidateRoot(
        rootId: root.rootId,
        projectId: projectId,
      );
      if (status != ProjectAccessStatus.active) {
        throw const FileSystemException('Project workspace is unavailable.');
      }
      final support = await getApplicationSupportDirectory();
      final nativePath = p.join(
        support.path,
        'project-sandbox-roots-v1',
        projectId.value,
      );
      return _requireRealDirectory(nativePath);
    }
    if (root is ExternalGrantRootReference) {
      final status = await projects.provisioner.revalidateRoot(
        grantId: root.grantId,
        projectId: projectId,
      );
      if (status != ProjectAccessStatus.active) {
        throw const FileSystemException('Project workspace is unavailable.');
      }
      final grantStore = projects.grants;
      if (grantStore is! FileProjectDirectoryGrantStore) {
        throw const FileSystemException('Project grant is unavailable.');
      }
      final nativePath = grantStore.nativePathFor(root.grantId);
      if (nativePath == null) {
        throw const FileSystemException('Project grant is unavailable.');
      }
      return _requireRealDirectory(nativePath);
    }
    throw const FileSystemException('Project workspace is unsupported.');
  }
}

Future<String> _requireRealDirectory(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('Project workspace is unavailable.');
  }
  final resolved = await Directory(path).resolveSymbolicLinks();
  if (p.normalize(resolved) != p.normalize(p.absolute(path))) {
    throw const FileSystemException('Project workspace is unavailable.');
  }
  return resolved;
}

final class LocalWorkspaceToolExecutor implements AgentToolExecutor {
  const LocalWorkspaceToolExecutor({required this.resolveRoot});

  final WorkspaceRootResolver resolveRoot;

  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) async {
    final projectId = invocation.projectId ?? ProjectId.defaultProject;
    try {
      _checkCancellation(cancellation);
      final root = await resolveRoot(projectId);
      _checkCancellation(cancellation);
      final output = switch (invocation.name) {
        'read' => await _read(root, invocation.arguments, cancellation),
        'write' => await _write(root, invocation.arguments, cancellation),
        'edit' => await _edit(root, invocation.arguments, cancellation),
        'bash' => await _bash(
          root,
          invocation.arguments,
          cancellation,
          liveness,
        ),
        _ => throw const FormatException('Unknown local tool.'),
      };
      liveness.reportProgress();
      return ToolExecutionResult.success(output);
    } on _LocalToolError catch (error) {
      return ToolExecutionResult.failure(error.message);
    } on FileSystemException {
      return ToolExecutionResult.failure('Local workspace access failed.');
    } on ProcessException {
      return ToolExecutionResult.failure('Local shell is unavailable.');
    } on Object {
      return ToolExecutionResult.failure('Local tool execution failed.');
    }
  }

  Future<Map<String, Object?>> _read(
    String root,
    Map<String, Object?> args,
    CancellationToken cancellation,
  ) async {
    final path = _stringArg(args, 'path');
    final target = await _filePath(root, path, requireExisting: true);
    final content = await File(target).readAsString();
    _checkCancellation(cancellation);
    final lines = const LineSplitter().convert(content);
    final offset = _positiveIntArg(args, 'offset') ?? 1;
    final limit = _positiveIntArg(args, 'limit') ?? 2000;
    if (offset > lines.length + 1) {
      throw const _LocalToolError('Read offset is past the end of the file.');
    }
    final from = offset - 1;
    final to = (from + limit).clamp(0, lines.length);
    var selected = lines.sublist(from, to).join('\n');
    var byteCount = utf8.encode(selected).length;
    if (byteCount > 50 * 1024) {
      final buffer = StringBuffer();
      byteCount = 0;
      for (final rune in selected.runes) {
        final char = String.fromCharCode(rune);
        final length = utf8.encode(char).length;
        if (byteCount + length > 50 * 1024) break;
        buffer.write(char);
        byteCount += length;
      }
      selected = buffer.toString();
    }
    return <String, Object?>{
      'path': path,
      'content': selected,
      'offset': offset,
      'totalLines': lines.length,
      'truncated':
          to < lines.length ||
          byteCount < utf8.encode(lines.sublist(from, to).join('\n')).length,
    };
  }

  Future<Map<String, Object?>> _write(
    String root,
    Map<String, Object?> args,
    CancellationToken cancellation,
  ) async {
    final path = _stringArg(args, 'path');
    final content = _stringArg(args, 'content', allowEmpty: true);
    final target = await _filePath(root, path, createParents: true);
    _checkCancellation(cancellation);
    await File(target).writeAsString(content, flush: true);
    return <String, Object?>{
      'path': path,
      'bytesWritten': utf8.encode(content).length,
    };
  }

  Future<Map<String, Object?>> _edit(
    String root,
    Map<String, Object?> args,
    CancellationToken cancellation,
  ) async {
    final path = _stringArg(args, 'path');
    final target = await _filePath(root, path, requireExisting: true);
    final rawEdits = args['edits'];
    if (rawEdits is! List || rawEdits.isEmpty) {
      throw const _LocalToolError('Provide at least one edit.');
    }
    final source = await File(target).readAsString();
    final replacements = <_Replacement>[];
    for (final raw in rawEdits) {
      if (raw is! Map<String, Object?>) {
        throw const _LocalToolError('Invalid edit.');
      }
      final oldText = _stringArg(raw, 'oldText');
      final newText = _stringArg(raw, 'newText', allowEmpty: true);
      final start = source.indexOf(oldText);
      if (start < 0 || source.indexOf(oldText, start + 1) >= 0) {
        throw const _LocalToolError(
          'Each oldText must occur exactly once in the original file.',
        );
      }
      replacements.add(_Replacement(start, start + oldText.length, newText));
    }
    replacements.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < replacements.length; i++) {
      if (replacements[i].start < replacements[i - 1].end) {
        throw const _LocalToolError('Edits must not overlap.');
      }
    }
    var result = source;
    for (final replacement in replacements.reversed) {
      result = result.replaceRange(
        replacement.start,
        replacement.end,
        replacement.text,
      );
    }
    _checkCancellation(cancellation);
    await File(target).writeAsString(result, flush: true);
    return <String, Object?>{'path': path, 'replacements': replacements.length};
  }

  Future<Map<String, Object?>> _bash(
    String root,
    Map<String, Object?> args,
    CancellationToken cancellation,
    ToolExecutionLiveness liveness,
  ) async {
    final command = _stringArg(args, 'command');
    final timeout = _positiveNumberArg(args, 'timeout');
    final shell = _shell();
    if (shell == null) {
      throw const _LocalToolError('Local shell is unavailable.');
    }
    _checkCancellation(cancellation);
    final process = await Process.start(
      shell,
      <String>['-c', command],
      workingDirectory: root,
      environment: _shellEnvironment(root),
      includeParentEnvironment: false,
      runInShell: false,
    );
    var timedOut = false;
    final timer = timeout == null
        ? null
        : Timer(Duration(milliseconds: (timeout * 1000).ceil()), () {
            timedOut = true;
            process.kill();
          });
    final registration = cancellation.register(process.kill);
    try {
      final stdout = _collectOutput(process.stdout, liveness);
      final stderr = _collectOutput(process.stderr, liveness);
      final results = await Future.wait<Object>(<Future<Object>>[
        process.exitCode,
        stdout,
        stderr,
      ]);
      _checkCancellation(cancellation);
      return <String, Object?>{
        'exitCode': results[0] as int,
        'stdout': results[1] as String,
        'stderr': results[2] as String,
        'timedOut': timedOut,
      };
    } finally {
      registration.dispose();
      timer?.cancel();
    }
  }
}

String? _shell() {
  if (Platform.isWindows) {
    for (final base in <String?>[
      Platform.environment['ProgramFiles'],
      Platform.environment['ProgramFiles(x86)'],
    ]) {
      if (base == null) continue;
      final candidate = p.join(base, 'Git', 'bin', 'bash.exe');
      if (File(candidate).existsSync()) return candidate;
    }
    return 'bash.exe';
  }
  if (File('/bin/bash').existsSync()) return '/bin/bash';
  if (Platform.isAndroid && File('/system/bin/sh').existsSync()) {
    return '/system/bin/sh';
  }
  if (File('/bin/sh').existsSync()) return '/bin/sh';
  return null;
}

Map<String, String> _shellEnvironment(String root) {
  final inherited = Platform.environment;
  final temporary = Directory.systemTemp.path;
  return <String, String>{
    'PATH':
        inherited['PATH'] ??
        (Platform.isWindows ? r'C:\Windows\System32' : '/usr/bin:/bin'),
    'HOME': root,
    'TMPDIR': temporary,
    'TMP': temporary,
    'TEMP': temporary,
    if (Platform.isWindows) ...<String, String>{
      'USERPROFILE': root,
      'SystemRoot': ?inherited['SystemRoot'],
      'WINDIR': ?inherited['WINDIR'],
    },
  };
}

Future<String> _collectOutput(
  Stream<List<int>> stream,
  ToolExecutionLiveness liveness,
) async {
  const maxBytes = 64 * 1024;
  final bytes = <int>[];
  await for (final chunk in stream) {
    liveness.reportProgress();
    final remaining = maxBytes - bytes.length;
    if (remaining > 0) bytes.addAll(chunk.take(remaining));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Future<String> _filePath(
  String root,
  String relative, {
  bool requireExisting = false,
  bool createParents = false,
}) async {
  final parsed = parseRelativeSegments(relative);
  if (parsed.denial != null) {
    throw const _LocalToolError('Path must be relative to the project.');
  }
  final target = p.joinAll(<String>[root, ...parsed.segments]);
  if (!p.isWithin(root, target)) {
    throw const _LocalToolError('Path is outside the project.');
  }
  var current = root;
  for (var i = 0; i < parsed.segments.length; i++) {
    current = p.join(current, parsed.segments[i]);
    final isLast = i == parsed.segments.length - 1;
    var type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const _LocalToolError('Symbolic links are not allowed.');
    }
    if (!isLast && type == FileSystemEntityType.notFound && createParents) {
      await Directory(current).create();
      type = await FileSystemEntity.type(current, followLinks: false);
    }
    if (!isLast && type != FileSystemEntityType.directory) {
      throw const _LocalToolError('Parent directory is unavailable.');
    }
    if (isLast &&
        (type == FileSystemEntityType.directory ||
            (requireExisting && type != FileSystemEntityType.file))) {
      throw const _LocalToolError('File is unavailable.');
    }
  }
  return target;
}

String _stringArg(
  Map<String, Object?> args,
  String key, {
  bool allowEmpty = false,
}) {
  final value = args[key];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw _LocalToolError('Invalid $key.');
  }
  return value;
}

int? _positiveIntArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! num ||
      !value.isFinite ||
      value <= 0 ||
      value != value.round()) {
    throw _LocalToolError('Invalid $key.');
  }
  return value.toInt();
}

num? _positiveNumberArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! num || !value.isFinite || value <= 0 || value > 2147483) {
    throw _LocalToolError('Invalid $key.');
  }
  return value;
}

void _checkCancellation(CancellationToken token) {
  if (token.isCancelled) {
    throw const _LocalToolError('Tool execution was cancelled.');
  }
}

final class _Replacement {
  const _Replacement(this.start, this.end, this.text);

  final int start;
  final int end;
  final String text;
}

final class _LocalToolError {
  const _LocalToolError(this.message);

  final String message;
}
