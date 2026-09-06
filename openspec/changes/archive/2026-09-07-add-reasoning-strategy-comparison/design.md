## Context

See `proposal.md` for motivation and `specs/` for observable behavior. Domovoy already has a provider-neutral one-shot `Agent` stream, an OpenAI-compatible DeepSeek Chat Completions adapter, reusable terminal metadata, settings, and two persistent destinations in an `IndexedStack`. Day 3 adds multi-stage orchestration and correctness evidence without introducing message history, an agent framework, or an LLM judge.

The original five-resident truth-teller puzzle was rejected because a natural formalization admits three assignments. The built-in preset is instead a four-house logic-grid puzzle: four residents, drinks, and pets must be assigned to houses 1–4 from left to right under six positional clues. Exhaustive enumeration yields exactly one complete grid, giving every strategy the same objective reference answer.

## Goals / Non-Goals

**Goals:**

- Keep the four strategies comparable by snapshotting one task and forcing native DeepSeek thinking off on every Day 3 call.
- Make the two-stage generated-prompt path and its extra cost visible rather than hiding orchestration.
- Continue later strategies after a failed stage while preserving partial output and sanitized errors.
- Provide a deterministic, uniquely solved reference grid for the preset and a transparent human verdict for natural-language answers.
- Make the complete comparison readable and testable on Linux without committing or logging credentials.

**Non-Goals:**

- Automatically grading arbitrary natural-language answers, claiming a statistically best prompting method, or using an LLM as a judge.
- Supporting arbitrary puzzle languages in the reference solver, conversation memory, autonomous expert agents, tool calls, or parallel provider requests.
- Enabling provider-native reasoning on Day 3, parsing hidden chain-of-thought, or comparing reasoning token budgets.
- Automatically recording or publishing the required video.

## Decisions

### 1. Add a third persistent destination and one full-comparison action

Extend the root navigation to Day 1, Day 2, and Day 3 children in the existing `IndexedStack`. Day 3 owns its shared task and most recent results; switching destinations preserves each day's independent state.

The screen presents four persistent strategy cards and one `Запустить 4 способа` action. One action snapshots the task and executes the full comparison, which prevents accidental prompt drift and is simpler to narrate than four unrelated buttons. Cards show their transformation and cost before execution, then stream their own state. Wide layouts use a two-column `Wrap`/grid; narrow layouts stack.

Independent per-strategy reruns were rejected for the first version because they can compare different task edits and complicate call accounting. A `run all in parallel` action was rejected because it increases instantaneous provider load and weakens stage/cost narration.

### 2. Represent strategies and stages separately

Use provider-neutral Day 3 domain values such as `ReasoningStrategy { direct, stepByStep, generatedPrompt, expertGroup }`, immutable task snapshots, and a lane state containing status, answer, failure, finish reason, usage, and manual verdict. The generated strategy additionally owns a prompt-builder lane and the generated prompt text.

A single controller runs the following sequential stage plan:

1. Direct answer — one call.
2. Step by step — one call.
3. Generated prompt builder — one call; on non-empty success, generated solver — one call.
4. Expert group — one call.

The expected total is five calls. A failed/empty prompt builder consumes its attempted call, skips only its solver stage, marks the generated strategy failed, and continues to experts. Every terminal stage cancels its subscription before the next begins. A generation id plus explicit subscription cancellation prevents stale updates and disposal leaks.

Four separate controllers were rejected because the generated strategy needs two related stages and the experiment needs one global order/cost/progress state.

### 3. Build prompt transformations with pure functions

Prompt construction is pure and unit tested:

- Direct returns the trimmed task byte-for-byte with no strategy suffix.
- Step by step appends a delimited Russian instruction to solve stepwise, test assumptions, and verify the conclusion.
- Prompt builder asks for a solver prompt that is self-contained, preserves every condition, checks uniqueness, and returns only the prompt text.
- Generated solver combines the generated instructions and the immutable original task in clearly delimited blocks. This guarantees all strategies still solve the same task even if the builder paraphrases or omits a condition.
- Expert group asks three named roles—analyst, engineer, critic—to reason independently in labeled sections and finish with a synthesis that reconciles disagreements.

Every constructed `AgentInput` explicitly uses `ThinkingMode.disabled`. The controller does not read or mutate the persisted Day 1/Day 2 reasoning preference. This isolates prompt design as the experimental variable and makes the policy auditable in tests.

### 4. Stream one active stage and normalize terminal handling

