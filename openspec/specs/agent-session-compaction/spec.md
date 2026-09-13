# agent-session-compaction Specification

## Purpose

Defines safe, replaceable reduction of long-lived agent-session context while preserving persisted history semantics, provider replay validity, cancellation, and bounded execution.

## Requirements

### Requirement: Independent trigger, estimator, and compactor extensions
The system SHALL expose independently replaceable trigger, estimator, and asynchronous compactor contracts without requiring a strategy registry. The runtime SHALL provide immutable credential-free compaction context containing operation/session identity, reason, current session model metadata, request/target model metadata, the complete request-shaped context, protected seed prefix, prior generated prefix, complete legal interaction groups, defensively copied continuation entries, prior provenance, current estimate and estimator identity, optional target, optional latest-completed provider context usage, and cancellation. The current session model and request/target model SHALL be independently addressable and SHALL be equal for ordinary same-model compaction but MAY differ during model-switch compaction. Proactive trigger input SHALL use only `requestContext` or equivalent effective provider usage from the latest completed physical LLM invocation. Estimation SHALL remain internal to compactor batch selection and candidate reduction and SHALL NOT be automatic-trigger pressure evidence or billed usage. A trigger SHALL return skip or compact; a compactor SHALL return no-change or an immutable candidate selecting one supplied legal suffix boundary plus zero or more non-privileged replacement-prefix messages. Extensions SHALL receive no mutable session/repository handle or commit callback and SHALL NOT mutate live or persisted state directly.

#### Scenario: All three extensions are replaced
- **WHEN** a runtime is composed with custom trigger, estimator, and compactor implementations
- **THEN** provider-usage automatic decisions, internal estimates, and candidates flow through those implementations while runtime validation, continuation remapping, persistence, and commit behavior remain unchanged

#### Scenario: Extension attempts an invalid replacement
- **WHEN** a compactor selects a partial/unknown boundary, emits privileged or tool-bearing generated messages, or returns malformed metadata
- **THEN** the runtime rejects the candidate before any live-state mutation, checkpoint, provider retry, or tool execution

#### Scenario: Fallback estimation is used
- **WHEN** no provider-specific estimator is configured
- **THEN** equal request values produce equal versioned estimates, larger serialized request content cannot produce a smaller estimate, and system context, messages, tools, continuation payload, and framing are all included

#### Scenario: Model-switch context separates model roles
- **WHEN** an idle session currently using one model needs compaction to fit a different target model
- **THEN** the context identifies the current session model for strategy-owned summary selection and separately identifies the target/request model and request shape for fit validation

### Requirement: Replaceable automatic trigger with bounded default recovery
For a runtime configured with automatic compaction, the system SHALL decide proactive compaction from `requestContext` or equivalent effective provider context usage on the latest completed physical LLM invocation, whether that completion contains tool calls or a final answer. It SHALL evaluate after that invocation's transcript and usage are committed at a safe boundary and before any next provider dispatch. Missing usable provider context usage SHALL produce a proactive skip/unavailable result. An `AgentContextEstimator` SHALL NOT provide automatic-trigger pressure or billed usage and SHALL remain internal to compactor batch selection and candidate reduction. The runtime SHALL continue to offer separately bounded recovery for an eligible typed provider context overflow. Existing runtimes without compaction configuration SHALL retain their current behavior.

#### Scenario: Completed final answer supplies provider pressure
- **WHEN** a final-answer LLM invocation completes with usable provider context usage
- **THEN** its transcript and usage are committed before proactive evaluation at a safe boundary, and no future provider dispatch can precede that evaluation

#### Scenario: Completed tool call supplies provider pressure
- **WHEN** a tool-call LLM invocation completes with usable provider context usage
- **THEN** its transcript and usage are committed before proactive evaluation at a safe boundary and before the next provider dispatch

#### Scenario: Default trigger remains below pressure
- **WHEN** the latest completed physical LLM invocation's usable provider context usage is equal to or below the configured pressure threshold
- **THEN** the trigger returns skip, no compactor/checkpoint is invoked for that decision, and the committed context remains unchanged

#### Scenario: Provider measurement is unavailable
- **WHEN** the latest completed physical LLM invocation omits usable provider context usage or only an estimate is available
- **THEN** proactive evaluation returns skip/unavailable, invokes no compactor, and does not treat the estimate as trigger pressure or billed usage

#### Scenario: Custom trigger uses another rule
- **WHEN** a custom proactive trigger applies another rule to the usable latest-completed provider context usage
- **THEN** the runtime honors its typed skip/compact decision without substituting an estimator or imposing the default threshold numbers

