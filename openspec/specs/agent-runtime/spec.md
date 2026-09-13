# Agent Runtime Specification

## Purpose

Defines an ergonomic, cancellable, provider-independent agent facade, persistent-ready session lifecycle, and guarded tool loop whose immutable definition is separate from mutable execution state.

## Requirements

### Requirement: Serializable agent definition
The system SHALL represent an agent definition as an immutable serializable value with a stable agent identifier, display name, system prompt, ordered initial messages, provider/model selection, generation settings including reasoning mode and canonical effort, enabled tool identifiers, policy reference, nullable run guards, liveness policy, no-progress policy, and nullable token budgets. Definitions SHALL contain no API keys, open clients, stream controllers, clocks, policy callbacks, tool executors, repositories, codecs, or mutable session history. Reasoning effort SHALL serialize as `modelDefault | low | medium | high | max`, never as a provider-specific request string.

#### Scenario: Definition round-trips
- **WHEN** a valid agent definition is serialized and restored
- **THEN** its prompt, initial messages, provider/model choice, tool identifiers, settings, policy reference, quota, liveness, no-progress, and token-budget policies are equal to the source definition

#### Scenario: Definition references unavailable runtime resources
- **WHEN** a session is opened for a definition whose provider, model, tool, or policy identifier is not registered
- **THEN** the session fails with a typed configuration error before a model request or tool side effect occurs

#### Scenario: Definition contains an invalid limit
- **WHEN** a caller supplies a finite non-positive model-turn limit, negative tool-call limit, finite non-positive duration, finite non-positive idle timeout, invalid loop threshold, or negative token budget
- **THEN** the definition is rejected before a session can start

#### Scenario: Definition omits productive quotas
- **WHEN** model-turn, tool-call, total-duration, and cumulative-token limits are absent from a definition and its runtime profile
- **THEN** those dimensions are unlimited while cancellation, provider/model bounds, idle liveness, and no-progress protection remain active

#### Scenario: Run overrides definition reasoning
- **WHEN** run options supply one typed reasoning mode/effort pair
- **THEN** that pair replaces both definition reasoning fields for the whole run; otherwise definition fields apply, and `modelDefault` delegates to selected model/profile metadata

#### Scenario: Reasoning choice is frozen for a run
- **WHEN** an agent performs multiple model/tool continuations in one run
- **THEN** the resolved run-over-definition-over-model/profile reasoning mode and effort remain unchanged for every provider request in that run

### Requirement: Ergonomic agent facade
The runtime SHALL bind a reusable immutable definition through an agent facade. The facade SHALL support a one-call run operation, creation of a caller-owned session, restoration by stable session identity, and idempotent asynchronous runtime close. A one-call run SHALL use a fresh transient session owned by that run and SHALL release it automatically after a terminal event or cancellation. From acceptance, the runtime SHALL own opening and live one-call/caller-owned sessions until cleanup, even before an opening session is registered.

#### Scenario: Caller uses one-call run
- **WHEN** a caller invokes the agent facade with valid user input
- **THEN** the facade creates a fresh transient session, returns an observable cancellable run, executes the complete agent loop, and closes its owned session after exactly one terminal result

#### Scenario: Caller creates a reusable session
- **WHEN** a caller creates a session and starts several runs sequentially
- **THEN** every run uses the same stable session identity and committed transcript until the caller closes the session

#### Scenario: Two one-call runs use one agent
- **WHEN** the same agent facade receives two one-call invocations
- **THEN** each invocation owns a distinct session identity and neither invocation receives the other's transcript or cancellation state

#### Scenario: Runtime closes with opening and live sessions
- **WHEN** `AgentRuntime.close()` begins while one session is opening and other sessions have active or idle runs
- **THEN** the runtime atomically rejects new agent/run/create/restore/registration work, prevents the opening session from registering late, requests all accepted sessions to close concurrently under one shared persistence-shutdown deadline, and completes only after every accepted run/session is closed or deterministically abandoned

#### Scenario: Runtime close is repeated
- **WHEN** multiple callers close the same runtime before or after shutdown finishes
- **THEN** they observe the same future/outcome, every child cleanup is attempted once, and the runtime remains closed

#### Scenario: One session fails during runtime close
- **WHEN** a child session reports persistence cleanup failure during runtime shutdown
- **THEN** the runtime still closes all other accepted sessions, reaches closed, and completes its shared close future with a sanitized failure after cleanup attempts finish

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

