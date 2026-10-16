import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/llm/cancellation.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/project_context.dart';
import '../../../core/rag/models.dart';
import 'git_object_verifier_io.dart';

/// No Flutter, path_provider or shell dependency. The caller authorizes roots.
final class LocalProjectContextService implements ProjectContextService {
  const LocalProjectContextService({
    required this.resolveRoot,
    this.documentationRoots = const {'docs', 'doc', 'documentation'},
  });
  final Set<String> documentationRoots;
  final Future<String> Function(ProjectId) resolveRoot;
  static const maxArchiveBytes = 128 * 1024 * 1024;
  static const excluded = {
    '.git',
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
    '.env',
  };

  @override
  Future<List<RagDocument>> scanDocumentation(
    ProjectId project,
    CancellationToken cancellation,
  ) async {
    final root = await resolveRoot(project);
    final docs = <RagDocument>[];
    var total = 0;
    Future<void> walk(Directory directory, {bool documentation = false}) async {
      await for (final entity in directory.list(followLinks: false)) {
        checkRagCancellation(cancellation.isCancelled);
        final name = p.basename(entity.path);
        final lower = name.toLowerCase();
        if (excluded.contains(lower) ||
            lower.startsWith('.') ||
            lower.endsWith('.pem') ||
            lower.endsWith('.key')) {
          continue;
        }
        if (entity is Directory) {
          if (documentation || documentationRoots.contains(lower)) {
            await walk(entity, documentation: true);
          }
        } else if (entity is File) {
          final readme = RegExp(
            r'^readme(?:\.[a-z0-9_-]+)*$',
            caseSensitive: false,
          ).hasMatch(name);
          if (!readme &&
              !(documentation &&
                  {
                    '.md',
                    '.markdown',
                    '.rst',
                    '.txt',
                    '.mdx',
                  }.contains(p.extension(lower)))) {
            continue;
          }
          if (await entity.length() > 2 * 1024 * 1024) {
            throw StateError(
              'Documentation file exceeds 2 MiB: ${p.relative(entity.path, from: root)}',
            );
          }
          final bytes = await entity.readAsBytes();
          total += bytes.length;
          if (total > 4 * 1024 * 1024 || docs.length >= 1000) {
            throw StateError(
              'Project documentation exceeds 4 MiB / 1000 files; narrow the docs tree.',
            );
          }
          final text = utf8.decode(bytes);
          if (text.contains('\u0000')) {
            throw const FormatException('Binary documentation is unsupported');
          }
          if (text.trim().isEmpty) continue;
          final path = p
              .relative(entity.path, from: root)
              .split(p.separator)
              .join('/');
          docs.add(
            RagDocument(
              source: path,
              title: path,
              text: text,
              sourceRevision: 'sha256:${ragHash(RagDocument.normalize(text))}',
            ),
          );
        }
      }
    }

    await walk(Directory(root));
    docs.sort((a, b) => a.source.compareTo(b.source));
    checkRagCancellation(cancellation.isCancelled);
    return docs;
  }

  Future<String> _safe(String root, String path) async {
    final absolute = p.normalize(p.absolute(path));
    if (!p.isWithin(root, absolute)) {
      throw const FormatException('Git pointer outside authorized project');
    }
    final resolved = await FileSystemEntity.isDirectory(absolute)
        ? await Directory(absolute).resolveSymbolicLinks()
        : await File(absolute).resolveSymbolicLinks();
    if (resolved != absolute || !p.isWithin(root, resolved)) {
      throw const FormatException('Unsafe Git metadata link');
    }
    return absolute;
  }

  Future<String> _metadata(String root, String path) async {
    final safe = await _safe(root, path);
    final file = File(safe);
    if (await file.length() > 65536) {
      throw const FormatException('Git metadata too large');
    }
    return (await file.readAsString()).trim();
  }

