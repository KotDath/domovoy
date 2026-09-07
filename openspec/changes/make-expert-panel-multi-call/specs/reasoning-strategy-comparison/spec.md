## MODIFIED Requirements

### Requirement: Four visible reasoning strategies
The Day 3 laboratory SHALL present Direct, Step by step, Generated prompt, and Expert group as four distinct strategies with their prompt transformation and real API-call cost visible before execution. Expert group SHALL be identified as three independent expert requests followed by one synthesis request, rather than one request that role-plays multiple experts.

#### Scenario: Laboratory opens
- **WHEN** the user opens the Day 3 laboratory
- **THEN** all four strategies, the shared task, the total eight-call cost, and one action to run the complete comparison are visible

#### Scenario: Direct strategy is constructed
- **WHEN** the Direct request starts
- **THEN** its sole user message contains the shared task without a reasoning-strategy instruction

#### Scenario: Step-by-step strategy is constructed
- **WHEN** the Step-by-step request starts
- **THEN** its sole user message contains the same task plus an explicit instruction to solve it step by step and check the conclusion

#### Scenario: Expert-group strategy is constructed
- **WHEN** the Expert-group strategy starts
- **THEN** it sends the same immutable task in three separate requests that assign the model respectively to analyst, engineer, and critic roles
- **AND** no expert request contains another expert's output

#### Scenario: Expert synthesis is constructed
- **WHEN** the three expert attempts have reached terminal states
- **THEN** a fourth request receives the immutable task and the three separately labeled expert outcomes and is instructed to reconcile disagreements and return the final answer

### Requirement: Prompt-level comparison disables native reasoning
Every Day 3 provider request SHALL explicitly disable native model thinking so the experiment compares prompt-level strategies rather than hidden changes in provider reasoning effort.

#### Scenario: Any Day 3 request starts
- **WHEN** a direct, step-by-step, prompt-builder, generated-solver, analyst, engineer, critic, or expert-synthesis request is constructed
- **THEN** it carries disabled thinking and no reasoning-effort value regardless of the persisted setting used by other application screens

#### Scenario: Reasoning policy is visible
- **WHEN** the Day 3 laboratory is displayed
- **THEN** it states that native reasoning is fixed off for all four strategies and links the explanation to comparison fairness

### Requirement: Same-task sequential execution
The comparison SHALL snapshot one non-empty task and execute Direct, Step by step, Generated prompt, and Expert group sequentially without adding any result to conversation history. The three expert attempts SHALL also execute sequentially, each without seeing prior expert output, before synthesis.

#### Scenario: User runs the comparison
- **WHEN** the user submits a non-empty shared task while no comparison is active
- **THEN** prior Day 3 results and ratings are cleared and all eight planned requests run in order using the same task snapshot

#### Scenario: Comparison is already active
- **WHEN** any Day 3 stage is streaming
- **THEN** the run action and task editing are disabled and a duplicate comparison cannot start

#### Scenario: An expert attempt fails
- **WHEN** an analyst, engineer, or critic request fails before or during streaming
- **THEN** its partial output and sanitized failure remain visible and the remaining expert requests still start

#### Scenario: Synthesis follows failed experts
- **WHEN** one or more expert attempts fail
- **THEN** the synthesis request still starts with every available partial result and an explicit unavailable marker for an expert that produced no content

#### Scenario: One strategy fails
- **WHEN** any Day 3 request fails before or during streaming
- **THEN** its partial output and sanitized error remain visible and the next scheduled stage still starts, except when the cancelled or superseded run must not continue

#### Scenario: Controller is disposed
- **WHEN** the user leaves or the controller is disposed while a stage is active
- **THEN** the active subscription is cancelled and no stale event changes a later state

### Requirement: Independent streamed evidence
Each strategy SHALL retain independent status, progressive answer text, sanitized failure, completion reason, usage, and stage-specific evidence without displaying an empty reasoning disclosure. Expert group SHALL retain the three expert streams separately from the synthesis stream and SHALL use the synthesis output as its final comparable answer.

#### Scenario: Answer deltas arrive
- **WHEN** a strategy stage emits answer deltas
- **THEN** its corresponding result area appends them in order while all other stage evidence remains unchanged

#### Scenario: Expert evidence is displayed
- **WHEN** any expert attempt has started
- **THEN** the Expert-group card shows separately labeled analyst, engineer, and critic states and content in addition to the final synthesis area

#### Scenario: Native reasoning content is absent
- **WHEN** disabled thinking produces answer content without reasoning deltas
- **THEN** the answer remains visible and no empty reasoning section is rendered

#### Scenario: Comparison completes
- **WHEN** every scheduled stage has reached a terminal state
- **THEN** all four comparable results, the generated prompt, three expert outputs, expert synthesis, actual call count, completion metadata, and comparison controls remain visible together

### Requirement: Responsive and demonstration-safe presentation
The Day 3 laboratory SHALL remain usable on narrow and wide Linux windows and SHALL provide a credential-safe checklist for the required video-plus-code delivery.

#### Scenario: Wide Linux window
- **WHEN** sufficient width is available
- **THEN** the four strategy cards use a readable two-column comparison grid with the reference and summary kept visible below

#### Scenario: Narrow Linux window
- **WHEN** the viewport cannot fit the grid
- **THEN** the task, strategy cards, expert evidence, reference, ratings, and primary action stack without clipping

#### Scenario: Live smoke is executed
- **WHEN** the opt-in Day 3 integration check runs
- **THEN** the API key is supplied only at runtime, all eight stages are exercised, and logs contain aggregate non-secret evidence rather than credential values

#### Scenario: Video is recorded
- **WHEN** the user records the Day 3 demonstration
- **THEN** the four prompts/results, three independent expert outputs, synthesis, unique reference grid, verdicts, and selected conclusion are legible while credentials and unrelated desktop content remain outside the recording