### Requirement: Guarded agent loop
For each run, the runtime SHALL add the submitted user content, invoke the selected provider with the session context, project normalized deltas, append completed assistant output, process requested tools, append correlated tool results, and repeat until a typed terminal condition occurs. A run MAY continue without a turn, tool, total-duration, or cumulative-token quota when those values are absent. The runtime SHALL preserve event and message order, commit only complete transcript artifacts at defined safe boundaries, and issue no model request or tool execution after a terminal event.

#### Scenario: Model returns a final answer
- **WHEN** a model turn completes without tool calls
- **THEN** assistant output is appended once and the run emits one successful terminal event with provider finish reason and cumulative usage

#### Scenario: Model requests tools
- **WHEN** a model turn completes with valid tool calls and continuation limits remain
- **THEN** calls are handled deterministically in provider order, their results are appended in the same order, and the next model turn sees the assistant calls and all correlated results

#### Scenario: Model-turn limit is reached
- **WHEN** completing a tool-bearing turn would require a model invocation beyond the configured maximum
- **THEN** no extra provider request is made and the run terminates with the model-turn-limit stop reason while retaining prior output and tool results

#### Scenario: No productive quota is configured
- **WHEN** each model turn makes observable progress and no finite productive quota is configured
- **THEN** the runtime continues model and tool turns until model completion, cancellation, liveness failure, no-progress stop, provider/model bound, or another typed terminal condition

### Requirement: Optional productive quotas and precedence
The runtime SHALL support nullable model-turn, attempted-tool-call, total-duration, cumulative input/output/total-token quotas and an optional per-turn output-token cap. Absence SHALL mean unlimited for that dimension. Finite values SHALL be resolved with per-run override taking precedence over the agent definition and the definition taking precedence over the runtime profile. Attempted calls SHALL include unknown, invalid, denied, and executed calls. Configured quotas SHALL be evaluated before affected work and after each reported usage update; a single provider turn MAY exceed a cumulative token quota, but no subsequent turn or tool execution SHALL begin after the runtime observes that quota.

#### Scenario: Tool-call limit would be exceeded
- **WHEN** the model requests more calls than the remaining attempted-tool-call allowance
- **THEN** the runtime executes none of the calls beyond the allowance and terminates with a tool-call-limit stop reason

#### Scenario: Reported usage reaches a budget
- **WHEN** cumulative reported token usage reaches or exceeds a configured budget
- **THEN** the runtime emits the updated usage, starts no later model turn or tool execution, and terminates with the corresponding budget stop reason

#### Scenario: Required usage is unavailable
- **WHEN** a cumulative token budget is configured but a provider turn omits the counter needed to determine compliance
- **THEN** the runtime preserves partial output and terminates with a typed budget-unverifiable failure before any continuation

#### Scenario: Wall-clock duration expires
- **WHEN** the configured run duration expires during provider streaming or tool execution
- **THEN** active work is cancelled and the run emits exactly one duration-limit terminal event

#### Scenario: Run override relaxes or tightens a definition value
- **WHEN** a run supplies an explicit finite value or explicit unlimited value for a dimension also set by its definition and runtime profile
- **THEN** the run value is enforced for that dimension without changing the reusable definition or profile

#### Scenario: Zero tool allowance is configured
- **WHEN** the resolved attempted-tool-call limit is zero and a model requests a tool
- **THEN** no tool executes and the run terminates with the tool-call-limit stop reason

### Requirement: Idle liveness watchdog
Every run SHALL have an idle watchdog whose default timeout is ten minutes unless an explicit run override, agent definition, or runtime profile supplies another positive duration or disables it. The idle clock SHALL reset on observable provider output or usage, inbound-message consumption, approval resolution, tool lifecycle progress/heartbeat, or completed transcript commit. Expiry SHALL cooperatively cancel active work and emit exactly one typed idle-timeout terminal. Total run duration SHALL remain a separate optional quota.

#### Scenario: Model continues streaming progress
- **WHEN** a provider emits valid deltas or usage updates often enough that no idle interval reaches the configured timeout
- **THEN** the watchdog does not stop the run regardless of its total elapsed duration

#### Scenario: Tool reports liveness
- **WHEN** a long-running tool periodically reports progress through its runtime liveness context
- **THEN** those heartbeats reset the idle clock without being persisted as transcript content

#### Scenario: Active work becomes idle
- **WHEN** provider, approval, or tool work produces no recognized progress for the full idle timeout
- **THEN** cancellation propagates to active work and exactly one idle-timeout terminal is emitted

