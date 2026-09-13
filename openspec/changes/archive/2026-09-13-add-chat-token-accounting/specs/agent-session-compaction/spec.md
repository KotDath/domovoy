## ADDED Requirements

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
