## Context

See `proposal.md` for the four final-audit defects and the later provider-measurement trigger correction. HEAD `f87c8a2d483e182e294ec60fc144b66d75b691d4` was the clean 436-test baseline. The current dirty implementation addresses the four review findings and passed its pre-revision checks, but still evaluates proactive compaction from `AgentContextEstimator` pressure before dispatch; those checks are therefore not acceptance evidence for this revised contract.

The accepted runtime already owns legal interaction groups, candidate validation, atomic checkpoint/swap, cancellation, and ordered per-invocation accounting. This change repairs only the interoperability gaps and reuses those contracts.

## Goals / Non-Goals

**Goals:**

- Make current-session and target/request model roles unambiguous without redesigning extension ports or persisted records.
- Make every proactive automatic-compaction decision follow a completed physical LLM invocation and depend only on that invocation's usable provider context usage.
- Make the built-in summary strategy converge on production-scale multi-group histories using selected summary-model capacity.
- Accept valid Responses reasoning completions and standard logprobs without leaking opaque state.
- Add tests at production composition/dialect boundaries that the prior formal suite missed.

**Non-Goals:**

- New catalog models, persistence envelope/record-format versions, UI flows, or summary formats.
- Splitting a legal interaction group, arbitrary token-perfect estimation, replaying summary-request turn state, or relaxing unrelated Responses fields.

## Decisions

### 1. Add current session model alongside the existing request model

`AgentCompactionContext.selectedModel` keeps its existing meaning as the model for the request shape and fit target. Add immutable `currentSessionModel`, defaulting to `selectedModel` for existing construction paths and explicitly populated from the live session selection by runtime context building. Ordinary/manual/overflow contexts therefore expose equal models; model-switch contexts expose current and target separately.

`SessionAgentSummaryModelSelector` selects `currentSessionModel`. Proactive pressure uses the latest completed invocation's provider context usage; request estimation, candidate reduction, and target continuation filtering use `selectedModel`. This is additive to the runtime-only context and does not by itself alter `AgentCompactionState` or session-record JSON. Existing custom strategies that only inspect `selectedModel` keep target-fit behavior; strategies needing the source model gain the new field.

Alternative: rename `selectedModel` to `targetModel`. Rejected because it creates avoidable extension/API churn and is inaccurate outside model switching.

### 2. Trigger proactive compaction only from completed provider usage

Use `requestContext`, or the equivalent effective context value derived from provider-reported counters, on the latest completed physical LLM invocation. Evaluate after that invocation's transcript and usage are committed at a safe boundary, for either a tool-call or final-answer completion, and before any next provider dispatch. Missing usable provider context usage yields a proactive skip/unavailable result; the separate typed provider-overflow recovery remains available.

`AgentContextEstimator` is not proactive trigger pressure and is not billed usage. It remains internal to compactor batch selection and candidate reduction.

### 3. Size incremental summary batches with the actual summary model

Resolve the summary model before prompt construction. Remove `maxInputCharacters` as the production capacity gate. Inject an `AgentContextEstimator` into the summary compactor (production composition supplies the same estimator used by runtime) and calculate for summary model `S`:

- output allowance `Oₛ = min(configuredMaxOutputTokens, S.outputBound)`;
- headroom `Hₛ = configuredHeadroom ?? max(1024, ceil(0.05 × S.contextBound))`;
- maximum estimated summary input `Bₛ = S.contextBound − Oₛ − Hₛ`.

Every physical summary request, including fixed instructions, rolling summary, framing, and selected complete groups, must estimate at or below `Bₛ`. Non-positive capacity fails before dispatch. Output streaming retains an independent bounded-memory guard derived from configured output limits; it is not used as history-input capacity.

Production compatibility is verified by evaluating this formula for every built-in DeepSeek, Kimi, and OpenAI model and by running production-composed scenarios, rather than assuming the former 262,144-character ceiling.

### 4. Increment over complete groups with two finite bounds

The removable source is the prior generated summary plus all interaction groups before the configured recent tail. Maintain one rolling structured summary and a cursor over removable groups:

1. Choose the largest non-empty consecutive group batch whose complete summary request fits `Bₛ`.
2. Invoke the summary model and replace the rolling summary with the validated response.
3. Advance the cursor by at least one whole group and append one ordered physical-invocation report.
4. Repeat until all selected groups are consumed; then return one candidate only if runtime estimation proves it strictly smaller and within any decision target.

