/// Namespace directory of the local research library (B5).
///
/// The library lives inside the application support directory of this device
/// as `ru.kotdath.domovoy/library-jsonl-v1`. The namespace is separate from
/// agent sessions, project workspaces and MCP configuration, so a library
/// stream can never collide with another store on the same device.
library;

/// Directory name of the JSONL library namespace.
const libraryJsonlStorageDirectoryName = 'library-jsonl-v1';
