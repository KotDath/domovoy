> **Implementation gate:** Heavy mode is selected, but no task may start until the user explicitly gives final approval of draft-2.

## Acceptance Criteria

| AC | Verifiable outcome |
|---|---|
| AC-01 | Trigger, estimator, and compactor can each be swapped independently; immutable context is sufficient for decisions/candidates and exposes no state mutation or repository capability. |
| AC-02 | Custom trigger rules are honored; the configurable OpenCode-inspired default performs pre-request pressure/no-op decisions without becoming a contract requirement. |
| AC-03 | Fallback estimates are deterministic, monotonic, versioned, and include system/messages/tools/continuations/framing; a replacement estimator changes decisions without other extension changes. |
| AC-04 | Summary, deterministic recent-N, and custom no-LLM candidates share one strategy-neutral representation; repeated compaction replaces generated prefix, preserves protected seed/tail, reduces estimate, and honors optional target. |
| AC-05 | Tool-call/result groups are never split; removed continuation entries are dropped and retained entries are remapped without payload change. |
| AC-06 | Public forced compaction bypasses trigger/threshold, uses the session compactor, supports deterministic compacted/no-change/cancelled outcomes, and rejects active-run/operation races as busy. |
| AC-07 | Candidate failure/conflict/cancellation-won rolls back; repository commit-won adopts exactly the acknowledged candidate; compacted and legacy records restore correctly. |
| AC-08 | Typed pre-output context overflow is offered once to the replaceable trigger and permits at most one accepted compaction/retry; skip, second overflow, prior delta, failure, no-change, or cancellation cannot loop. |
| AC-09 | Automatic and forced lifecycle evidence exposes reason/extension identities/generation/estimates/usage without summary, removed history, credentials, or opaque continuation. |
| AC-10 | Existing runtime composition without compaction and the production one-shot prompt workspace retain their behavior. |

## 1. Extension and State Foundation

**Expected paths:** new focused files such as `lib/core/agents/compaction.dart` and/or `compaction_{context,strategies}.dart`, `policies.dart`, `transcript.dart`, `record.dart`, agent exports, `test/core/agents/compaction_test.dart`, and focused record/repository tests.

- [x] 1.1 Define immutable estimate input/result, compaction context/reason, trigger decision, strategy candidate/no-change, provenance, and cancellation-aware trigger/estimator/compactor ports; verify constructor validation and that no context exposes credentials, mutable state, repository, or commit callback in `flutter test test/core/agents/compaction_test.dart` (AC-01).
- [x] 1.2 Implement the versioned UTF-8/framing fallback estimator over complete request-shaped context; verify exact ASCII, Cyrillic, CJK, emoji, tool-schema, continuation, monotonicity, and replacement-estimator fixtures in focused tests (AC-03).
- [x] 1.3 Partition mutable history into stable complete interaction groups and implement strategy-neutral candidate reconstruction/validation; verify protected seed, generated-prefix restrictions, optional target, strict reduction, no-change, repeated replacement, and invalid-boundary negatives (AC-04, AC-05).
- [x] 1.4 Add optional generated-prefix/provenance state to snapshots/records with legacy generation-zero decode and strict codec validation; verify summary/truncation round trips and malformed prefix/generation/continuation rejection (AC-04, AC-07).

## 2. Nearest Functional Slice — Forced Deterministic and Replaceable Runtime

**Result after approval:** caller-owned sessions expose transactional forced compaction using deterministic recent-N, and runtime composition demonstrably swaps trigger, estimator, and compactor implementations. This is the first Heavy implementation assignment: tasks `1.1–2.4`.

**Expected paths:** `lib/core/agents/runtime.dart`, `events.dart`, `hooks.dart`, `errors.dart`, compaction strategy files, `record.dart`, `repository.dart` only if required, `test/core/agents/{compaction,loop,repository,session_facade}_test.dart`, and `test/support/agent_harness.dart`.

