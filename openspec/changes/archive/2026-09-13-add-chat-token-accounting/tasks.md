## Acceptance Criteria

| AC | Verifiable outcome |
|---|---|
| AC-01 | Normalized additive `input/cacheRead/cacheWrite/output/reasoning` dimensions, non-additive reported parents, provenance, completeness, effective request/response/overall precedence, and cache-hit ratio obey the canonical arithmetic without double count. |
| AC-02 | Chat Completions and Responses fixtures normalize supported prompt/input, completion/output, overall, cache, reasoning, and explicit cache-write aliases through typed dialect semantics with no provider-id branch in agent runtime. |
| AC-03 | Missing, negative, non-integral, conflicting-alias, child-exceeds-parent, and inconsistent-total usage leaves affected values unavailable/flagged while preserving independent valid counters and an otherwise valid provider completion. Cache miss never becomes cache write. |
| AC-04 | Multiple usage updates and repeated terminal usage reconcile as cumulative snapshots into one attempt; corrections/inconsistencies are not converted to deltas and finalization cannot occur twice. |
| AC-05 | Immutable ledger entries have unique stable sequence/attempt/model plus valid assistant run/turn/retry/request/response or compaction-operation correlation; tool-loop turns, overflow retries, historical models, and compacted-out message identities remain distinguishable. |
| AC-06 | Public immutable views expose active-or-latest request input breakdown, latest committed response output/reasoning, current retained request-shaped context with provider/estimator provenance, assistant/compaction/session aggregates, known subtotals/completeness, per-model groups, and ledger data without provider types. |
| AC-07 | Normal completion, tool loops, overflow recovery, and later turns produce one entry per physical provider invocation and deterministic assistant/session/budget projections with no reset, loss, or duplicate charge. |
| AC-08 | Failure, cancellation, local stop, persistence conflict/failure, and shutdown timeout finalize observed usage at most once, never correlate partial output as a response, start no forbidden later work, and preserve existing cancellation/persistence precedence. |
| AC-09 | Same-model, alternate-model, multi-invocation, failed, and cancelled model-backed compaction reports separate compaction entries; deterministic compaction emits none; compaction never appears as an assistant response. |
| AC-10 | A pre-change record decodes as accounting generation zero with empty ledger and unattributed legacy baseline; new codec validation rejects malformed identities/correlation/arithmetic/projections while compatibility coarse usage remains deterministic. |
| AC-11 | Fresh codec/JSONL store/runtime instances exactly restore acknowledged assistant, retry, compaction, model, outcome, message-correlation, context-revision, legacy, and aggregate data; an unacknowledged in-flight attempt is not invented after restart. |
| AC-12 | No pricing, tokenizer, UI, external analytics, database/storage-envelope migration, raw provider payload persistence, or unsupported-provider guessing is introduced; focused tests, `dart format .`, `flutter analyze`, full `flutter test`, strict OpenSpec validation, and diff checks pass. Platform builds run only if platform-conditional files or dependencies change. |

## Heavy Slice Plan

**Recommended nearest Heavy slice — H1, tasks 1.1–2.5:** freeze the canonical usage contract and normalize both provider wire families through pure semantic helpers and fixtures. The independent result is that every currently supported provider stream emits non-overlapping, provenance-aware cumulative usage snapshots, including safe negative/inconsistent cases, without any runtime/provider ledger dependency (AC-01–AC-04).

**Subsequent slices in this same change:** H2 tasks 3.1–4.5 adds immutable ledger/projection/codec values and generation-zero decode (AC-05, AC-06, AC-10); H3 tasks 5.1–5.6 adopts them in normal runtime lifecycle, guards, events, and persistence races (AC-04–AC-08); H4 tasks 6.1–8.4 adds compaction attribution, real restart coverage, and final formal verification (AC-05–AC-12). Every slice uses the user-selected Heavy route: Sol implementation followed by independent DeepSeek verification, with no mandatory general Sol code review and no product approval gate.

## 1. Canonical Usage Values and Snapshot Reconciliation — H1

**Result:** core can represent and reconcile provider facts without overlap or fabricated values.

