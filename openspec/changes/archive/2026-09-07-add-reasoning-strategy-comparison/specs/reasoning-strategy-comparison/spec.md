## Purpose

Defines a visible Day 3 laboratory that applies four prompt-level reasoning strategies to the same analytical task, streams their independent results, and supports a transparent comparison against deterministic reference evidence.

## ADDED Requirements

### Requirement: Four visible reasoning strategies
The Day 3 laboratory SHALL present Direct, Step by step, Generated prompt, and Expert group as four distinct strategies with their prompt transformation and API-call cost visible before execution.

#### Scenario: Laboratory opens
- **WHEN** the user opens the Day 3 laboratory
- **THEN** all four strategies, the shared task, the total five-call cost, and one action to run the complete comparison are visible

#### Scenario: Direct strategy is constructed
- **WHEN** the Direct request starts
- **THEN** its sole user message contains the shared task without a reasoning-strategy instruction

#### Scenario: Step-by-step strategy is constructed
- **WHEN** the Step-by-step request starts
- **THEN** its sole user message contains the same task plus an explicit instruction to solve it step by step and check the conclusion

#### Scenario: Expert-group strategy is constructed
- **WHEN** the Expert-group request starts
- **THEN** its sole user message contains the same task and asks an analyst, engineer, and critic to provide separately labeled solutions before a final synthesis

### Requirement: Generated-prompt strategy chain
The Generated-prompt strategy SHALL first ask the model to create a self-contained solver prompt for the shared task and SHALL then use the generated text in one independent solver request while displaying both stages.

#### Scenario: Prompt generation completes
- **WHEN** the prompt-builder stream completes successfully with non-empty text
- **THEN** the generated prompt remains visible and the system starts a solver request containing that generated prompt and the immutable shared-task snapshot

#### Scenario: Prompt generation fails
- **WHEN** the prompt-builder stream fails or completes with empty text
- **THEN** its partial output and sanitized error remain visible, the solver stage is not started, and later comparison strategies still receive their scheduled attempts

#### Scenario: Generated solver completes
- **WHEN** the solver stream reaches a terminal state
- **THEN** its answer is shown as the Generated-prompt strategy result separately from the generated prompt

### Requirement: Prompt-level comparison disables native reasoning
Every Day 3 provider request SHALL explicitly disable native model thinking so the experiment compares prompt-level strategies rather than hidden changes in provider reasoning effort.

#### Scenario: Any Day 3 request starts
- **WHEN** a direct, step-by-step, prompt-builder, generated-solver, or expert-group request is constructed
- **THEN** it carries disabled thinking and no reasoning-effort value regardless of the persisted setting used by other application screens

#### Scenario: Reasoning policy is visible
- **WHEN** the Day 3 laboratory is displayed
- **THEN** it states that native reasoning is fixed off for all four strategies and links the explanation to comparison fairness

### Requirement: Same-task sequential execution
The comparison SHALL snapshot one non-empty task and execute Direct, Step by step, Generated prompt, and Expert group sequentially without adding any result to conversation history.

#### Scenario: User runs the comparison
- **WHEN** the user submits a non-empty shared task while no comparison is active
- **THEN** prior Day 3 results and ratings are cleared and the four strategies run in order using the same task snapshot

#### Scenario: Comparison is already active
- **WHEN** any Day 3 stage is streaming
- **THEN** the run action and task editing are disabled and a duplicate comparison cannot start

#### Scenario: One strategy fails
- **WHEN** a strategy fails before or during streaming
- **THEN** its partial output and sanitized error remain visible and the next scheduled strategy still starts

#### Scenario: Controller is disposed
- **WHEN** the user leaves or the controller is disposed while a stage is active
- **THEN** the active subscription is cancelled and no stale event changes a later state

### Requirement: Independent streamed evidence
Each strategy SHALL retain independent status, progressive answer text, sanitized failure, completion reason, usage, and stage-specific evidence without displaying an empty reasoning disclosure.

#### Scenario: Answer deltas arrive
- **WHEN** a strategy emits answer deltas
- **THEN** its result card appends them in order while the other cards retain their own state

#### Scenario: Native reasoning content is absent
- **WHEN** disabled thinking produces answer content without reasoning deltas
- **THEN** the answer remains visible and no empty reasoning section is rendered

#### Scenario: Comparison completes
- **WHEN** every scheduled stage has reached a terminal state
- **THEN** all four results, the generated prompt, actual call count, completion metadata, and comparison controls remain visible together

### Requirement: Deterministic puzzle reference
For the supplied four-house logic-grid preset, the application SHALL derive reference evidence by exhaustively evaluating all one-to-one resident, drink, and pet assignments under the six positional clues rather than asking another model to judge correctness.

#### Scenario: Preset reference is shown
- **WHEN** the shared task matches the supplied preset
- **THEN** the laboratory explains that houses are ordered left to right, every house has exactly one resident, drink, and pet, and exhaustive enumeration admits exactly one complete grid

#### Scenario: Unique assignment is enumerated
- **WHEN** the reference solver evaluates the preset
- **THEN** it returns exactly this grid: house 1 — Vera, coffee, parrot; house 2 — Anna, water, dog; house 3 — Gleb, tea, fish; house 4 — Boris, juice, cat

#### Scenario: Clues are evaluated
- **WHEN** the reference solver accepts a candidate grid
- **THEN** the grid satisfies all six preset clues and assigns every resident, drink, and pet exactly once

#### Scenario: Task differs from the preset
- **WHEN** the user changes the shared task text
- **THEN** the UI marks the built-in reference as not applicable and does not claim an automated correctness result for the modified task

### Requirement: Transparent accuracy comparison
The laboratory SHALL place the four natural-language results beside the reference evidence and SHALL let the user assign an explicit Unrated, Correct, Partial, or Incorrect verdict to each completed strategy and record which strategy was most accurate.

#### Scenario: User rates completed answers
- **WHEN** a strategy has completed or failed
- **THEN** the user can set its verdict while the original answer and reference remain unchanged

#### Scenario: Best strategy is selected
- **WHEN** the user selects a most-accurate strategy after reviewing the evidence
- **THEN** the comparison summary names that strategy, shows all four verdicts, and states that the selection is a transparent user judgment rather than an LLM-generated score

#### Scenario: No strategy is selected
- **WHEN** the comparison has results but no most-accurate strategy has been chosen
- **THEN** the summary prompts the user to compare each result with the unique reference grid without inventing a winner

### Requirement: Responsive and demonstration-safe presentation
The Day 3 laboratory SHALL remain usable on narrow and wide Linux windows and SHALL provide a credential-safe checklist for the required video-plus-code delivery.

#### Scenario: Wide Linux window
- **WHEN** sufficient width is available
- **THEN** the four strategy cards use a readable two-column comparison grid with the reference and summary kept visible below

#### Scenario: Narrow Linux window
- **WHEN** the viewport cannot fit the grid
- **THEN** the task, strategy cards, reference, ratings, and primary action stack without clipping

#### Scenario: Live smoke is executed
- **WHEN** the opt-in Day 3 integration check runs
- **THEN** the API key is supplied only at runtime, all five stages are exercised, and logs contain aggregate non-secret evidence rather than credential values

#### Scenario: Video is recorded
- **WHEN** the user records the Day 3 demonstration
- **THEN** the four prompts/results, generated prompt, unique reference grid, verdicts, and selected conclusion are legible while credentials and unrelated desktop content remain outside the recording
