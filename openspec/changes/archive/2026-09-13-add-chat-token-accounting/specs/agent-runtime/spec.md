## ADDED Requirements

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
