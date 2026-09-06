# Temperature Comparison Specification

## Purpose

Defines a visible Day 4 laboratory that runs one prompt with three sampling temperatures and supports evidence-based comparison of accuracy, creativity, diversity, and suitable use cases.

## Requirements

### Requirement: Configurable three-temperature experiment
The Day 4 laboratory SHALL present one editable shared prompt and three horizontal temperature controls initialized to `0.0`, `0.7`, and `1.2`, with the applied values and total three-call cost visible before execution.

#### Scenario: Laboratory opens
- **WHEN** the user opens Day 4
- **THEN** the shared prompt, three result lanes, preset values `0.0`, `0.7`, and `1.2`, three-call disclosure, and one run-all action are visible

#### Scenario: Temperature is adjusted
- **WHEN** the user moves a temperature control while no comparison is active
- **THEN** its value changes in `0.1` steps within the inclusive range `0.0…2.0` and the other two values remain unchanged

#### Scenario: Required presets are restored
- **WHEN** the user activates the reset action while no comparison is active
- **THEN** the three controls return to `0.0`, `0.7`, and `1.2`

#### Scenario: Values are not distinct
- **WHEN** the user attempts to run with two or more equal temperature values
- **THEN** no provider request starts and the UI explains that comparison values must be distinct

### Requirement: Same-prompt sequential execution
The laboratory SHALL snapshot one non-empty prompt and the three distinct configured temperatures, clear prior results and evaluations, and execute exactly one independent request per temperature sequentially without conversation history.

#### Scenario: Default comparison starts
- **WHEN** the user runs the unchanged Day 4 presets
- **THEN** the same prompt snapshot is sent in order with temperatures `0.0`, `0.7`, and `1.2`

#### Scenario: Comparison is active
- **WHEN** any temperature lane is streaming
- **THEN** prompt editing, temperature controls, reset, and duplicate execution are disabled

#### Scenario: One lane fails
- **WHEN** a temperature request fails before or during streaming
- **THEN** its partial output and sanitized error remain visible and the next configured temperature still receives its request

#### Scenario: Controller is disposed
- **WHEN** the Day 4 controller is disposed during an active request
- **THEN** its subscription is cancelled and stale events cannot change later state

### Requirement: Temperature-effective provider policy
Every Day 4 request SHALL explicitly disable native thinking, SHALL send the exact snapshotted temperature through OpenAI-compatible Chat Completions, and SHALL leave `top_p` unset so temperature is the only sampling variable.

#### Scenario: A temperature lane starts
- **WHEN** a Day 4 input is constructed
- **THEN** it contains the shared prompt, disabled thinking, no reasoning effort or response control, and the lane's temperature

#### Scenario: Request body is created
- **WHEN** the DeepSeek request body is serialized for a Day 4 input
- **THEN** it contains the numeric `temperature`, `thinking.type` is `disabled`, and `top_p` and `reasoning_effort` are absent

#### Scenario: Provider constraints are explained
- **WHEN** the Day 4 laboratory is visible
- **THEN** it states that DeepSeek supports temperatures from `0.0` through `2.0`, that temperature is ineffective in thinking mode, and that `top_p` is intentionally unchanged

### Requirement: Independent streamed temperature evidence
Each temperature lane SHALL retain its exact applied temperature, independent progressive answer, sanitized failure, completion reason, token usage, character count, and lexical evidence after the run.

#### Scenario: Answer deltas arrive
- **WHEN** a lane emits answer deltas
- **THEN** its card appends them in order while the other lane outputs remain unchanged

#### Scenario: No reasoning is returned
- **WHEN** a Day 4 request emits answer content without reasoning deltas
- **THEN** the answer remains visible and no empty reasoning disclosure is rendered

#### Scenario: Comparison completes
- **WHEN** all three requests reach terminal states
- **THEN** all answers, applied values, completion metadata, character counts, token usage, actual call count, and comparison controls remain visible together

### Requirement: Transparent quality evaluation
The laboratory SHALL let the user assign an Unrated or `1…5` score for accuracy, creativity, and diversity to every terminal lane and add an optional local use-case note without modifying or resubmitting the original answers.

#### Scenario: User rates an answer
- **WHEN** the user scores a terminal lane
- **THEN** the selected values and optional note appear in the comparison summary while the answer remains unchanged

#### Scenario: New comparison starts
- **WHEN** the user starts another valid comparison
- **THEN** all earlier scores and use-case notes are cleared with the prior results

#### Scenario: Results are unrated
- **WHEN** a comparison has results but the user has not supplied scores
- **THEN** the UI prompts for human evaluation and does not invent quality scores or a winner

### Requirement: Diversity indicators and limitations
For completed non-empty outputs, the laboratory SHALL show deterministic lexical-diversity and pairwise-similarity indicators as descriptive evidence and SHALL distinguish those indicators from semantic quality judgments.

#### Scenario: Text evidence is calculated
- **WHEN** a non-empty answer completes
- **THEN** the UI shows its Unicode character count and unique normalized-word ratio using documented deterministic token normalization

#### Scenario: Multiple answers complete
- **WHEN** at least two non-empty lanes complete
- **THEN** the comparison shows pairwise normalized-word Jaccard similarity for the available pairs

#### Scenario: Limitation is shown
- **WHEN** the Day 4 summary is displayed
- **THEN** it explains that one sample per temperature demonstrates differences but cannot estimate the full stochastic output distribution

### Requirement: Practical temperature conclusions
The laboratory SHALL display concise provider-informed guidance for low, balanced, and higher temperature settings and SHALL allow the user to record which tasks best fit the observed outputs.

#### Scenario: Guidance is shown
- **WHEN** Day 4 is visible
- **THEN** it explains that lower values favor focused deterministic work, intermediate values balance focus and variation, and higher values favor brainstorming or creative variation while preserving the exact values as experiment evidence

#### Scenario: Official recommendations are distinguished
- **WHEN** the guidance references DeepSeek use cases
- **THEN** it identifies the provider's documented examples separately from conclusions inferred for the exercise's `0.7` and `1.2` values

### Requirement: Responsive and demonstration-safe presentation
The Day 4 laboratory SHALL remain usable on narrow and wide Linux desktop windows and SHALL provide a credential-safe video-plus-code demonstration checklist.

#### Scenario: Wide Linux window
- **WHEN** sufficient width is available
- **THEN** the three result cards use a readable multi-column comparison layout with controls and summary visible in the same scrollable screen

#### Scenario: Narrow Linux window
- **WHEN** the viewport cannot fit the comparison columns
- **THEN** prompt, sliders, action, result cards, ratings, and conclusions stack without clipping

#### Scenario: Live smoke is executed
- **WHEN** the opt-in Day 4 integration test runs
- **THEN** a runtime-only API key is used, all three preset temperatures complete with non-empty output, and logs contain only aggregate non-secret evidence

#### Scenario: Video is recorded
- **WHEN** the user records the Day 4 demonstration
- **THEN** the three values, same prompt, streamed outputs, evaluations, diversity evidence, and conclusions are legible while credentials remain outside every frame and log
