# Feature State: fix-production-compaction-interoperability

- **change:** `fix-production-compaction-interoperability`
- **result:** ACCEPTED on the frozen draft-3 implementation. Reviewer author `ses_f66e4de49ffeZHhitU9lQHTyfW` returned APPROVED and closed `REV-COMP-001`, `REV-COMP-002`, `REV-COMP-003`, `REV-OPENAI-001`, and the provider-trigger finding against reviewed digest `69f7572957401814b4cc1ea0203377a23c6f1690105b5ebeb4180e96a01404dc`. Separate-context verifier `ses_f6673abcfffe8fdqdWv3grSrGO` returned PASS/CHECKS_PASS at runner `worktree-sha256:2f25513bdfa1e33b29b52c869484e3e7de1ea4e7577b0e2078cd1dcbba09bfd3`, result `check-71b2f92d4f8cdd2204f12cd13a6fe60c1d5ed89617a4c400bd0217f7d8a1ce08`, full `+449` tests. Delta specs synced to main specs and the change archived. Execution Light, `rework_count: 1`.
- **scope_id:** `production-compaction-interoperability-fixes`
- **attempt_id:** `implementation-1`
- **stage:** `accepted`
- **contract_revision:** `draft-3`
- **base_revision:** `f87c8a2d483e182e294ec60fc144b66d75b691d4`
- **starting_dirty_diff:** HEAD matched base. At this continuation start the tree already carried the draft-1 application/test changes plus partial draft-3 trigger edits: 12 tracked files, `1696 insertions(+), 217 deletions(-)`, plus the untracked planning/state paths. Those edits were preserved and completed, not reverted. At draft-1 writer start the same 12 paths held `1493 insertions(+), 128 deletions(-)`.
- **initial_tier:** `T2`
- **current_tier:** `T2`
- **risk_evidence:** T2 remains separate because automatic-compaction timing and model-switch lifecycle are architectural contracts.
- **complexity:** moderate and bounded; the correction reuses existing provider usage, trigger, compactor, and model-switch seams, has no unresolved architecture question, and has focused deterministic AC.
- **recommended_mode:** `light`
- **execution_mode:** `light`
- **selection_source:** Latest explicit user request: “используй лёгкого имплементатора”.
- **mode_rationale:** DeepSeek can apply the focused trigger correction; Sol code review and separate-context DeepSeek verification can check the same frozen diff in parallel. T2 does not require Heavy by itself.
- **model_tiers_used:** planning/revision architect `strong`; planned coder DeepSeek `fast`, reviewer Sol `strong`, verifier DeepSeek `fast` in separate context.
- **rework_count:** `1` (final-audit fix cycle 1; not reset by this new targeted change)

## Findings and Existing Evidence

- **reviewer task:** `ses_f66e4de49ffeZHhitU9lQHTyfW` — `CHANGES_REQUIRED` on base HEAD.
- **verifier task:** `ses_f66e4de2cffeOBS2iLcZw4lGna` — 436 tests passed, but the four production combinations below were not covered.
- **REV-COMP-001 High:** model-switch context substitutes target model for current session model, causing wrong default summary selection.
- **REV-COMP-002 High:** valid tool-free Responses summary completion is rejected solely for non-null provider turn state.
- **REV-COMP-003 High:** fixed 262,144-character input gate prevents production-default long-history recovery before provider dispatch.
- **REV-OPENAI-001 High:** standard Responses `output_text.logprobs: []` is rejected by the closed continuation schema.
- **REV-COMP-001 status:** `closed` — reviewer `ses_f66e4de49ffeZHhitU9lQHTyfW` approved; context separates current and target models, production-like large-current→smaller-target coverage proves default summary dispatch remains on the current model and commit uses the target.
- **REV-COMP-002 status:** `closed` — reviewer approved; tool-free Responses summary turn state is accepted then discarded with no replay/persistence/projection.
- **REV-COMP-003 status:** `closed` — reviewer approved; fixed input-character gate removed, estimator/model-bound maximal complete-group batching with rolling summary and cap/cancel/failure rollback verified.
- **REV-OPENAI-001 status:** `closed` — reviewer approved; closed `output_text.logprobs` validation supports empty/populated standard shapes, exact opaque round-trip/replay, and rejects malformed/unrelated extras.
- **CONTRACT-COMP-TRIGGER-001 T2 status:** `closed` — reviewer approved the provider-usage trigger and model-switch correction; verifier PASS at runner `worktree-sha256:2f25513bdfa1e33b29b52c869484e3e7de1ea4e7577b0e2078cd1dcbba09bfd3`.
- **open_findings:** none. All five findings are closed by reviewer `ses_f66e4de49ffeZHhitU9lQHTyfW`; verifier `ses_f6673abcfffe8fdqdWv3grSrGO` returned PASS/CHECKS_PASS for AC-01–AC-09.