The invocation count is bounded by both monotonic group consumption and configurable `maxSummaryInvocations` (default 32). There is no retry of a failed batch. If prior summary plus the next complete group cannot fit, the recent retained group alone prevents the target, cancellation wins, or the cap is reached, return typed failure with all reports collected so far; runtime keeps original history and applies existing accounting/finalization.

This handles histories larger than one request while never splitting tool boundaries. Alternative character slicing was rejected because it can split tool interactions and remains disconnected from model capacity.

### 5. Treat tool-free summary turn state as ignorable successful metadata

The summary request sends no tools and already rejects any tool-call delta and disallowed finish reason. A non-null, provider-validated `LlmProviderTurnState` on otherwise successful completion is therefore neither an error nor useful summary input. Accept completion, parse only the streamed summary text, and drop turn state immediately. It never enters candidate metadata, transcript, continuation entries, events, diagnostics, or a later batch.

This permits GPT-5 required reasoning while retaining the stronger rule that summary compaction never replays opaque reasoning state.

### 6. Validate and preserve standard Responses logprobs

Add `logprobs` to the closed `output_text` content-part field set. Validate it as a list. Each populated entry has the closed required shape `{token, logprob, bytes, top_logprobs}`: token is a string, logprob is finite numeric, bytes is null or a list of integers `0..255`, and top_logprobs is a list of closed `{token, logprob, bytes}` entries with the same leaf validation and no recursive nesting. Empty lists are valid. Existing decoded response/body and model-output bounds provide the outer size bound; no smaller compaction-specific limit is introduced.

After validation, preserve the exact defensively frozen JSON field in opaque output-item turn state so round-trip/replay remains exact. Normalized text projection ignores it, and diagnostics expose no contents. Unknown fields and malformed shapes still fail; no generic “accept extras” path is added.

Alternative: validate then strip. Rejected because existing stateless replay promises the validated output-item array exactly and stripping would silently alter opaque state.

### 7. Use provider context usage for target-model switching

Compare the latest completed physical LLM invocation's provider-reported context usage with target capacity. If that usage is unavailable and the target is smaller, run the configured compactor before switching without using an estimator as the switch trigger or claiming numeric fit. A no-change, failure, or cancellation preserves the old selection. Estimation remains internal to compactor batch selection and candidate reduction.

### 8. Light route and verification boundary

Risk remains T2 because model-switch lifecycle and automatic-compaction timing are architectural contracts. The correction is bounded and directly testable against the existing usage ledger and runtime seams, with no unresolved design unknowns. The user selected light mode: DeepSeek implements, then Sol code review and separate-context DeepSeek verification run in parallel on the same frozen implementation.

The final-audit review is the originating review. This work remains fix cycle 1 with `rework_count: 1`; the trigger correction is contract revision `draft-3`, not another review cycle. Verification targets the four existing findings and the focused trigger/model-switch AC rather than reopening broad feature review.

## Risks / Trade-offs

- [Rolling summary loses information across batches] → preserve structured prior summary in every next prompt, retain the configured recent complete tail, and test repeated batches.
- [Many tiny groups cause excessive calls] → maximal fitting batches, monotonic cursor, default cap 32, no batch retry.
- [Estimator undercounts summary request] → summary-model headroom plus typed provider failure; no candidate commit or internal overflow loop.
- [A single legal group exceeds summary capacity] → fail before dispatching that group and retain original transaction state.
- [Responses logprob schema evolves] → support only the documented closed shape; future fields require an explicit delta rather than silent acceptance.
- [Additive context field changes custom implementations] → preserve `selectedModel`, default `currentSessionModel` to it, and add focused backward-construction tests.
- [Provider usage is absent or incomplete] → proactive skip/unavailable; retain separately bounded typed-overflow recovery.
- [Provider usage is unavailable for a smaller target] → run configured compaction before switching and preserve the old selection on no-change, failure, or cancellation.

## Migration Plan

1. Preserve the already implemented context field/fallback, strict Responses validation, and incremental summary batches.
2. Replace estimator-led proactive pressure with latest-completed provider context usage and evaluate after transcript/usage commit at a safe boundary.
3. Apply the provider-context comparison and unavailable-smaller-target compaction rule to model switching.
4. Run focused trigger/model-switch regressions, then `dart format .`, `flutter analyze`, and full `flutter test`.

Rollback is code-only because no record/schema migration is introduced; records and opaque payloads remain in their existing formats.
