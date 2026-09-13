## ADDED Requirements

### Requirement: Target-model switch compaction planning
The configured compactor SHALL be reusable by an idle model-switch operation with a distinct `modelSwitch` reason, target-model metadata, and a target estimate derived from the configured target fit policy. Its immutable context SHALL contain the same protected seed, generated prefix, complete legal interaction groups, accounting state, and cancellation guarantees as other compaction origins, but its request shape and bound SHALL describe the validated target selection with incompatible origin-bound continuation entries omitted. The compactor SHALL NOT receive a mutable session, repository handle, or authority to commit either compaction or selection.

#### Scenario: Smaller target model requires compaction
- **WHEN** the current retained context fits the old model but exceeds the validated target model's fit threshold
- **THEN** the configured compactor receives one model-switch context carrying the target model/bound and a target no greater than that threshold

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