Reuse `AgentEvent` and terminal metadata rather than adding provider response types. The controller retains partial answer text, accepts zero reasoning deltas, maps stream errors to sanitized failures, and treats end-of-stream without `AgentCompleted`/`AgentFailed` as interruption. Direct, step, and expert failures do not stop the remaining schedule.

The prompt-builder's answer is rendered as generated-prompt evidence, not as a normal final solution. The generated solver result remains distinct. Call count increments for each attempted API stream, so the UI can accurately show `N из 5` even when a stage fails or is skipped.

Parallel execution was rejected to preserve the existing one-active-request property and predictable rate/cost behavior.

### 5. Implement the preset reference as exhaustive pure-Dart logic

Model houses 1–4, four residents (Anna, Boris, Vera, Gleb), four drinks (tea, coffee, juice, water), and four pets (cat, dog, fish, parrot). Enumerate all independent permutations and retain only grids satisfying these six clues:

- The coffee drinker lives immediately left of Anna.
- Gleb lives immediately left of the juice drinker.
- The parrot owner lives immediately left of the water drinker.
- The fish owner lives immediately left of Boris.
- The dog owner lives somewhere left of Gleb.
- Anna lives somewhere left of the tea drinker.

The immutable reference must contain exactly one grid: house 1 — Vera, coffee, parrot; house 2 — Anna, water, dog; house 3 — Gleb, tea, fish; house 4 — Boris, juice, cat. Unit tests assert the exact solution, every clue, one-to-one category assignments, and uniqueness.

The reference is applicable only when normalized task text equals the built-in preset. Edited tasks remain runnable, but the screen states that built-in reference evidence is unavailable. Attempting a general natural-language theorem prover was rejected because it would be opaque and well beyond the exercise.

### 6. Use explicit human verdicts instead of brittle automatic grading

Natural-language responses may present the same grid in arbitrary order and vocabulary. Regex extraction would misclassify valid explanations, while an LLM judge would introduce another prompting strategy and nondeterminism. Each completed/failed card therefore exposes `Без оценки`, `Точно`, `Частично`, and `Неверно`; below the cards, the user selects the most accurate strategy after comparing it with the immutable reference.

The summary shows all verdicts and the selected winner, explicitly labeling the choice as the user's evaluation. Ratings are local experiment state, reset on a new run, and never sent back to the model. This is transparent enough for video evidence without claiming machine certainty.

### 7. Keep delivery deterministic and credential-safe

Unit tests cover prompt builders and the reference solver. Controller tests use controllable streams for order, identical task snapshots, call counts, generated-stage branching, failure continuation, cancellation, and verdict reset. Widget tests cover navigation, responsive layout, disabled execution, progressive results, generated-prompt disclosure, the unique reference grid, ratings, and summary.

An opt-in integration test outside the default unit-test directory executes all five live stages with `DEEPSEEK_API_KEY` supplied at runtime and logs only aggregate lengths, finish reasons, token counts, and reference/verdict status. The demo checklist keeps settings and terminal secrets outside the recorded frame.

## Risks / Trade-offs

- **The puzzle wording can be interpreted differently** → State the one-to-one category and left-to-right house rules explicitly, and prove uniqueness with exhaustive enumeration.
- **A response can be correct but phrased unexpectedly** → Use human verdicts against visible reference evidence rather than a fragile parser.
- **The generated prompt can be empty or poor** → Preserve builder evidence, skip only the dependent solver when empty/failed, and continue experts.
- **Five live calls increase cost and latency** → Show cost before execution, run sequentially, disable duplicates, and use reasoning off.
- **A stage can hang or emit after navigation** → Store/cancel the active subscription, use generation guards, and test silent-stream disposal.
- **Manual ratings are subjective** → Label them explicitly and retain original answers plus the deterministic unique reference for auditability.
- **Video can expose credentials** → Use runtime-only keys, aggregate integration logs, and an application-window-only checklist.

## Migration Plan

1. Add pure strategy prompt builders, lane/result models, and preset reference solver without changing existing destinations.
2. Add the sequential five-stage controller and deterministic tests using the existing `Agent` abstraction.
3. Add the Day 3 responsive screen, navigation destination, ratings, reference panel, and widget tests.
4. Add an opt-in live integration smoke and demo checklist, then run format, analysis, unit/widget tests, Linux release build, and live smoke.
5. After verification, sync both delta specs and archive the change. The manual video remains outside the repository.

Rollback removes the Day 3 destination and its isolated feature directory; Day 1, Day 2, the shared agent adapter, settings, and their archived specifications remain intact.