## Tasks / AC

- **nearest independently verifiable result:** delivered and accepted — reviewed+verified frozen draft-3 implementation, synced main specs, archived change, and local bookkeeping commit for user report.
- **AC:** existing `AC-01–AC-07` remain; `AC-08` covers latest-completed provider usage, safe commit boundary, unavailable skip, typed overflow, and estimator exclusion; `AC-09` covers provider-first target switching and unavailable smaller-target compaction fallback.

## Scope and Paths

- **included:** existing four-finding fixes plus latest-completed provider context trigger, safe post-commit evaluation, missing-usage skip, retained typed-overflow recovery, estimator exclusion, provider-first smaller-target switching, and regression updates for the three draft-1 tests that assumed the estimator trigger (`test/app_composition_test.dart`, `test/core/agents/model_switch_test.dart`, `test/features/chat/integration/chat_workspace_end_to_end_test.dart`).
- **excluded:** new event/provenance APIs; UI redesign; strategy registry; new providers/models; persistence migration; summary format change; unrelated Responses fields.
- **planning_paths:** `openspec/changes/fix-production-compaction-interoperability/**`, `.opencode/workflow/feature-state/fix-production-compaction-interoperability.md`.
- **expected_implementation_paths:** focused correction in `lib/core/agents/{compaction,runtime}.dart`, `lib/app.dart` composition, and focused tests `test/core/agents/{compaction,loop,model_switch}_test.dart`, `test/app_composition_test.dart`, and the chat journey integration test. `lib/core/agents/token_accounting.dart` and `test/core/agents/token_accounting_test.dart` required no draft-3 edit.

## Decisions / Gates / Dependencies

