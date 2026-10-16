import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/llm/cancellation.dart';
import '../../core/rag/models.dart';

/// One policy for indexing and read-tool admission. Symlinks are never followed.
/// This is a text-source policy, not a claim to detect secrets in arbitrary code.
abstract final class ProjectSourcePolicy {
  static const version = 'source-v1';
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
    final name = parts.last.toLowerCase();
    if (name == '.env' ||
        name.startsWith('.env.') ||
        {'.netrc', '.npmrc', '.pypirc', '.git-credentials'}.contains(name) ||
        path.startsWith('.config/gh/') ||
        path.startsWith('.config/gcloud/')) {
      return false;
    }
    if ({
      'pubspec.lock',
      'package-lock.json',
      'yarn.lock',
      'credentials.json',
      'credentials.yaml',
      'credentials.yml',
      'secrets.json',
      'secrets.yaml',
      'secrets.yml',
      'id_rsa',
      'id_ed25519',
      'id_ecdsa',
      'id_dsa',
    }.contains(name)) {
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
