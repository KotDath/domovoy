## REMOVED Requirements

### Requirement: Distinct prompt and output areas
**Reason**: The side-by-side/stacked one-shot prompt-and-output page is replaced by the persistent chat list, conversation timeline, and anchored composer.

**Migration**: Production routes to `chat-workspace-ui`; prompt entry and output remain available there as conversation messages.

### Requirement: One-shot submission lifecycle
**Reason**: Independent transient submissions conflict with durable sequential runs in a selected chat.

**Migration**: Submission uses the selected repository-backed session and the serialized workspace command contract.

### Requirement: Progressive reasoning presentation
**Reason**: Reasoning presentation now belongs to each assistant response in the typed conversation timeline and is collapsed by default.

**Migration**: Use the reasoning disclosure behavior specified by `chat-workspace-ui`.

### Requirement: Progressive answer presentation
**Reason**: Progressive answer output is now merged with persisted assistant messages in the duplicate-free timeline.

**Migration**: Use the live-plus-snapshot timeline projection specified by `chat-workspace-ui`.

### Requirement: User-facing status and errors
**Reason**: Run, tool, compaction, stop, switch, persistence, and error status are unified in workspace and timeline state.

**Migration**: Use the typed lifecycle and sanitized error presentation specified by `chat-workspace-ui`.

### Requirement: Key settings access
**Reason**: Settings access remains required but moves from the retired one-shot page to the persistent workspace shell and credential error actions.

**Migration**: Use the settings reachability requirement in `chat-workspace-ui`; credential semantics remain owned by the credential capabilities.

### Requirement: No conversation history
**Reason**: The defining limitation is intentionally removed now that durable sessions and a persistent conversation workspace are available.

**Migration**: Existing transient one-call API behavior may remain for non-workspace callers, but production user prompts use durable chats restored from JSONL.
