# Feature State: add-agent-session-compaction

- **change:** `add-agent-session-compaction`
- **result:** The complete replaceable agent-session compaction change is accepted after independent Heavy verification of AC-01–AC-10 and is ready for synchronized OpenSpec archival and the requested local commit.
- **scope_id:** `agent-session-compaction-final-regression`
- **attempt_id:** `implementation-1`
- **stage:** `accepted`
- **contract_revision:** `draft-2` — approved by the user before this implementation
- **base_revision:** `7bdcd3a4a4a208a7becd834eb98209e74dde9c0b`
- **starting_dirty_diff:** inherited and accepted tasks `1.1–4.3`: tracked changes in agent runtime/provider/test files plus untracked compaction implementation/tests, feature-state, and approved `openspec/changes/add-agent-session-compaction/**`; latest verified runner revision `worktree-sha256:3a830f2c504af3b61a45a3cd47e9844d1429708120d6caa8433d2f562b6d03fb`; no staged diff
- **initial_tier:** `T2`
- **current_tier:** `T2`
- **risk_evidence:** The local delta is regression-only, but final evidence covers the accumulated T2 change across public runtime APIs, persisted state, provider overflow retry, paid compactor usage, quotas, cancellation, and lifecycle evidence.
- **recommended_mode:** `heavy`
- **execution_mode:** `heavy`
- **mode_rationale:** User-selected Heavy mode is satisfied: the final independent DeepSeek verifier passed AC-01–AC-10 and formal checks on the frozen whole-change snapshot without a separate Sol code review.
- **selection_source:** explicit user assignment after approved `draft-2`; final tasks `5.1–5.2` expressly assigned
- **model_tiers_used:** planning architect and Heavy writers `strong` (`openai/gpt-5.6-sol`); foundation, automation, LLM-summary, and final whole-change verifiers `fast`/DeepSeek
- **rework_count:** `0`

## Implemented Tasks / AC

- **Completed in this scope:** writer tasks `5.1–5.2` plus verifier-owned task `5.3`; overall progress is `18/18`.
- **Previously accepted:** tasks `1.1–2.4` by foundation verifier `ses_f69127475ffemobnqKATSwZBuS`; tasks `3.1–3.4` by automation verifier `ses_f68e56a8cffeUcZeqJpkJnSNOP`; tasks `4.1–4.3` by LLM-summary verifier `ses_f68c74e8fffe05n67oXKtJzsS1`.
- **AC-01–AC-09:** implementations and focused evidence from the three accepted slices are preserved unchanged in the final application tree.
- **AC-10 / task 5.1:** production composition explicitly remains without a compaction trigger or history compactor. A real `buildProductionAgentStack` regression performs two prompt-workspace submissions through the production DeepSeek adapter, observes distinct transient session IDs, no automatic-compaction events, exactly two HTTP requests, and exactly one current user message (`first` then `second`) per request. Existing one-call, no-shared-history, zero-tool, model, reasoning, and serialization regressions remain passing.
- **Task 5.2:** final repository-wide formatting, analysis, and all tests pass on the frozen 21-file application/test manifest; strict OpenSpec validation and diff whitespace validation also pass.
- **VF-1 note:** cancelled LLM-compactor usage charging was not duplicated in this AC-10 integration slice because it is nonblocking and does not naturally belong to production prompt composition; existing accepted cancellation/usage coverage is preserved.
- **Task 5.3 / acceptance:** final verifier `ses_f68bd0023ffeU01jS0xRQtn6Zr` returned `PASS/CHECKS_PASS` for AC-01–AC-10 at runner revision `worktree-sha256:762738ae1a78556a7587cf2227a1fe8535d99d4e1df70a338a3035e1b8bbc36a`, result ID `check-7c3cd3db5f8a67084166a93f308746ebda34f9100fd3ccb790399d6300458fa1`; Heavy acceptance is satisfied with no blocking findings.

## Changed Paths

