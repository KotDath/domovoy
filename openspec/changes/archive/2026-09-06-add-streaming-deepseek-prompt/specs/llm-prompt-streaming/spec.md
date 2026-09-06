## Purpose

Defines a provider-independent, one-shot LLM prompt contract and the observable streaming behavior of its initial OpenAI-compatible DeepSeek implementation.

## ADDED Requirements

### Requirement: Provider-independent prompt stream
The system SHALL expose an agent contract that accepts one non-empty text input and returns a stream whose events distinguish reasoning text deltas, answer text deltas, successful completion, and failure without exposing provider response objects to consumers.

#### Scenario: Reasoning and answer are streamed separately
- **WHEN** a provider emits reasoning text followed by final-answer text for a prompt
- **THEN** the agent stream emits reasoning deltas separately from answer deltas and terminates with successful completion

#### Scenario: Each invocation is independent
- **WHEN** the agent is invoked after an earlier invocation has completed
- **THEN** the new provider request contains only the new prompt and no content from the earlier invocation

#### Scenario: Failure is represented consistently
- **WHEN** prompt execution fails before or during streaming
- **THEN** the stream terminates with a typed failure that can be presented without inspecting provider-specific data

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