  @override
  Future<ProjectGitContext> gitContext(ProjectId project) async {
    final root = await Directory(
      await resolveRoot(project),
    ).resolveSymbolicLinks();
    var git = p.join(root, '.git');
    final type = await FileSystemEntity.type(git, followLinks: false);
    if (type == FileSystemEntityType.file) {
      final pointer = await _metadata(root, git);
      if (!pointer.startsWith('gitdir: ')) {
        throw const FormatException('Invalid gitfile');
      }
      git = p.normalize(p.join(root, pointer.substring(8)));
    } else if (type != FileSystemEntityType.directory) {
      throw const FormatException(
        'No supported Git repository in selected project',
      );
    }
    git = await _safe(root, git);
    var common = git;
    if (await File(p.join(git, 'commondir')).exists()) {
      common = await _safe(
        root,
        p.join(git, await _metadata(root, p.join(git, 'commondir'))),
      );
    }
    final head = await _metadata(root, p.join(git, 'HEAD'));
    final oid = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');
    if (oid.hasMatch(head)) {
      await _verifyObjects(root, common, head);
      return ProjectGitContext(head: head);
    }
    if (!head.startsWith('ref: refs/heads/')) {
      throw const FormatException('Unsupported Git HEAD');
    }
    final ref = head.substring(5);
    if (ref.contains('..') ||
        ref.contains('\\') ||
        ref.contains(RegExp(r'[\s~^:?*\[\x00-\x1f]')) ||
        ref.endsWith('/')) {
      throw const FormatException('Invalid Git ref');
    }
    String? commit;
    final loose = File(p.join(common, ref));
    if (await loose.exists()) commit = await _metadata(root, loose.path);
    if (commit == null && await File(p.join(common, 'packed-refs')).exists()) {
      final packedFile = File(await _safe(root, p.join(common, 'packed-refs')));
      if (await packedFile.length() > 4 * 1024 * 1024) {
        throw const FormatException('Packed refs too large');
      }
      for (final row in const LineSplitter().convert(
        await packedFile.readAsString(),
      )) {
        if (row.endsWith(' $ref')) commit = row.split(' ').first;
      }
    }
    if (commit == null || !oid.hasMatch(commit)) {
      throw const FormatException('Git branch has no valid commit');
    }
    await _verifyObjects(root, common, commit);
    return ProjectGitContext(head: commit, branch: ref.substring(11));
  }

  Future<void> _verifyObjects(String root, String common, String head) async {
    final config = await _metadata(root, p.join(common, 'config'));
    var section = '', format = 'sha1';
    for (final line in const LineSplitter().convert(config)) {
      final value = line.trim();
      if (value.startsWith('[') && value.endsWith(']')) {
        section = value.substring(1, value.length - 1).trim().toLowerCase();
      } else if (section == 'extensions') {
        final match = RegExp(
          r'^objectformat\s*=\s*(\S+)$',
          caseSensitive: false,
        ).firstMatch(value);
        if (match != null) format = match[1]!.toLowerCase();
      }
    }
    if (!{'sha1', 'sha256'}.contains(format) ||
        head.length != (format == 'sha1' ? 40 : 64)) {
      throw const FormatException('Unsupported/incoherent Git object format');
    }
    final shallow = <String>{};
    if (await File(p.join(common, 'shallow')).exists()) {
      final text = await _metadata(root, p.join(common, 'shallow'));
      for (final oid in const LineSplitter().convert(text)) {
        if (!RegExp('^[0-9a-f]{${head.length}}\$').hasMatch(oid)) {
          throw const FormatException('Invalid shallow boundary');
        }
        shallow.add(oid);
      }
    }
    await GitObjectVerifier(
      objects: p.join(common, 'objects'),
      safePath: (path) => _safe(root, path),
    ).verify(head, shallow);
  }

