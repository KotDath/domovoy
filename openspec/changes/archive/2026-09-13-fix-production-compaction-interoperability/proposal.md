## Why

The clean production baseline passes 436 formal tests, but final semantic review found four untested High-severity interoperability failures across model switching, long-history summary compaction, reasoning-capable OpenAI Responses completions, and standard Responses continuation payloads. A subsequent user contract correction also found that proactive automatic compaction is currently decided from an estimator before a request instead of from the latest completed physical LLM invocation's provider-reported request-context usage. Together these failures prevent accepted compaction guarantees from holding under supported production compositions.

## What Changes

- Distinguish the current session model from the target/request model in immutable compaction context so default summary selection remains strategy-owned and defaults to the current model during a switch to a smaller target.
- Replace the fixed summary-input character ceiling with bounded incremental summarization over complete legal interaction groups, sized from the actual summary model context/output bounds, headroom, and configured estimator.
- Accept a successful tool-free summary completion carrying validated provider turn state, while discarding that state instead of replaying, persisting, or exposing it.
- Accept and strictly validate standard OpenAI Responses `output_text.logprobs`, including `[]`, while preserving the validated field in opaque turn state and retaining all unrelated closed-schema checks.
- Move proactive automatic-compaction evaluation to the safe boundary after each completed physical LLM invocation's transcript/usage commit, use only that invocation's usable provider-reported `requestContext` or equivalent as trigger pressure, and skip as unavailable when that usage is missing. Estimator values remain internal to compactor batch selection/candidate reduction and are neither trigger pressure nor billed usage.
- Define target-model switching from the same latest completed provider context usage; when usage is unavailable and the target is smaller, run the configured compactor before switching without claiming numeric fit and preserve the old selection on no-change, failure, or cancellation.
- Add production-composition regression coverage for actual DeepSeek/Kimi/OpenAI catalog capacities, smaller-target switching, reasoning Responses summaries, histories beyond the former cap, impossible single groups, and realistic `output_item.done` payloads.
- Preserve transaction, cancellation, continuation, per-invocation usage accounting, model-switch atomicity, and chat UI behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `agent-session-compaction`: Clarify current-session versus target model context; make proactive triggering provider-completion-driven with bounded overflow recovery and truthful evidence; and make the built-in summary strategy bounded, incremental, production-capacity-aware, and compatible with tool-free Responses turn state.
- `llm-provider-core`: Extend the strict OpenAI Responses output-text continuation schema to support validated standard `logprobs` content.

## Impact

- Compaction/model-switch context, provider-attempt accounting, and orchestration: `lib/core/agents/compaction.dart`, `runtime.dart`, `summary_compactor.dart`, and `token_accounting.dart` as required by the focused correction.
- OpenAI Responses opaque-state validation: `lib/core/llm/continuation.dart` and the Responses adapter only as needed for realistic payload coverage.
- Focused tests: `test/core/agents/summary_compactor_test.dart`, `model_switch_test.dart`, `loop_test.dart`, `test/core/llm/reasoning_continuation_test.dart`, `test/infrastructure/llm/openai_responses_adapter_test.dart`, production composition tests, and supporting harnesses.
- No UI redesign, strategy registry, provider catalog expansion, persistence migration, or unrelated schema relaxation.
