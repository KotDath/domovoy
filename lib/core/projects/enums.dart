enum ProjectLifecycle { active, deleting }

enum ProjectRootKind { externalGrant, appSandbox }

enum DirectoryGrantRole { root, additional }

enum DirectoryGrantAccess { readWrite, readOnly }

enum DirectoryGrantOrigin { attached, created }

enum ProjectPlatformKind { linux, windows, macos, android, ios, web }

enum ProjectAccessStatus {
  active,
  requiresRegrant,
  revoked,
  missing,
  unsupported,
  corrupt,
  unverifiable,
}

enum ProjectDesktopRootMode { attachExisting, createExclusive }

extension ProjectLifecycleCodec on ProjectLifecycle {
  static ProjectLifecycle parse(String name) {
    return ProjectLifecycle.values.firstWhere(
      (value) => value.name == name,
      orElse: () => throw FormatException('Unknown project lifecycle "$name".'),
    );
  }
}

extension ProjectRootKindCodec on ProjectRootKind {
  static ProjectRootKind parse(String name) {
    return ProjectRootKind.values.firstWhere(
      (value) => value.name == name,
      orElse: () => throw FormatException('Unknown project root kind "$name".'),
    );
  }
}

extension DirectoryGrantRoleCodec on DirectoryGrantRole {
  static DirectoryGrantRole parse(String name) {
    return DirectoryGrantRole.values.firstWhere(
      (value) => value.name == name,
      orElse: () => throw FormatException('Unknown grant role "$name".'),
    );
  }
}

extension DirectoryGrantAccessCodec on DirectoryGrantAccess {
  static DirectoryGrantAccess parse(String name) {
    return DirectoryGrantAccess.values.firstWhere(
      (value) => value.name == name,
      orElse: () => throw FormatException('Unknown grant access "$name".'),
    );
  }
}

extension DirectoryGrantOriginCodec on DirectoryGrantOrigin {
  static DirectoryGrantOrigin parse(String name) {
    return DirectoryGrantOrigin.values.firstWhere(
      (value) => value.name == name,
      orElse: () => throw FormatException('Unknown grant origin "$name".'),
    );
  }
}

extension ProjectPlatformKindCodec on ProjectPlatformKind {
  static ProjectPlatformKind parse(String name) {
    return ProjectPlatformKind.values.firstWhere(
      (value) => value.name == name,
      orElse: () =>
          throw FormatException('Unknown project platform kind "$name".'),
    );
  }

  bool get isDesktop =>
      this == ProjectPlatformKind.linux ||
      this == ProjectPlatformKind.windows ||
      this == ProjectPlatformKind.macos;

  bool get isMobileSandbox =>
      this == ProjectPlatformKind.android || this == ProjectPlatformKind.ios;

  bool get treatsPathsCaseInsensitive =>
      this == ProjectPlatformKind.windows || this == ProjectPlatformKind.macos;
}
