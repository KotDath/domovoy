## Context

See `proposal.md` for motivation. Today `LlmUsage` contains nullable coarse counters, adapters pass inclusive provider totals without semantic metadata, runtime merges usage snapshots then adds one mutable session total, and `AgentSessionRecord` persists only that total. `TurnId` and `RunId` exist only during execution; transcript messages do not retain accounting correlation. The JSONL store already persists complete codec records and can carry backward-compatible record additions without a storage-envelope change. The existing context-estimator seam can provide a labelled fallback; this change does not add a tokenizer.

The provider protocols, runtime retry/tool/cancellation lifecycle, record codec, compaction contracts, and public snapshots all meet in this change. Complexity is high and the selected route is **Heavy**. Risk is **T2** because this changes public usage semantics, provider-protocol normalization, persisted record evolution, and exact-once retry/cancellation lifecycle behavior.

## Goals / Non-Goals

**Goals:**

- Establish one additive vocabulary that cannot double-count cache or reasoning.
- Retain provider facts separately from derivations and estimates.
- Make a finalized physical provider invocation the accounting unit and derive every cumulative view from immutable facts.
- Correlate normal requests to stable run/turn/request/response identities and compaction requests to stable operation identity.
- Preserve useful legacy cumulative usage without pretending it has per-turn, message, model, cache-write, or reasoning attribution.
- Let a later UI consume current/latest request, latest response, current retained context, assistant-conversation, compaction, complete-session, and per-model views without importing provider adapters.

**Non-Goals:**

- Pricing, currency/cost calculation, quotas beyond preserving existing token guards, or external analytics.
- A tokenizer, provider-side count endpoint, or guessing dimensions for unsupported providers.
- Chat screens, presentation formatting, database/storage-envelope migration, or platform-specific storage work.
- Reconstructing usage for a provider invocation lost before durable acknowledgement.

## Decisions

### 1. Keep additive components and provider parent totals in separate namespaces

The normalized vocabulary is:

| Name | Canonical meaning | Additive |
|---|---|---|
| `inputTokens` | Request token work not represented by cache read or cache write | yes |
| `cacheReadTokens` | Request tokens explicitly served from provider cache | yes |
| `cacheWriteTokens` | Request tokens explicitly reported as cache creation/write | yes |
| `outputTokens` | Generated non-reasoning output tokens | yes |
| `reasoningTokens` | Generated reasoning tokens | yes |
| `reportedInputTotalTokens` | Provider parent input/prompt total, with declared inclusion semantics | no |
| `reportedOutputTotalTokens` | Provider parent completion/output total, with declared inclusion semantics | no |
| `reportedOverallTokens` | Provider total across input/output work | no |

`cache miss` is evidence about uncached input, not cache creation. A dialect may use a consistent hit/miss partition to derive `inputTokens`, but only an explicit cache-creation/write counter populates `cacheWriteTokens`.

Each metric is an immutable `(value, provenance)` value. Provenance is `providerReported`, `derivedFromProvider`, or, only in the context view, `estimated`. Null means unavailable, not zero. Usage carries a closed sanitized anomaly set such as invalid value, alias conflict, child-exceeds-parent, and inconsistent total, plus completeness for request decomposition, response decomposition, and overall.

The effective calculations are ordered and per invocation:

1. `requestContextTokens`: valid reported input parent; otherwise all three complete additive request dimensions.
2. `responseGeneratedTokens`: valid reported output parent; otherwise both complete additive generated dimensions.
3. `overallTokens`: valid and consistent reported overall; otherwise non-overlapping complete request/response parents; otherwise all five complete additive dimensions; otherwise unavailable.

Provider parents are never summed with children. A reported overall smaller than known non-overlapping work is retained for diagnostics but is not effective. Cache-hit ratio is a derived view (`cacheRead / requestContext`) only for a known positive denominator.

Alternative rejected: retain current `input/output/total/cacheHit/cacheMiss` and add reasoning. It cannot say whether input includes cache or output includes reasoning, so it preserves the defect.

### 2. Version `LlmUsage` compatibly and centralize semantic normalization

