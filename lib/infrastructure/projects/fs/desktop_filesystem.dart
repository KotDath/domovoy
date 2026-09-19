import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/identity.dart';
import 'filesystem_ops.dart';

abstract interface class DesktopFilesystem {
  ProjectFilesystemOpLog get opLog;

  Future<CanonicalDirectoryIdentity> canonicalize(String path);

  Future<CanonicalDirectoryIdentity> inspect(String path);

  Future<CanonicalDirectoryIdentity> revalidateIdentity(
    CanonicalDirectoryIdentity identity,
  );

  Future<bool> hasAccess(
    CanonicalDirectoryIdentity identity,
    DirectoryGrantAccess access,
  );

  String pathForIdentity(CanonicalDirectoryIdentity identity);

  Future<bool> exists(CanonicalDirectoryIdentity identity);

  Future<bool> isEmpty(CanonicalDirectoryIdentity identity);

  Future<CanonicalDirectoryIdentity> createExclusiveChild({
    required CanonicalDirectoryIdentity parent,
    required String folderName,
  });

  Future<void> deleteIfEmpty(CanonicalDirectoryIdentity identity);
}

final class MemoryDirectoryNode {
  MemoryDirectoryNode({
    required this.identity,
    this.isDirectory = true,
    this.isLink = false,
    this.isReparsePoint = false,
    this.children = const <String, MemoryDirectoryNode>{},
    this.target,
  });

  CanonicalDirectoryIdentity identity;
  bool isDirectory;
  bool isLink;
  bool isReparsePoint;
  Map<String, MemoryDirectoryNode> children;
  CanonicalDirectoryIdentity? target;
}

final class FakeDesktopFilesystem implements DesktopFilesystem {
  FakeDesktopFilesystem({
    required this.platformKind,
    this.sandboxPrefix = const <String>['sandbox'],
  });

  final ProjectPlatformKind platformKind;
  final List<String> sandboxPrefix;
  final Map<String, MemoryDirectoryNode> nodes =
      <String, MemoryDirectoryNode>{};
  @override
  final ProjectFilesystemOpLog opLog = ProjectFilesystemOpLog();
  final Map<String, String> handlePaths = <String, String>{};

  void mount({
    required List<String> components,
    bool isDirectory = true,
    bool isLink = false,
    bool isReparsePoint = false,
    String? volume,
    CanonicalDirectoryIdentity? target,
  }) {
    final identity = _identity(
      components,
      volume: volume,
      isDirectory: isDirectory,
      isLink: isLink,
      isReparsePoint: isReparsePoint,
    );
    nodes[_key(identity)] = MemoryDirectoryNode(
      identity: identity,
      isDirectory: isDirectory,
      isLink: isLink,
      isReparsePoint: isReparsePoint,
      children: <String, MemoryDirectoryNode>{},
      target: target,
    );
  }

  void bindHandle(String handleId, List<String> components, {String? volume}) {
    handlePaths[handleId] = _join(components, volume: volume);
  }

  String pathForHandle(String handleId) {
    final path = handlePaths[handleId];
    if (path == null) {
      throwProject(ProjectErrorKind.cancelled, 'cancelled');
    }
    return path;
  }

  @override
  Future<CanonicalDirectoryIdentity> inspect(String path) async {
    opLog.add(ProjectFilesystemOpKind.stat, detail: 'inspect');
    final parsed = _parse(path);
    final node = nodes[_key(parsed)];
    if (node == null) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    return node.identity;
  }

  @override
  Future<CanonicalDirectoryIdentity> canonicalize(String path) async {
    opLog.add(ProjectFilesystemOpKind.canonicalize);
    final inspected = await inspect(path);
    if (!inspected.isDirectory) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    if (inspected.isLink || inspected.isReparsePoint) {
      final node = nodes[_key(inspected)];
      if (node?.target != null) {
        opLog.add(ProjectFilesystemOpKind.stat, detail: 'follow-link');
        return node!.target!;
      }
      throw ProjectException(sanitizedProjectAccessError());
    }
    return inspected;
  }

  @override
  Future<CanonicalDirectoryIdentity> revalidateIdentity(
    CanonicalDirectoryIdentity identity,
  ) async {
    opLog.add(ProjectFilesystemOpKind.canonicalize, detail: 'revalidate');
    final node = nodes[_key(identity)];
    if (node == null || !node.identity.isUsableRoot || node.target != null) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    return node.identity;
  }

  @override
  Future<bool> hasAccess(
    CanonicalDirectoryIdentity identity,
    DirectoryGrantAccess access,
  ) async => nodes[_key(identity)]?.identity.isUsableRoot ?? false;

  @override
  String pathForIdentity(CanonicalDirectoryIdentity identity) =>
      _join(identity.components, volume: identity.volume);