#### Scenario: Protected context cannot be compacted enough
- **WHEN** protected configuration and required complete history cannot satisfy a trigger-supplied target
- **THEN** the candidate is rejected with a typed sanitized compaction error before a normal provider request

#### Scenario: Typed provider overflow remains recoverable
- **WHEN** a provider returns the eligible typed context-overflow classification
- **THEN** the existing bounded provider-overflow recovery remains available independently of missing proactive provider context usage

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
The system SHALL provide both an OpenCode-inspired structured-summary compactor and a deterministic configurable recent-N-complete-interaction-groups compactor through the same compactor contract. The summary strategy SHALL own an injected LLM invocation facility, estimator, and configurable model selector whose default selects the context's current session model and whose replacement MAY select another registered model; the runtime SHALL NOT substitute the request/target model, hard-code the summary model, or assume one physical invocation. The summary strategy SHALL derive each invocation's input capacity from the actual selected summary model's context/output bounds, configured headroom/output allowance, and estimator; it SHALL incrementally replace a rolling prior summary while consuming one or more complete legal interaction groups per successful invocation until the removable prefix is consumed and the final candidate meets any supplied target. It SHALL impose a finite configurable invocation cap, SHALL make monotonic group progress on every successful invocation, and SHALL fail safely when no next complete group fits, a required retained group alone prevents the target, or the cap is reached. Any conforming LLM-backed compactor SHALL cooperate with cancellation and return ordered per-invocation usage reports. A successful tool-free summary completion MAY carry validated provider turn state; the strategy SHALL accept the completion while discarding that state without replay, persistence, generated-prefix inclusion, events, or diagnostics. The recent-N strategy SHALL require no LLM facility, emit no generated prefix, and preserve the last N complete interaction groups.

#### Scenario: Summary uses another model
- **WHEN** the summary compactor's model selector returns a registered model different from the session model
- **THEN** that strategy sizes and sends summary work for the selected model and returns its candidate/per-invocation usage through the common contract without changing runtime transaction logic

#### Scenario: Smaller target retains current-model summary default
- **WHEN** a large-current-model session switches to a smaller target model and the default summary model selector is used
- **THEN** every summary invocation uses the current session model while the final candidate is estimated and validated against the separate target-model request

#### Scenario: Long removable history requires several batches
- **WHEN** removable complete groups exceed one summary-model request but each next batch can fit the model-derived input capacity
- **THEN** each successful invocation consumes at least one next complete group, replaces the rolling summary, reports its own ordinal/model/usage, and the bounded sequence produces one final candidate within target

#### Scenario: Prior summary is compacted again
- **WHEN** a previously generated summary precedes newly removable groups
- **THEN** the rolling prior summary is included as source context for the first and subsequent bounded batches and is replaced by one final generated summary rather than accumulated

#### Scenario: One complete group cannot fit
- **WHEN** the fixed summary instructions, rolling summary, output allowance, headroom, and one next complete interaction group exceed the summary model context capacity
- **THEN** the strategy starts no invocation for that group, returns a typed sanitized failure with prior invocation reports preserved, and runtime commits no candidate transcript or provenance

#### Scenario: Incremental summarization is cancelled or capped
- **WHEN** cancellation wins or the finite invocation cap is reached before all required groups are consumed
- **THEN** no candidate is returned, all completed/pending physical invocation reports remain available for existing accounting, and runtime performs no compaction commit or automatic retry loop

#### Scenario: Reasoning Responses summary returns turn state
- **WHEN** a tool-free summary request to a reasoning-required Responses model completes with valid summary text and non-null validated provider turn state but no tool-call delta
- **THEN** the summary is accepted and the turn state is discarded without replay, persistence, candidate metadata, event projection, or diagnostics

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

### Requirement: Target-model switch compaction planning
The configured compactor SHALL be reusable by an idle model-switch operation with a distinct `modelSwitch` reason, current-session model metadata, separate target/request-model metadata, and the configured target capacity. After validating the requested selection, the runtime SHALL compare the latest completed physical LLM invocation's usable provider-reported context usage with target capacity and SHALL NOT use an estimator as the switch trigger. If that usage is unavailable and the target is smaller, the runtime SHALL conservatively run the configured compactor before switching without claiming numeric fit; no-change, failure, or cancellation SHALL preserve the old selection. Estimation SHALL remain internal to compactor batch selection and candidate reduction. The compaction context SHALL retain the same protected seed, generated prefix, complete legal interaction groups, accounting state, and cancellation guarantees as other compaction origins, while its request shape describes the validated target selection with incompatible origin-bound continuation entries omitted. The default summary selector SHALL continue to select the current session model; an explicitly configured strategy selector MAY choose another model. The compactor SHALL NOT receive a mutable session, repository handle, or authority to commit either compaction or selection.