**Expected paths:** `lib/core/llm/usage.dart`; optional focused helpers such as `lib/core/llm/usage_normalization.dart`; `lib/core/llm/events.dart`; `lib/core/llm/llm.dart`; `test/core/llm/request_events_test.dart`; optional new `test/core/llm/usage_normalization_test.dart`.

- [x] 1.1 Add immutable metric provenance, additive dimensions, reported parent totals, completeness/anomaly values, effective request/response/overall getters, and cache-hit ratio; verify table tests cover provider-total precedence, both fallback derivations, partial/unavailable values, zero denominator, and parent/child no-double-count invariants (AC-01).
- [x] 1.2 Version usage JSON while preserving conservative decode of old `input/output/total/cacheHit/cacheMiss` payloads; verify exact old/new round trips, cache miss never becoming cache write, invalid negative persisted values being rejected, and defensive immutability (AC-01, AC-03, AC-10).
- [x] 1.3 Implement a pure semantic normalizer with explicit inclusive-child declarations and checked subtraction; verify equal/conflicting aliases, missing operands, child-exceeds-parent, inconsistent overall, and independent-valid-field retention without provider identifiers (AC-01, AC-03).
- [x] 1.4 Implement the single-invocation cumulative-snapshot accumulator and finalization guard; verify partial then complete updates, repeated terminal usage, valid correction, inconsistent decrease, empty usage, and repeated-finalize behavior without additive deltas (AC-04).

## 2. Chat Completions and Responses Mapping — H1 Completion

**Result:** both supported wire families produce the canonical core contract directly at their boundaries.

**Expected paths:** `lib/infrastructure/llm/openai_compatible/openai_chat_completions_llm_provider.dart`; provider profile/dialect metadata if needed; `lib/infrastructure/llm/openai_responses/openai_responses_llm_provider.dart`; `test/infrastructure/llm/openai_compatible_adapter_test.dart`; `test/infrastructure/llm/openai_responses_adapter_test.dart`; fixture/support files under `test/support/` if useful.

- [x] 2.1 Add typed dialect-owned usage extraction semantics shared with the pure normalizer and verify static/source tests find no usage mapping branch on provider id in agent runtime (AC-02, AC-12).
- [x] 2.2 Normalize Chat Completions prompt/input, completion/output, total, cache direct/detail, DeepSeek-style hit/miss, reasoning details, and configured explicit cache-write aliases; verify canonical SSE fixtures for inclusive/exclusive arithmetic, equal aliases, absent write, and exact provenance (AC-01–AC-03).
- [x] 2.3 Normalize Responses input/output/total, cached-input details, reasoning-output details, and configured explicit cache-write detail; verify canonical SSE fixtures preserve reported parents, derive exclusive input/output once, and leave unsupported cache write unavailable (AC-01–AC-03).
- [x] 2.4 Make malformed optional usage fields degrade only affected metrics while preserving unrelated usage and valid completion; verify negative, non-integral, conflicting alias, impossible child/parent, and inconsistent overall fixtures in both adapters (AC-03).
- [x] 2.5 Run the H1 focused core/provider tests, freeze the slice, and obtain independent Heavy verification with PASS/FAIL/UNVERIFIED evidence for AC-01–AC-04 and the no-provider-runtime-branch check (AC-01–AC-04, AC-12).

## 3. Stable Ledger and Transcript Correlation — H2

**Result:** physical provider work has immutable, model-aware identities independent of runtime mutation.

**Expected paths:** new `lib/core/agents/token_accounting.dart` or cohesive equivalents; `lib/core/agents/ids.dart`; `lib/core/agents/transcript.dart`; `lib/core/agents/agents.dart`; `test/core/agents/token_accounting_test.dart`; compaction transformation tests.