- **decisions:** record only the user's clarified behavior: latest-completed provider `requestContext`/equivalent drives proactive compaction after transcript/usage commit; missing usage skips unavailable; typed overflow remains; estimator is internal to compactor batching/candidate reduction and never trigger or billed usage; unavailable usage with a smaller target runs configured compaction before switching and no-change/failure/cancellation preserve the old selection without numeric-fit claims.
- **gates:** all gates passed. Independent Light reviewer `ses_f66e4de49ffeZHhitU9lQHTyfW` (Sol) approved on digest `69f7572957401814b4cc1ea0203377a23c6f1690105b5ebeb4180e96a01404dc`; separate-context verifier `ses_f6673abcfffe8fdqdWv3grSrGO` (DeepSeek) returned PASS/CHECKS_PASS at runner `worktree-sha256:2f25513bdfa1e33b29b52c869484e3e7de1ea4e7577b0e2078cd1dcbba09bfd3`, result `check-71b2f92d4f8cdd2204f12cd13a6fe60c1d5ed89617a4c400bd0217f7d8a1ce08`, full `+449`.
- **dependencies:** clean base HEAD and accepted compaction/ledger/model-switch contracts; the four draft-1 finding fixes are preserved on the same frozen tree; AC-08–AC-09 verified post-draft-3.
- **blockers:** none. Implementation, review, verification, spec sync, and archive are complete.
- **writer task id:** `ses_f66c8eacfffehqqdVj7PTF3yqQ` was the architect revision that recorded draft-3 and edited only OpenSpec/state. The application/test implementation continuation issued no runner result_id/fingerprint of its own; the verifier's runner revision/result above are the authoritative check evidence.
- **implementation task IDs:** `1.1–4.2` implemented; `5.1–5.2` executed with passing evidence below; `5.3` closed by the accepted review/verification.
- **current_dirty_state before bookkeeping commit:** 13 tracked application/test files (`1810 insertions(+), 222 deletions(-)`), 2 modified main specs (`openspec/specs/agent-session-compaction/spec.md`, `openspec/specs/llm-provider-core/spec.md`), the untracked feature-state file, and the archived change at `openspec/changes/archive/2026-09-13-fix-production-compaction-interoperability/`. No unrelated dirty paths. Base remains `f87c8a2d483e182e294ec60fc144b66d75b691d4`. `.opencode/bin/repo-git diff --check` exit `0`, no output.
- **planning validation and archive:** prior strict change validation exit `0`. After sync, `openspec validate --specs --strict` exit `0` (`9 passed, 0 failed`); `openspec list` reports no active changes; delta specs were merged into main specs and the sole active change was archived to `openspec/changes/archive/2026-09-13-fix-production-compaction-interoperability/`. All `16/16` tasks in the archived `tasks.md` are checked.

## Draft-3 Implementation Evidence

- **implementation content:** `lib/app.dart` injects the runtime estimator into `OpenCodeSummaryCompactor`; `lib/core/agents/compaction.dart` adds `AgentCompactionContext.currentSessionModel`/`providerContextUsage`, provider-usage triggering with provider/unavailable metadata, and the corrected terminal-outcome report consistency; `lib/core/agents/runtime.dart` tracks and invalidates `_LiveSession.latestProviderContextUsage`, evaluates automatic compaction after transcript/usage commit at the pre-request boundary and after a final-answer commit, and switches models from provider usage with the smaller-target conservative fallback. The four draft-1 finding fixes (separate current/target model, tool-free summary turn state discard, bounded incremental batching, Responses `logprobs`) are unchanged.
- **continuation scope:** completed the partial draft-3 edits present at continuation start; no file was reverted. Added one focused AC-08 tool-call-boundary test and updated three draft-1 tests that assumed estimator-led triggering (`test/app_composition_test.dart` fake SSE now reports provider `usage`; the model-switch cancellation-race test now uses a smaller target; the chat journey test reports above-threshold provider usage and asserts the `provider` source).
- **focused suite (task 5.1):** cwd `/home/auroraos/omp/personal/domovoy`; `flutter test test/core/agents/compaction_test.dart test/core/agents/token_accounting_test.dart test/core/agents/model_switch_test.dart test/core/agents/loop_test.dart test/core/llm/reasoning_continuation_test.dart test/infrastructure/llm/openai_responses_adapter_test.dart test/app_composition_test.dart`; exit `0`; final output `+142: All tests passed!`.
- **mandatory Flutter suite (task 5.2):** same cwd; `dart format .` exit `0` (`155 files (0 changed)`); `flutter analyze` exit `0` (`No issues found!`); full `flutter test` exit `0` (`+449: All tests passed!` — 436 baseline plus 13 added cases, including the one added on continuation).
- **targeted debugging evidence (superseded by the final runs above):** the initial draft-3 continuation focused run showed `+139 -2` (two estimator-trigger test regressions) and the first full run showed `+448 -1` in the chat journey integration test; all three were draft-1 tests whose fixtures assumed estimator-led compaction and were updated as described.
- **formal/diff checks:** cwd `/home/auroraos/omp/personal/domovoy`; `.opencode/bin/repo-git diff --check` exit `0`, no output; `.opencode/bin/repo-git status --short` shows the 13 tracked paths plus the two untracked planning/state paths.
- **environment/dependencies:** Linux; Flutter/Dart from the repository environment; dependency resolution succeeded; 14 newer package versions reported incompatible with current constraints and unchanged; no network provider calls, builds, commit, or archive.
- **implementation content fingerprint:** SHA-256 manifest digest `69f7572957401814b4cc1ea0203377a23c6f1690105b5ebeb4180e96a01404dc`, over the 13 tracked implementation/test paths in the order `lib/app.dart`, `lib/core/agents/compaction.dart`, `lib/core/agents/runtime.dart`, `lib/core/agents/summary_compactor.dart`, `lib/core/llm/continuation.dart`, `test/app_composition_test.dart`, `test/core/agents/compaction_test.dart`, `test/core/agents/loop_test.dart`, `test/core/agents/model_switch_test.dart`, `test/core/agents/summary_compactor_test.dart`, `test/core/llm/reasoning_continuation_test.dart`, `test/features/chat/integration/chat_workspace_end_to_end_test.dart`, `test/infrastructure/llm/openai_responses_adapter_test.dart`. This is a direct content manifest, not a runner RESULT/fingerprint.
- **subsequent fixes before final evidence:** after the partial draft-3 edits, updated the production composition fake to emit provider `usage`, switched the cancellation-race fixture to a smaller target, added the tool-call-boundary trigger test, and raised the journey provider usage above the smaller-target threshold. The successful focused and full checks postdate all such fixes.

