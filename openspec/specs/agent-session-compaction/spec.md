# agent-session-compaction Specification

## Purpose

Defines safe, replaceable reduction of long-lived agent-session context while preserving persisted history semantics, provider replay validity, cancellation, and bounded execution.

## Requirements

### Requirement: Independent trigger, estimator, and compactor extensions
The system SHALL expose independently replaceable trigger, estimator, and asynchronous compactor contracts without requiring a strategy registry. The runtime SHALL provide immutable credential-free compaction context containing operation/session identity, reason, selected model metadata, the complete request-shaped context, protected seed prefix, prior generated prefix, complete legal interaction groups, defensively copied continuation entries, prior provenance, current estimate and estimator identity, optional target, and cancellation. A trigger SHALL return skip or compact; a compactor SHALL return no-change or an immutable candidate selecting one supplied legal suffix boundary plus zero or more non-privileged replacement-prefix messages. Extensions SHALL receive no mutable session/repository handle or commit callback and SHALL NOT mutate live or persisted state directly.

#### Scenario: All three extensions are replaced
- **WHEN** a runtime is composed with custom trigger, estimator, and compactor implementations
- **THEN** automatic decisions, estimates, and candidates flow through those implementations while runtime validation, continuation remapping, persistence, and commit behavior remain unchanged

#### Scenario: Extension attempts an invalid replacement
- **WHEN** a compactor selects a partial/unknown boundary, emits privileged or tool-bearing generated messages, or returns malformed metadata
- **THEN** the runtime rejects the candidate before any live-state mutation, checkpoint, provider retry, or tool execution

#### Scenario: Fallback estimation is used
- **WHEN** no provider-specific estimator is configured
- **THEN** equal request values produce equal versioned estimates, larger serialized request content cannot produce a smaller estimate, and system context, messages, tools, continuation payload, and framing are all included

### Requirement: Replaceable automatic trigger with bounded default recovery
For a runtime configured with automatic compaction, the system SHALL evaluate its configured trigger at a safe boundary after pending input and completed tool results are committed and before the next normal provider request. The supplied OpenCode-inspired trigger SHALL use configurable pre-request pressure derived from the active estimator, selected-model context bound, output reserve, headroom, and post-compaction target, and SHALL request one bounded recovery for an eligible typed context overflow. Those thresholds and decisions SHALL NOT be requirements of custom triggers. Existing runtimes without compaction configuration SHALL retain their current behavior.

#### Scenario: Default trigger remains below pressure
- **WHEN** the complete estimate does not exceed the configured default pressure threshold
- **THEN** the trigger returns skip, no compactor/checkpoint is invoked, and the provider receives unchanged context

#### Scenario: Custom trigger uses another rule
- **WHEN** a custom trigger decides from turn count or another context field rather than the default token-pressure calculation
- **THEN** the runtime honors its typed skip/compact decision without imposing the default threshold numbers

#### Scenario: Protected context cannot be compacted enough
- **WHEN** protected configuration and required complete history cannot satisfy a trigger-supplied target
- **THEN** the candidate is rejected with a typed sanitized compaction error before a normal provider request

### Requirement: Strategy-neutral valid and repeatable context
A mutating compaction candidate SHALL preserve immutable definition seed messages, replace any prior generated prefix with zero or more clearly identified non-privileged/non-tool generated messages, and retain a contiguous suffix beginning at a complete interaction-group boundary. It SHALL carry serializable provenance, be strictly smaller under the active estimator, and meet the trigger target when one is supplied. A typed no-change result SHALL perform no checkpoint and SHALL not increment record revision or compaction generation.

#### Scenario: Session is compacted repeatedly
- **WHEN** a previously compacted session is compacted again
- **THEN** the old generated prefix is supplied separately to the compactor and the accepted next generation replaces rather than accumulates it while retaining one valid suffix

