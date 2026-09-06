## Purpose

Defines the Day 5 laboratory for comparing weak, medium, and strong model profiles with the same prompt using observable quality, speed, token, cost, and resource evidence.

## ADDED Requirements

### Requirement: Three-tier same-prompt experiment
The Day 5 laboratory SHALL present one editable shared prompt and three configured lanes labeled weak, medium, and strong, with the exact profile identity, endpoint host, model id, source link, and three-call cost visible before execution.

#### Scenario: Laboratory opens with presets
- **WHEN** the user opens Day 5 with default settings
- **THEN** the prompt asks for a Dart ECS based on sparse sets and the lanes show local Ollama `qwen3.5:2b`, DeepSeek V4 Flash, and DeepSeek V4 Pro

#### Scenario: Tier label is shown
- **WHEN** a profile is described as weak, medium, or strong
- **THEN** the UI explains that the tier is an experiment label rather than a guaranteed quality judgment

#### Scenario: Source evidence is inspected
- **WHEN** the user reviews a lane or the final summary
- **THEN** the complete provider/model reference URL is visible and copyable

### Requirement: Fair sequential model execution
The laboratory SHALL validate and snapshot the trimmed prompt and all three profiles, clear earlier results and evaluations, and run exactly one independent request per profile sequentially without conversation history or native reasoning.

#### Scenario: Default comparison starts
- **WHEN** the user runs the unchanged presets
- **THEN** the same prompt snapshot is sent in weak-to-medium-to-strong order to the exact snapshotted endpoint and model values

#### Scenario: Comparison is active
- **WHEN** any model lane is running
- **THEN** prompt/profile editing, reset, duplicate execution, and settings dismissal during a save are disabled

#### Scenario: One lane cannot run or fails
- **WHEN** credentials are missing, the local service is unavailable, or a stream fails
- **THEN** sanitized failure and partial evidence remain visible and the next profile still runs

#### Scenario: Comparison controller is disposed
- **WHEN** the controller is disposed during an active request
- **THEN** the active subscription is cancelled and stale events cannot change results or timing

### Requirement: Monotonic latency evidence
Every lane SHALL measure time to first non-empty answer delta and total terminal duration using a monotonic clock, while preserving unavailable states for lanes that never produce an answer token.

#### Scenario: First answer delta arrives
- **WHEN** a lane receives its first non-empty answer content
- **THEN** TTFT is frozen once and later deltas do not change it

#### Scenario: Lane terminates
- **WHEN** a lane completes or fails
- **THEN** total duration is frozen once and no later event can mutate timing or double-count the call

#### Scenario: Warm-up affects a local model
- **WHEN** timing conclusions are displayed
- **THEN** the UI states that sequential order, network latency, cache state, and local cold-start/loading can affect a single run

### Requirement: Token and resource evidence
Each terminal lane SHALL show provider-reported prompt, completion, total, and cache token fields when present, and SHALL distinguish provider token accounting from local model size and unmeasured CPU, RAM, energy, or network resources.

#### Scenario: Provider reports usage
- **WHEN** terminal usage metadata is available
- **THEN** the exact reported fields are displayed and used for dependent calculations

#### Scenario: Provider omits usage
- **WHEN** usage or a usage subfield is absent
- **THEN** the corresponding value is labeled unavailable and is not inferred from character count

#### Scenario: Local preset is shown
- **WHEN** the default Ollama lane is visible
- **THEN** its documented model parameter count and download size are presented as profile metadata, not as measured runtime RAM or compute consumption

### Requirement: Reproducible estimated cost
For profiles with snapshotted pricing and sufficient token usage, the laboratory SHALL calculate an estimated provider cost from per-million rates and SHALL show a range when cache-hit versus cache-miss input tokens cannot be distinguished.

#### Scenario: Cache token split is reported
- **WHEN** usage distinguishes cached and uncached prompt tokens
- **THEN** cost uses the matching cache-hit and cache-miss input rates plus the output rate

#### Scenario: Cache token split is absent
- **WHEN** prompt and completion tokens exist but a profile has different cache-hit and cache-miss rates
- **THEN** the UI shows the minimum-to-maximum estimate bounded by all-hit and all-miss input assumptions

#### Scenario: Provider fee is explicitly zero
- **WHEN** a local profile declares no provider billing fee
- **THEN** provider cost is shown as zero with a note that hardware and energy costs are excluded

#### Scenario: Cost cannot be calculated
- **WHEN** rates or required token fields are missing
- **THEN** cost is labeled unavailable and no numeric zero is invented

### Requirement: Transparent code-answer quality evaluation
The laboratory SHALL retain every answer unchanged, show a deterministic checklist heuristic for expected sparse-set ECS concepts, and let the user assign optional `1…5` correctness, completeness, and practical-usefulness scores plus notes.

#### Scenario: Answer completes
- **WHEN** a lane completes with non-empty output
- **THEN** the UI reports whether the text visibly includes Dart code, sparse/dense mapping, swap-remove, complexity, component storage, and query concepts as a labeled lexical/structural heuristic

#### Scenario: User evaluates a lane
- **WHEN** the user records scores or notes
- **THEN** the summary repeats only those human judgments without changing or resubmitting the answer

#### Scenario: New comparison starts
- **WHEN** another valid run begins
- **THEN** prior answers, checklist evidence, scores, notes, and conclusion text are cleared

#### Scenario: No scores are supplied
- **WHEN** results exist without human ratings
- **THEN** the UI requests evaluation and does not invent semantic scores or a quality winner

### Requirement: Evidence-based comparison summary
The Day 5 summary SHALL identify objective per-run extrema only when comparable evidence exists, SHALL keep quality conclusions tied to user ratings, and SHALL provide editable short conclusion text suitable for the assignment.

#### Scenario: All durations are available
- **WHEN** the three lanes terminate with total-duration evidence
- **THEN** the summary may identify the fastest lane specifically for this run and shows all measured values

#### Scenario: Token or cost evidence is incomplete
- **WHEN** one or more lanes lack comparable values
- **THEN** no universal token or cost winner is declared and unavailable evidence is named

#### Scenario: User writes a conclusion
- **WHEN** the user records a short comparison conclusion
- **THEN** it remains local to the current results and is displayed with the three source links

#### Scenario: Single-run limitation is shown
- **WHEN** the summary is visible
- **THEN** it states that one prompt and one response per model cannot establish general model quality, stable latency, or total resource efficiency

### Requirement: Responsive and demonstration-safe presentation
The Day 5 laboratory SHALL remain usable on narrow and wide Linux desktop windows and SHALL provide credential-safe code, live-smoke, and video guidance.

#### Scenario: Wide Linux window
- **WHEN** sufficient width is available
- **THEN** three result cards form a readable comparison layout inside one scrollable screen

#### Scenario: Narrow Linux window
- **WHEN** the viewport cannot fit three cards
- **THEN** prompt, profile evidence, actions, results, evaluations, and summary stack without clipping

#### Scenario: DeepSeek live smoke runs
- **WHEN** the opt-in cloud integration test receives a runtime-only DeepSeek key
- **THEN** Flash and Pro each return non-empty output and logs contain only model ids, aggregate timing, token, status, and cost evidence

#### Scenario: Local test is prepared
- **WHEN** the user follows the Ollama checklist
- **THEN** it names the pull command, local Chat Completions endpoint, model id, and opt-in smoke command without assuming the service is installed or running

#### Scenario: Video is recorded
- **WHEN** the user records the Day 5 demonstration
- **THEN** the same prompt, three identities, results, timing, tokens, costs, quality evidence, conclusion, and links are legible while secrets remain outside every frame and log