`LlmUsage` remains the provider-neutral transport value but gains the canonical metrics, reported parents, completeness, and anomalies. Its JSON form receives an internal schema version. Generation-one JSON with old `inputTokens`, `outputTokens`, `totalTokens`, `cacheHitTokens`, and `cacheMissTokens` decodes conservatively: old input/output/overall become reported parents, cache hit becomes cache read, and cache miss can establish exclusive input only when parent/hit/miss form a valid partition. It never becomes cache write.

A pure normalization helper accepts semantic counters and explicit inclusion declarations, not a provider id. Adapter/dialect mapping performs alias extraction and passes facts to the helper. This separates two test surfaces:

- extraction fixtures prove supported wire aliases and malformed-field behavior;
- table-driven helper tests prove inclusive subtraction, provenance, completeness, and overall precedence.

For aliases, absence is unknown, equal duplicate aliases collapse once, and conflicting aliases invalidate only that semantic counter. Negative/non-integral optional usage values and impossible subtraction produce sanitized anomalies; they do not turn a successful response into a protocol failure. Structurally unusable non-usage response data retains existing protocol-failure behavior.

Built-in mappings cover:

- Chat Completions prompt/input, completion/output, overall, cached-token direct/detail forms, cache hit/miss partitions, reasoning details, and explicitly configured cache-write paths;
- Responses input/output/overall, `input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`, and an explicitly configured cache-write path if a compatible dialect later supplies one.

No runtime branch tests `providerId`; provider profiles/dialects own extraction semantics. Unknown provider data remains unavailable.

Alternative rejected: preserve arbitrary raw usage maps. They leak unstable vendor payloads into persisted/public contracts and do not solve overlap.

### 3. Treat provider usage events as cumulative snapshots

One reusable `LlmUsageSnapshotAccumulator` reconciles source-ordered updates for a single physical invocation. A later valid metric replaces/completes the same metric in the pending snapshot; terminal usage passes through the same reconciliation. Snapshots are never added to each other. A source decrease or semantic contradiction is retained as an anomaly rather than converted into a negative delta.

The accumulator produces one immutable final snapshot and guards against a second finalization. This helper is used by normal assistant requests and built-in model-backed compaction. Runtime aggregation only adds finalized attempts and the current accumulator once.

Alternative rejected: infer deltas between stream updates. Providers commonly repeat final cumulative usage, and subtraction becomes unsafe with missing or corrected fields.

### 4. Persist one ledger entry per physical provider invocation

Add stable `ProviderAttemptId` and transcript-message identity values. The runtime allocates an assistant attempt id before entering a provider stream. A finalized `AgentModelUsageEntry` contains:

- session-local monotonic sequence and stable attempt id;
- exact `LlmModelRef` from the dispatched request;
- `assistant` or `compaction` operation kind;
- terminal outcome (`completed`, `failed`, `overflow`, `cancelled`, or `stopped`);
- final normalized usage and completeness, even when all counters are unknown;
- context revision measured by that request;
- for assistant work: run id, logical turn id, retry ordinal, stable request-message id, and response-message id only after a complete assistant message commits;
- for compaction work: compaction-operation id, optional owning run id, and invocation ordinal, with no response-message id.

Every provider invocation accepted by the operation is represented, even if it returns no usable usage. This distinguishes unknown from no provider work. A deterministic compactor that dispatches nothing creates no entry.

Transcript message identities are stored as a sidecar aligned with currently retained transcript messages and exposed through immutable transcript/accounting projections. New user, assistant, tool, inbound, and generated-summary messages receive stable ids. Legacy messages may have no id. Compaction retains ids for retained messages, removes sidecar entries with removed messages, and assigns a new id to generated replacement messages. Historical ledger correlations remain stable even if the referenced message is later compacted out; public projections mark whether the message is still retained.

Alternative rejected: transcript index as identity. Compaction reindexes messages and makes persisted response correlation unstable.

### 5. Separate physical attempts, logical turns, runs, and operations

A logical normal `TurnId` is allocated once outside overflow recovery. The first dispatch and its single retry share that turn but have different attempt ids and retry ordinals. Each tool-loop continuation receives a new turn under the same run. This removes the current risk of resetting `_turnUsage` after overflow and losing or re-adding work.

