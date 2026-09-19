final _pathLike = RegExp(r'(/[^ \n]+)|([A-Za-z]:\\[^ \n]+)|(\\\\[^ \n]+)');
final _tokenLike = RegExp(
  r'(bookmark|handle|token|capability|security[-_ ]?scope)[=:][^\s]+',
  caseSensitive: false,
);
final _base64Like = RegExp(r'[A-Za-z0-9+/_-]{48,}={0,2}');

String redactUnsafeProjectText(String source, {required String fallback}) {
  if (_pathLike.hasMatch(source) ||
      _tokenLike.hasMatch(source) ||
      _base64Like.hasMatch(source)) {
    return fallback;
  }
  return source;
}

bool jsonContainsUnsafeProjectMaterial(Object? json) {
  if (json is Map) {
    for (final entry in json.entries) {
      final key = entry.key;
      if (key is String) {
        final lower = key.toLowerCase();
        if (_unsafeKeys.contains(lower)) {
          return true;
        }
      }
      if (jsonContainsUnsafeProjectMaterial(entry.value)) {
        return true;
      }
    }
    return false;
  }
  if (json is List) {
    return json.any(jsonContainsUnsafeProjectMaterial);
  }
  if (json is String) {
    return _pathLike.hasMatch(json) ||
        _tokenLike.hasMatch(json) ||
        _base64Like.hasMatch(json);
  }
  return false;
}

const _unsafeKeys = <String>{
  'path',
  'rawpath',
  'bookmark',
  'bookmarkdata',
  'handle',
  'token',
  'capability',
  'native',
  'securityscope',
  'securityscopedbookmark',
  'filesystem',
  'fd',
  'filedescriptor',
};
