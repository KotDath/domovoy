## MODIFIED Requirements

### Requirement: Versioned session records and persistence seam
The runtime SHALL represent restorable state as a versioned serializable session record containing stable session identity, record revision, serializable agent-definition snapshot, committed provider-neutral transcript, message-indexed provider continuation metadata, cumulative reported usage and counters, and creation/update metadata. Continuation metadata SHALL be committed atomically with its complete normalized assistant turn, SHALL be absent for partial/cancelled/failed output, and SHALL be validated against transcript indexes and the definition's exact model/wire origin during decode/restore. A replaceable repository port SHALL load, cancellation-aware revision-check and save, and cancellation-aware expected-revision delete records; a companion platform-neutral catalog port SHALL project immutable summaries and sanitized storage issues for listing without exposing infrastructure types. Save and delete SHALL complete successfully only after commit. If cancellation wins before commit admission, a conforming repository SHALL complete with the typed cancelled error and guarantee no later mutation from that operation; if commit admission already won, it SHALL complete successfully after durable acknowledgement. Conflict and persistence failures SHALL append no later logical mutation from that operation. A codec port SHALL remain authoritative for encoding and strict decoding of supported record versions. The system SHALL provide behaviorally conforming in-memory and durable JSONL implementations.

#### Scenario: Caller-owned session is restored
- **WHEN** a caller closes a repository-backed idle session and later restores its identifier from the configured repository
- **THEN** the restored session has the same identity, definition snapshot, committed transcript, usage, and counters and begins idle with no active run resources

#### Scenario: Record round-trips through the codec
- **WHEN** a valid session record is encoded and decoded
- **THEN** all public non-secret fields and the record version/revision round-trip while credentials and executable runtime objects remain absent

#### Scenario: Stored record version is unknown or malformed
- **WHEN** restoration reads an unsupported record version, invalid transcript, or unavailable provider/tool/policy reference
- **THEN** restoration fails with a typed configuration or persistence error before a model request or tool side effect occurs

#### Scenario: Concurrent revision is observed
- **WHEN** a repository save supplies an expected revision that no longer matches the stored record
- **THEN** the save fails with a typed conflict and does not overwrite the newer record

#### Scenario: Active work existed at process loss
- **WHEN** a record is restored after the prior process ended during provider streaming, approval, or tool execution
- **THEN** restoration uses only the last committed checkpoint and does not automatically replay or resume that active operation

#### Scenario: Repository checkpoint fails
- **WHEN** a repository-backed session cannot save a newly committed productive checkpoint before a cancellation-family terminal has been selected
- **THEN** the run emits a typed sanitized persistence failure and starts no further provider turn or tool while making no exact-once claim for an external tool side effect that completed before the failed save

#### Scenario: A normal durable checkpoint is delayed
- **WHEN** a repository save completes after asynchronous durable storage work while neither run nor session cancellation has begun
- **THEN** the runtime awaits its actual completion, advances revision exactly once, and does not classify it from microtask or event-loop-turn timing

#### Scenario: Cancellation interrupts a checkpoint
- **WHEN** cancellation begins while a repository save is pending
- **THEN** the save token is cancelled, all persistence finalization shares one absolute shutdown deadline, and the selected terminal is delayed until the save outcome and any permitted final flush are acknowledged or that deadline expires

#### Scenario: Repository ignores checkpoint cancellation
- **WHEN** the pending save does not settle by the persistence-shutdown deadline
- **THEN** the runtime abandons waiting, closes the persistence-unreliable session, starts no later work, promises restoration only from the last acknowledged checkpoint, suppresses the abandoned future's late effects on events and in-memory revision, and quarantines same-runtime restore while that future remains pending

#### Scenario: Terminal checkpoint fails
- **WHEN** the final checkpoint for normal completion or a non-cancellation stop fails
- **THEN** a typed sanitized persistence or conflict failure replaces the provisional terminal and the unreliable session closes

#### Scenario: Catalog implementation is replaced
- **WHEN** a caller composes another conforming repository/catalog implementation
- **THEN** listing, load, save, restore, and delete preserve the same summaries, revisions, cancellation, and error semantics without runtime dependence on its storage technology

#### Scenario: Current revision is deleted
- **WHEN** repository delete supplies the active session revision and its cancellation has not won before commit admission
- **THEN** deletion is acknowledged exactly once and later load/restore/catalog operations treat the identifier as absent

#### Scenario: Stale revision is deleted
- **WHEN** repository delete supplies a revision that does not equal the active record revision
- **THEN** deletion fails with a typed conflict and the active record remains unchanged