#### Scenario: Strategy returns an ineffective candidate
- **WHEN** a strategy returns a mutating candidate that splits a boundary, is not smaller than the source, or exceeds a supplied target
- **THEN** the candidate is rejected, original state is retained, and the operation reports a typed sanitized compaction failure

#### Scenario: Strategy reports no change
- **WHEN** the configured compactor reports that no eligible reduction exists
- **THEN** the operation completes with a typed no-change outcome without mutating transcript, provenance, generation, or revision

### Requirement: Built-in summary and deterministic recent-group strategies
The system SHALL provide both an OpenCode-inspired structured-summary compactor and a deterministic configurable recent-N-complete-interaction-groups compactor through the same compactor contract. The summary strategy SHALL own an injected LLM invocation facility and configurable model selector that can select the session model or another registered model; the runtime SHALL NOT hard-code its model or internal request count. Any conforming LLM-backed compactor SHALL cooperate with cancellation and report aggregate provider usage it causes. The recent-N strategy SHALL require no LLM facility, emit no generated prefix, and preserve the last N complete interaction groups.

#### Scenario: Summary uses another model
- **WHEN** the summary compactor's model selector returns a registered model different from the session model
- **THEN** that strategy uses the selected model and returns its candidate/aggregate usage through the common contract without changing runtime transaction logic

#### Scenario: Deterministic strategy is forced
- **WHEN** a session with more than N compactable groups uses the recent-N strategy
- **THEN** the candidate retains exactly the final N complete groups with no generated summary and repeated execution over unchanged state is deterministic

#### Scenario: Custom compactor uses no model
- **WHEN** a caller injects another deterministic conforming compactor
- **THEN** compaction succeeds without an LLM facility and without any summary-specific runtime requirement

### Requirement: Public forced compaction operation
Each caller-owned agent session SHALL expose a public forced compaction operation that invokes the session-configured compactor independently of its automatic trigger and threshold while retaining estimator and runtime validation. The runtime SHALL supply that compactor a manual-reason compact decision with no target rather than call the trigger. The operation SHALL be observable, cancellable, and identified stably. It SHALL be accepted only when the session is open and idle; an active run or compaction SHALL cause a typed busy rejection without cancellation, queueing, or mutation, and a run/second compaction requested during it SHALL be rejected likewise. Session close SHALL cancel active compaction under the existing persistence shutdown budget.

#### Scenario: Caller compacts below automatic threshold
- **WHEN** an idle session invokes forced compaction while its automatic trigger would skip
- **THEN** the configured compactor is still invoked and the operation ends as compacted or no-change according to its validated result

#### Scenario: Caller compacts during a run
- **WHEN** forced compaction is requested while a model/tool run is active
- **THEN** it is rejected as busy without changing or cancelling the run, transcript, or revision

#### Scenario: Run starts during manual compaction
- **WHEN** a run or second forced compaction is requested while manual compaction is active
- **THEN** the new operation is rejected as busy and the original compaction continues unchanged

#### Scenario: Caller cancels forced compaction
- **WHEN** the caller cancels before candidate commit
- **THEN** cancellation reaches the compactor/save, original state remains, and the operation emits exactly one cancelled terminal

### Requirement: Tool and continuation replay invariants
Compaction SHALL treat each assistant tool-call message and all of its correlated tool results as an indivisible retained-or-removed group and SHALL never retain an orphan tool result or unresolved tool call. Provider continuation entries whose assistant message is removed SHALL be discarded; entries whose complete assistant interaction survives SHALL retain their opaque payload unchanged and SHALL be deterministically re-indexed to the assistant message's new transcript position. Generated replacement-prefix messages SHALL carry no provider continuation entry. Candidate validation SHALL occur before any provider dispatch.

#### Scenario: Removed assistant had continuation state
- **WHEN** compaction removes an assistant message with origin-bound continuation metadata
- **THEN** that entry is discarded with the removed interaction and no opaque state from it is replayed

