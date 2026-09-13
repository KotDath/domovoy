## ADDED Requirements

### Requirement: Durable chat title and current selection metadata
The versioned nested session record SHALL persist an optional stable chat title and one current selection containing exact provider/model reference, reasoning mode, and canonical effort. The catalog summary SHALL expose the title and current selection without requiring presentation code to load every transcript. The title SHALL be absent until the configured deterministic title policy derives it from the first committed user text, SHALL be acknowledged in the same checkpoint as that first user input, and SHALL thereafter remain unchanged by later messages, compaction, model switching, close, and restart. Selection-only and combined model-switch/compaction records SHALL use ordinary successor revision and atomic JSONL snapshot rules. Neither field SHALL contain credentials, provider payloads, continuation data, executable configuration, or removed history.

#### Scenario: First user input and title commit together
- **WHEN** a repository-backed untitled session accepts its first user message
- **THEN** one acknowledged successor contains both that user message and its deterministic title, and the catalog never exposes a title whose source message was not acknowledged

#### Scenario: Model selection changes
- **WHEN** an idle selection successor is acknowledged
- **THEN** the catalog reports the new provider/model/reasoning selection while earlier ledger entries retain their original model attribution

#### Scenario: Compaction removes the first interaction
- **WHEN** later compaction removes the first user message from retained request context
- **THEN** the previously acknowledged title remains unchanged and available in the catalog without retaining removed raw history as title provenance

#### Scenario: Serialized metadata is inspected
- **WHEN** current JSONL records are decoded as JSON values
- **THEN** title and selection contain only declared credential-free fields and no secret, raw provider response, or opaque continuation payload

### Requirement: Backward-compatible chat metadata restoration
A valid earlier nested record without title or current-selection fields SHALL remain readable with no JSONL storage-envelope migration. Restoration SHALL expose a null title and derive current selection exactly from the record's immutable definition model and generation reasoning values. The catalog SHALL use the localized untitled fallback until a future first committed user message establishes a title; it SHALL NOT synthesize a title from later assistant content or invoke a model. Current records SHALL reject blank/invalid titles, malformed identifiers, unsupported reasoning combinations, and selection/continuation origin contradictions before provider or tool execution.

#### Scenario: Legacy record has existing messages but no title
- **WHEN** a valid earlier record with transcript history but no title field is restored
- **THEN** its history remains intact, the catalog exposes a null title for fallback presentation, and restoration does not retroactively persist or guess a title

#### Scenario: Legacy definition supplies selection
- **WHEN** a valid earlier record has no current-selection field
- **THEN** model and reasoning derive from the definition exactly and are validated against the newly bound registry before the session becomes usable

#### Scenario: Current selection is malformed
- **WHEN** replay reaches a complete record whose current selection names an absent model or violates its reasoning capability
- **THEN** that session is unreadable with a typed sanitized issue and no provider request, tool execution, or silent fallback model occurs

### Requirement: Catalog consistency for workspace mutations
Catalog listing that overlaps title creation, selection change, combined model-switch compaction, or deletion SHALL expose either the complete prior summary/record revision or the complete acknowledged successor, never a mixture. Tombstoned sessions SHALL expose neither title nor selection as available chat summaries. Optimistic conflict SHALL append no chat metadata successor and SHALL preserve the winning record.

#### Scenario: Listing overlaps combined model switch
- **WHEN** catalog listing overlaps atomic acknowledgement of compacted transcript plus target selection
- **THEN** it reports either the old revision/selection/message count or the complete new revision/selection/message count, never fields from both

#### Scenario: Listing follows tombstone
- **WHEN** a chat carrying title and selection metadata is successfully deleted
- **THEN** later catalog results omit its identifier and metadata and stale saves cannot restore them
