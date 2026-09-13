## MODIFIED Requirements

### Requirement: Definition and session state separation
Each agent session SHALL have one stable `AgentSessionId` used for runtime identity, restoration, and messaging, and SHALL own mutable ordered messages, cumulative usage, run counters, inbox, current provider/model/reasoning selection, optional stable title, and active cancellation resources separately from its reusable immutable agent definition. A new session SHALL initialize its current selection from the definition. A live session SHALL permit at most one active run, compaction, or selection mutation and SHALL expose immutable snapshots/events rather than mutable collections. Caller-owned lifecycle SHALL move among idle, running, compacting, and switching-model operation states and back to idle, while close SHALL transition through closing to closed, cancel active work, flush any committed repository-backed checkpoint, and be idempotent. Closing SHALL NOT mean deleting a stored session record. Close SHALL use a runtime-only positive persistence-shutdown budget, defaulting to five seconds and separate from run duration and idle liveness. It SHALL reach closed within that budget when a repository ignores cancellation; a flush that is not acknowledged SHALL complete the shared close future with a sanitized persistence error and SHALL make the session unavailable for further work.

#### Scenario: Two sessions use one definition
- **WHEN** two sessions are opened from the same agent definition and receive different input or selection changes
- **THEN** they share immutable defaults but maintain independent current selections, messages, usage, counters, inboxes, titles, and cancellation state

#### Scenario: Concurrent run is requested
- **WHEN** a session already has an active run and another run is requested for the same session
- **THEN** the second request is rejected without changing the active run or session history

#### Scenario: Process lifetime ends
- **WHEN** the application process is terminated and restarted during this MVP
- **THEN** only records previously accepted by an explicitly configured durable repository can later be restored; queued envelopes, active tools, approvals, and in-flight model streams are not restored or resumed

#### Scenario: Session is closed during a run
- **WHEN** a caller closes a session with active provider or tool work
- **THEN** the active run is cancelled, already committed transcript state is retained, resources are released, and later run requests on that session are rejected

#### Scenario: Close meets a non-cooperative save
- **WHEN** close cancels a pending save but the repository does not settle it before the configured persistence-shutdown deadline
- **THEN** close reaches the closed lifecycle within the bound, its future reports a typed sanitized persistence failure, no additional save or run starts, and the same runtime rejects restoration of that identifier while the abandoned write remains pending

#### Scenario: Closed session record is deleted
- **WHEN** a caller only closes a repository-backed session
- **THEN** its saved record remains available for restoration until a separate delete operation succeeds

### Requirement: Versioned session records and persistence seam
The runtime SHALL represent restorable state as a versioned serializable session record containing stable session identity, record revision, serializable agent-definition snapshot, current provider/model/reasoning selection, optional stable title, committed provider-neutral transcript, message-indexed provider continuation metadata, cumulative reported usage and counters, and creation/update metadata. Continuation metadata SHALL be committed atomically with its complete normalized assistant turn, SHALL be absent for partial/cancelled/failed output, and SHALL be validated against transcript indexes and the current selection's exact model/wire origin during decode/restore. A replaceable repository port SHALL load, cancellation-aware revision-check and save, and cancellation-aware expected-revision delete records; a companion platform-neutral catalog port SHALL project immutable summaries and sanitized storage issues for listing without exposing infrastructure types. Save and delete SHALL complete successfully only after commit. If cancellation wins before commit admission, a conforming repository SHALL complete with the typed cancelled error and guarantee no later mutation from that operation; if commit admission already won, it SHALL complete successfully after durable acknowledgement. Conflict and persistence failures SHALL append no later logical mutation from that operation. A codec port SHALL remain authoritative for encoding and strict decoding of supported record versions. The system SHALL provide behaviorally conforming in-memory and durable JSONL implementations. A valid earlier record without current-selection or title fields SHALL derive its initial selection from the definition and retain a null title without changing the JSONL storage-envelope version.

#### Scenario: Caller-owned session is restored
- **WHEN** a caller closes a repository-backed idle session and later restores its identifier from the configured repository
- **THEN** the restored session has the same identity, definition snapshot, current selection, optional title, committed transcript, usage, and counters and begins idle with no active run resources

#### Scenario: Earlier session record is restored
- **WHEN** a supported record has no current-selection or title fields
- **THEN** restoration uses the definition model and generation reasoning as the current selection, retains a null title for later deterministic derivation, and does not rewrite the record until a real mutation occurs

#### Scenario: Record round-trips through the codec
- **WHEN** a valid current record is encoded and decoded
- **THEN** all public non-secret fields including current selection and title plus record version/revision round-trip while credentials and executable runtime objects remain absent

#### Scenario: Stored record version is unknown or malformed
- **WHEN** restoration reads an unsupported record version, invalid transcript, invalid current selection/title, incompatible continuation origin, or unavailable provider/tool/policy reference
- **THEN** restoration fails with a typed configuration or persistence error before a model request or tool side effect occurs

#### Scenario: Concurrent revision is observed
- **WHEN** a repository save supplies an expected revision that no longer matches the stored record
- **THEN** the save fails with a typed conflict and does not overwrite the newer record

