import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import '../projects/context/portable_file_mode_io.dart';
import '../../core/agents/agents.dart';
import '../../core/llm/cancellation.dart';
import '../../core/projects/ids.dart';
import '../../core/projects/policy.dart';

part 'local_workspace_discovery_io.dart';

typedef WorkspaceRootResolver = Future<String> Function(ProjectId projectId);

final class LocalWorkspaceToolExecutor implements AgentToolExecutor {
  LocalWorkspaceToolExecutor({
    required this.resolveRoot,
    this.resolveWritableRoot,
    this.cleanupTemporary = _cleanupTemporary,
  });

  final WorkspaceRootResolver resolveRoot;
  final WorkspaceRootResolver? resolveWritableRoot;

  /// Host IO seam: cleanup may be slow or fail after the file is committed.
  /// Its outcome can never replace a committed change receipt.
  final Future<void> Function(Directory) cleanupTemporary;
  Future<void> _mutationTail = Future<void>.value();

  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) async {
    final projectId = invocation.projectId ?? ProjectId.defaultProject;
    ToolExecutionResult? committed;
    void acknowledge(ToolExecutionResult receipt) {
      committed = receipt;
      if (liveness is ToolExecutionCommitReporter) {
        liveness.reportCommitted(receipt);
      }
    }

    try {
      _checkCancellation(cancellation);
      final mutating = {'write', 'edit', 'bash'}.contains(invocation.name);
      final root = await (mutating
          ? resolveWritableRoot ?? resolveRoot
          : resolveRoot)(projectId);
      _checkCancellation(cancellation);
      Future<void> revalidate() async {
        _checkCancellation(cancellation);
        final current = await (resolveWritableRoot ?? resolveRoot)(projectId);
        if (p.normalize(current) != p.normalize(root)) {
          throw const _LocalToolError(
            'Project root changed; no content saved.',
          );
        }
        _checkCancellation(cancellation);
      }

      final output = switch (invocation.name) {
        'read' => await _read(root, invocation.arguments, cancellation),
        'ls' || 'find' || 'grep' => await _discover(
          root,
          invocation.name,
          invocation.arguments,
          cancellation,
          liveness,
        ),
        'write' => await _serializeMutation(
          () => _write(
            root,
            invocation.arguments,
            cancellation,
            revalidate,
            acknowledge,
          ),
        ),
        'edit' => await _serializeMutation(
          () => _edit(
            root,
            invocation.arguments,
            cancellation,
            revalidate,
            acknowledge,
          ),
        ),
        'bash' => await _bash(
          root,
          invocation.arguments,
          cancellation,
          liveness,
        ),
        _ => throw const FormatException('Unknown local tool.'),
      };
      liveness.reportProgress();
      return committed ?? ToolExecutionResult.success(output);
    } on _LocalToolError catch (error) {
      return committed ?? ToolExecutionResult.failure(error.message);
    } on FileSystemException {
      return committed ??
          ToolExecutionResult.failure('Local workspace access failed.');
    } on ProcessException {
      return committed ??
          ToolExecutionResult.failure('Local shell is unavailable.');
    } on Object {
      return committed ??
          ToolExecutionResult.failure('Local tool execution failed.');
    }
  }

  Future<Map<String, Object?>> _read(
    String root,
    Map<String, Object?> args,
    CancellationToken cancellation,
  ) async {
    final path = _stringArg(args, 'path');
    final target = await _filePath(root, path, requireExisting: true);
    final content = await _readText(target);
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
      'revision': _textRevision(content),
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
    Future<void> Function() revalidate,
    void Function(ToolExecutionResult) acknowledge,
  ) async {
    final path = _stringArg(args, 'path');
    final content = _stringArg(args, 'content', allowEmpty: true);
    _requireMutationSize(content);
    final target = await _filePath(root, path, createParents: true);
    final exists = await File(target).exists();
    final before = exists
        ? await _readText(target, maxBytes: _maxMutationBytes)
        : null;
    if (exists &&
        args['expectedContent'] != before &&
        args['expectedRevision'] != _textRevision(before!)) {
      throw const _LocalToolError(
        'Overwrite conflict: provide expectedRevision from read, exact expectedContent, or use edit.',
      );
    }
    if (!exists &&
        (args['expectedContent'] != null || args['expectedRevision'] != null)) {
      throw const _LocalToolError(
        'Expected file is missing; no content saved.',
      );
    }
    return _saveChange(
      root,
      path,
      before,
      content,
      cancellation,
      revalidate,
      acknowledge,
      cleanupTemporary,
    );
  }

  Future<Map<String, Object?>> _edit(
    String root,
    Map<String, Object?> args,
    CancellationToken cancellation,
    Future<void> Function() revalidate,
    void Function(ToolExecutionResult) acknowledge,
  ) async {
    final path = _stringArg(args, 'path');
    final target = await _filePath(root, path, requireExisting: true);
    final rawEdits = args['edits'];
    if (rawEdits is! List || rawEdits.isEmpty) {
      throw const _LocalToolError('Provide at least one edit.');
    }
    final source = await _readText(target, maxBytes: _maxMutationBytes);
    if (args['expectedRevision'] != null &&
        args['expectedRevision'] != _textRevision(source)) {
      throw const _LocalToolError(
        'Edit revision conflict; read the file again.',
      );
    }
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
    _requireMutationSize(result);
    return _saveChange(
      root,
      path,
      source,
      result,
      cancellation,
      revalidate,
      acknowledge,
      cleanupTemporary,
      metadata: {'replacements': replacements.length},
    );
  }

  Future<Map<String, Object?>> _serializeMutation(
    Future<Map<String, Object?>> Function() action,
  ) async {
    final previous = _mutationTail;
    final done = Completer<void>();
    _mutationTail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
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
  if (!_allowedWorkspacePath(relative)) {
    throw const _LocalToolError('Path is excluded from workspace file tools.');
  }
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
        (type != FileSystemEntityType.file &&
                type != FileSystemEntityType.notFound ||
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

const _maxMutationBytes = 128 * 1024;

void _requireMutationSize(String text) {
  if (utf8.encode(text).length > _maxMutationBytes) {
    throw const _LocalToolError(
      'Change exceeds 128 KiB per file; no file saved.',
    );
  }
}

Future<String> _readText(String target, {int maxBytes = 1024 * 1024}) async {
  final handle = await File(target).open();
  try {
    final bytes = await handle.read(maxBytes + 1);
    if (bytes.length > maxBytes) {
      throw const _LocalToolError(
        'Text file exceeds the operation size limit.',
      );
    }
    if (bytes.contains(0)) {
      throw const _LocalToolError('Binary file is unsupported.');
    }
    try {
      final decoded = utf8.decode(bytes);
      // Utf8Decoder discards an initial BOM; keep it as actual file content so
      // revision guards and unrelated bytes survive an exact edit.
      final hasBom =
          bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf;
      return hasBom ? '\uFEFF$decoded' : decoded;
    } on FormatException {
      throw const _LocalToolError('File is not valid UTF-8 text.');
    }
  } finally {
    await handle.close();
  }
}

/// No awaits between the final conflict/path check and rename: app mutations
/// are serialized, and external changes observed before commit fail closed.
/// Dart has no portable filesystem compare-and-swap against hostile OS writers.
Future<Map<String, Object?>> _saveChange(
  String root,
  String path,
  String? before,
  String after,
  CancellationToken cancellation,
  Future<void> Function() revalidate,
  void Function(ToolExecutionResult) acknowledge,
  Future<void> Function(Directory) cleanupTemporary, {
  Map<String, Object?> metadata = const {},
}) async {
  _checkCancellation(cancellation);
  final target = await _filePath(root, path, createParents: true);
  final directory = await Directory(
    p.dirname(target),
  ).createTemp('.domovoy-save-');
  final temporary = File(p.join(directory.path, 'content'));
  try {
    final output = <String, Object?>{
      ...metadata,
      'path': path,
      'bytesWritten': before == after ? 0 : utf8.encode(after).length,
      'change': {
        'path': path,
        'kind': before == after
            ? 'unchanged'
            : before == null
            ? 'created'
            : 'modified',
        'before': before,
        'after': after,
      },
    };
    final receipt = ToolExecutionResult.success(output);
    await temporary.writeAsString(after, flush: true);
    await revalidate();
    await _filePath(root, path, createParents: false);
    _checkCancellation(cancellation);
    // Recheck synchronously after all asynchronous grant/path operations.
    var component = root;
    if (FileSystemEntity.typeSync(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const _LocalToolError('Project root is unavailable.');
    }
    for (final segment in parseRelativeSegments(path).segments) {
      component = p.join(component, segment);
      final type = FileSystemEntity.typeSync(component, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const _LocalToolError('Symbolic links are not allowed.');
      }
    }
    final file = File(target);
    List<int>? current;
    if (file.existsSync()) {
      final handle = file.openSync();
      try {
        current = handle.readSync(_maxMutationBytes + 1);
      } finally {
        handle.closeSync();
      }
    }
    if ((before == null && current != null) ||
        (before != null &&
            (current == null || !_sameBytes(current, utf8.encode(before))))) {
      throw const _LocalToolError(
        'File changed concurrently; no content saved. Read again before editing.',
      );
    }
    if (before == after) return output;
    if (before != null) {
      applyPortablePermissionBits(temporary.path, file.statSync().mode);
    }
    temporary.renameSync(target);
    // No await after the irreversible effect until its exact receipt is in
    // the runtime transcript. Cancellation during cleanup preserves this save.
    acknowledge(receipt);
    return output;
  } finally {
    try {
      await cleanupTemporary(directory);
    } on Object {
      // Best effort, including before commit: preserve the original operation
      // outcome rather than replacing it with a temporary-cleanup failure.
    }
  }
}

Future<void> _cleanupTemporary(Directory directory) async {
  if (await directory.exists()) await directory.delete(recursive: true);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _textRevision(String text) =>
    sha256.convert(utf8.encode(text)).toString();