#### Scenario: Retained tool cycle had continuation state
- **WHEN** a complete assistant tool-call/result cycle remains in the retained suffix
- **THEN** its continuation payload is byte-for-byte unchanged, its index points to the retained assistant's new position, and local request validation succeeds

#### Scenario: Strategy splits a tool cycle
- **WHEN** a proposed cut would retain a tool result without its assistant call or omit a correlated result required by a retained call
- **THEN** compaction is rejected before checkpoint, provider dispatch, or tool execution

### Requirement: Transactional state replacement and persistence
The runtime SHALL prepare and validate compaction against an immutable committed snapshot before replacing live state, regardless of automatic or forced origin and compactor implementation. For a transient session, transcript, continuation entries, compaction state, and counters SHALL change in one in-memory commit. For a repository-backed session, the complete candidate record SHALL be revision-checked and durably acknowledged before live state changes. A failed, conflicted, or cancellation-won candidate operation SHALL leave original live state and last acknowledged record usable and SHALL start no normal provider request from the rejected candidate.

#### Scenario: Repository checkpoint accepts compaction
- **WHEN** candidate validation passes and the repository acknowledges the expected-revision save
- **THEN** the live session atomically adopts exactly that record revision and the next request uses its compacted context

#### Scenario: Compactor or checkpoint fails
- **WHEN** any custom/built-in compactor, candidate validation, or candidate checkpoint fails before commit
- **THEN** transcript, continuation entries, compaction generation, and acknowledged revision remain unchanged and the active run/manual operation terminates with one typed sanitized failure

#### Scenario: Cancellation wins before compaction commit
- **WHEN** run, manual-operation, or session-close cancellation wins during strategy work or before the repository commits the candidate
- **THEN** strategy/save cancellation is requested, original session state remains, no normal provider request starts, and exactly one cancelled terminal is emitted for the active operation

#### Scenario: Repository commit wins a cancellation race
- **WHEN** the candidate record is durably committed before cancellation wins
- **THEN** the live session adopts the acknowledged compacted revision and then completes cancellation without attempting to roll back an already committed record

### Requirement: Persisted compaction provenance and restoration
A session record with compacted history SHALL persist generated-prefix range/count, monotonically increasing generation, automatic/manual/overflow reason, trigger identifier/version when applicable, strategy and estimator identifier/version, cumulative removed-message count, before/after estimates, sanitized decision metadata, and update metadata without persisting removed raw history. Record decoding SHALL treat absence of compaction state in a valid earlier record as an uncompacted generation-zero session. Restoration SHALL validate generated-prefix position, generation, transcript boundaries, continuation indexes, and model/wire origin before allowing a request. Persisted strategy identity SHALL be provenance, not a registry lookup requirement; a restored session SHALL use its newly bound runtime extensions for later decisions.

#### Scenario: Compacted session is restored
- **WHEN** a repository-backed summary-based or deterministic-truncation record is closed and restored with compatible runtime resources
- **THEN** its generated prefix if any, retained tail, continuation mappings, generation, estimates, and provenance round-trip and newly bound extensions receive that restored context

#### Scenario: Earlier record has no compaction field
- **WHEN** a valid session record written before this capability is decoded
- **THEN** it restores as uncompacted generation zero without inventing a summary or losing transcript/continuation data

#### Scenario: Stored compaction state is malformed
- **WHEN** a record has a mismatched generated-prefix range, invalid generation/provenance, broken tool boundary, or mismatched continuation index
- **THEN** restoration fails locally with a typed sanitized configuration or persistence error before provider or tool work

### Requirement: Bounded overflow recovery and retry semantics
The runtime SHALL recognize only a typed provider context-overflow classification as eligible for recovery. When a normal provider request fails with that classification before producing any model delta or tool side effect, the runtime SHALL offer at most one `providerOverflow` context to the configured trigger. If that trigger chooses compaction and the configured compactor commits an effective candidate, the runtime MAY retry that logical model turn once. A custom trigger MAY skip recovery. Failure, cancellation, no-change, ineffectiveness, prior output, or a second overflow SHALL terminate without another compaction/retry loop.