Compaction attempts are grouped by `AgentCompactionOperationId`. A compactor result and its typed failure/cancellation carry ordered per-invocation reports `(ordinal, model, outcome, usage)` instead of one unattributed aggregate. Runtime assigns ledger attempt ids and preserves report order. The built-in summary currently emits one report; the contract permits multiple calls/models. Deterministic compactors report an empty list.

Historical entry models are validated as syntactically valid references but are not resolved through the current registry during restore. Current/future dispatch retains existing registry validation. This supports later session model switching and alternate compaction models without making historical providers runtime dependencies.

Alternative rejected: one ledger entry per assistant message. It hides failed/overflow/retried and compaction work that may be billable but produces no message.

### 6. Finalize and checkpoint at lifecycle-safe boundaries

Normal-flow ordering is:

1. create attempt and pending accumulator;
2. reconcile usage snapshots while exposing an immutable active view and evaluating guards;
3. select outcome and, for success, commit the complete assistant message plus response-message correlation;
4. finalize the entry once;
5. include transcript/message identities, continuation state, ledger, and compatibility usage in the same required checkpoint before later tool/provider work;
6. emit the terminal or continue the tool loop.

Failure, overflow, cancellation, or post-dispatch stop finalizes without a response-message id. Overflow finalization occurs before any recovery compaction and retry. Cancellation keeps existing sole-terminal precedence: accounting finalization participates in the remaining persistence-shutdown budget but cannot replace a selected cancellation terminal. A failed acknowledgement prevents later work and follows existing persistence/conflict rules. Process death before acknowledgement restores only the previous ledger; no exact accounting claim is possible for the in-flight provider side effect.

An entry finalization key is the stable attempt id. Pending, checkpoint retry, terminal repetition, and late provider teardown all consult the same finalized-id guard. Record validation requires unique ids and strictly increasing sequence, so replay cannot accumulate duplicates.

Alternative rejected: checkpoint every usage event. It creates excessive full-record writes and still needs terminal deduplication; live snapshots plus one finalized checkpoint preserve truth at the supported safe boundary.

### 7. Make all totals deterministic projections

`AgentTokenAccountingProjector` is a pure helper over `(legacy baseline, finalized ledger, optional active snapshot, current request-shaped context measurement)`. It returns:

- `currentRequest`: active assistant attempt, otherwise latest finalized assistant attempt;
- `latestResponse`: latest completed assistant entry with a committed response-message id;
- `retainedContext`: provider-known only when the current context revision equals the measured attempt revision, otherwise the existing configured estimator result with id/version and `estimated` provenance;
- `assistantConversation`: all assistant physical attempts, including retry/failure/cancellation entries with observed work;
- `compaction`: all model-backed compaction attempts;
- `session`: assistant plus compaction plus explicitly identified legacy baseline;
- `byModel`: finalized attributed entries grouped by exact model; legacy baseline is never assigned to a model;
- immutable ledger and correlation views.

The session maintains a monotonic persisted `contextRevision`; every mutation of request-shaped context increments it. A provider input measurement is current only when revisions match. Otherwise the projector builds the same request-shaped value used by runtime (system prompt, retained transcript, enabled tools, continuation state, and framing) and invokes the already configured estimator. Estimator failure makes retained context unavailable with sanitized estimate metadata and does not relabel stale provider usage.

For each aggregate dimension, expose `knownSubtotal`, missing/inconsistent contributor counts, and completeness. A full `value` exists only when every contributor has that effective dimension. Empty groups are complete zero; an invocation with unknown usage makes the group partial/unavailable. Overall is summed from each entry's effective overall, never recomputed from cross-entry parent/child mixtures.

The existing coarse `usage` properties and token-budget inputs become compatibility projections:

- legacy input/output/overall parents retain their old meaning;
- new entry input/output/total correspond to effective request-context, response-generated, and overall values;
- cache hit aliases cache read;
- old cache miss remains legacy evidence and is not exposed as cache write.

Budget-unverifiable behavior remains: if a configured dimension has any required unknown contributor, later work cannot proceed. Reasoning/cache-specific budgets are not added in this change.

Alternative rejected: update cumulative totals alongside the ledger. Two mutable sources inevitably drift during retry, failure, or restore.

### 8. Add one optional accounting block to the existing record

