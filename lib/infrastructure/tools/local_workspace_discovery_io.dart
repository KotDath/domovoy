part of 'local_workspace_executor_io.dart';

// Fixed exclusions, deliberately not a .gitignore interpreter. Source files
// called credentials.dart or secret_management.md remain ordinary source data.
const _excludedDirectories = {
  '.git',
  '.dart_tool',
  'build',
  'node_modules',
  '.venv',
  'venv',
  '__pycache__',
  '.gradle',
  'dist',
  'coverage',
  '.cache',
  '.idea',
  '.ssh',
  '.aws',
  '.azure',
  '.kube',
  '.docker',
};
const _credentialNames = {
  '.netrc',
  '_netrc',
  '.git-credentials',
  '.gitcookies',
  '.npmrc',
  '.pypirc',
  '.pgpass',
  '.my.cnf',
  '.dockercfg',
  '.s3cfg',
  '.boto',
  'id_ecdsa_sk',
  'id_ed25519_sk',
  '.vault-token',
  'id_rsa',
  'id_dsa',
  'id_ecdsa',
  'id_ed25519',
  'credentials.json',
  'credentials.yaml',
  'credentials.yml',
  'secrets.json',
  'secrets.yaml',
  'secrets.yml',
  'service-account.json',
  'application_default_credentials.json',
};
bool _allowedWorkspacePath(String path, {bool directory = false}) {
  final parts = path.toLowerCase().split('/');
  // Portable filenames must not alias Windows devices or trimmed paths.
  // Check on every platform so an Android-imported tree has the same contract.
  final device = RegExp(r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])$');
  if (parts.any(
    (part) =>
        part.endsWith(' ') ||
        part.endsWith('.') ||
        RegExp(r'[<>"|?*\x00-\x1f\x7f]').hasMatch(part) ||
        device.hasMatch(part.split('.').first.trimRight()),
  )) {
    return false;
  }
  if (parts.asMap().entries.any(
    (entry) =>
        (_excludedDirectories.contains(entry.value) &&
            (directory ||
                entry.key < parts.length - 1 ||
                {
                  '.git',
                  '.ssh',
                  '.aws',
                  '.azure',
                  '.kube',
                  '.docker',
                }.contains(entry.value))) ||
        _credentialNames.contains(entry.value) ||
        entry.value == '.env' ||
        entry.value.startsWith('.env.') ||
        ['.pem', '.key', '.keystore', '.jks'].any(entry.value.endsWith) ||
        entry.value.startsWith('.domovoy-save-'),
  )) {
    return false;
  }
  final joined = parts.join('/');
  return ![
    '.config/gh',
    '.config/gcloud',
    '.config/hub',
    '.gem/credentials',
    '.bundle/config',
  ].any(
    (store) =>
        joined == store ||
        joined.startsWith('$store/') ||
        joined.contains('/$store/'),
  );
}

Future<String> _discoveryPath(String root, String relative) async {
  if (relative == '.') return root;
  // Shared validator checks each component without following symbolic links.
  final parsed = parseRelativeSegments(relative);
  if (parsed.denial != null || !_allowedWorkspacePath(relative)) {
    throw const _LocalToolError(
      'Path is invalid or excluded from workspace file tools.',
    );
  }
  var current = root;
  for (final segment in parsed.segments) {
    current = p.join(current, segment);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.directory &&
        _excludedDirectories.contains(segment.toLowerCase())) {
      throw const _LocalToolError(
        'Directory is excluded from workspace file tools.',
      );
    }
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw const _LocalToolError(
        'Search path is unavailable; symbolic links are not allowed.',
      );
    }
  }
  if (!p.isWithin(root, current)) {
    throw const _LocalToolError('Path is outside the project.');
  }
  return current;
}

int _boundedInt(
  Map<String, Object?> args,
  String name,
  int fallback,
  int maximum, {
  int minimum = 0,
}) {
  final value = args[name];
  if (value == null) return fallback;
  if (value is! num ||
      !value.isFinite ||
      value != value.round() ||
      value < minimum ||
      value > maximum) {
    throw _LocalToolError(
      '$name must be an integer from $minimum to $maximum.',
    );
  }
  return value.toInt();
}

