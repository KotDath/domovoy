/// Platform policy for offering third-party stdio MCP servers.
library;

/// Reason B9 should pass when composing an Aurora build.
///
/// Aurora can report `Platform.operatingSystem == 'linux'` and
/// `Platform.isLinux == true`, so Dart platform facts alone cannot exclude it.
const auroraStdioDisabledReason =
    'Third-party stdio MCP servers are not confirmed on Aurora.';

/// True when spawning external MCP server processes may be offered.
///
/// [disabledByPolicy] is the explicit composition override: B9 sets it on
/// platforms Dart cannot classify reliably (Aurora reporting as Linux) from
/// its own build target detection. Automatic Aurora detection is not claimed:
/// `isLinux` is derived from `operatingSystem == 'linux'` by the Dart runtime,
/// so a device that reports `linux` is allowed here unless the override says
/// otherwise.
///
/// Built-in servers keep working through the in-process stream fallback
/// everywhere.
bool supportsStdioOnPlatform({
  required String operatingSystem,
  required bool isLinux,
  required bool isWindows,
  required bool isMacOS,
  bool disabledByPolicy = false,
}) {
  if (disabledByPolicy) {
    return false;
  }
  if (isWindows || isMacOS) {
    return true;
  }
  if (!isLinux) {
    return false;
  }
  // Runtimes that expose a distinct Aurora OS string are excluded directly.
  return operatingSystem.toLowerCase() != 'aurora';
}
