## MODIFIED Requirements

### Requirement: Provider-independent prompt stream
The system SHALL execute each non-empty prompt through the ergonomic agent one-call operation backed by a fresh transient ephemeral session and return a stream whose events distinguish reasoning text deltas, answer text deltas, successful completion, cancellation, and typed failure without exposing provider response objects to consumers. The prompt workspace SHALL apply a feature-specific one-model-turn and zero-tool allowance, SHALL continue to run one submission at a time, and SHALL not carry session messages from one submission into the next. Its existing DeepSeek reasoning toggle SHALL remain an enabled/disabled UI setting: enabled resolves to canonical `modelDefault` and therefore the backwards-compatible DeepSeek high profile default, while disabled remains off. Adding a level selector or new persisted settings key is outside this foundation change. These workspace limits SHALL NOT become global agent-runtime defaults.

#### Scenario: Reasoning and answer are streamed separately
- **WHEN** a provider emits reasoning text followed by final-answer text for a prompt
- **THEN** the runtime stream emits reasoning deltas separately from answer deltas and terminates with successful completion

#### Scenario: Each invocation is independent
- **WHEN** the runtime is invoked after an earlier prompt-workspace invocation has completed
- **THEN** it creates a fresh session whose initial provider request contains only definition context and the new prompt, with no content from the earlier invocation

#### Scenario: Existing DeepSeek reasoning setting is loaded
- **WHEN** the stored boolean reasoning setting is enabled or disabled
- **THEN** the prompt snapshots the corresponding existing `ReasoningMode`, preserves `ReasoningEffort.modelDefault`, and requires no settings migration or new level control

#### Scenario: Workspace model asks for a tool
- **WHEN** the prompt workspace's zero-tool definition receives a model tool request
- **THEN** no tool executes, the run terminates with the typed tool-limit result, and the global runtime remains unlimited for callers that did not select this workspace policy

#### Scenario: Failure is represented consistently
- **WHEN** prompt execution fails before or during streaming
- **THEN** the stream terminates with a typed sanitized failure that can be presented without inspecting provider-specific data

#### Scenario: Workspace is disposed during execution
- **WHEN** the Flutter controller or its run-event subscription is disposed while a prompt is active
- **THEN** the active run is cancelled and no later event mutates the disposed controller

#### Scenario: Application composition is disposed during execution
- **WHEN** the Flutter root starts dependency close while a prompt run or its ephemeral session is still active
- **THEN** its internally ordered close future awaits idempotent bounded runtime/session cleanup, then closes owned repository/router resources, and closes the shared HTTP client last even though synchronous Flutter `dispose` cannot await that future

#### Scenario: Ordered dependency close is awaited by a host
- **WHEN** a test or non-Flutter host awaits dependency close more than once
- **THEN** it observes one shared completion, no new runtime work is accepted, and the transport remains open until all accepted runtime cleanup attempts finish
