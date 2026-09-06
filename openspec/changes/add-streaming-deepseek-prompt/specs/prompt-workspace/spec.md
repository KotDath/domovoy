## Purpose

Defines the single-prompt user experience for entering a question and observing separate progressive reasoning and final-answer output.

## ADDED Requirements

### Requirement: Distinct prompt and output areas
The application SHALL present a prompt input area and a distinct output area, arranging them responsively so both remain usable on narrow and wide screens.

#### Scenario: Workspace opens
- **WHEN** the user opens the application
- **THEN** the prompt input, submit action, output area, and settings access are available instead of the generated counter screen

#### Scenario: Narrow viewport
- **WHEN** the available width cannot comfortably fit two columns
- **THEN** the prompt and output areas are arranged vertically without clipping their controls or content

#### Scenario: Wide viewport
- **WHEN** the available width can comfortably fit two columns
- **THEN** the prompt and output areas are presented side by side

### Requirement: One-shot submission lifecycle
The workspace SHALL accept a non-empty prompt, start one agent stream at a time, clear the previous result when a new submission starts, and return to a state that permits another independent submission after completion or failure.

#### Scenario: Empty prompt is submitted
- **WHEN** the user attempts to submit empty or whitespace-only input
- **THEN** no agent call is made and the input displays a validation message

#### Scenario: Valid prompt is submitted
- **WHEN** the user submits non-empty input while no request is active
- **THEN** the previous reasoning, answer, and error are cleared and the workspace begins consuming the new agent stream

#### Scenario: Submission is already active
- **WHEN** an agent stream is active
- **THEN** the submit action is disabled and a second concurrent call cannot be started

#### Scenario: Submission terminates
- **WHEN** the stream completes or fails
- **THEN** the loading state ends and the user can submit another independent prompt

### Requirement: Progressive reasoning presentation
The workspace SHALL append reasoning deltas as they arrive inside a visually muted section that the user can expand or collapse without affecting the underlying stream.

#### Scenario: First reasoning text arrives
- **WHEN** the first reasoning delta is emitted
- **THEN** a labeled reasoning section appears in the output area and displays the accumulated reasoning using a muted theme color

#### Scenario: User toggles reasoning
- **WHEN** the user activates the reasoning section header
- **THEN** the reasoning body alternates between expanded and collapsed states while retaining all accumulated text

#### Scenario: More reasoning arrives while collapsed
- **WHEN** reasoning deltas arrive while the section is collapsed
- **THEN** the text continues accumulating and is visible in full when the section is expanded again

### Requirement: Progressive answer presentation
The workspace SHALL append answer deltas as they arrive and keep the accumulated final answer directly visible rather than placing it behind a disclosure control.

#### Scenario: Answer begins after reasoning
- **WHEN** the first answer delta arrives after reasoning content
- **THEN** the answer appears in a separate, normally styled region and subsequent answer deltas are appended in order

#### Scenario: Provider returns no reasoning text
- **WHEN** answer deltas arrive without any reasoning delta
- **THEN** the answer is still displayed and no empty reasoning section is shown

### Requirement: User-facing status and errors
The workspace SHALL show an in-progress indication during execution and a sanitized actionable error on failure while retaining any partial reasoning and answer text already received.

#### Scenario: Missing key prevents execution
- **WHEN** the agent reports a missing-key failure
- **THEN** the workspace explains how to configure the key and offers access to settings

#### Scenario: Stream fails after partial output
- **WHEN** the stream fails after emitting reasoning or answer deltas
- **THEN** the partial output remains visible and the error is shown separately

### Requirement: Key settings access
The workspace SHALL provide settings that allow saving a new application key, explicitly removing a saved override, and identifying the active credential source without revealing credential contents.

#### Scenario: Environment key is active
- **WHEN** no application override exists and an environment key is available
- **THEN** settings identify the environment as the active source without displaying the key

#### Scenario: Application override is active
- **WHEN** an application override exists
- **THEN** settings identify the application override as the active source and provide an explicit remove action

### Requirement: No conversation history
The workspace SHALL retain only the current submission's input and output in memory and SHALL not present previous prompts as a conversation.

#### Scenario: User submits a second prompt
- **WHEN** a completed prompt is followed by a new submission
- **THEN** the output area contains only the second submission's reasoning, answer, status, and error state