- [x] 3.1 Add stable provider-attempt and transcript-message identities plus immutable assistant/compaction ledger entry variants; verify constructors/JSON reject blank/duplicate ids, negative sequence/ordinal, invalid outcomes, missing assistant correlation, response ids on non-completed or compaction entries, and mutable collection escape (AC-05, AC-10).
- [x] 3.2 Add a retained-transcript message-identity sidecar/projection, assigning ids to new messages while permitting null legacy ids; verify append order/alignment, role-aware response correlation, exact round trip, and immutability (AC-05, AC-06, AC-10).
- [x] 3.3 Preserve retained message ids through legal compaction, assign ids to generated replacement messages, and retain historical ledger correlations for removed messages; verify reindexing/removal cannot alias another response and exposes retained-vs-historical status (AC-05).

## 4. Pure Projections and Record Evolution — H2 Completion

**Result:** later UI and persistence can consume deterministic accounting without running the agent loop.

**Expected paths:** accounting/projector files; `lib/core/agents/record.dart`; `lib/core/agents/transcript.dart`; `lib/core/agents/catalog.dart` only if its projection requires compile adaptation; `test/core/agents/token_accounting_test.dart`; `test/core/agents/session_facade_test.dart`; `test/core/agents/repository_test.dart`.

- [x] 4.1 Implement pure latest-request/latest-response, assistant, compaction, session, per-model, and ledger projections; verify known subtotals, complete/partial/unavailable values, retries/failures, mixed models, empty groups, cache ratio, legacy exclusion, and no cumulative re-derivation across overlapping parents/children (AC-01, AC-05, AC-06).
- [x] 4.2 Implement context revision and retained-context projection that uses provider input only for an exact revision match and otherwise the existing estimator with id/version; verify every request-shaped mutation invalidates stale provider context, estimator failure is sanitized/unavailable, and no tokenizer/provider guess appears (AC-06, AC-12).
- [x] 4.3 Add the optional versioned accounting block and deterministic compatibility `usage` projection to `AgentSessionRecord`; verify old records decode to generation zero/empty ledger/legacy baseline and re-encode without invented request, response, model, or compaction attribution (AC-10).
- [x] 4.4 Add strict accounting decode/record validation and verify duplicate/out-of-order attempts, sidecar misalignment, invalid operation/outcome/message correlation, malformed model refs, impossible metric provenance/completeness, and compatibility-total disagreement fail before provider/tool work with sanitized errors (AC-05, AC-10).
- [x] 4.5 Run H2 focused accounting/codec/repository tests, freeze the slice, and obtain independent Heavy verification with evidence for AC-05, AC-06, and AC-10, including generation-zero and negative decode fixtures (AC-05, AC-06, AC-10).

## 5. Normal Agent Runtime Lifecycle — H3

**Result:** normal assistant work, retries, tools, guards, and terminals use one exact-once accounting source.

**Expected paths:** `lib/core/agents/runtime.dart`; `lib/core/agents/events.dart`; `lib/core/agents/hooks.dart` only if correlation adaptation is required; `lib/core/agents/transcript.dart`; `test/core/agents/loop_test.dart`; `test/core/agents/session_facade_test.dart`; `test/core/agents/repository_test.dart`; prompt controller only for compile-compatible adaptation, not new UI.

- [x] 5.1 Replace mutable turn/session addition with one pending attempt accumulator and finalized ledger projection; verify repeated updates/terminal usage produce one entry, one usage event projection, one guard contribution, and stable request/response correlation on a normal completed answer (AC-04–AC-07).
- [x] 5.2 Allocate one logical turn outside overflow retry and distinct physical attempt ids for overflow/retry and tool-loop continuations; verify first-attempt usage survives recovery, compaction ordering is deterministic, retry shares the turn but not attempt, later tool turns differ, and every known token contributes once (AC-05, AC-07).
- [x] 5.3 Finalize failure, overflow, cancellation, duration/idle/budget stop after dispatch with partial/unknown usage and no response id; verify no partial assistant commit, no later provider/tool work, sole-terminal precedence, and no duplicate from late teardown or repeated cancel (AC-07, AC-08).
- [x] 5.4 Evaluate existing input/output/total budgets from the same ledger-plus-active run projection; verify cache/reasoning inclusion is counted once, known thresholds stop correctly, and partial required totals retain budget-unverifiable behavior (AC-01, AC-04, AC-07, AC-08).
- [x] 5.5 Include finalized entries/message ids/context revision in the next required checkpoint and expose immutable accounting in session snapshots/events while retaining coarse compatibility access; verify success, conflict, save failure, cancellation-before-admission, commit-wins cancellation, ignored-save timeout, restore quarantine, and current prompt compile/behavior without adding chat UI (AC-06–AC-08, AC-12).
- [x] 5.6 Run H3 focused loop/session/repository lifecycle tests, freeze the slice, and obtain independent Heavy verification with evidence for AC-04–AC-08 and exact ledger cardinality under retries, tools, cancellation, and persistence races (AC-04–AC-08).

