## Context

See `proposal.md` for motivation and `specs/agent-session-compaction/spec.md` for the proposed behavior contract. The runtime currently builds each request from the entire `AgentTranscript`, while model metadata already supplies `contextBound`/`outputBound`. Continuation entries point at assistant-message indexes, and repository records use optimistic revision saves. There is no tokenizer, estimator, compaction state, or typed context-overflow error today.

The design synthesizes the supplied Codex/Qwen Code/Koog/OpenCode research rather than reopening it. Codex and OpenCode motivate protected context, persisted lifecycle, and overflow recovery; Qwen motivates pre-send pressure, effectiveness checks, and retry latching; Koog supplies the explicit strategy seam.

**Status:** replaceability, public forced compaction, and Heavy execution mode are user-selected in draft-2. Application implementation remains gated only on explicit final approval of this revised plan.

## Goals / Non-Goals

**Goals:**

- Keep **WHEN** (policy), **HOW MUCH** (estimator), and **HOW** (compactor) independently replaceable.
- Expose sufficient immutable context for deterministic, LLM-backed, and future custom implementations without granting mutation access to live session state.
- Make every accepted rewrite replay-safe, persistent, cancellable, observable, and bounded.
- Deliver useful LLM-summary and deterministic recent-history built-ins without requiring a general plugin registry.
- Support caller-forced compaction through the same configured compactor and transaction contract as automatic compaction.
- Keep the contract testable with fake estimators/compactors/providers and the existing in-memory repository.

**Non-Goals:**

- Prompt-workspace UI adoption, settings UI, or changing its transient one-shot behavior.
- Provider tokenizer packages, dynamic strategy discovery/registry, remote compaction services, or durable repository adapters.
- Perfect semantic recall, restoration of removed raw history, or cross-model summary portability guarantees.

## Decisions

### 1. Fix extension contracts, not algorithms

**User-selected.** Runtime composition exposes three independent ports:

- `AgentContextEstimator.estimate(AgentContextEstimateInput)` returns a non-negative estimate and stable estimator id/version.
- `AgentCompactionTrigger.evaluate(AgentCompactionContext)` returns `skip` or `compact`, with an optional target estimate and strategy-neutral decision metadata.
- `AgentHistoryCompactor.compact(AgentCompactionContext, AgentCompactionDecision)` asynchronously returns `noChange` or an immutable candidate.

`AgentCompactionContext` contains operation/session identity; reason (`preRequest`, `providerOverflow`, or `manual`); selected session model metadata; a credential-free complete request snapshot; protected definition seed prefix; current generated-prefix messages; immutable complete interaction groups with stable group/range identity; defensively copied continuation entries; prior compaction provenance; current estimate/estimator identity; optional target; and cooperative cancellation. It contains no repository handle, live collections, mutable session reference, credentials, provider client, or commit callback.

A candidate selects a contiguous suffix by one supplied legal group boundary, may supply zero or more validated non-privileged/non-tool replacement-prefix messages, and reports strategy id/version, aggregate optional usage, and sanitized metadata. Strategies cannot mutate live state, choose arbitrary partial message indexes, write a repository, or install continuation state for generated messages. The runtime alone reconstructs the candidate transcript, remaps continuations, estimates, validates, checkpoints, and swaps state.

The runtime binds one trigger, estimator, and compactor directly for a session lifetime. Restore binds the persisted state to the current runtime composition. No registry is needed until one live runtime must select among named implementations dynamically.

Alternative: one `compactIfNeeded()` service would be simpler initially but would make trigger, tokenizer, summarizer/model choice, and transaction ownership inseparable—the defect this revision corrects.

### 2. OpenCode-inspired behavior is only the default trigger

The built-in trigger evaluates at the safe boundary before a normal provider request, after queued input and complete tool results are committed. Its configurable defaults are:

- `C` = selected model context bound;
- `O` = explicit per-turn output cap, otherwise `min(model.outputBound, max(2048, ceil(0.10 * C)))`;
- `H` = `max(1024, ceil(0.05 * C))`;
- trigger target `T = C - O - H`;
- post-compaction target `L = floor(0.70 * T)`.

It returns `compact(target: L)` when the complete estimate exceeds `T`; otherwise `skip`. It also returns `compact` for the one eligible typed pre-output provider-overflow event. These numbers and reasons belong to this implementation, not the trigger interface: a custom trigger may use turn count, time, user policy, another threshold, disable overflow recovery, or always skip.

