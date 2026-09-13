## MODIFIED Requirements

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