- **Final/bookkeeping scope:** `.opencode/workflow/feature-state/add-agent-session-compaction.md`; `openspec/specs/agent-session-compaction/spec.md`; and the complete archived change under `openspec/changes/archive/2026-09-12-add-agent-session-compaction/`. The accepted implementation/test paths are unchanged.
- **Preserved accepted application tree:** `lib/core/agents/{agents,compaction,errors,events,ids,record,runtime,summary_compactor,transcript}.dart`; `lib/core/llm/errors.dart`; `lib/features/prompt/presentation/prompt_controller.dart`; three provider files under `lib/infrastructure/llm/`; `test/core/agents/{compaction,loop,summary_compactor}_test.dart`; both provider adapter tests; and `test/support/agent_harness.dart`.
- Approved `.openspec.yaml`, `proposal.md`, `design.md`, and delta `spec.md` remain unchanged by implementation.

## Public Contracts / Semantics

- This final slice changes no production code or public contract. Compaction remains opt-in through runtime composition; `buildProductionAgentStack` passes no compaction trigger or compactor.
- Prompt workspace continues to use `Agent.run`, whose one-call facade opens and closes a fresh transient session for each submission. It retains `maxModelTurns: 1`, `maxToolCalls: 0`, no enabled tools, and no cross-submission history.
- Configured caller-owned sessions continue to use the accepted trigger/estimator/compactor composition and transactional behavior. The final regression does not introduce prompt-workspace compaction, chat UI/storage, token UI, dependencies, or platform changes.

## Evidence / Immutable Application Snapshot