### Requirement: Identical no-progress loop detection
The runtime SHALL fingerprint consecutive completed tool-continuation cycles using ordered tool identifiers, canonical validated arguments, normalized tool outcomes, committed assistant answer content, and inbound-message progress. A cycle SHALL count as identical no-progress only when its fingerprint equals the preceding cycle and it adds no new answer content or inbound state. The default policy SHALL emit a warning event when the consecutive count reaches five and SHALL stop after the tenth identical no-progress cycle before another model continuation. Any changed arguments, changed normalized result, new answer content, consumed inbound message, or explicit progress marker SHALL reset the count. Thresholds SHALL be validated and MAY be overridden by run, definition, or runtime profile with the same precedence as other guards.

#### Scenario: Repeated cycles make no progress
- **WHEN** ten consecutive completed tool-continuation cycles have the same fingerprint and no progress signal
- **THEN** the fifth cycle emits one warning, the tenth emits a no-progress terminal, and no eleventh provider turn or tool execution starts

#### Scenario: Similar polling result changes
- **WHEN** repeated calls use the same tool and arguments but their normalized results change
- **THEN** the no-progress counter resets and no warning or stop is caused by those calls

#### Scenario: New content breaks repetition
- **WHEN** a repeated tool cycle also commits new answer content, consumes a new inbound message, or records an explicit progress marker
- **THEN** the cycle is treated as progress and the consecutive no-progress count resets

### Requirement: Validated and policy-controlled tools
Each enabled tool SHALL expose a serializable name, description, input schema, and a runtime-only asynchronous Dart executor. The runtime SHALL assemble complete arguments, require a JSON object, validate it against the declared schema before policy evaluation, and apply a runtime permission decision of `allow`, `deny`, or `ask` before execution. MVP executions SHALL be sequential, and cooperative cancellation plus a non-persisted liveness/progress reporter SHALL be passed to every executor.

#### Scenario: Tool is allowed
- **WHEN** a known call has valid arguments and policy resolves to `allow`
- **THEN** its executor runs once with immutable invocation context and cancellation, and a correlated success result is appended

#### Scenario: Tool requires approval
- **WHEN** policy resolves to `ask`
- **THEN** the runtime requests a decision from the configured approval handler and executes only if that handler allows the exact invocation

#### Scenario: Approval handler is absent
- **WHEN** policy resolves to `ask` and no approval handler is registered
- **THEN** the invocation is denied safely, no executor runs, and a sanitized correlated denial result is supplied to the next model turn

#### Scenario: Tool call is invalid or denied
- **WHEN** a call names an unknown/disabled tool, contains malformed/non-object/schema-invalid arguments, or policy denies it
- **THEN** no executor runs and the runtime appends a sanitized correlated error result that the next model turn can inspect

#### Scenario: Tool executor fails
- **WHEN** an approved executor throws or returns a failure
- **THEN** the runtime converts it to a sanitized correlated tool error result without exposing a stack trace or secret and continues only while the resolved guards permit

### Requirement: Observable run lifecycle and hooks
The runtime SHALL expose a single-subscription ordered event stream covering run start, inbound-message consumption, reasoning and answer deltas, assembled tool requests, permission decisions, tool start/result/progress, usage, liveness/no-progress warnings, and exactly one completed, stopped, failed, or cancelled terminal event. Runtime-only lifecycle hooks SHALL observe the same stable identifiers and snapshots around model turns and tool execution without receiving credentials, and a hook failure SHALL become a typed sanitized runtime failure.

#### Scenario: Flutter controller subscribes
- **WHEN** a Flutter controller starts a run
- **THEN** it can derive loading, progressive reasoning, progressive answer, tool activity, cumulative usage, and terminal state solely from runtime events without importing provider or transport types

#### Scenario: Lifecycle hook observes execution
- **WHEN** registered hooks surround a model turn and an approved tool execution
- **THEN** callbacks receive session/run/turn/call identifiers and immutable snapshots in deterministic order

#### Scenario: Event subscription is cancelled
- **WHEN** the sole run-event subscription is cancelled or the owning session is closed
- **THEN** provider/tool work is cooperatively cancelled, resources are released, and no further events are delivered to that subscriber

### Requirement: Explicit run cancellation
Callers SHALL be able to cancel a run idempotently. Cancellation SHALL propagate to provider streaming, approval waiting, repository checkpoint waiting, and active tool execution, SHALL retain already committed session messages and partial observable output, and SHALL prevent partial assistant/tool fragments from being committed as completed messages. Run-work and persistence-operation cancellation SHALL use separate sources. Cancellation-triggered persistence finalization SHALL use one configurable positive shutdown budget, defaulting to five seconds and independent of productive duration and idle liveness. The cancelled terminal SHALL remain the sole terminal if its final flush fails or is abandoned; in that case the persistence-unreliable session SHALL close. A caller-owned session SHALL return to idle after cancellation only if it is transient or its final repository record is acknowledged. Repeated waits SHALL use detachable cancellation registrations and SHALL release each registration after settlement or abandonment.

