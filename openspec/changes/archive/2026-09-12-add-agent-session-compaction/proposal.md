## Why

Long-lived agent sessions currently resend their entire append-only transcript, even when the selected model's context bound can no longer safely contain the next request. Domovoy needs a deterministic, persistent, and replaceable compaction mechanism before reusable sessions can operate reliably near that bound.

## What Changes

- Add three independent extension contracts: a provider-neutral estimator, a typed trigger that decides **when**, and an injected compactor that decides **how**. Runtime-provided contexts and strategy results are immutable; only the runtime may validate and commit session state.
- Provide an OpenCode-inspired automatic trigger as a configurable default, not architectural law, with pre-request pressure and one bounded provider-overflow recovery. Custom triggers may make different decisions through the same contract.
- Provide an OpenCode-inspired LLM summary compactor with configurable same-or-alternate model selection and a deterministic recent-N-complete-interaction-groups compactor. Keep strategies directly injectable rather than adding a registry.
- Add a public forced compaction operation on caller-owned sessions. It bypasses the automatic trigger/threshold, invokes the session-configured compactor, and uses the same serialization, cancellation, validation, and revision guarantees.
- Make compaction transactional: prepare and validate a candidate, then commit transcript, continuation metadata, compaction provenance, and repository checkpoint as one logical state transition; failures and cancellation that wins before commit preserve the prior session state.
- Persist strategy-neutral compaction generation/provenance so summary, truncation, and future custom candidates restore coherently and can be compacted repeatedly.
- Preserve protected agent configuration and valid user/assistant/tool boundaries, and deterministically remap or discard provider continuation entries after history replacement.
- Emit sanitized lifecycle events with reason and before/after estimates, and allow at most one compaction-based retry after a provider-classified context-overflow failure.
- Keep the production prompt workspace's transient one-shot behavior unchanged.

No existing public behavior is intentionally broken. Record decoding will require an explicit compatibility rule for records written before compaction metadata exists.

## Capabilities

### New Capabilities

- `agent-session-compaction`: Automatic and forced replaceable transactional compaction for reusable agent-session context, including extension contexts, built-in summary/truncation strategies, estimation, persistence, replay invariants, recovery, cancellation, and observability.

### Modified Capabilities

None. The new capability composes with the existing `agent-runtime` and `llm-provider-core` contracts without changing their existing guarantees.

## Impact

- Agent runtime/session public API, composition, and safe-boundary request loop: `lib/core/agents/runtime.dart`, `definition.dart`, `policies.dart`, `transcript.dart`, `record.dart`, `events.dart`, and `hooks.dart`.
- Provider-neutral model metadata, requests, continuation replay, usage, and overflow classification under `lib/core/llm/`; provider adapters may need only typed overflow mapping and request-estimation inputs.
- Session codec/record compatibility and optimistic repository checkpoints.
- Agent runtime and provider test suites under `test/core/agents/**`, relevant `test/core/llm/**`, and `test/support/agent_harness.dart`.
- No database/file/cloud repository, mandatory tokenizer dependency, strategy registry, settings UI, or prompt-workspace adoption is included.
