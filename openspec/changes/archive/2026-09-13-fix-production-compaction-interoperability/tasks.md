## Acceptance Criteria

| AC | Verifiable outcome |
|---|---|
| AC-01 | During large-current→smaller-target model switching, compaction context exposes both models, the default summary selector invokes the current session model, and candidate fit/continuation filtering use the target model. |
| AC-02 | A tool-free GPT-5/Responses summary with valid text and non-null validated turn state succeeds; the turn state is neither replayed, persisted, projected, nor leaked. |
| AC-03 | Production-default automatic compaction over many complete groups and input beyond the former 262,144-character cap batches by the actual selected summary-model capacity and converges within a finite call bound for supported catalog models. |
| AC-04 | Prior summaries participate in rolling batches; each successful call consumes at least one complete group; one impossible oversized group, cancellation, provider failure, or invocation-cap exhaustion fails without candidate commit or loops. |
| AC-05 | Every physical batch preserves ordered exact-model usage/outcome reports and existing transaction, cancellation, ledger, revision, and model-switch accounting semantics. |
| AC-06 | Realistic Responses `output_item.done` with `output_text.logprobs: []` is accepted and preserved opaquely; valid populated closed entries round-trip/replay, malformed or unknown fields remain protocol failures. |
| AC-07 | Existing compaction strategies, manual/automatic/overflow flows, continuation invariants, model selection, persistence, token accounting, and chat UI/composition regressions remain green. |
| AC-08 | For tool-call and final-answer completions, proactive auto-compaction uses only `requestContext`/equivalent provider context usage from the latest completed physical LLM invocation, evaluates after transcript/usage commit at a safe boundary and before any next dispatch, skips as unavailable when usage is missing, retains typed overflow recovery, and never treats estimator output as trigger pressure or billed usage. |
| AC-09 | Target-model switching compares the latest provider-reported context usage with target capacity; when usage is unavailable and target capacity is smaller, configured compaction runs before switching without numeric-fit claims or estimator triggering, while no-change, failure, or cancellation preserves the old selection. |

## 1. Separate Current and Target Model Context

**Expected paths:** `lib/core/agents/compaction.dart`, `runtime.dart`, `summary_compactor.dart`, `test/core/agents/compaction_test.dart`, `summary_compactor_test.dart`, and `model_switch_test.dart`.

- [x] 1.1 Add additive `currentSessionModel` context metadata with fallback to existing `selectedModel`, preserve all existing immutable copies/`withTarget` behavior, and verify old construction plus ordinary contexts resolve both fields equally (AC-01, AC-07).
- [x] 1.2 Populate current and target models separately for model-switch compaction and make the default summary selector use current-session metadata while candidate estimation/fit keep target metadata; verify an actual large-current→smaller-target catalog scenario dispatches summary requests to the current provider/model and validates the candidate against the target (AC-01). Provider-first switch triggering is superseding work in 4.2.
- [x] 1.3 Verify alternate explicit summary-model selection still overrides the default and no `AgentCompactionState`/record JSON field changes are introduced (AC-01, AC-07).

## 2. Strict Responses Logprobs Interoperability

**Expected paths:** `lib/core/llm/continuation.dart`, `test/core/llm/reasoning_continuation_test.dart`, and `test/infrastructure/llm/openai_responses_adapter_test.dart`; adapter production code only if collection currently strips the validated field.

- [x] 2.1 Extend only the closed `output_text` validator for optional `logprobs`, implementing the documented closed entry/top-entry shapes, finite-number checks, nullable byte arrays with `0..255` elements, and exact frozen preservation; verify `[]`, valid populated content, JSON round-trip, and replay projection tests (AC-06).
- [x] 2.2 Add negative tests for non-list, unknown fields, malformed entry/top-entry, non-finite/non-numeric probability, and invalid bytes, plus regression assertions that unrelated output-item extras remain rejected (AC-06, AC-07).
- [x] 2.3 Add a realistic Responses `response.output_item.done` SSE fixture containing `logprobs: []`; verify completion/turn-state collection succeeds, normalized text is unchanged, opaque payload retains the field, and diagnostics/events do not expose it (AC-06).

