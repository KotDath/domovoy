## Purpose

Defines truthful provider-first token accounting for chat requests, responses, retained context, cumulative session work, and durable per-model history without inventing unavailable provider data.

## ADDED Requirements

### Requirement: Mutually exclusive normalized token semantics
The system SHALL represent model usage with independently optional non-negative additive dimensions: `input` for request tokens not counted as cache read or cache write, `cacheRead` for request tokens reused from provider cache, `cacheWrite` for request tokens explicitly reported as cache creation/write, `output` for generated non-reasoning tokens, and `reasoning` for generated reasoning tokens. Provider-reported input, output, and overall totals SHALL be retained as separate non-additive parent values and SHALL never be added again to their normalized children. Each available value SHALL identify whether it was provider-reported or derived from provider counters; unavailable values SHALL remain unavailable rather than become zero.

A valid request-context value SHALL prefer the provider-reported input parent total and otherwise equal `input + cacheRead + cacheWrite` only when that decomposition is complete. A valid response-generated value SHALL prefer the provider-reported output parent total and otherwise equal `output + reasoning` only when complete. Effective overall SHALL prefer a valid provider-reported overall total, otherwise derive from valid non-overlapping provider input and output parent totals, otherwise derive from all five additive dimensions only when complete; it SHALL remain unavailable when no complete, non-overlapping derivation exists. A provider total contradicted by known non-overlapping components SHALL be retained only as inconsistent provenance and SHALL NOT become effective overall.

#### Scenario: Provider parents include child dimensions
- **WHEN** a provider reports an input total that includes cache reads and an output total that includes reasoning
- **THEN** normalization subtracts only the children declared inclusive by that provider mapping, exposes mutually exclusive additive dimensions, preserves both parent totals, and counts every token at most once in context, response, and overall values

#### Scenario: Cache miss is reported
- **WHEN** a compatible provider reports cache-hit and cache-miss request partitions
- **THEN** cache-hit tokens normalize as cache read, cache-miss tokens may establish uncached input when the declared partition is internally consistent, and cache miss is never relabelled as cache write without an explicit provider cache-write counter

#### Scenario: Dimension is unavailable
- **WHEN** reasoning, cache read, cache write, or another dimension is not returned and cannot be derived exactly from declared semantics
- **THEN** that dimension remains unavailable, completeness records the gap, and no zero or provider-specific guess is fabricated

#### Scenario: Overall total is absent
- **WHEN** the provider omits overall but supplies a complete valid input/output parent pair or a complete set of mutually exclusive additive dimensions
- **THEN** effective overall is their non-overlapping sum and is labelled derived-from-provider rather than provider-reported

#### Scenario: Counters are inconsistent
- **WHEN** a reported child exceeds its inclusive parent, aliases conflict, or overall is smaller than known non-overlapping work
- **THEN** impossible derived dimensions and totals are unavailable, valid independent counters remain observable, and sanitized completeness/anomaly metadata identifies inconsistency without exposing raw response content

#### Scenario: Cache-hit ratio is requested
- **WHEN** cache read and a positive complete request-context value are available
- **THEN** cache-hit ratio is derived as `cacheRead / requestContext`, labelled derived, and is otherwise unavailable rather than stored or guessed as a provider fact

### Requirement: Immutable per-provider-attempt ledger
The system SHALL finalize one immutable ledger entry for each accepted physical provider invocation. Every entry SHALL have a stable attempt identifier, monotonically ordered session position, exact selected provider/model reference, operation kind, outcome, and normalized usage/completeness. A normal assistant operation SHALL carry stable run and logical-turn identifiers, attempt number, request-message identity, and an optional response-message identity only when a complete assistant message was committed. A model-backed compaction operation SHALL carry its stable compaction-operation identity and optional owning run, SHALL support the session model or another model, and SHALL never carry or masquerade as an assistant response. Historical model references SHALL be data and SHALL NOT require the model still to be the session's currently selected model.