The runtime's fixed safety law is only bounding: at most one overflow event is offered to the trigger and at most one retry is allowed for a logical provider turn. Generic HTTP 400/protocol failures are never guessed to be overflow.

### 3. Estimation remains replaceable with a conservative fallback

The default estimator covers canonical provider-neutral system context, every message/content part, tool schema, opaque continuation JSON, and request framing. Without a tokenizer it uses `ceil(utf8Bytes / 2)` plus fixed framing overhead. This is deterministic and intentionally high-biased, not a universal tokenizer upper bound. Fixed ASCII, Cyrillic, CJK, emoji, tool-schema, and continuation fixtures prove determinism, monotonicity, complete accounting, and stable versioning.

A custom trigger receives the estimate but need not interpret it as tokens or use the default threshold formula. A provider tokenizer can replace only the estimator without changing trigger/compactor or persisted candidate shape.

### 4. Strategy-neutral replacement representation

Definition seed messages and system/developer configuration are protected. Mutable history is partitioned by the runtime into complete interaction groups; each assistant tool call and all correlated results are indivisible. Accepted history is:

`protected seed messages + zero or more generated replacement-prefix messages + one contiguous suffix of complete source interaction groups`.

Generated prefix messages may contain ordinary provider-neutral user/assistant text but no system/developer role, tool call/result, reasoning continuation, or opaque provider state. `AgentCompactionState` records their range/count, so they are not confused with original history. On repeated compaction the old generated prefix is supplied separately to the compactor and replaced—not accumulated—when the strategy returns a new prefix.

This accommodates both summary strategies (generated prefix plus tail) and deterministic recent-N (empty generated prefix plus last N groups). Runtime validation requires every mutating candidate to be strictly smaller under the active estimator and to satisfy the trigger's target when one was supplied. `noChange` is valid and causes no checkpoint/revision increment.

### 5. Ship two built-ins through the same port

`OpenCodeSummaryCompactor` is an OpenCode-inspired incremental structured summary strategy. It receives/injects its own LLM invocation facility and a model selector whose default is the session model but may return another registered model. Runtime does not choose its model, assume one current-model request, or know its internal request count. The built-in bounds its own calls/output, uses non-privileged instructions, sends no tools or opaque continuation state, cooperates with cancellation, and returns aggregate provider usage. It produces a structured generated prefix covering objective, constraints/decisions, facts, relevant tool outcomes, and pending work plus a recent complete tail.

`RecentInteractionGroupsCompactor(N)` is deterministic: it keeps the last `N` complete interaction groups, emits no generated prefix, returns `noChange` when no group can be removed, and never splits a tool cycle. It proves that LLM facilities and summaries are not assumptions of the extension contract and provides deterministic forced-compaction behavior.

Both strategies are ordinary injected implementations. Custom compactors may use another model, no model, one or several internally bounded calls, or another deterministic transform, while the runtime retains state and safety ownership.

### 6. Public forced compaction is an idle serialized operation

**User-selected.** `AgentSession.compact()` returns an observable cancellable `AgentCompactionOperation`, analogous to `AgentRun`, with stable operation identity, ordered lifecycle events, cancellation, and a typed terminal outcome (`compacted` or `noChange`; failures remain typed errors). It always invokes the session-configured compactor independently of the automatic trigger and threshold: the runtime creates a forced `compact` decision with reason `manual` and no target, while the estimator and runtime candidate validation still apply.

The operation is accepted only while a caller-owned session is open and idle. If a run or another compaction is active, it is rejected as busy without cancelling, queueing behind, or mutating that work. While manual compaction is active, a run/second compact is likewise rejected. Session close cancels active compaction and uses the existing persistence shutdown budget. Caller cancellation, revision conflict, and repository commit races follow the same transaction semantics as automatic compaction. `noChange` performs no save and does not increment generation/revision.

Alternatives considered: silently queueing behind a run makes “compact now” timing and snapshot unclear; cancelling a productive run is surprising and can lose partial work. Idle-only serialization is deterministic and consistent with the existing one-active-run session contract.

### 7. Validate, save, then swap

Build a candidate from an immutable context. Validate legal retained boundary, generated-prefix roles/parts, tool correlation, continuation remapping, strict estimate reduction, optional target, strategy metadata, and record codec round-trip before mutation.