- [x] 2.1 Implement `RecentInteractionGroupsCompactor(N)` through the common port; verify exact last-N complete groups, zero generated prefix, deterministic repeated result, N validation, tool-cycle preservation, and no-change when nothing is removable (AC-04, AC-05).
- [x] 2.2 Add public `AgentSession.compact()` and observable cancellable operation/result/events; serialize it with runs/other compactions, reject busy cases without cancellation/queueing, and verify below-threshold forced invocation, no-change, run-vs-compact races, caller cancellation, and close cancellation (AC-06, AC-09).
- [x] 2.3 Implement runtime-owned validate/checkpoint/swap for transient and repository forced operations; verify validation/save/conflict rollback, no save on no-change, exact revision adoption, commit-wins cancellation, restoration, and no leaked cancellation registrations (AC-05, AC-07).
- [x] 2.4 Bind one trigger/estimator/compactor directly per session lifetime and wire the custom trigger safe-boundary path; verify independent fake substitution for all three, custom skip/compact decisions, immutable context fields, and unchanged transaction behavior without any strategy registry (AC-01, AC-02, AC-03, AC-10).

## 3. Default Automatic Trigger and Overflow Recovery

**Result:** optional automatic compaction follows OpenCode-inspired defaults while custom trigger behavior remains authoritative.

**Expected paths:** compaction policy/trigger implementation, `lib/core/agents/runtime.dart`, `lib/core/llm/errors.dart`/`events.dart`, both provider adapters under `lib/infrastructure/llm/`, corresponding core/infrastructure tests, and the agent harness.

- [x] 3.1 Implement the configurable OpenCode-inspired pre-request trigger with `C/O/H/T/L` defaults only inside that implementation; verify below-threshold skip, above-threshold target, configurable values, impossible protected context, and a custom trigger unaffected by those numbers (AC-02).
- [x] 3.2 Add typed LLM context-overflow classification and conservative provider mappings based only on confirmed codes/fields; verify known mappings and that generic 400/protocol failures do not map to overflow in both infrastructure adapter tests (AC-08).
- [x] 3.3 Offer one pre-output overflow context to the trigger and allow one retry only after effective commit; verify trigger skip, successful recovery, second overflow, prior delta/tool side effect, no-change, compactor failure, and cancellation bounds in `loop_test.dart` (AC-08).
- [x] 3.4 Verify ordered automatic events/redaction and trigger/strategy/estimator identities, target, generation, estimates, and no-loop attempt counts (AC-09).

## 4. Configurable-Model OpenCode Summary Strategy

**Result:** an LLM summary implementation using the same or another selected model remains an ordinary replaceable compactor.

**Expected paths:** summary strategy/model-selector files under `lib/core/agents/`, provider-neutral LLM interfaces already exposed under `lib/core/llm/`, focused `test/core/agents/compaction_test.dart`/`loop_test.dart`, and harness fakes.

- [x] 4.1 Implement `OpenCodeSummaryCompactor` with injected LLM facility/model selector, strategy-owned request/output bounds, structured non-privileged generated prefix, complete recent tail, cancellation, and aggregate usage; verify same-model, alternate-model, empty/inflated/oversized output, and no tools/opaque continuation in focused tests (AC-04, AC-09).
- [x] 4.2 Verify swapping summary, recent-N, and a custom no-LLM compactor requires no runtime/record changes and that repeated summary replaces prior generated prefix while deterministic compaction remains summary-free (AC-01, AC-04).
- [x] 4.3 Integrate reported compactor usage with session usage and applicable guards without assuming a runtime-selected model or fixed internal request count; verify aggregation, quota stop, cancellation, and redacted events (AC-09).

## 5. Integrated Verification

- [x] 5.1 Add regressions proving unconfigured runtime behavior and production prompt-workspace one-shot composition remain unchanged (AC-10).
- [x] 5.2 Format with `dart format .`, then run `flutter analyze` and `flutter test`; record command, cwd, exit code, concise output, and exact checked diff for verifier evidence (AC-01–AC-10).
- [x] 5.3 Under selected Heavy mode, have an independent DeepSeek verifier report PASS/FAIL/UNVERIFIED for AC-01–AC-10 on the frozen implementation, reusing current test evidence; no separate general Sol code review is required.
