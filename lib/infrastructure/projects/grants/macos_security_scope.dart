import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';

final class MacosBookmarkRestoreResult {
  const MacosBookmarkRestoreResult({required this.status, this.path});

  final ProjectAccessStatus status;
  final String? path;
}

abstract interface class MacosSecurityScopeBroker {
  bool get isAvailable;

  Future<String?> createBookmark({
    required String handleId,
    required String fingerprint,
  });

  Future<MacosBookmarkRestoreResult> restoreBookmark(String bookmark);

  Future<void> revokeBookmark(String bookmark);

  String? bookmarkForFingerprint(String fingerprint);

  void registerBookmark(String fingerprint, String bookmark);
}

final class FakeMacosSecurityScopeBroker implements MacosSecurityScopeBroker {
  FakeMacosSecurityScopeBroker({this.available = true});

  bool available;
  final Map<String, String> bookmarksByHandle = <String, String>{};
  final Map<String, String> fingerprintsByBookmark = <String, String>{};
  final Map<String, String> pathsByBookmark = <String, String>{};
  final Set<String> revoked = <String>{};
  final Set<String> stale = <String>{};
  int createCount = 0;
  int restoreCount = 0;
  int revokeCount = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<String?> createBookmark({
    required String handleId,
    required String fingerprint,
  }) async {
    createCount += 1;
    if (!available) {
      return null;
    }
    final bookmark = 'scope:$handleId';
    bookmarksByHandle[handleId] = bookmark;
    fingerprintsByBookmark[bookmark] = fingerprint;
    pathsByBookmark[bookmark] = handleId;
    return bookmark;
  }

  @override
  Future<MacosBookmarkRestoreResult> restoreBookmark(String bookmark) async {
    restoreCount += 1;
    if (!available) {
      return const MacosBookmarkRestoreResult(
        status: ProjectAccessStatus.unverifiable,
      );
    }
    if (revoked.contains(bookmark)) {
      return const MacosBookmarkRestoreResult(
        status: ProjectAccessStatus.revoked,
      );
    }
    if (stale.contains(bookmark)) {
      return const MacosBookmarkRestoreResult(
        status: ProjectAccessStatus.requiresRegrant,
      );
    }
    if (!fingerprintsByBookmark.containsKey(bookmark)) {
      return const MacosBookmarkRestoreResult(
        status: ProjectAccessStatus.missing,
      );
    }
    return MacosBookmarkRestoreResult(
      status: ProjectAccessStatus.active,
      path: pathsByBookmark[bookmark],
    );
  }

  @override
  Future<void> revokeBookmark(String bookmark) async {
    revokeCount += 1;
    revoked.add(bookmark);
    fingerprintsByBookmark.remove(bookmark);
    pathsByBookmark.remove(bookmark);
  }

  @override
  String? bookmarkForFingerprint(String fingerprint) {
    for (final entry in fingerprintsByBookmark.entries) {
      if (entry.value == fingerprint) {
        return entry.key;
      }
    }
    return null;
  }

  @override
  void registerBookmark(String fingerprint, String bookmark) {
    fingerprintsByBookmark[bookmark] = fingerprint;
  }
}

final class MethodChannelMacosSecurityScopeBroker
    implements MacosSecurityScopeBroker {
  MethodChannelMacosSecurityScopeBroker({
    MethodChannel channel = const MethodChannel(
      'ru.kotdath.domovoy/project_security_scope',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;
  final Map<String, String> _bookmarksByFingerprint = <String, String>{};

  @override
  bool get isAvailable => Platform.isMacOS;

  @override
  Future<String?> createBookmark({
    required String handleId,
    required String fingerprint,
  }) async {
    if (!isAvailable) return null;
    try {
      final bookmark = await _channel.invokeMethod<String>('createBookmark', {
        'path': handleId,
      });
      if (bookmark == null || bookmark.isEmpty) return null;
      _bookmarksByFingerprint[fingerprint] = bookmark;
      return bookmark;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<MacosBookmarkRestoreResult> restoreBookmark(String bookmark) async {
    if (!isAvailable) {
      return const MacosBookmarkRestoreResult(
        status: ProjectAccessStatus.unverifiable,
      );
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'restoreBookmark',
        {'bookmark': bookmark},
      );
      final statusName = result?['status'];
      final status = ProjectAccessStatus.values.firstWhere(
        (candidate) => candidate.name == statusName,
        orElse: () => ProjectAccessStatus.unverifiable,
      );
      return MacosBookmarkRestoreResult(
        status: status,
        path: result?['path'] as String?,
      );
    } on PlatformException {
      return const MacosBookmarkRestoreResult(
        status: ProjectAccessStatus.unverifiable,
      );
    } on MissingPluginException {
      return const MacosBookmarkRestoreResult(
        status: ProjectAccessStatus.unverifiable,
      );
    }
  }

  @override
  Future<void> revokeBookmark(String bookmark) async {
    _bookmarksByFingerprint.removeWhere((_, value) => value == bookmark);
    try {
      await _channel.invokeMethod<void>('revokeBookmark', {
        'bookmark': bookmark,
      });
    } on PlatformException {
      // Removing the durable bookmark is the fail-closed revocation boundary.
    } on MissingPluginException {
      // The durable store still removes the capability material.
    }
  }

  @override
  String? bookmarkForFingerprint(String fingerprint) =>
      _bookmarksByFingerprint[fingerprint];

  @override
  void registerBookmark(String fingerprint, String bookmark) {
    _bookmarksByFingerprint[fingerprint] = bookmark;
  }
}

Never failClosedWithoutMacosScope() {
  throw ProjectException(
    ProjectError(
      kind: ProjectErrorKind.unverifiable,
      message: 'macOS security-scoped access is unavailable.',
    ),
  );
}