#### Scenario: Tool loop performs several model turns
- **WHEN** one run completes an assistant tool-call turn and a later assistant answer turn
- **THEN** the ledger contains separately identified provider attempts sharing the run but carrying distinct logical-turn and response-message identities

#### Scenario: Overflow retry is performed
- **WHEN** one logical assistant turn dispatches an overflowing attempt, model-backed compaction, and one retry
- **THEN** the first attempt, every reported compaction invocation, and the retry have distinct attempt identities; the assistant attempts share their logical turn; and all known work contributes exactly once to the appropriate projections

#### Scenario: Alternate model compacts the session
- **WHEN** a compaction strategy uses a model different from the session's assistant model
- **THEN** its entries retain the alternate model and compaction identity, contribute to compaction and session totals, and are excluded from assistant-response projections

#### Scenario: Deterministic compaction runs
- **WHEN** compaction performs no provider invocation
- **THEN** no token-ledger entry or fabricated zero-usage model attempt is created

#### Scenario: Provider model changes later
- **WHEN** restored history contains entries for one model and a later supported session operation selects another model
- **THEN** both model references remain intact and per-model/session projections include each entry without rewriting historical attribution

### Requirement: Public chat accounting views
The session SHALL expose immutable provider-neutral accounting views containing: the active assistant request attempt when one exists or otherwise the latest finalized assistant request; the latest committed assistant response; current retained request-shaped context; cumulative assistant-conversation work; cumulative compaction work; complete session work; per-model groups; and immutable finalized ledger entries. The request view SHALL expose input/cache-read/cache-write and request-context values. The response view SHALL expose output/reasoning and response-generated values and SHALL correlate to its stable response-message identity. Aggregate dimensions SHALL expose a known subtotal and completeness; a full value SHALL be available only when every contributing entry is complete for that value. Legacy unattributed usage SHALL contribute only to explicitly legacy-inclusive session projections, never to a request, response, model, or compaction view.

Current retained context SHALL mean the complete request-shaped state that would be sent next, including system context, retained messages, tools, continuation state, and framing. It MAY use provider-known request context only while that exact request-shaped state still matches the captured attempt; after any input, assistant/tool append, compaction, or other context mutation it SHALL use the configured context estimator and expose estimator identity/version with estimated provenance. This change SHALL NOT introduce a tokenizer or label an estimate as provider-reported.

#### Scenario: Request is streaming
- **WHEN** an active assistant attempt receives one or more cumulative usage snapshots
- **THEN** observers receive an immutable current-request view with its stable identity, evolving known input breakdown, completeness, and no duplicate cumulative addition

#### Scenario: Assistant response is committed
- **WHEN** a normal provider attempt completes and its assistant message is committed
- **THEN** latest response exposes that message identity, model, output, reasoning, and response-generated value independently from request-context and cumulative-session values

#### Scenario: Context mutates after a reported request
- **WHEN** a tool result, inbound message, assistant response, or compaction changes retained request-shaped state after provider input usage was reported
- **THEN** current retained context no longer presents the old provider input as current and instead presents a labelled estimator result for the new state

#### Scenario: One aggregate entry is incomplete
- **WHEN** session entries contain known totals for some provider attempts and no effective overall for another
- **THEN** the aggregate reports the known subtotal and partial completeness while withholding a falsely complete overall value

#### Scenario: Session contains assistant and compaction work
- **WHEN** model-backed compaction occurs between normal assistant requests
- **THEN** assistant-conversation totals exclude compaction, compaction totals exclude assistant attempts, session totals include both, and per-model grouping preserves their exact models

#### Scenario: Collections escape the boundary
- **WHEN** a caller obtains a snapshot, aggregate group, or ledger list and attempts to mutate source collections or later observes live session changes
- **THEN** the obtained values remain immutable snapshots and cannot mutate session accounting state