#### Scenario: Active work existed at process loss
- **WHEN** a record is restored after the prior process ended during provider streaming, approval, tool execution, or selection switching
- **THEN** restoration uses only the last committed record and does not automatically replay or resume that active operation

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

## ADDED Requirements

### Requirement: Validated durable session selection
Every session SHALL expose one immutable current selection containing exact provider and model identifiers plus reasoning mode and canonical effort. Creation and restoration SHALL resolve that selection through the configured registry and validate mode/effort against model capabilities before any provider work. An idle reasoning-only change SHALL validate and durably checkpoint one successor record before changing live state. Exact equality SHALL return a typed unchanged outcome with no revision, timestamp, event, compaction, or provider work. A run SHALL snapshot the complete current selection at admission and use it for all physical attempts and tool continuations in that run.

#### Scenario: Invalid reasoning pair is requested
- **WHEN** a caller selects disabled reasoning for a required-reasoning model or an undeclared explicit effort
- **THEN** the operation fails with a typed sanitized validation error before estimator, compactor, repository, provider, or live-state mutation

#### Scenario: Reasoning-only change commits
- **WHEN** an idle repository-backed session changes to another valid reasoning mode/effort for the same model
- **THEN** one revision-checked record is acknowledged before the snapshot changes and the next run uses the new pair

#### Scenario: Selection change is requested during a run
- **WHEN** a run is active and any selection change is requested
- **THEN** the change is rejected with a typed busy outcome identifying the active operation and the run continues with its frozen selection

### Requirement: Atomic target-model switch
An idle provider/model change SHALL retain the old live and durable selection until the target pair and target reasoning choice are resolved and validated. The runtime SHALL construct the next request-shaped context for the target model, exclude origin-bound continuation entries that cannot be replayed under the target, and evaluate it with the configured context estimator and model-switch fit policy against the target context/output bounds. If it fits, one revision-checked record SHALL atomically commit the new selection and removal of incompatible continuation entries. If it does not fit, the runtime SHALL invoke the configured history compactor with a model-switch reason and a target no greater than the fit threshold, validate the candidate against the target-shaped request, and atomically commit the compacted transcript/provenance/accounting, incompatible-continuation removal, and new selection as one successor record. No intermediate compacted transcript or new selection SHALL become live or durable.

#### Scenario: Target context already fits
- **WHEN** a validated idle model switch produces a target-shaped estimate within the configured fit threshold
- **THEN** no compactor or provider compaction call occurs and one acknowledged successor switches selection for the next run

#### Scenario: Compaction makes target fit
- **WHEN** target-shaped context exceeds the fit threshold and the configured compactor returns an effective candidate within target
- **THEN** exactly one successor record adopts the candidate and target selection together, and no observer can restore or use a compacted-old-selection intermediate record

#### Scenario: No compactor is configured
- **WHEN** a target model cannot fit retained context and the session has no configured compactor
- **THEN** the switch fails with a typed sanitized compaction error and keeps the old selection, transcript, compaction state, and continuation entries

#### Scenario: Compactor reports no change or ineffective candidate
- **WHEN** required model-switch compaction returns no-change or a candidate that remains above target or violates an interaction boundary
- **THEN** the switch fails, the old selection and visible history remain current, and no candidate transcript is committed

#### Scenario: Switching across model origins
- **WHEN** a switch to a different provider/model is acknowledged from a chat containing origin-bound continuation entries
- **THEN** visible normalized messages remain, incompatible opaque continuation entries are removed atomically, and switching back later does not resurrect them

### Requirement: Selection-switch cancellation, usage, and conflict precedence
A model switch SHALL be an observable cancellable operation and SHALL exclude runs, forced compaction, second switches, and close except for cancellation/close handling. If cancellation wins before the combined record commit, the old selection and visible transcript SHALL remain; if model-backed compaction incurred reported usage, that usage SHALL still be finalized and checkpointed under existing exact-once accounting rules without falsely reporting a successful switch. If the combined repository commit wins before cancellation, commit SHALL win and the operation SHALL report the acknowledged selection rather than roll it back. A conflict or persistence failure SHALL keep the old live selection, surface a sanitized typed error, and start no request from an unacknowledged candidate.

#### Scenario: Stop cancels model-switch compaction
- **WHEN** cancellation wins while the compactor is producing a target-model candidate
- **THEN** no selection/candidate commit occurs, the old model remains current, and one cancelled terminal is observed

#### Scenario: Cancelled compactor reported usage
- **WHEN** model-backed switch compaction reports partial provider usage before cancellation wins
- **THEN** the usage is finalized and durably accounted exactly once under the old selected chat while no assistant response or successful switch is fabricated

#### Scenario: Commit wins cancellation race
- **WHEN** the combined selection/candidate record enters and wins atomic commit before cancellation is observed
- **THEN** the new selection and any compaction are acknowledged together, live state adopts them, and cancellation does not restore the old model

#### Scenario: External successor causes conflict
- **WHEN** another writer commits a successor after switch planning but before the combined save
- **THEN** the switch conflicts, does not overwrite the successor, keeps no unacknowledged candidate live, and exposes a sanitized refresh-required outcome
