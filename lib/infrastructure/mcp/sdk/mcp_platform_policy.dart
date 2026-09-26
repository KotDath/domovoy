/// Platform policy for offering third-party stdio MCP servers.
library;

/// True when spawning external MCP server processes may be offered.
///
/// Only desktop platforms with a confirmed child-process story are allowed:
/// Linux, Windows and macOS. Mobile platforms cannot launch arbitrary
/// executables, Aurora reports itself as Linux but is not confirmed, and
/// unknown platforms are refused. Built-in servers keep working through the
/// in-process stream fallback everywhere.
bool supportsStdioOnPlatform({
  required String operatingSystem,
  required bool isLinux,
  required bool isWindows,
  required bool isMacOS,
}) {
  if (isWindows || isMacOS) {
    return true;
  }
  if (!isLinux) {
    return false;
  }
  return operatingSystem.toLowerCase() != 'aurora';
}
