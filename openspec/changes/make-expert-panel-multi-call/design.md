## Context

See `proposal.md` for motivation. Day 3 currently has one controller that schedules five provider-neutral `Agent` streams. Its Expert-group stage is a single prompt that asks one response to contain three role sections and a synthesis. The UI and tests therefore correctly report one call for that implementation, but the produced sections are not independent evidence.

The existing experiment deliberately disables provider-native reasoning, snapshots the task, runs requests sequentially, preserves partial streams on failure, and avoids agent frameworks. Those constraints remain.

## Goals / Non-Goals

**Goals:**

- Make analyst, engineer, and critic outputs independent at the API-request boundary.
- Produce one final comparable Expert-group answer through a fourth synthesis request.
- Keep intermediate evidence, failures, progress, and actual/planned cost inspectable in the existing Day 3 card.
- Preserve deterministic cancellation and stale-generation protection across the longer eight-stage schedule.

**Non-Goals:**

- Parallel provider requests, persistent autonomous agents, conversation memory, tool use, or an agent framework.
- Automatic LLM judging or changes to the deterministic puzzle reference.
- Changing the other three strategies or enabling provider-native reasoning.

## Decisions

### Model the ensemble as four explicit stages under one strategy

Expand the Day 3 stage schedule with Analyst, Engineer, Critic, and Expert synthesis. Each stage owns the same lane data already used for streamed evidence. Expert group remains one comparison strategy whose final answer/status/usage comes from the synthesis lane, while the three role lanes are supporting evidence.

This retains the existing controller's lifecycle and cancellation guarantees. Treating experts as separate controllers was rejected because it would duplicate generation guards and complicate a single ordered progress counter.

### Keep expert execution sequential but informationally independent

The three role requests run one after another, but each input contains only the immutable task and its role-specific method. Analyst emphasizes logical deduction, Engineer emphasizes systematic constraint checking, and Critic emphasizes falsification and verification. No expert sees an earlier expert's text.

Parallel calls were rejected for this change because independence does not require concurrency, while sequential calls retain predictable provider load, video narration, and the current single-subscription design.

### Always attempt synthesis after all three expert attempts

The synthesis input includes the immutable task and three delimited evidence blocks. A failed expert contributes its retained partial output when non-empty; otherwise it contributes an explicit unavailable marker plus a sanitized failure label. The synthesis prompt must reconcile disagreements, verify the result against the original task, and return one final answer rather than impersonating new experts.

Skipping synthesis after an expert failure was rejected because it would make planned cost and the strategy's comparable result dependent on one intermediate failure. The synthesis attempt is omitted only when the entire run is cancelled or superseded.

### Expose four-call and eight-call accounting directly

Expert group reports four planned calls; the full experiment reports eight. The global completed count increments once for every terminal request attempt, including provider failures, matching the existing accounting semantics. The UI explains the decomposition so “4 API calls” cannot be mistaken for four strategies in one request.

### Present role evidence inside the existing Expert-group card

Add compact labeled sections for Analyst, Engineer, and Critic, followed by a visually distinct Synthesis result. Sections stream independently and retain error/finish/usage metadata. On narrow Linux layouts they stack inside the card; on wide layouts they may wrap without changing reading order.

## Risks / Trade-offs

- **Three additional paid calls and longer elapsed time** → Disclose four calls on the strategy card and eight calls on the run action before execution; show stage-aware progress while running.
- **A failed expert can weaken synthesis quality** → Preserve the failure and partial text, label missing evidence explicitly, and instruct synthesis to avoid treating unavailable evidence as agreement.
- **Model output embedded in the synthesis prompt can contain conflicting instructions** → Delimit each output as untrusted evidence and tell the synthesizer to follow only the synthesis task and original puzzle constraints.
- **More nested evidence can make the card tall** → Use compact collapsible/expandable evidence areas while keeping the synthesis visible as the primary comparable answer.
- **Cancellation can leave partial expert evidence** → Reuse the generation id and subscription cancellation path, and test cancellation at expert stages.

## Migration Plan

1. Extend domain stages/state and prompt builders without changing persisted settings or credentials.
2. Update orchestration and tests, then update the Day 3 UI/call disclosures and documentation.
3. Run formatting, analysis, unit/widget tests, and the opt-in live smoke when a runtime key is available.
4. Roll back by reverting this change; no stored data migration is required.
