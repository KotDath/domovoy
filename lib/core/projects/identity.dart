import 'enums.dart';

final class CanonicalDirectoryIdentity {
  CanonicalDirectoryIdentity({
    required List<String> components,
    required this.platformKind,
    required this.fingerprint,
    this.volume,
    this.isLink = false,
    this.isReparsePoint = false,
    this.isDirectory = true,
  }) : components = List<String>.unmodifiable(List<String>.from(components));

  final List<String> components;
  final ProjectPlatformKind platformKind;
  final String fingerprint;
  final String? volume;
  final bool isLink;
  final bool isReparsePoint;
  final bool isDirectory;

  List<String> get comparisonComponents {
    if (!platformKind.treatsPathsCaseInsensitive) {
      return components;
    }
    return [for (final component in components) component.toLowerCase()];
  }

  bool get isUsableRoot =>
      isDirectory && !isLink && !isReparsePoint && components.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanonicalDirectoryIdentity &&
          other.fingerprint == fingerprint &&
          other.platformKind == platformKind;

  @override
  int get hashCode => Object.hash(fingerprint, platformKind);

  @override
  String toString() => 'CanonicalDirectoryIdentity($fingerprint)';
}

String fingerprintForComponents(
  List<String> components, {
  required ProjectPlatformKind platformKind,
  String? volume,
}) {
  final normalized = platformKind.treatsPathsCaseInsensitive
      ? components.map((part) => part.toLowerCase()).join('\u0000')
      : components.join('\u0000');
  final source = '${platformKind.name}\u0000${volume ?? ''}\u0000$normalized';
  var hash = 2166136261;
  for (final code in source.codeUnits) {
    hash ^= code;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

bool identitiesOverlap(
  CanonicalDirectoryIdentity left,
  CanonicalDirectoryIdentity right,
) {
  if (left.platformKind != right.platformKind) {
    return false;
  }
  if (left.volume != right.volume) {
    return false;
  }
  final a = left.comparisonComponents;
  final b = right.comparisonComponents;
  if (_equal(a, b)) {
    return true;
  }
  return _isPrefix(a, b) || _isPrefix(b, a);
}

bool identityContains(
  CanonicalDirectoryIdentity ancestor,
  CanonicalDirectoryIdentity descendant,
) {
  if (ancestor.platformKind != descendant.platformKind ||
      ancestor.volume != descendant.volume) {
    return false;
  }
  return _isPrefix(
    ancestor.comparisonComponents,
    descendant.comparisonComponents,
  );
}

bool _equal(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i += 1) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

bool _isPrefix(List<String> prefix, List<String> full) {
  if (prefix.length >= full.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i += 1) {
    if (prefix[i] != full[i]) {
      return false;
    }
  }
  return true;
}
