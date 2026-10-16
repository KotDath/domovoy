import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/llm/cancellation.dart';
import '../../core/rag/models.dart';

/// One policy for indexing and read-tool admission. Symlinks are never followed.
/// This is a text-source policy, not a claim to detect secrets in arbitrary code.
abstract final class ProjectSourcePolicy {
  static const version = 'source-v2';
  static const excludedDirectories = {
    '.git',
    '.ssh',
    '.aws',
    '.azure',
    '.kube',
    '.docker',
    '.local',
    '.dart_tool',
    'build',
    'node_modules',
    '.venv',
    'venv',
    '__pycache__',
    '.idea',
    '.gradle',
    'vendor',
    'dist',
    'coverage',
    '.next',
    '.cache',
  };
  static const extensions = {
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.tsx',
    '.jsx',
    '.json',
    '.yaml',
    '.yml',
    '.toml',
    '.ini',
    '.cfg',
    '.md',
    '.markdown',
    '.rst',
    '.txt',
    '.mdx',
    '.c',
    '.h',
    '.cpp',
    '.hpp',
    '.cc',
    '.rs',
    '.go',
    '.java',
    '.kt',
    '.swift',
    '.m',
    '.mm',
    '.sh',
    '.bash',
    '.sql',
    '.html',
    '.css',
    '.scss',
    '.xml',
    '.cmake',
    '.gradle',
    '.properties',
    '.rb',
    '.ex',
    '.exs',
    '.vue',
  };
  static const sensitiveNames = {
    '.netrc',
    '_netrc',
    '.git-credentials',
    '.gitcookies',
    '.npmrc',
    '.pypirc',
    '.dockercfg',
    '.pgpass',
    '.my.cnf',
    '.s3cfg',
    '.boto',
    '.vault-token',
    'id_rsa',
    'id_dsa',
    'id_ecdsa',
    'id_ed25519',
    'id_ecdsa_sk',
    'id_ed25519_sk',
    'credentials.json',
    'service-account.json',
    'application_default_credentials.json',
    'credentials.yaml',
    'credentials.yml',
    'secrets.json',
    'secrets.yaml',
    'secrets.yml',
  };
  static const sensitiveStores = [
    ['.aws', 'credentials'],
    ['.docker', 'config.json'],
    ['.kube', 'config'],
    ['.gem', 'credentials'],
    ['.bundle', 'config'],
    ['.config', 'gh'],
    ['.config', 'hub'],
    ['.config', 'gcloud'],
    ['.azure', 'accesstokens.json'],
    ['.azure', 'msal_token_cache.json'],
  ];

  static bool permits(String path) {
    if (path.isEmpty || p.posix.isAbsolute(path) || path.contains('\\')) {
      return false;
    }
    final parts = path.split('/');
    if (parts.any(
      (part) =>
          part.isEmpty ||
          part == '..' ||
          part == '.' ||
          excludedDirectories.contains(part.toLowerCase()),
    )) {
      return false;
    }
    final lower = parts.map((part) => part.toLowerCase()).toList();
    if (lower.any(
          (part) =>
              part.startsWith('.env') ||
              sensitiveNames.contains(part) ||
              ['.pem', '.key', '.keystore', '.jks'].any(part.endsWith),
        ) ||
        sensitiveStores.any(
          (store) => List.generate(lower.length, (i) => i).any(
            (i) =>
                i + store.length <= lower.length &&
                List.generate(
                  store.length,
                  (j) => j,
                ).every((j) => lower[i + j] == store[j]),
          ),
        )) {
      return false;
    }
    final name = lower.last;
    if ({'pubspec.lock', 'package-lock.json', 'yarn.lock'}.contains(name)) {
      return false;
    }
    return extensions.contains(p.posix.extension(name)) ||
        {
          'readme',
          'license',
          'copying',
          'makefile',
          'dockerfile',
          'cmakelists.txt',
          '.gitignore',
          '.gitattributes',
          '.editorconfig',
          '.dockerignore',
          '.prettierrc',
          '.eslintrc',
          '.tool-versions',
        }.contains(name);
  }
}

final class ProjectSourceSnapshot {
  ProjectSourceSnapshot(this.documents, this.excluded);
  final List<RagDocument> documents;
  final List<String> excluded;
  String get revision =>
      ragHash(documents.map((d) => '${d.source}:${d.revision}').join('\n'));
}

Future<ProjectSourceSnapshot> scanProjectSources(
  String root,
  CancellationToken token, {
  int maxFileBytes = 512 * 1024,
  int maxTotalBytes = 20 * 1024 * 1024,
}) async {
  final docs = <RagDocument>[];
  final excluded = <String>[];
  var total = 0;
  Future<void> walk(Directory dir) async {
    final entries = await dir.list(followLinks: false).toList();
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entries) {
      checkRagCancellation(token.isCancelled);
      final path = p
          .relative(entity.path, from: root)
          .split(p.separator)
          .join('/');
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (!ProjectSourcePolicy.excludedDirectories.contains(
          name.toLowerCase(),
        )) {
          await walk(entity);
        }
      } else if (entity is File && ProjectSourcePolicy.permits(path)) {
        if (await entity.length() > maxFileBytes) {
          excluded.add('$path: exceeds file byte limit');
          continue;
        }
        final bytes = await entity.readAsBytes();
        String text;
        try {
          text = utf8.decode(bytes);
        } on FormatException {
          excluded.add('$path: not UTF-8');
          continue;
        }
        if (text.contains('\u0000')) {
          excluded.add('$path: binary');
          continue;
        }
        total += bytes.length;
        if (total > maxTotalBytes) {
          throw StateError(
            'Source corpus exceeds $maxTotalBytes bytes; narrow the workspace.',
          );
        }
        if (text.trim().isNotEmpty) {
          docs.add(
            RagDocument(
              source: path,
              title: path,
              text: text,
              sourceRevision: 'sha256:${ragHash(text)}',
            ),
          );
        }
      }
    }
  }

  await walk(Directory(root));
  return ProjectSourceSnapshot(
    List.unmodifiable(docs),
    List.unmodifiable(excluded),
  );
}
