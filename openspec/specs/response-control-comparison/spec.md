# Response Control Comparison Specification

## Purpose

Defines a visible response laboratory in which Domovoy runs the same base request with and without one class of response control, validates observable results, and explains the limits of prompt, API, and application-level guarantees.

## Requirements

### Requirement: Response laboratory navigation
The system SHALL preserve the Day 1 one-shot prompt workspace and SHALL provide a clearly labeled way to open a dedicated Day 2 response laboratory containing Format, Length, and Stop experiments.

#### Scenario: User opens the laboratory
- **WHEN** the user activates the Day 2 response-control entry from the prompt workspace
- **THEN** the system displays the three experiments and preserves the existing one-shot prompt workflow as a separate destination

#### Scenario: Narrow Linux window
- **WHEN** the laboratory is shown in a viewport too narrow for side-by-side results
- **THEN** controls and result cards stack without clipping or hiding primary actions

### Requirement: Configurable reasoning mode
The system SHALL expose a persisted Reasoning switch in DeepSeek model settings and SHALL apply the selected mode consistently to every request in an experiment.

#### Scenario: Reasoning is enabled
- **WHEN** a request starts while Reasoning is enabled
- **THEN** the provider request enables thinking with high reasoning effort and separately streams any reasoning content returned by the provider

#### Scenario: Reasoning is disabled
- **WHEN** a request starts while Reasoning is disabled
- **THEN** the provider request explicitly disables thinking, omits reasoning effort, and the result does not reserve or render an empty reasoning section

#### Scenario: Reasoning setting is reopened
- **WHEN** the user changes the Reasoning switch and later reopens model settings
- **THEN** the previously saved selection is restored

#### Scenario: Length experiment uses reasoning
- **WHEN** Reasoning is enabled while the user configures a small maximum-token ceiling
- **THEN** the Length experiment displays a warning that thinking tokens may consume the completion budget without silently changing the setting

### Requirement: Independent same-prompt comparisons
Each experiment SHALL execute an unrestricted baseline followed by one controlled request derived from the same non-empty base prompt, without adding either result to conversation history.

#### Scenario: User runs one experiment
- **WHEN** the user submits valid inputs for the selected experiment
- **THEN** the system clears that experiment's prior results, runs its baseline to a terminal state, and then runs its controlled request

#### Scenario: Requests remain independent
- **WHEN** the controlled request is constructed
- **THEN** it contains the same base prompt but no reasoning, answer text, or message produced by the baseline request

#### Scenario: Other experiments remain available
- **WHEN** one experiment completes
- **THEN** its result remains visible and the user can select another experiment without those results becoming conversation context

#### Scenario: One lane fails
- **WHEN** the baseline or controlled stream fails before or during generation
- **THEN** its partial output and sanitized error remain visible independently and the other lane still receives its scheduled attempt

### Requirement: Format contract comparison
The Format experiment SHALL support editable JSON and Markdown presets, append the selected explicit structure only to the controlled request, and display structural validation for every completed answer.

#### Scenario: JSON format is selected
- **WHEN** the controlled JSON request starts
- **THEN** it explicitly requests JSON, includes an example of the required keys and value types, and enables the provider's JSON-object response mode

#### Scenario: JSON answer is validated
- **WHEN** either JSON result completes
- **THEN** the system reports whether it parses as one JSON object and whether all required keys, value types, and configured collection counts match the visible contract

#### Scenario: Markdown format is selected
- **WHEN** the controlled Markdown request starts
- **THEN** it includes the visible required headings, their order, and the required number or type of list items without enabling JSON-object response mode

#### Scenario: Markdown answer is validated
- **WHEN** either Markdown result completes
- **THEN** the system reports whether the required headings, order, and list structure match the visible contract rather than treating arbitrary text as valid Markdown

#### Scenario: Format inputs are invalid
- **WHEN** the selected format contract is empty or cannot define a supported structural check
- **THEN** no provider request starts and the affected control displays an actionable validation error

### Requirement: One-shot format repair
The Format experiment SHALL offer at most one user-triggered repair request for an invalid controlled answer and SHALL make the original and repaired validation evidence independently visible.

#### Scenario: Controlled answer is invalid
- **WHEN** controlled format validation fails and no repair has been attempted
- **THEN** the system displays the validation diagnostics and enables an "Исправить формат" action

#### Scenario: User requests repair
- **WHEN** the user activates the repair action
- **THEN** the system sends one independent user message containing the original task, visible contract, invalid output, and validation diagnostics, streams the repaired answer, and validates it on completion