### Requirement: Exactly-once finalization across lifecycle outcomes
Usage updates within one physical invocation SHALL be cumulative snapshots, not additive deltas. New valid fields SHALL replace or complete the pending attempt snapshot; a terminal event repeating the same usage SHALL not add it again. The runtime SHALL finalize an accepted invocation at most once for completion, provider failure, overflow, cancellation, or local stop after dispatch, retaining partial known usage and an explicit outcome even when no response message commits. Retries and later tool-loop turns SHALL create new attempt identities. Cumulative projections and token guards SHALL derive from the legacy baseline, finalized entries, and at most one active pending snapshot, and SHALL not maintain an independently drifting total.

For repository-backed sessions, a finalized entry SHALL join the next required acknowledged session checkpoint before later provider/tool work proceeds or the terminal lifecycle settles under existing persistence and cancellation precedence. If process loss occurs before an entry is durably acknowledged, restoration SHALL make no claim to recover or estimate that in-flight provider work.

#### Scenario: Usage repeats at completion
- **WHEN** an invocation emits multiple partial/cumulative updates and repeats final usage on completion
- **THEN** its pending snapshot is reconciled field-by-field, one finalized entry is produced, and every aggregate and guard counts the invocation once

#### Scenario: Provider fails after usage
- **WHEN** an invocation reports valid usage and then fails or overflows without a committed assistant message
- **THEN** one failure/overflow entry retains that usage and model attribution, has no response-message identity, and contributes once to assistant and session work

#### Scenario: Cancellation follows partial usage
- **WHEN** cancellation wins after an invocation reports usage
- **THEN** one cancelled entry retains the observed usage, no incomplete assistant response is correlated, and existing cancellation-terminal precedence remains authoritative if persistence finalization fails or times out

#### Scenario: Failure has no usage
- **WHEN** an accepted provider invocation fails before returning any usable counter
- **THEN** its finalized entry records unknown usage and incomplete accounting rather than fabricated zero tokens

#### Scenario: Budget observes active usage
- **WHEN** an active attempt update reaches a configured token budget
- **THEN** the guard evaluates the same reconciled active snapshot used by the public view, stops later work according to existing precedence, and finalizes that attempt without double charging it

#### Scenario: Process ends during an invocation
- **WHEN** the process ends after provider dispatch but before its finalized ledger checkpoint is acknowledged
- **THEN** restore returns only previously acknowledged entries and explicitly does not infer the unacknowledged invocation's cost

### Requirement: Backward-compatible record evolution and strict restoration
The versioned session record SHALL persist accounting generation, immutable finalized entries, explicit legacy unattributed baseline, and sufficient projection metadata to reproduce public values without provider payloads. The existing coarse cumulative usage field SHALL remain a compatibility projection and SHALL be validated against the ledger plus baseline rather than become a second source of truth. A valid earlier record without accounting fields SHALL decode as accounting generation zero with an empty ledger and its former usage as the unattributed legacy baseline. It SHALL expose no historical latest request, response, compaction, or per-model attribution that the record did not contain.

Decode and restore SHALL reject duplicate/out-of-order attempt identities, invalid operation/correlation combinations, negative values, impossible completeness/provenance, malformed model references, and disagreement between the compatibility cumulative projection and ledger-derived totals before any provider or tool work. The existing JSONL full-record storage SHALL carry the additions without a storage-envelope migration.

#### Scenario: Legacy record is restored
- **WHEN** a valid pre-change record contains transcript and coarse cumulative usage but no accounting ledger
- **THEN** it restores as generation zero with an empty ledger, preserves the old usage only as legacy unattributed baseline/session total, and leaves latest request/response and model groups unavailable

#### Scenario: New record restarts
- **WHEN** a repository-backed session with assistant, retry, and alternate-model compaction entries is acknowledged, closed, and restored through a fresh codec/store/runtime instance
- **THEN** entry order, identities, models, outcomes, normalized values, completeness, response correlation, legacy baseline, and every deterministic projection round-trip exactly

#### Scenario: Ledger record is malformed
- **WHEN** persisted accounting duplicates an attempt, assigns a response message to compaction/failure, contains contradictory usage, or disagrees with its compatibility cumulative usage
- **THEN** restoration fails with a typed sanitized configuration or persistence error before dispatch and exposes no raw stored/provider content