## 3. Bounded Incremental Summary Compaction

**Expected paths:** `lib/core/agents/summary_compactor.dart`, `compaction.dart` only for additive context plumbing, production composition where estimator/config is injected, `test/core/agents/summary_compactor_test.dart`, `loop_test.dart`, `model_switch_test.dart`, `test/app_composition_test.dart`, and harness/provider fakes.

- [x] 3.1 Replace `maxInputCharacters` production gating with injected-estimator capacity `Bₛ = summaryModel.contextBound − min(configuredMaxOutputTokens, summaryModel.outputBound) − resolvedHeadroom`; verify positive/configurable bounds and capacity calculations across every built-in DeepSeek, Kimi, and OpenAI catalog model (AC-03, AC-07).
- [x] 3.2 Implement maximal fitting batches over consecutive complete legal groups with rolling prior-summary replacement, strictly increasing group cursor, ordered invocation ordinals/reports, no batch retry, and configurable `maxSummaryInvocations` default 32; verify multi-batch success, prior-summary participation, tool-boundary preservation, and exact usage aggregation (AC-03, AC-04, AC-05).
- [x] 3.3 Accept successful tool-free summary completion with non-null validated Responses turn state while discarding it; retain rejection for tool-call deltas and disallowed finish outcomes, and verify a required-reasoning GPT-5 fixture succeeds without turn-state replay/persistence/projection (AC-02, AC-07).
- [x] 3.4 Add negative tests where the next complete group cannot fit, the retained group prevents target fit, cancellation/provider failure occurs after earlier batches, or the invocation cap is reached; verify no candidate/provenance commit, no extra invocation/retry, and all incurred reports finalize exactly once (AC-04, AC-05).
- [x] 3.5 Add a production-composed compaction scenario whose many-group input exceeds the former character cap; verify summary capacities are compatible with supported provider measurements/targets, compaction converges within the bounded calls, and equivalent scenarios cover representative DeepSeek, Kimi, and OpenAI model bounds (AC-03, AC-05). The pre-revision estimator-trigger assertion is superseded by section 4.

## 4. Provider-Completion Trigger and Model-Switch Correction

**Expected paths:** `lib/core/agents/{compaction,runtime,token_accounting}.dart` and focused `test/core/agents/{compaction,loop,model_switch,token_accounting}_test.dart`; composition only if required by the existing wiring.

- [x] 4.1 Replace estimator-led proactive pressure with latest-completed provider `requestContext`/equivalent usage and move evaluation after transcript/usage commit; verify tool-call and final-answer boundaries, missing-usage skip/unavailable, retained typed-overflow recovery, and that estimates affect only compactor batching/candidate reduction and never billed usage (AC-08).
- [x] 4.2 Make model switching compare latest provider context usage with target capacity; verify unavailable usage plus a smaller target runs configured compaction before switching without numeric-fit or estimator-trigger claims, and no-change/failure/cancellation preserve the old selection (AC-09, AC-01, AC-05).

## 5. Final-Audit Regression Verification

- [x] 5.1 After tasks 4.1–4.2, run focused tests for compaction, token accounting, model switching, loop boundaries, reasoning continuation, Responses adapter, and production composition; record commands, cwd, exit codes, outputs, and exact checked dirty content (AC-01–AC-09). Prior `+147` evidence predates draft-3 and is historical only.
- [x] 5.2 Run `dart format .`, `flutter analyze`, and full `flutter test` on the revised implementation; require the existing 436 baseline tests plus all added cases to pass and record reproducible evidence (AC-07–AC-09). Prior `+448` evidence predates draft-3 and is historical only.
- [x] 5.3 Under selected Light mode, have Sol code review and a separate-context DeepSeek verifier run in parallel on one frozen implementation; close `REV-COMP-001`, `REV-COMP-002`, `REV-COMP-003`, and `REV-OPENAI-001`, and return code verdict plus PASS/FAIL/UNVERIFIED evidence for AC-01–AC-09 without another broad contract review.
