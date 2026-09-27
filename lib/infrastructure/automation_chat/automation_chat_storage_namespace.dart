/// Namespace directory of the local automation chat delivery store (B8).
///
/// Delivered result cards live inside the application support directory of this
/// device as `ru.kotdath.domovoy/automation-chat-jsonl-v1`. The namespace is
/// separate from agent sessions, projects, the MCP configuration, the research
/// library and the automation task/run store, so a card stream can never
/// collide with another store on the same device.
library;

/// Directory name of the JSONL chat delivery namespace.
const automationChatJsonlStorageDirectoryName = 'automation-chat-jsonl-v1';