- **checked application fingerprint:** ordered 21-file `sha256sum` manifest fingerprint `c7fa69a999e5101bf1e847cd4077b41d07c2d8a88dddd7698459df5e3001d3e1`. It includes every dirty/untracked application or test file from accepted tasks `1.1–4.3` plus this scope's `test/app_composition_test.dart`; it is not HEAD-only. Application/test content is frozen after the checks below.
- **manifest:** `agents.dart 3852d0f01a1197813f436595e40bc6c60d2198f9f4c3afc0374e1e8b89d70144`; `compaction.dart 5ad7fe87ae47fc689632513585db695430921ab88309968bc4f614835bec25b0`; `agent errors.dart 1c9ab9f61ce7454ebafa0328cde4a1f39a437bf3f435683e903da0b813153589`; `events.dart 86d66cab0999054f714ce4fe2a460f4a47b3356ea2c77916a13d0ccb657e7a80`; `ids.dart faee788395b5459bd4eb5b1bde4a235b800f60f0a3f2e09f05218160612f3c3d`; `record.dart bbb17cce1cdb3e7154ec2daccfce07b5fd18aa685c3073e5b1864cd1efac8d8d`; `runtime.dart ab2a802538c38f45a870ddd7c1e9bfc87532bf8b2407987846b68c402d9bd63c`; `summary_compactor.dart 84c264e600bfb7b0cf6d772ec8d2a4f0996ddbfcbba0dc316f7dd08d5b98d310`; `transcript.dart 1d1e4f272dbe0fc96a2863498ef245749ac8bf9df1485d50328d98dfd0eab510`; `llm/errors.dart 399e7a6391b138f0d63bbd20626e6b26f3bc78270f6f59e21ad01544412ec0a6`; `prompt_controller.dart 5bad80ca5871888e7959a18dc244c42410c63e36b00caa6cbd7a917ffe00b1bb`; `chat provider.dart 5d67fef60a8e9440cade5f005832d00607f04dc5fe0d0bc27f602c6dc51ae90c`; `stream_session.dart b769b40156857e5b02d63d3a2148a2c993fbd5db56700f1df127eec3576b439c`; `responses provider.dart 4889c2f5c17b54c0252dc4c796f5d459d5d6e6384ce1918860ce210662b9d81f`; `app_composition_test.dart 8dd5e962da62248b0825295cca53069f227319cc4288e1f0ae277a3ada2fc42a`; `compaction_test.dart 1569fa81ff06d342447b11ce419e5c61777600f753c43187e4331c2728dc085a`; `loop_test.dart 0ca3d3656a019919b83ebbf7c3867fa53186a07039a63ea96e3ccbf786664136`; `summary_compactor_test.dart 608a7e23d99604efa3f6142238ee139500a2c080524fd6ae45c59a96549b8120`; `chat adapter test.dart f5bc45b175922b85b747145f8aa86f404580bf4376e09948de7312361e28f5cb`; `responses adapter test.dart 3b6f65bf28c7cc1a1d33df96afcd69666ee8f41de41929934b17d9787e1f9246`; `agent_harness.dart ad97d3d62d2a5c656684e765e85850e6da135635fd4d626963329c75b3ea76e3`.
- `dart format test/app_composition_test.dart && flutter test test/app_composition_test.dart` — cwd repository root, exit `0`; `Formatted 1 file (0 changed)` and `11 tests passed`.
- `dart format . && flutter analyze && flutter test` — cwd repository root, exit `0`; `Formatted 92 files (0 changed) in 0.39 seconds`; `No issues found! (ran in 1.4s)`; `295 tests passed`.
- `openspec validate "add-agent-session-compaction" --strict && .opencode/bin/repo-git diff --check` — cwd repository root, exit `0`; `Change 'add-agent-session-compaction' is valid`; diff check produced no output.
- **archived task file hash:** `openspec/changes/archive/2026-09-12-add-agent-session-compaction/tasks.md 3665a4190a635f9db0529a10668e4fbcb3ac01138ebf4af39f33e25ffcf70f4c` with all tasks `1.1–5.3` checked.
- **synced main spec:** `openspec/specs/agent-session-compaction/spec.md e7b4e052c1d7c30ee069db1e36a7aa8365e3d72b1eb2dea0c690e8be831dcd6f`; the new capability Purpose and all ten accepted requirements/scenarios match the archived delta.
- **archive:** `openspec archive "add-agent-session-compaction" --yes --json` archived the change as `openspec/changes/archive/2026-09-12-add-agent-session-compaction/`; CLI reported zero additional spec operations because the agent-driven sync had already been verified as exact and idempotent.
- **prior acceptance retained:** foundation `ses_f69127475ffemobnqKATSwZBuS`; automation `ses_f68e56a8cffeUcZeqJpkJnSNOP`; LLM summary `ses_f68c74e8fffe05n67oXKtJzsS1`; latest verified runner revision `worktree-sha256:3a830f2c504af3b61a45a3cd47e9844d1429708120d6caa8433d2f562b6d03fb`.
- **final acceptance:** verifier `ses_f68bd0023ffeU01jS0xRQtn6Zr`, `PASS/CHECKS_PASS`, runner revision `worktree-sha256:762738ae1a78556a7587cf2227a1fe8535d99d4e1df70a338a3035e1b8bbc36a`, result ID `check-7c3cd3db5f8a67084166a93f308746ebda34f9100fd3ccb790399d6300458fa1`.
- **corrective evidence:** no compile/test failure occurred in this scope. The focused AC-10 regression passed on its first run; no requirement or test was weakened.
- **environment:** Linux; existing Flutter/Dart lockfile constraints. Flutter reported 13 newer incompatible package versions, informational only; no dependency files, network product services, or platform identifiers changed.

## Role IDs / Findings / Next Step

- **research:** runtime `ses_f6960ede6ffeVmVGUZlIEg5Bc0`; Codex/Qwen `ses_f6960edc8ffeDacwczdrx3v1jM`; Koog/OpenCode `ses_f6960edabffe7C9V3czaRwDPU8`.
- **architect task ID:** `ses_f695bfabaffeqUDQcP2nsggpuf`.
- **verifier IDs:** foundation `ses_f69127475ffemobnqKATSwZBuS`; automation `ses_f68e56a8cffeUcZeqJpkJnSNOP`; LLM summary `ses_f68c74e8fffe05n67oXKtJzsS1`; final whole change `ses_f68bd0023ffeU01jS0xRQtn6Zr`.
- **implementation task IDs:** OpenSpec `5.1–5.2`; direct Heavy assignment, no runner used in this scope, so no new implementation revision/result id or runner RESULT/fingerprint is claimed.
- **open_findings:** none blocking. VF-1 remains a nonblocking verifier note and does not prevent acceptance.
- **blockers:** none.
- **next:** preserve the accepted application/test fingerprint and create the user-requested local commit `feat: add replaceable agent session compaction`; do not push, fetch, rebase, or amend.