For transient sessions, assign transcript/continuations/state together. For repository sessions, save a full candidate record against the expected revision and adopt it in memory only after acknowledgement. Repository cancellation retains the existing commit-wins rule: if cancellation wins, the original remains; if persistence already committed, live state adopts that revision and cancellation then terminates the active run or manual operation. This avoids pretending an acknowledged durable write can be rolled back locally.

Removed continuation entries are dropped. A surviving entry at old index `i` is remapped by the exact protected-prefix/generated-prefix/cut offset, while its origin-bound payload remains byte-for-byte unchanged. This means removed OpenAI Responses encrypted reasoning cannot be replayed, but complete retained tool cycles still have the exact state their adapters require.

Alternative: mutate then checkpoint exposes partially compacted live state and makes conflict rollback unsafe. A two-record transaction is unnecessary because one revisioned session record already contains the entire candidate.

### 8. Additive record compatibility and explicit provenance

Add optional strategy-neutral compaction state to session transcript/record serialization. Missing state decodes as generation zero. A compacted state records generated-prefix range/count, generation, reason, trigger/strategy/estimator ids and versions where applicable, cumulative removed-message count, before/after estimates, sanitized decision metadata, and timestamp; it does not retain removed history or a digest. Decode/restore performs strict structural and continuation validation.

This is an additive compatibility migration. Rollback of code remains able to read only records supported by that older code; therefore deployment rollback for persisted compacted records requires restoring the pre-change record snapshot or retaining forward-compatible optional-field decoding in the old reader. The in-memory repository limits operational migration exposure in this change.

### 9. Complexity, risk, and execution mode

- **Complexity:** high. The change links runtime lifecycle, async cancellation, provider requests/errors, transcript grammar, continuation replay, record codecs, and optimistic persistence. The ports are simple; their atomic interactions are not.
- **Risk:** initial/current **T2**, separately from complexity, because this changes persisted session state, cancellation/retry lifecycle, provider replay behavior, and public architectural contracts.
- **Execution mode:** **heavy**, explicitly selected by the user after draft-1. Sol implements the linked nearest slice and DeepSeek independently verifies every AC/formal criterion; no separate general Sol code review is required.
- **Implementation gate:** still pending explicit final approval of draft-2 because the user requested discussion before implementation.

## Risks / Trade-offs

- [LLM summary can omit or distort important context] → make it one replaceable strategy, keep a complete recent tail, structured sections/provenance, and provide deterministic recent-N as a no-LLM alternative.
- [Summary prompt injection or privilege elevation] → keep summary in non-privileged assistant history, never merge it into system/developer configuration, and omit tools from the summary request.
- [Fallback estimator over-compacts or undercounts] → injectable estimator, visible before/after evidence, safety headroom, low-water hysteresis, and one bounded overflow recovery.
- [An LLM compactor adds cost/latency and may consume quotas] → strategy-owned bounds/model choice, aggregate usage events/accounting, and the deterministic built-in alternative.
- [Custom strategy blocks or hides internal calls] → cancellation is mandatory, usage/provenance are contract outputs, and runtime accepts no mutation until a candidate returns and validates; hard execution deadlines remain configurable at composition.
- [Cancellation races persistence] → immutable candidate plus existing repository commit-wins contract; never claim rollback after an acknowledged commit.
- [Dropping continuation state changes provider cache/reasoning replay] → drop only with removed complete interactions, preserve retained payload exactly, and locally validate before dispatch.
- [A huge protected prefix/current interaction cannot be compacted] → typed deterministic failure before repeated requests; future work may add chunked or user-directed reduction.

## Migration Plan

1. Add strategy-neutral state, extension contexts/ports, fallback estimator, legal-group/remapping helpers, and backward-compatible decode.
2. Deliver the nearest functional slice: deterministic recent-N plus public idle forced compaction and transactional transient/repository tests.
3. Add the replaceable automatic trigger path and OpenCode-inspired default with typed bounded overflow recovery.
4. Add the configurable-model OpenCode summary strategy through the same compactor port.
5. Keep prompt workspace composition unchanged. Roll back by disabling runtime compaction; compacted transcripts remain valid ordinary history when their optional state is understood.

## User Decisions Required Before Implementation

No product or execution-mode choice remains unresolved. Only explicit final approval to begin the Heavy implementation is pending.
