## Purpose

Defines how Domovoy runs the same base prompt with and without response controls and presents the two streamed results for a direct, repeatable comparison.

## ADDED Requirements

### Requirement: Same-prompt comparison
The system SHALL provide a comparison action that executes one unrestricted request and one controlled request from the same non-empty base prompt, without adding either result to conversation history.

#### Scenario: User starts a comparison
- **WHEN** the user submits a valid base prompt and valid response controls
- **THEN** the system starts an unrestricted request and then a controlled request using the same base prompt

#### Scenario: Requests remain independent
- **WHEN** the controlled request is constructed after the unrestricted request terminates
- **THEN** neither request contains reasoning, answer text, or messages produced by the other request

#### Scenario: New comparison replaces prior results
- **WHEN** the user starts another comparison after a previous comparison terminates
- **THEN** both prior results and their statuses are cleared before the new unrestricted request begins

### Requirement: Explicit controlled-output format
The controlled request SHALL append a clearly separated, non-empty, user-visible description of the required answer format to the same base prompt, while the unrestricted request SHALL omit that response contract.

#### Scenario: Format description is applied
- **WHEN** the user provides a format description such as a fixed heading and bullet-list structure
- **THEN** the controlled request explicitly instructs the model to follow that description while preserving the original base prompt text

#### Scenario: Format description is blank
- **WHEN** the user attempts a comparison with an empty or whitespace-only format description
- **THEN** no provider request is started and the format control displays a validation error

### Requirement: Controlled response length
The controlled request SHALL include a positive maximum completion-token limit supported by the configured provider, while the unrestricted request SHALL omit an explicit completion-token limit.

#### Scenario: Valid completion limit
- **WHEN** the user submits a supported positive maximum-token value
- **THEN** the controlled API request carries that value as its completion-token limit

#### Scenario: Invalid completion limit
- **WHEN** the maximum-token value is missing, non-numeric, non-positive, or outside the supported range
- **THEN** no provider request is started and the length control displays a validation error

#### Scenario: Provider reaches the length limit
- **WHEN** the controlled response terminates because its completion-token limit is reached
- **THEN** the controlled result remains visible and is labeled as terminated by the length limit

### Requirement: Controlled stop condition
The controlled request SHALL carry a non-empty stop sequence and SHALL explicitly instruct the model to emit that sequence after satisfying the requested response format; the unrestricted request SHALL omit both additions.

#### Scenario: Stop sequence is configured
- **WHEN** the user submits a non-empty stop sequence
- **THEN** the controlled request passes the sequence to the provider and includes an instruction to emit it only after the requested answer is complete

#### Scenario: Configured stop is reached
- **WHEN** the provider terminates generation after encountering the configured stop sequence
- **THEN** the returned answer excludes the sequence and the controlled result is labeled as stopped normally

#### Scenario: Stop sequence is blank
- **WHEN** the user attempts a comparison with an empty or whitespace-only stop sequence
- **THEN** no provider request is started and the stop control displays a validation error

### Requirement: Comparable streamed results
The workspace SHALL present separately labeled unrestricted and controlled results, stream reasoning and answer content for each result, and display a provider-neutral completion reason or sanitized failure for each request.

#### Scenario: Comparison is in progress
- **WHEN** either comparison request is active
- **THEN** both result areas remain visible, the active result shows progress, and another comparison cannot be started

#### Scenario: Both requests complete
- **WHEN** the unrestricted and controlled streams terminate successfully
- **THEN** their accumulated answers remain visible together with labels that identify applied controls and completion reasons

#### Scenario: One request fails
- **WHEN** either request fails before or during streaming
- **THEN** its partial output and sanitized failure remain visible independently of the other request's result

#### Scenario: Narrow viewport
- **WHEN** the comparison workspace cannot comfortably fit both result areas side by side
- **THEN** the unrestricted and controlled results are stacked without clipping their controls or streamed content

### Requirement: Demonstration-safe delivery
The Day 2 deliverable SHALL include the implementation code and a Linux desktop demonstration showing one comparison without displaying, logging, embedding, or recording the effective API key.

#### Scenario: Demonstration is recorded
- **WHEN** the Day 2 video is captured on Linux desktop
- **THEN** it shows the shared prompt, configured controls, both results, and their observable differences while keeping credential values out of every frame and recorded log