bool _boolArg(Map<String, Object?> args, String name) {
  final value = args[name];
  if (value != null && value is! bool) throw _LocalToolError('Invalid $name.');
  return value == true;
}

// Iterative wildcard matcher, bounded by pattern length * candidate length.
// ** crosses separators; **/ also matches zero directories. No braces/classes.
bool _globMatches(String pattern, String path) {
  if (pattern.length > 256 || pattern.contains(RegExp(r'[\[\]{}\\]'))) {
    throw const _LocalToolError(
      'Glob supports only *, ** and ? (max 256 characters).',
    );
  }
  final target = pattern.contains('/') ? path : p.posix.basename(path);
  final memo = <(int, int), bool>{};
  bool match(int i, int j) {
    if (memo.containsKey((i, j))) return memo[(i, j)]!;
    bool result;
    if (i == pattern.length) {
      result = j == target.length;
    } else if (pattern[i] == '*') {
      final double = i + 1 < pattern.length && pattern[i + 1] == '*';
      final next = i + (double ? 2 : 1);
      result =
          match(next, j) ||
          (double &&
              next < pattern.length &&
              pattern[next] == '/' &&
              match(next + 1, j)) ||
          (j < target.length &&
              (double || target[j] != '/') &&
              match(i, j + 1));
    } else {
      result =
          j < target.length &&
          ((pattern[i] == '?' && target[j] != '/') ||
              pattern[i] == target[j]) &&
          match(i + 1, j + 1);
    }
    memo[(i, j)] = result;
    return result;
  }

  return match(0, 0);
}