#### Scenario: First answer is valid
- **WHEN** the controlled answer satisfies the selected contract
- **THEN** the system reports that repair is unnecessary and does not offer a repair request

#### Scenario: Repair remains invalid
- **WHEN** the single repair attempt also fails validation
- **THEN** the system displays its diagnostics and does not offer another automatic repair cycle

### Requirement: Length-control comparison
The Length experiment SHALL compare an unrestricted request with a controlled request that includes both a visible maximum-character instruction and a positive API maximum-completion-token ceiling.

#### Scenario: Controlled length request starts
- **WHEN** the user supplies a positive character target and a supported positive maximum-token value
- **THEN** the controlled request includes the character instruction in its user message and carries the maximum-token value in the Chat Completions request while the baseline omits both controls

#### Scenario: Length result completes
- **WHEN** either result reaches a terminal state
- **THEN** the system displays its actual Unicode character count, configured limits that apply to it, provider-neutral completion reason, and completion-token usage when supplied by the provider

#### Scenario: Token ceiling is reached
- **WHEN** the provider reports that generation ended at the maximum-token limit
- **THEN** the answer remains visible and is labeled as truncated by the token ceiling without claiming compliance with the character target

#### Scenario: Length inputs are invalid
- **WHEN** the character target or maximum-token value is missing, non-numeric, non-positive, or outside the supported range
- **THEN** no provider request starts and the affected length control displays an actionable validation error

### Requirement: Stop-sequence comparison
The Stop experiment SHALL send the same marker-producing prompt to both lanes, omit a stop field from the baseline, and pass the visible non-empty marker as the controlled request's API stop sequence.

#### Scenario: Stop experiment starts
- **WHEN** the user supplies a prompt that instructs the model to emit the visible marker before post-marker text
- **THEN** both messages contain that same instruction and only the controlled API request carries the stop sequence

#### Scenario: Configured marker is emitted
- **WHEN** the controlled provider encounters the configured stop sequence
- **THEN** generation ends before returning the marker or post-marker text and the result displays the normalized stop completion reason

#### Scenario: Marker is not emitted
- **WHEN** the model terminates without producing the configured sequence
- **THEN** the completed result remains valid evidence and the UI does not claim that the configured sequence caused termination

#### Scenario: Stop marker is invalid
- **WHEN** the marker is empty or whitespace-only
- **THEN** no provider request starts and the stop control displays an actionable validation error

### Requirement: Comparable streamed evidence
The laboratory SHALL present separate "Без ограничений" and "С контролем" result cards for the selected experiment, preserve reasoning and answer streaming for each lane, and summarize objective evidence without assigning a nondeterministic quality score.

#### Scenario: Comparison is in progress
- **WHEN** either lane is active
- **THEN** both cards remain visible, the active card shows progress, and duplicate execution of that experiment is disabled

#### Scenario: Results complete
- **WHEN** both lanes reach terminal states
- **THEN** their answers, validation or measurement evidence, applied non-secret controls, and human-readable completion reasons remain visible together

#### Scenario: Provider returns no reasoning
- **WHEN** a lane emits answer content without reasoning content
- **THEN** its answer still streams progressively and no empty reasoning disclosure is shown

### Requirement: Experiment conclusions
The laboratory SHALL display a concise conclusion for each experiment that explains the strength and limitation of its controls using the evidence visible in the current run.

#### Scenario: Format conclusion is shown
- **WHEN** the Format experiment is selected
- **THEN** the UI explains that prompting and JSON-object mode do not guarantee the application schema, while validation and bounded repair can enforce the visible contract

#### Scenario: Length conclusion is shown
- **WHEN** the Length experiment is selected
- **THEN** the UI explains that a character instruction is behavioral, a maximum-token value is a hard but potentially truncating token ceiling, and exact length requires application validation

#### Scenario: Stop conclusion is shown
- **WHEN** the Stop experiment is selected
- **THEN** the UI explains that the stop sequence ends generation only when the exact marker is emitted and that the marker itself is excluded from returned content

### Requirement: Demonstration-safe delivery
The Day 2 deliverable SHALL include implementation code and a Linux desktop demonstration of all three experiments without displaying, logging, embedding, or recording the effective API key.

#### Scenario: Demonstration is recorded
- **WHEN** the Day 2 video is captured
- **THEN** it shows the Reasoning state, shared prompt, controlled inputs, paired results, objective evidence, and conclusions while credential values remain outside every frame and recorded log

#### Scenario: Nondeterministic format result is valid initially
- **WHEN** the live provider satisfies a format contract on its first attempt
- **THEN** the video presents that real result without fabricating a failure and deterministic tests provide evidence for the invalid-and-repair path