## 6. Model-Backed Compaction Accounting — H4

**Result:** compaction cost is model-aware session work but can never be mistaken for an assistant response.

**Expected paths:** `lib/core/agents/compaction.dart`; `lib/core/agents/summary_compactor.dart`; `lib/core/agents/runtime.dart`; `test/core/agents/compaction_test.dart`; `test/core/agents/summary_compactor_test.dart`; `test/core/agents/loop_test.dart`.

- [x] 6.1 Replace aggregate-only compactor usage with ordered per-invocation model/outcome/usage reports on success, failure, and cancellation; verify invalid missing-model/ordinal reports are rejected and deterministic compactors return no reports (AC-09).
- [x] 6.2 Route the built-in summary provider stream through the shared snapshot accumulator and emit its exact selected model; verify repeated terminal usage, partial failure/cancellation, same/alternate model, and no raw summary/provider payload in reports (AC-04, AC-09, AC-12).
- [x] 6.3 Finalize compactor reports as operation-correlated ledger entries before candidate continuation/terminal settlement; verify automatic/manual/overflow compaction, multiple custom invocations/models, guard charging, persistence failure/cancellation precedence, deterministic no-entry behavior, and exclusion from latest assistant response/conversation totals (AC-05–AC-09).

## 7. Codec and Durable Restart Integration — H4 Completion

**Result:** acknowledged accounting remains exact across the already delivered JSONL persistence boundary.

**Expected paths:** `test/infrastructure/agents/jsonl/jsonl_agent_session_store_test.dart`; core runtime/repository integration tests; JSONL implementation only if generic full-record replay reveals an actual compatibility defect, with no envelope version change.

- [x] 7.1 Persist and restore through fresh `AgentSessionCodec`, JSONL store, repository, and runtime instances a session containing legacy baseline, normal/tool turns, overflow retry, failed/unknown usage, same/alternate-model compaction, compacted-out response correlation, and mixed completeness; verify exact entries and all projections after restart (AC-05, AC-06, AC-09–AC-11).
- [x] 7.2 Verify only acknowledged entries restore across save conflict/failure, cancellation admission, commit-wins, trailing-fragment recovery, and simulated process loss during an active attempt; confirm no storage-envelope/database migration and no invented in-flight usage (AC-08, AC-10–AC-12).

## 8. Formal Checks and Independent Heavy Verification

- [x] 8.1 Run all focused usage, provider adapter, accounting, runtime, compaction, codec, repository, and JSONL restart tests; record cwd, exact commands, exits, concise outputs, checked diff/fingerprint, environment, and limitations (AC-01–AC-12).
- [x] 8.2 Run `dart format .`, `flutter analyze`, and full `flutter test`; run relevant web/native debug builds only if platform-conditional code or dependencies changed, otherwise record why builds are not impacted (AC-12).
- [x] 8.3 Run `openspec validate add-chat-token-accounting --strict`, `.opencode/bin/repo-git diff --check`, and static checks proving no provider-id usage branch in agent runtime and no pricing/tokenizer/UI/analytics/database/envelope additions; preserve this as the sole active change (AC-02, AC-12).
- [x] 8.4 Freeze the complete implementation and obtain independent DeepSeek Heavy verification returning PASS/FAIL/UNVERIFIED with evidence for AC-01–AC-12 and the negative alias/arithmetic/retry/cancellation/persistence/legacy/restart scenarios; no separate general Sol review is required.
