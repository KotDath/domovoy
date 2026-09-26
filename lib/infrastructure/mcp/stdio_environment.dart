/// Builds the minimal environment for a spawned stdio MCP server process.
///
/// The child must not inherit the whole application environment: it contains
/// LLM API keys, tokens and unrelated application state. Only a fixed allowlist
/// of operational variables is copied from the parent, plus explicitly
/// configured values and secure-storage references resolved at connect time.
library;

/// Variables copied from the parent process on Unix-like systems.
const unixStdioEnvironmentAllowlist = <String>[
  'PATH',
  'HOME',
  'TMPDIR',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
];

/// Variables copied from the parent process on Windows.
const windowsStdioEnvironmentAllowlist = <String>[
  'PATH',
  'PATHEXT',
  'SystemRoot',
  'SystemDrive',
  'WINDIR',
  'ComSpec',
  'TEMP',
  'TMP',
  'USERPROFILE',
  'HOMEDRIVE',
  'HOMEPATH',
  'NUMBER_OF_PROCESSORS',
  'PROCESSOR_ARCHITECTURE',
];

/// Returns the environment for one stdio server process.
///
/// [explicit] values come from the persisted connection configuration;
/// [secretValues] were resolved from secure storage immediately before the
/// spawn and are never persisted.
Map<String, String> buildStdioEnvironment({
  required Map<String, String> parent,
  required Map<String, String> explicit,
  required Map<String, String> secretValues,
  required bool windows,
}) {
  final allowlist = windows
      ? windowsStdioEnvironmentAllowlist
      : unixStdioEnvironmentAllowlist;
  final result = <String, String>{};
  for (final name in allowlist) {
    final value = parent[name];
    if (value != null && value.isNotEmpty) {
      result[name] = value;
    }
  }
  if (windows) {
    for (final name in <String>[...explicit.keys, ...secretValues.keys]) {
      result.removeWhere((key, _) => key.toLowerCase() == name.toLowerCase());
    }
  }
  result.addAll(explicit);
  result.addAll(secretValues);
  return Map<String, String>.unmodifiable(result);
}