#### Scenario: Smaller target model requires compaction
- **WHEN** the latest completed physical LLM invocation has usable provider context usage above the target model capacity
- **THEN** the configured compactor runs before the switch using context that separates the current session model from the target model

#### Scenario: Provider measurement fits target
- **WHEN** the latest completed physical LLM invocation has usable provider context usage within target capacity
- **THEN** the selection and incompatible-continuation removal may commit atomically without using an estimator as the switch trigger

#### Scenario: Smaller target has no usable provider measurement
- **WHEN** the target is smaller and the latest completed physical LLM invocation has no usable provider context usage
- **THEN** the runtime runs the configured compactor before switching, does not claim numeric fit, and does not use an estimator as the switch trigger

#### Scenario: Conservative smaller-target compaction does not complete
- **WHEN** provider context usage is unavailable for a smaller target and configured compaction returns no-change, fails, or is cancelled
- **THEN** the old selection is preserved and no target-model request starts

#### Scenario: Default summary selection during model switch
- **WHEN** model-switch compaction uses the default summary selector
- **THEN** summary invocations use the current session model while candidate fit and incompatible continuation removal use the target-model request shape

#### Scenario: Target selection is invalid
- **WHEN** the requested provider/model/reasoning selection is absent or capability-incompatible
- **THEN** validation fails before a compaction context is created or any compactor/provider invocation starts

#### Scenario: Compactor inspects continuation state
- **WHEN** the old session contains provider-origin continuation entries incompatible with the target model
- **THEN** target request estimation omits those entries while compaction boundary validation still protects complete normalized tool interactions

### Requirement: Combined model-switch candidate commit
A valid model-switch candidate SHALL satisfy all ordinary compaction invariants, be strictly smaller under the configured estimator when mutation is required, and fit the supplied target when evaluated as the next target-model request. The runtime SHALL stage the candidate, updated provenance with `modelSwitch` reason, finalized compactor usage, target selection, and removal of incompatible continuation entries as one revision-checked record and SHALL expose none of that candidate as live state before acknowledgement. A no-change result while the source remains oversized, ineffective/invalid candidate, failure, cancellation before commit, conflict, or persistence failure SHALL NOT commit candidate transcript/provenance or target selection.

#### Scenario: Combined record is acknowledged
- **WHEN** model-switch compaction returns a valid candidate and the repository accepts the expected-revision successor
- **THEN** compaction generation, candidate transcript, remapped accounting, target selection, and continuation removal become visible atomically

#### Scenario: Combined save fails
- **WHEN** candidate validation succeeds but the repository rejects or fails the combined successor
- **THEN** original live transcript, compaction generation, current selection, and continuation entries remain usable and no target-model request starts

#### Scenario: No-change cannot fit target
- **WHEN** the compactor reports no-change and the unchanged target-shaped estimate still exceeds the fit threshold
- **THEN** the switch terminates with a sanitized cannot-fit outcome and keeps the old selection

### Requirement: Model-switch compaction observability and accounting
Model-switch compaction SHALL emit ordered started and exactly one succeeded, no-change, failed, or cancelled terminal carrying operation/session identity, target model identity, strategy/estimator identity, target and before/after estimates where available, and no removed/generated content or opaque continuation payload. Every physical compactor provider invocation SHALL retain its exact model and existing compaction-operation correlation and SHALL contribute to compaction/session accounting rather than assistant-response totals, including failure or cancellation. A successfully combined commit SHALL persist those entries with the candidate; an unsuccessful switch SHALL persist any incurred usage through the existing terminal accounting checkpoint while retaining the old selection and visible transcript.

#### Scenario: Model-backed switch compaction succeeds
- **WHEN** a summary compactor invokes the old session model and its candidate is committed with a different target model
- **THEN** the compaction ledger entry names the model actually invoked, the selection names the target model, and token projections do not attribute compaction usage to an assistant response

#### Scenario: Compactor fails after provider usage
- **WHEN** model-switch compaction reports provider usage and then fails before a candidate commit
- **THEN** one failed compaction entry is finalized under the old chat selection, the switch remains failed, and no generated summary or removed raw history is exposed