  void addLeaf(List<String> parentComponents, String name, {String? volume}) {
    final parent = _identity(parentComponents, volume: volume);
    final parentNode = nodes[_key(parent)];
    if (parentNode == null) {
      return;
    }
    final child = _identity([...parentComponents, name], volume: volume);
    final node = MemoryDirectoryNode(identity: child, isDirectory: false);
    parentNode.children[name] = node;
    nodes[_key(child)] = node;
  }

  @override
  Future<bool> exists(CanonicalDirectoryIdentity identity) async {
    opLog.add(ProjectFilesystemOpKind.stat);
    return nodes.containsKey(_key(identity));
  }

  @override
  Future<bool> isEmpty(CanonicalDirectoryIdentity identity) async {
    opLog.add(ProjectFilesystemOpKind.list);
    final node = nodes[_key(identity)];
    if (node == null) {
      return false;
    }
    return node.children.isEmpty;
  }

  @override
  Future<CanonicalDirectoryIdentity> createExclusiveChild({
    required CanonicalDirectoryIdentity parent,
    required String folderName,
  }) async {
    opLog.add(ProjectFilesystemOpKind.createDirectory);
    final parentNode = nodes[_key(parent)];
    if (parentNode == null || !parentNode.isDirectory) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    if (parentNode.children.containsKey(folderName)) {
      throw ProjectException(sanitizedProjectCollisionError());
    }
    final child = _identity([
      ...parent.components,
      folderName,
    ], volume: parent.volume);
    final node = MemoryDirectoryNode(identity: child);
    parentNode.children[folderName] = node;
    nodes[_key(child)] = node;
    return child;
  }

  @override
  Future<void> deleteIfEmpty(CanonicalDirectoryIdentity identity) async {
    opLog.add(ProjectFilesystemOpKind.deleteDirectory);
    final node = nodes[_key(identity)];
    if (node == null) {
      return;
    }
    if (node.children.isNotEmpty) {
      throw ProjectException(sanitizedProjectCleanupWarning());
    }
    nodes.remove(_key(identity));
    for (final parent in nodes.values) {
      parent.children.removeWhere(
        (name, child) => _key(child.identity) == _key(identity),
      );
    }
  }

  CanonicalDirectoryIdentity _identity(
    List<String> components, {
    String? volume,
    bool isDirectory = true,
    bool isLink = false,
    bool isReparsePoint = false,
  }) {
    return CanonicalDirectoryIdentity(
      components: components,
      platformKind: platformKind,
      fingerprint: fingerprintForComponents(
        components,
        platformKind: platformKind,
        volume: volume,
      ),
      volume: volume,
      isDirectory: isDirectory,
      isLink: isLink,
      isReparsePoint: isReparsePoint,
    );
  }

  CanonicalDirectoryIdentity _parse(String path) {
    final windows = platformKind == ProjectPlatformKind.windows;
    var volume = null as String?;
    var rest = path;
    if (windows && RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      volume = path.substring(0, 2).toUpperCase();
      rest = path.substring(2);
    }
    final parts = rest
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return _identity(parts, volume: volume);
  }

  String _join(List<String> components, {String? volume}) {
    if (platformKind == ProjectPlatformKind.windows) {
      return '${volume ?? 'C:'}/${components.join('/')}';
    }
    return '/${components.join('/')}';
  }

  String _key(CanonicalDirectoryIdentity identity) =>
      '${identity.volume ?? ''}::${identity.comparisonComponents.join('/')}';
}

/// The production desktop adapter. It keeps paths behind the infrastructure
/// boundary and exposes only canonical identities to the domain layer.
final class IoDesktopFilesystem implements DesktopFilesystem {
  IoDesktopFilesystem({required this.platformKind})
    : assert(platformKind.isDesktop);

  final ProjectPlatformKind platformKind;
  final Map<String, String> _pathsByFingerprint = <String, String>{};

  @override
  final ProjectFilesystemOpLog opLog = ProjectFilesystemOpLog();

  p.Context get _context => p.Context(
    style: platformKind == ProjectPlatformKind.windows
        ? p.Style.windows
        : p.Style.posix,
  );

  @override
  Future<CanonicalDirectoryIdentity> inspect(String path) async {
    opLog.add(ProjectFilesystemOpKind.stat, detail: 'inspect');
    final absolute = _context.normalize(_context.absolute(path));
    if (!_context.isAbsolute(path)) {
      throw ProjectException(sanitizedProjectDeniedError());
    }
    final type = await FileSystemEntity.type(absolute, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw ProjectException(sanitizedProjectDeniedError());
    }
    final resolved = await Directory(absolute).resolveSymbolicLinks();
    final normalizedResolved = _context.normalize(resolved);
    final linkLike = !_samePath(absolute, normalizedResolved);
    final identity = _identity(
      normalizedResolved,
      isLink: linkLike && platformKind != ProjectPlatformKind.windows,
      isReparsePoint: linkLike && platformKind == ProjectPlatformKind.windows,
    );
    _pathsByFingerprint[identity.fingerprint] = normalizedResolved;
    return identity;
  }