#### Scenario: Caller cancels during model output
- **WHEN** the caller cancels after answer deltas but before provider completion
- **THEN** provider work stops, partial deltas remain visible, incomplete assistant output is not committed to session history, and the run terminates as cancelled

#### Scenario: Caller cancels during a tool
- **WHEN** the caller cancels an active tool execution
- **THEN** the executor receives cancellation, no later tool or model turn begins, and the run terminates as cancelled exactly once

#### Scenario: Caller cancels while persistence ignores cancellation
- **WHEN** a caller cancels a run whose active repository save ignores its cancellation token
- **THEN** cancellation completes after at most the single persistence-shutdown budget, exactly one cancelled terminal is selected, and the session closes as persistence-unreliable without a competing persistence terminal

#### Scenario: Caller cancels during a cooperative checkpoint
- **WHEN** the active save settles with typed cancellation before the shared deadline and the one final frozen-snapshot save is acknowledged within the remaining budget
- **THEN** exactly one cancelled terminal is emitted and the caller-owned session returns to idle with an acknowledged revision

#### Scenario: Productive checkpoints do not retain cancellation callbacks
- **WHEN** many repository checkpoints settle successfully before cancellation
- **THEN** every operation-scoped cancellation registration is detached after its save and the number of live callbacks does not grow with completed checkpoints

### Requirement: Ledger-backed provider attempt lifecycle
The agent runtime SHALL allocate a stable attempt identity before each provider invocation, correlate normal invocations to stable session/run/logical-turn/request-message identity, and reconcile every cumulative provider usage update into one pending attempt. Completion, failure, overflow, cancellation, or a post-dispatch local stop SHALL finalize that attempt at most once. A committed assistant message SHALL receive a stable response-message identity correlated only to its successful attempt. Overflow retries and later tool-loop turns SHALL be separate physical attempts, while token budgets and cumulative usage SHALL count each finalized attempt and at most one pending snapshot exactly once.

#### Scenario: Completion repeats usage update
- **WHEN** provider completion repeats usage already emitted by an update
- **THEN** the runtime finalizes one attempt and neither session totals nor token guards add the repeated snapshot twice

#### Scenario: Tool continuation starts
- **WHEN** a completed assistant tool-call message and its tool results cause another provider invocation
- **THEN** the next invocation receives a new attempt and turn identity while preserving the same run identity and prior response-message correlation

#### Scenario: Overflow is retried
- **WHEN** typed context overflow is eligible for one compact-and-retry recovery
- **THEN** the overflow attempt is finalized before compaction, the retry has a distinct attempt under the same logical turn, and no attempt is reset out of cumulative accounting

#### Scenario: Cancellation or failure follows reported usage
- **WHEN** an active provider invocation reports usage and then is cancelled or fails
- **THEN** its known usage is finalized once with the terminal outcome and no partial assistant message identity

### Requirement: Accounting snapshots, persistence, and guard compatibility
Session snapshots and ordered runtime events SHALL expose immutable accounting views for active/latest request, latest committed response, current retained context, assistant, compaction, session, and per-model usage without provider transport types. Repository-backed checkpoints SHALL include newly finalized ledger entries before subsequent provider/tool work or terminal settlement, subject to existing persistence-shutdown and cancellation precedence. Restore SHALL resume from only the last acknowledged ledger and SHALL preserve coarse public usage/budget compatibility as a deterministic ledger-plus-legacy projection rather than an independently mutable accumulator.

#### Scenario: Controller observes usage
- **WHEN** a provider usage update arrives during an assistant request
- **THEN** a runtime consumer can obtain current request input/cache breakdown, cumulative projections, source/completeness, and stable correlation from provider-neutral events without importing adapter types

#### Scenario: Context changed after request
- **WHEN** retained request-shaped state no longer equals the most recently measured provider request
- **THEN** the session snapshot labels current context with the configured estimator identity/version and does not reuse stale provider input as current context

#### Scenario: Finalized usage checkpoint fails
- **WHEN** a repository cannot acknowledge a checkpoint containing newly finalized usage
- **THEN** existing persistence failure/cancellation precedence determines the terminal outcome, no later provider/tool work starts from an unacknowledged accounting state, and the runtime does not claim the entry will restore

#### Scenario: Legacy cumulative token budget continues
- **WHEN** an existing input, output, or total token budget is configured after ledger adoption
- **THEN** it evaluates the corresponding deterministic active-run projection with the same stop and budget-unverifiable behavior and without counting cache/reasoning parents and children twice
