import 'dart:convert';
import 'dart:io';

import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/grants.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/identity.dart';
import '../fs/desktop_filesystem.dart';
import 'macos_security_scope.dart';

typedef ProjectGrantDirectoryResolver = Future<Directory> Function();

/// Durable native-only storage for paths and security-scoped bookmarks.
///
/// This file is intentionally separate from Project/session JSONL storage: its
/// contents are capability material and must never cross the infrastructure
/// boundary.
final class FileProjectDirectoryGrantStore
    implements ProjectDirectoryGrantStore {
  FileProjectDirectoryGrantStore({
    required this.applicationSupportDirectoryResolver,
    required this.filesystem,
    required this.platformKind,
    this.macosScope,
  });

  static const namespaceDirectoryName = 'project-directory-grants-v1';

  final ProjectGrantDirectoryResolver applicationSupportDirectoryResolver;
  final DesktopFilesystem filesystem;
  final ProjectPlatformKind platformKind;
  final MacosSecurityScopeBroker? macosScope;

  Map<String, _DurableGrant>? _grants;
  Future<void>? _loading;

  @override
  Future<void> acknowledge(StagedDesktopGrant staged) async {
    await _ensureLoaded();
    final descriptor = staged.descriptor.withStatus(ProjectAccessStatus.active);
    final bookmark = platformKind == ProjectPlatformKind.macos
        ? macosScope?.bookmarkForFingerprint(staged.identity.fingerprint)
        : null;
    if (platformKind == ProjectPlatformKind.macos &&
        (bookmark == null || bookmark.isEmpty)) {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
    _grants![descriptor.grantId.value] = _DurableGrant(
      descriptor: descriptor,
      identity: staged.identity,
      nativePath: filesystem.pathForIdentity(staged.identity),
      bookmark: bookmark,
    );
    await _persist();
  }

  @override
  Future<DesktopGrantDescriptor> revalidate(DirectoryGrantId grantId) async {
    await _ensureLoaded();
    final stored = _grants![grantId.value];
    if (stored == null) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    return stored.descriptor;
  }

  @override
  Future<DesktopGrantDescriptor> regrant({
    required DirectoryGrantId grantId,
    required ProjectId projectId,
    required CanonicalDirectoryIdentity expectedIdentity,
  }) async {
    await _ensureLoaded();
    final stored = _grants![grantId.value];
    if (stored == null ||
        stored.descriptor.projectId != projectId ||
        stored.identity.fingerprint != expectedIdentity.fingerprint) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    final updated = _DurableGrant(
      descriptor: stored.descriptor.withStatus(ProjectAccessStatus.active),
      identity: expectedIdentity,
      nativePath: stored.nativePath,
      bookmark: stored.bookmark,
    );
    _grants![grantId.value] = updated;
    await _persist();
    return updated.descriptor;
  }

  @override
  Future<void> revoke(DirectoryGrantId grantId) async {
    await _ensureLoaded();
    final removed = _grants!.remove(grantId.value);
    if (removed?.bookmark case final bookmark?) {
      await macosScope?.revokeBookmark(bookmark);
    }
    await _persist();
  }

  @override
  Future<List<OrphanGrantRecord>> enumerateOrphans() async {
    await _ensureLoaded();
    return [
      for (final grant in _grants!.values)
        OrphanGrantRecord(
          grantId: grant.descriptor.grantId,
          projectId: grant.descriptor.projectId,
          origin: grant.descriptor.origin,
          fingerprint: grant.identity.fingerprint,
        ),
    ];
  }

  @override
  CanonicalDirectoryIdentity? identityFor(DirectoryGrantId grantId) =>
      _grants?[grantId.value]?.identity;

  String? nativePathFor(DirectoryGrantId grantId) =>
      _grants?[grantId.value]?.nativePath;

  String? bookmarkFor(DirectoryGrantId grantId) =>
      _grants?[grantId.value]?.bookmark;

  Future<void> _ensureLoaded() async {
    if (_grants != null) return;
    final existing = _loading;
    if (existing != null) return existing;
    final loading = _load();
    _loading = loading;
    try {
      await loading;
    } finally {
      _loading = null;
    }
  }

  Future<void> _load() async {
    try {
      final file = await _storeFile(createParent: false);
      if (!await file.exists()) {
        _grants = <String, _DurableGrant>{};
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> || decoded['version'] != 1) {
        throw const FormatException('Unsupported grant store.');
      }
      final entries = decoded['grants'];
      if (entries is! List<Object?>) {
        throw const FormatException('Invalid grants.');
      }
      final loaded = <String, _DurableGrant>{};
      for (final entry in entries) {
        final grant = _DurableGrant.fromJson(entry, platformKind);
        if (loaded.containsKey(grant.descriptor.grantId.value)) {
          throw const FormatException('Duplicate grant.');
        }
        loaded[grant.descriptor.grantId.value] = grant;
        if (grant.bookmark case final bookmark?) {
          macosScope?.registerBookmark(grant.identity.fingerprint, bookmark);
        }
      }
      _grants = loaded;
    } on ProjectException {
      rethrow;
    } on Object {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
  }

  Future<void> _persist() async {
    try {
      final file = await _storeFile(createParent: true);
      final temporary = File('${file.path}.tmp');
      final payload = jsonEncode(<String, Object?>{
        'version': 1,
        'grants': [for (final grant in _grants!.values) grant.toJson()],
      });
      await temporary.writeAsString(payload, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } on Object {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
  }

  Future<File> _storeFile({required bool createParent}) async {
    final support = await applicationSupportDirectoryResolver();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}$namespaceDirectoryName',
    );
    if (createParent) await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}grants.json');
  }
}

final class _DurableGrant {
  const _DurableGrant({
    required this.descriptor,
    required this.identity,
    required this.nativePath,
    this.bookmark,
  });

  factory _DurableGrant.fromJson(
    Object? value,
    ProjectPlatformKind expectedPlatform,
  ) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Invalid grant entry.');
    }
    T enumValue<T extends Enum>(List<T> values, String key) {
      final raw = value[key];
      return values.firstWhere(
        (item) => item.name == raw,
        orElse: () => throw FormatException('Invalid $key.'),
      );
    }

    final platform = enumValue(ProjectPlatformKind.values, 'platform');
    if (platform != expectedPlatform) {
      throw const FormatException('Grant platform mismatch.');
    }
    final components = value['components'];
    if (components is! List<Object?> ||
        components.any((component) => component is! String)) {
      throw const FormatException('Invalid identity components.');
    }
    final identity = CanonicalDirectoryIdentity(
      components: components.cast<String>(),
      platformKind: platform,
      fingerprint: value['fingerprint'] as String,
      volume: value['volume'] as String?,
    );
    final descriptor = DesktopGrantDescriptor(
      grantId: DirectoryGrantId(value['grantId'] as String),
      projectId: ProjectId(value['projectId'] as String),
      role: enumValue(DirectoryGrantRole.values, 'role'),
      requestedAccess: enumValue(DirectoryGrantAccess.values, 'access'),
      origin: enumValue(DirectoryGrantOrigin.values, 'origin'),
      safeDisplayLabel: value['label'] as String,
      canonicalFingerprint: value['fingerprint'] as String,
      platformKind: platform,
      createdAtMicros: value['createdAtMicros'] as int,
      updatedAtMicros: value['updatedAtMicros'] as int,
      status: enumValue(ProjectAccessStatus.values, 'status'),
    );
    return _DurableGrant(
      descriptor: descriptor,
      identity: identity,
      nativePath: value['nativePath'] as String,
      bookmark: value['bookmark'] as String?,
    );
  }

  final DesktopGrantDescriptor descriptor;
  final CanonicalDirectoryIdentity identity;
  final String nativePath;
  final String? bookmark;

  Map<String, Object?> toJson() => <String, Object?>{
    'grantId': descriptor.grantId.value,
    'projectId': descriptor.projectId.value,
    'role': descriptor.role.name,
    'access': descriptor.requestedAccess.name,
    'origin': descriptor.origin.name,
    'label': descriptor.safeDisplayLabel,
    'fingerprint': identity.fingerprint,
    'platform': descriptor.platformKind.name,
    'createdAtMicros': descriptor.createdAtMicros,
    'updatedAtMicros': descriptor.updatedAtMicros,
    'status': descriptor.status.name,
    'components': identity.components,
    'volume': identity.volume,
    'nativePath': nativePath,
    if (bookmark != null) 'bookmark': bookmark,
  };
}