Future<Map<String, Object?>> _discover(
  String root,
  String name,
  Map<String, Object?> args,
  CancellationToken cancellation,
  ToolExecutionLiveness liveness,
) async {
  final path = args['path'] == null ? '.' : _stringArg(args, 'path');
  final start = await _discoveryPath(root, path);
  final limit = _boundedInt(
    args,
    'limit',
    name == 'ls' ? 500 : 100,
    500,
    minimum: 1,
  );
  final offset = _boundedInt(args, 'offset', 0, 10000);
  final pattern = name == 'ls' ? '' : _stringArg(args, 'pattern');
  if (pattern.length > 512) {
    throw const _LocalToolError('Pattern exceeds 512 characters.');
  }
  final literal = name == 'grep' && _boolArg(args, 'literal');
  final ignoreCase = name == 'grep' && _boolArg(args, 'ignoreCase');
  RegExp? regex;
  if (name == 'grep' && !literal) {
    final problem = toolPatternProblem(pattern);
    if (problem != null) {
      throw _LocalToolError(
        'Unsupported regex: $problem Use literal=true or separate searches.',
      );
    }
    try {
      regex = RegExp(pattern, caseSensitive: !ignoreCase);
    } on FormatException {
      throw const _LocalToolError('Invalid search regex.');
    }
  }
  final context = name == 'grep' ? _boundedInt(args, 'context', 0, 5) : 0;
  final glob = name == 'find' ? pattern : args['glob'] as String?;
  if (glob != null) _globMatches(glob, '');
  final entries = <Object?>[];
  final warnings = <String>{};
  var visited = 0, matched = 0, skipped = 0, readBytes = 0, outputBytes = 0;
  var stopped = false, traversalLimited = false;
  void add(Object entry) {
    if (matched++ < offset) return;
    final size = utf8.encode(jsonEncode(entry)).length;
    if (entries.length >= limit || outputBytes + size > 48 * 1024) {
      stopped = true;
      return;
    }
    outputBytes += size;
    entries.add(entry);
  }

  Future<void> visit(String native, int depth) async {
    if (stopped || traversalLimited) return;
    _checkCancellation(cancellation);
    liveness.reportProgress();
    final relative = p
        .relative(native, from: root)
        .split(p.separator)
        .join('/');
    final type = await FileSystemEntity.type(native, followLinks: false);
    if (relative != '.' &&
        !_allowedWorkspacePath(
          relative,
          directory: type == FileSystemEntityType.directory,
        )) {
      skipped++;
      return;
    }
    if (type == FileSystemEntityType.link) {
      skipped++;
      warnings.add('Symbolic links skipped.');
      return;
    }
    if (++visited > 10000) {
      traversalLimited = true;
      warnings.add('10000 entry traversal limit; narrow path.');
      return;
    }
    if (type == FileSystemEntityType.directory) {
      if (name == 'ls' && native != start) {
        add({'path': relative, 'type': 'directory'});
        return;
      }
      if (depth >= 32) {
        skipped++;
        warnings.add('32 directory depth limit; narrow path.');
        return;
      }
      if (native != root) await _discoveryPath(root, relative);
      final children = <FileSystemEntity>[];
      try {
        await for (final child in Directory(native).list(followLinks: false)) {
          _checkCancellation(cancellation);
          children.add(child);
          if (children.length > 10000) {
            traversalLimited = true;
            warnings.add('Directory exceeds 10000 entries; narrow path.');
            return;
          }
        }
      } on FileSystemException {
        skipped++;
        warnings.add('Unreadable directory skipped.');
        return;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        await visit(child.path, depth + 1);
        if (stopped || traversalLimited) break;
      }
    } else if (type == FileSystemEntityType.file) {
      if (name == 'ls') {
        add({'path': relative, 'type': 'file'});
        return;
      }
      final searchRelative = start == native
          ? p.basename(native)
          : p.relative(native, from: start).split(p.separator).join('/');
      if (glob != null && !_globMatches(glob, searchRelative)) return;
      if (name == 'find') {
        add(relative);
        return;
      }
      try {
        final stat = await File(native).stat();
        if (readBytes + stat.size > 16 * 1024 * 1024) {
          traversalLimited = true;
          warnings.add('16 MiB search read budget; narrow path.');
          return;
        }
        readBytes += stat.size;
        // Recheck paths after asynchronous traversal; never follow a replaced link.
        await _discoveryPath(root, relative);
        final text = await _readText(native);
        final lines = const LineSplitter().convert(text);
        for (var i = 0; i < lines.length; i++) {
          if (i % 100 == 0) {
            _checkCancellation(cancellation);
            await Future<void>.delayed(Duration.zero);
          }
          final haystack = ignoreCase ? lines[i].toLowerCase() : lines[i];
          final needle = ignoreCase ? pattern.toLowerCase() : pattern;
          if (literal ? haystack.contains(needle) : regex!.hasMatch(lines[i])) {
            String bounded(String line) => line.length <= 1000
                ? line
                : '${line.substring(0, 1000)} [line truncated; use read]';
            add({
              'path': relative,
              'line': i + 1,
              'text': bounded(lines[i]),
              if (context > 0)
                'context': [
                  for (
                    var j = (i - context).clamp(0, lines.length);
                    j <= (i + context).clamp(0, lines.length - 1);
                    j++
                  )
                    {'line': j + 1, 'text': bounded(lines[j])},
                ],
            });
            if (stopped) break;
          }
        }
      } on _LocalToolError catch (e) {
        skipped++;
        warnings.add(e.message);
      } on FileSystemException {
        skipped++;
        warnings.add('Unreadable file skipped.');
      }
    } else {
      skipped++;
    }
  }

  if (name == 'ls' &&
      await FileSystemEntity.type(start, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw const _LocalToolError('ls requires a directory.');
  }
  await visit(start, 0);
  _checkCancellation(cancellation);
  return {
    'path': path,
    name == 'grep' ? 'matches' : 'entries': entries,
    'offset': offset,
    'truncated': stopped || traversalLimited,
    if (stopped) 'nextOffset': offset + entries.length,
    'visited': visited,
    'skipped': skipped,
    'readBytes': readBytes,
    'warnings': warnings.toList(),
    'exclusions':
        'fixed caches, VCS and credential stores; no gitignore interpretation',
  };
}