  @override
  Future<CanonicalDirectoryIdentity> canonicalize(String path) async {
    opLog.add(ProjectFilesystemOpKind.canonicalize);
    final identity = await inspect(path);
    if (!identity.isUsableRoot) {
      throw ProjectException(sanitizedProjectDeniedError());
    }
    return identity;
  }

  @override
  Future<CanonicalDirectoryIdentity> revalidateIdentity(
    CanonicalDirectoryIdentity identity,
  ) async {
    final current = await canonicalize(pathForIdentity(identity));
    if (current.fingerprint != identity.fingerprint || !current.isUsableRoot) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    return current;
  }

  @override
  Future<bool> hasAccess(
    CanonicalDirectoryIdentity identity,
    DirectoryGrantAccess access,
  ) async {
    try {
      final stat = await Directory(pathForIdentity(identity)).stat();
      if (stat.type != FileSystemEntityType.directory) return false;
      if (platformKind == ProjectPlatformKind.windows) {
        return true;
      }
      final readable = stat.mode & 0x124 != 0;
      final writable = stat.mode & 0x92 != 0;
      return readable && (access == DirectoryGrantAccess.readOnly || writable);
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> exists(CanonicalDirectoryIdentity identity) async =>
      Directory(pathForIdentity(identity)).exists();

  @override
  Future<bool> isEmpty(CanonicalDirectoryIdentity identity) async {
    opLog.add(ProjectFilesystemOpKind.list);
    try {
      return await Directory(pathForIdentity(identity)).list().isEmpty;
    } on FileSystemException {
      throw ProjectException(sanitizedProjectAccessError());
    }
  }

  @override
  Future<CanonicalDirectoryIdentity> createExclusiveChild({
    required CanonicalDirectoryIdentity parent,
    required String folderName,
  }) async {
    opLog.add(ProjectFilesystemOpKind.createDirectory);
    if (folderName.isEmpty ||
        folderName == '.' ||
        folderName == '..' ||
        folderName.contains('/') ||
        folderName.contains('\\') ||
        folderName.contains('\u0000')) {
      throw ProjectException(sanitizedProjectDeniedError());
    }
    final path = _context.join(pathForIdentity(parent), folderName);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw ProjectException(sanitizedProjectCollisionError());
    }
    try {
      await Directory(path).create(recursive: false);
      return await canonicalize(path);
    } on FileSystemException {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw ProjectException(sanitizedProjectCollisionError());
      }
      throw ProjectException(sanitizedProjectAccessError());
    }
  }

  @override
  Future<void> deleteIfEmpty(CanonicalDirectoryIdentity identity) async {
    opLog.add(ProjectFilesystemOpKind.deleteDirectory);
    final directory = Directory(pathForIdentity(identity));
    try {
      if (!await directory.exists()) return;
      if (!(await directory.list().isEmpty)) {
        throw ProjectException(sanitizedProjectCleanupWarning());
      }
      await directory.delete(recursive: false);
      _pathsByFingerprint.remove(identity.fingerprint);
    } on ProjectException {
      rethrow;
    } on FileSystemException {
      throw ProjectException(sanitizedProjectCleanupWarning());
    }
  }

  @override
  String pathForIdentity(CanonicalDirectoryIdentity identity) {
    return _pathsByFingerprint[identity.fingerprint] ??
        _context.join(
          identity.volume ?? _context.rootPrefix('/'),
          _context.joinAll(identity.components),
        );
  }

  CanonicalDirectoryIdentity _identity(
    String path, {
    bool isLink = false,
    bool isReparsePoint = false,
  }) {
    final root = _context.rootPrefix(path);
    final relative = _context.relative(path, from: root);
    final components = _context
        .split(relative)
        .where((part) => part.isNotEmpty && part != '.')
        .toList(growable: false);
    final volume = platformKind == ProjectPlatformKind.windows
        ? root.replaceAll(RegExp(r'[\\/]+$'), '').toUpperCase()
        : null;
    return CanonicalDirectoryIdentity(
      components: components,
      platformKind: platformKind,
      fingerprint: fingerprintForComponents(
        components,
        platformKind: platformKind,
        volume: volume,
      ),
      volume: volume,
      isLink: isLink,
      isReparsePoint: isReparsePoint,
    );
  }

  bool _samePath(String left, String right) {
    if (platformKind.treatsPathsCaseInsensitive) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }
}
