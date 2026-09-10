# LLM Prompt Streaming Specification

## Purpose

Defines a provider-independent, one-shot LLM prompt contract and the observable streaming behavior of its initial OpenAI-compatible DeepSeek implementation.

## Requirements

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

### Requirement: DeepSeek Chat Completions request
The initial provider implementation SHALL call the official OpenAI-compatible DeepSeek Chat Completions API with model `deepseek-v4-flash`, streaming enabled, thinking explicitly enabled, high reasoning effort, a bearer API key, and exactly one current user message.

#### Scenario: Request is constructed for thinking-mode streaming
- **WHEN** a valid prompt and API key are supplied
- **THEN** the system sends an authenticated request to `https://api.deepseek.com/chat/completions` with `stream` set to `true`, `thinking.type` set to `enabled`, `reasoning_effort` set to `high`, and the current prompt as the sole user message

#### Scenario: No agent SDK is involved
- **WHEN** the DeepSeek request is executed
- **THEN** the application communicates with the HTTP API directly and does not require an LLM SDK or agent framework

### Requirement: OpenAI-compatible stream normalization
The provider implementation SHALL parse the Chat Completions server-sent event stream across arbitrary network chunk boundaries, map `choices[0].delta.reasoning_content` to reasoning deltas, map `choices[0].delta.content` to answer deltas, ignore supported chunks that carry no display text, and report completion only after the stream's terminal marker.

#### Scenario: Fragmented SSE event is reconstructed
- **WHEN** one JSON event is split across multiple network chunks
- **THEN** the system reconstructs the complete SSE event before decoding and emitting its text

#### Scenario: Reasoning delta arrives
- **WHEN** an SSE data object contains non-empty `choices[0].delta.reasoning_content`
- **THEN** the agent emits that value as a reasoning delta

#### Scenario: Answer delta arrives
- **WHEN** an SSE data object contains non-empty `choices[0].delta.content`
- **THEN** the agent emits that value as an answer delta

#### Scenario: Stream completes normally
- **WHEN** the API sends the `[DONE]` terminal data marker after zero or more content chunks
- **THEN** the agent emits one successful-completion event and no later events

### Requirement: Provider and transport failures
The agent SHALL convert missing credentials, non-success HTTP responses, provider error payloads, malformed streaming data, unexpected end-of-stream, and network failures into sanitized typed failures while preserving any reasoning or answer deltas already emitted.

#### Scenario: API rejects a request
- **WHEN** DeepSeek returns a non-success HTTP status
- **THEN** the agent emits a provider failure with a useful sanitized message and does not expose the bearer key

#### Scenario: Connection closes without a terminal marker
- **WHEN** the network stream ends before `[DONE]`
- **THEN** the agent emits a stream-interrupted failure rather than reporting success

#### Scenario: Malformed display event is received
- **WHEN** a text-bearing SSE event cannot be decoded according to the expected schema
- **THEN** the agent emits a protocol failure and does not silently treat the response as complete

### Requirement: Optional sampling temperature
The provider-independent prompt input SHALL accept an optional finite sampling temperature from `0.0` through `2.0`, and the DeepSeek Chat Completions adapter SHALL serialize that value only when the caller supplies it.

#### Scenario: Temperature is supplied
- **WHEN** a prompt input carries a valid temperature
- **THEN** the DeepSeek request body contains the same numeric `temperature`

#### Scenario: Temperature is omitted
- **WHEN** an existing prompt input does not carry a temperature
- **THEN** the DeepSeek request body omits `temperature` and preserves the provider's default behavior

#### Scenario: Temperature is invalid
- **WHEN** a caller attempts to construct an input with a non-finite value or a value outside `0.0…2.0`
- **THEN** the input is rejected before any provider request can begin
