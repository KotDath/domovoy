/// Namespace directory of the local automation store (B6).
///
/// Tasks and run history live inside the application support directory of this
/// device as `ru.kotdath.domovoy/automation-jsonl-v1`. The namespace is
/// separate from agent sessions, projects, the MCP configuration and the
/// research library, so an automation stream can never collide with another
/// store on the same device.
library;

/// Directory name of the JSONL automation namespace.
const automationJsonlStorageDirectoryName = 'automation-jsonl-v1';