  /// Uncompressed USTAR only: fixed input/output bounds and no archive links.
  /// Extract privately, then publish the complete checkout with one rename.
  @override
  Future<void> importArchive(
    ProjectId project,
    List<int> bytes,
    CancellationToken cancellation,
  ) async {
    if (bytes.length > maxArchiveBytes ||
        bytes.length < 1024 ||
        bytes.length % 512 != 0) {
      throw const FormatException('Use a USTAR .tar archive up to 128 MiB');
    }
    final root = await resolveRoot(project);
    if (!await Directory(root).list().isEmpty) {
      throw StateError(
        'Import requires an empty project; create a new project.',
      );
    }
    final stage = await Directory(
      p.dirname(root),
    ).createTemp('.project-import-');
    try {
      var offset = 0, count = 0, total = 0;
      final seen = <String>{};
      var terminated = false;
      while (offset + 512 <= bytes.length) {
        checkRagCancellation(cancellation.isCancelled);
        final h = bytes.sublist(offset, offset + 512);
        if (h.every((b) => b == 0)) {
          if (offset + 1024 > bytes.length ||
              bytes.skip(offset).any((b) => b != 0)) {
            throw const FormatException('Invalid archive terminator');
          }
          terminated = true;
          break;
        }
        String field(int start, int length) => utf8.decode(
          h.sublist(start, start + length).takeWhile((b) => b != 0).toList(),
        );
        int octal(int start, int length) =>
            int.parse(field(start, length).trim(), radix: 8);
        final checksum = octal(148, 8);
        var sum = 0;
        for (var i = 0; i < 512; i++) {
          sum += i >= 148 && i < 156 ? 32 : h[i];
        }
        if (sum != checksum || field(257, 5) != 'ustar') {
          throw const FormatException('Invalid USTAR header/checksum');
        }
        final prefix = field(345, 155);
        final raw = '${prefix.isEmpty ? '' : '$prefix/'}${field(0, 100)}';
        final path = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
        final parts = path.split('/');
        if (path.isEmpty ||
            path.contains('\\') ||
            path.contains(':') ||
            parts.any(
              (s) =>
                  s.isEmpty ||
                  s == '.' ||
                  s == '..' ||
                  s.endsWith('.') ||
                  s.endsWith(' ') ||
                  RegExp(
                    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                    caseSensitive: false,
                  ).hasMatch(s),
            ) ||
            path.contains(RegExp(r'[\x00-\x1f]')) ||
            !seen.add(path.toLowerCase())) {
          throw const FormatException('Unsafe or duplicate archive path');
        }
        final size = octal(124, 12);
        final kind = h[156];
        if (!(kind == 0 || kind == 48 || kind == 53) ||
            (kind == 53 && size != 0)) {
          throw const FormatException(
            'Archive links and special entries are forbidden',
          );
        }
        total += size;
        if (++count > 30000 ||
            size > 32 * 1024 * 1024 ||
            total > maxArchiveBytes ||
            size < 0 ||
            offset + 512 + size > bytes.length) {
          throw const FormatException('Archive exceeds extraction limits');
        }
        final target = p.joinAll([stage.path, ...parts]);
        if (kind == 53) {
          await Directory(target).create(recursive: true);
        } else {
          await File(target).parent.create(recursive: true);
          await File(
            target,
          ).writeAsBytes(bytes.sublist(offset + 512, offset + 512 + size));
        }
        offset += 512 + ((size + 511) ~/ 512) * 512;
      }
      if (!terminated) throw const FormatException('Truncated archive');
      // Imported checkouts must be standalone; host gitdir/alternates never work.
      if (await FileSystemEntity.type(
                p.join(stage.path, '.git'),
                followLinks: false,
              ) !=
              FileSystemEntityType.directory ||
          !await Directory(p.join(stage.path, '.git', 'objects')).exists() ||
          !await File(p.join(stage.path, '.git', 'config')).exists() ||
          await File(
            p.join(stage.path, '.git', 'objects', 'info', 'alternates'),
          ).exists() ||
          await File(p.join(stage.path, '.git', 'commondir')).exists()) {
        throw const FormatException(
          'Archive must contain a standalone checkout with genuine .git',
        );
      }
      await LocalProjectContextService(
        resolveRoot: (_) async => stage.path,
      ).gitContext(project);
      checkRagCancellation(cancellation.isCancelled);
      if (!await Directory(root).list().isEmpty) {
        throw StateError('Project changed during import');
      }
      await Directory(root).delete();
      try {
        await stage.rename(root);
      } on Object {
        await Directory(root).create();
        rethrow;
      }
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }
}