## Historical Draft-1 Implementation Evidence

- **implementation paths:** `lib/app.dart`; `lib/core/agents/{compaction,runtime,summary_compactor}.dart`; `lib/core/llm/continuation.dart`; `test/app_composition_test.dart`; `test/core/agents/{compaction,loop,model_switch,summary_compactor}_test.dart`; `test/core/llm/reasoning_continuation_test.dart`; `test/infrastructure/llm/openai_responses_adapter_test.dart`; assigned tasks/state only under the existing change.
- **evidence_status:** retained but stale for contract revision draft-3; it supports the existing four-finding implementation only and is not CHECKS_PASS or acceptance evidence for AC-08–AC-09.
- **focused suite:** cwd `/home/auroraos/omp/personal/domovoy`; `flutter test "test/core/agents/summary_compactor_test.dart" "test/core/agents/compaction_test.dart" "test/core/agents/model_switch_test.dart" "test/core/agents/loop_test.dart" "test/core/llm/reasoning_continuation_test.dart" "test/infrastructure/llm/openai_responses_adapter_test.dart" "test/app_composition_test.dart"`; exit `0`; final output `+147: All tests passed!` before draft-3.
- **mandatory Flutter suite:** same cwd; `dart format . && flutter analyze && flutter test`; exit `0`; format `155 files (0 changed)`; analyze `No issues found!`; full test `+448: All tests passed!` (436 baseline plus 12 cases) before draft-3.
- **formal/diff checks:** prior strict validation/apply progress and diff checks predate draft-3 and remain historical only; current planning validation is recorded after this revision.
- **environment/dependencies:** Linux; Flutter/Dart from repository environment; dependency resolution succeeded; 14 newer package versions were reported as incompatible with current constraints and were not changed; no network provider calls, builds, commit, or archive.
- **implementation content fingerprint:** SHA-256 manifest digest `2e291fa8ad6423cbeeec6e5697edb244e0572b650f4452f67b18e32b5d379a2e`, over the 12 implementation/test paths listed above in that order. This is a direct content manifest, not a runner RESULT/fingerprint.
- **subsequent fixes before final evidence:** removed the obsolete test-only `maxInputCharacters` use; aligned loop fixtures to inject their runtime estimator; corrected reasoning-delta discard and realistic Responses/request assertions. The successful focused and full checks postdate all such fixes.