#### Scenario: Estimator undercounts and default trigger accepts recovery
- **WHEN** the first request fails with typed context overflow before output and the configured trigger/compactor produces an effective committed candidate
- **THEN** the runtime retries the logical model turn once using the candidate context

#### Scenario: Custom trigger declines overflow recovery
- **WHEN** the configured trigger returns skip for the single provider-overflow context
- **THEN** the original provider failure terminates the run without invoking the compactor or retrying

#### Scenario: Retry also overflows
- **WHEN** the single post-compaction retry receives another context-overflow failure
- **THEN** the run reports that provider failure and performs no third request or second recovery compaction for that logical turn

#### Scenario: Overflow follows observable provider progress
- **WHEN** a provider reports context overflow after any reasoning, text, tool-call delta, or externally visible side effect
- **THEN** the runtime does not retry the request and terminates through the ordinary typed failure path

### Requirement: Observable and budgeted compaction lifecycle
Automatic run events and public forced-compaction operation events SHALL report ordered started, succeeded, no-change, failed, and cancelled outcomes as applicable with session/operation and optional run identity, automatic/manual/overflow reason, trigger/strategy/estimator identity, generation, optional target, and before/after estimates where available. Events, hooks, results, errors, and logs SHALL NOT expose removed raw history, generated summary text, credentials, or opaque continuation payload. A conforming compactor that performs provider work SHALL return aggregate usage; the runtime SHALL report and charge that usage to the same session usage and applicable guards. Cancellation SHALL remain the sole terminal when it wins.

#### Scenario: Automatic compaction succeeds
- **WHEN** trigger-driven compaction is accepted
- **THEN** observers receive started then succeeded events before the normal provider request, including reason, selected extension identities, before/after estimates, and new generation but no compacted content

#### Scenario: Forced compaction completes without change
- **WHEN** the session-configured compactor returns no-change to a public forced operation
- **THEN** that operation emits started then no-change terminal events with no revision increment

#### Scenario: Compactor provider usage is reported
- **WHEN** an LLM-backed strategy reports aggregate token usage from its selected model
- **THEN** usage is emitted and accumulated under existing session/operation guard semantics rather than becoming hidden cost

#### Scenario: Compaction fails safely
- **WHEN** an automatic or forced compaction attempt fails without cancellation
- **THEN** observers receive exactly one sanitized failed terminal for that operation and no generated or removed content is disclosed

### Requirement: Model-aware compaction attempt accounting
Every conforming compactor that performs provider work SHALL return ordered per-invocation usage reports containing the exact selected model, cumulative normalized usage, completeness, and outcome, including reports carried by typed failure or cancellation. The runtime SHALL correlate those reports to the stable compaction operation and optional owning run, finalize them as compaction ledger entries, and charge them under existing guards. An aggregate-only report without per-model invocation identity SHALL not be accepted for model-backed compaction. A deterministic compactor SHALL return no provider reports.

#### Scenario: Summary invocation succeeds
- **WHEN** the built-in summary compactor completes one provider invocation
- **THEN** one compaction entry records its operation, exact selected model, normalized usage, and completion outcome and contributes to compaction/session but not assistant-response totals

#### Scenario: Summary invocation fails after usage
- **WHEN** a model-backed compactor observes usage and then fails or is cancelled
- **THEN** its ordered per-invocation report remains available to runtime finalization under existing failure/cancellation precedence without creating an assistant response

#### Scenario: Compactor uses multiple models
- **WHEN** a conforming custom compactor performs several provider invocations using one or more registered models
- **THEN** each physical invocation is reported and persisted separately in source order with its exact model rather than collapsed into an unattributed aggregate

#### Scenario: Compactor performs no provider work
- **WHEN** deterministic compaction succeeds, returns no change, fails, or is cancelled without provider dispatch
- **THEN** no usage entry is created and no zero-valued usage is invented