`AgentSessionRecord` gains an optional versioned accounting block containing accounting generation, context revision, retained transcript-message sidecar, explicit legacy baseline, and finalized entries. The existing `usage` field remains encoded as the deterministic compatibility projection so old readers can still parse the record. New decode rules are:

- no accounting block: generation zero, empty ledger, existing usage copied verbatim to unattributed legacy baseline, and no invented message/model attribution;
- accounting block present: validate schema version, generation/sequence/id uniqueness, operation/outcome correlation, message-sidecar alignment, model syntax, metric provenance/completeness, and exact agreement between compatibility usage and projector output;
- malformed accounting: reject before provider/tool work with existing sanitized configuration/persistence behavior.

The JSONL envelope remains unchanged because it stores full codec snapshots. Fresh-instance tests must cross the real codec and JSONL replay, not merely serialize the accounting object in isolation.

Alternative rejected: synthesize historical ledger entries from the legacy total and selected model. It would fabricate turn/model/response attribution and misclassify old compaction/retries.

### 9. Public API adds accounting views without forcing UI work

`AgentSessionSnapshot` gains an immutable `tokenAccounting` view. Ordered runtime usage events carry the same accounting snapshot or a narrowly equivalent current/aggregate projection; provider adapter types and raw payloads never cross the boundary. Existing event/terminal coarse usage access remains available as compatibility projection so the current prompt controller need not adopt the future chat presentation in this change.

Expected core paths include a focused `token_accounting.dart` (value objects, ledger, projector, codec helpers), `usage.dart`, agent ids/events/transcript/record/runtime/compaction/exports, and tests. Adapter extraction remains in their infrastructure packages. The implementation may split files differently while preserving dependency direction: infrastructure maps wire fields into core semantic helpers; core/runtime never branches on provider id.

Alternative rejected: expose only a raw ledger and make UI derive values. That duplicates high-risk overlap/completeness logic in presentation code.

## Risks / Trade-offs

- [Inclusive/exclusive semantics are mapped incorrectly] → Table-driven normalization invariants plus canonical Chat Completions and Responses fixtures assert parent/child arithmetic and no double count.
- [Repeated usage or terminal events charge twice] → One accumulator/finalization guard per stable attempt id; retry/tool/cancellation tests assert ledger cardinality and projections.
- [Optional malformed provider metadata breaks otherwise valid output] → Isolate usage extraction, retain valid independent fields, record sanitized anomalies, and test negative/conflicting aliases.
- [Cancellation or persistence races lose acknowledged truth] → Finalized entries share existing checkpoint admission/deadline rules; tests cover commit-wins, cancellation-wins, failure, timeout, and no later work.
- [Legacy totals are falsely attributed] → Keep an explicit unattributed baseline and never include it in latest request/response, compaction, or per-model groups.
- [Current context shows stale provider input] → Persist/increment context revision and use provider input only on exact revision match; otherwise label the existing estimator.
- [Ledger growth increases full-record/JSONL entry size] → Preserve complete accounting as required and rely on existing bounded persistence failures; no silent truncation or aggregation is introduced. A future retention policy requires a separate change.
- [Rollback through an old writer loses new ledger data] → Keep old JSON fields readable, but document that an old runtime rewriting a new record discards unknown accounting; rollback is read-compatible, not accounting-preserving.
- [Historical alternate model is no longer registered] → Treat historical model refs as attribution data and validate registration only for new dispatch.

## Migration Plan

1. Introduce versioned normalized usage values and pure mapper/accumulator tests while retaining legacy JSON decode and compatibility getters.
2. Add ledger/projector/message-correlation values and record codec support; prove generation-zero legacy decode and strict malformed-ledger rejection before runtime adoption.
3. Route normal provider attempts and existing token guards through pending/finalized projections, then add lifecycle and persistence tests.
4. Upgrade compactor reports to ordered model-aware attempts and include them in session projections.
5. Prove real JSONL fresh-instance restore, then run full formatting, analysis, and tests. No data rewrite or storage-envelope migration runs at startup.

Rollback to the pre-change binary can read records only because compatibility `usage` and existing fields remain. If that binary saves a record, it will discard the unknown ledger, so rollback after new writes must be treated as accounting-destructive; preserve the data or return to the new reader before further writes.
