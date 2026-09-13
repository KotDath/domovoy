## MODIFIED Requirements

### Requirement: OpenAI Responses family
The OpenAI Responses adapter SHALL translate provider-neutral requests for the registered OpenAI profile into the Responses API, including instructions and ordered conversation items, function tools and correlated function-call outputs, optional valid temperature where supported, output-token limits, model-valid reasoning controls, streaming usage, and cancellation. Every request SHALL use `store: false` and omit `previous_response_id`; every reasoning-capable request SHALL request `reasoning.encrypted_content`. It SHALL normalize Responses SSE output text, reasoning, function-call arguments, usage, completion, refusal, and sanitized error events into the common provider grammar. It SHALL also collect complete supported `response.output_item.done` items in provider order and return them as `openai.responses.output_items.v1` turn state only after successful completion; potentially incomplete `output_item.added` reasoning content SHALL NOT be retained for replay. An `output_text` content part MAY contain standard `logprobs`, including an empty list. Each populated entry SHALL have only required `token`, `logprob`, `bytes`, and `top_logprobs` fields: token SHALL be a string, logprob SHALL be finite numeric, bytes SHALL be null or a list of integers from 0 through 255, and top_logprobs SHALL be a list of closed entries containing only required token/logprob/bytes fields with the same leaf validation and no recursive nesting; outer response/model bounds SHALL remain authoritative. Validated logprobs SHALL remain defensively copied opaque turn-state content, SHALL round-trip and replay with that item, and SHALL NOT be projected into normalized text, agent events, snapshots, hooks, errors, logs, or diagnostics. Unknown output-text or logprob fields and malformed values SHALL remain protocol errors without loosening unrelated closed schemas.

#### Scenario: OpenAI text response is streamed
- **WHEN** a reasoning-capable curated OpenAI model streams reasoning and output text through the Responses API
- **THEN** the adapter emits normalized reasoning and answer deltas followed by exactly one completed terminal with reported usage

#### Scenario: OpenAI requests a function tool
- **WHEN** the Responses stream produces a function call whose arguments arrive incrementally
- **THEN** the adapter emits stable ordered tool-call fragments, retains complete reasoning/message/function-call output items including ids, status, phase, call correlation, summaries, encrypted reasoning, and validated standard output-text logprobs, and the runtime can correlate a later function-call output without synthesizing provider reasoning

#### Scenario: Standard empty output-text logprobs are received
- **WHEN** a realistic completed Responses message contains an `output_text` part with `logprobs: []`
- **THEN** the output item is accepted, normalized text remains unchanged, and the empty list remains in the defensively copied opaque turn-state payload

#### Scenario: Populated output-text logprobs are valid
- **WHEN** output-text logprobs contain only bounded standard token, finite logprob, byte, and top-logprob values
- **THEN** they survive turn-state JSON round-trip and stateless replay without appearing in normalized or agent-visible projections

#### Scenario: Output-text logprobs are malformed
- **WHEN** logprobs are not a list, contain a non-object/unknown field, non-string token, non-finite/non-numeric probability, out-of-range byte, or malformed top-logprob entry
- **THEN** turn-state validation fails with a typed sanitized protocol error while unrelated closed-schema validation remains unchanged

#### Scenario: Stateless tool continuation is replayed
- **WHEN** a completed reasoning-capable Responses turn requests a function and the runtime supplies its result in a continuation request
- **THEN** the request replays the prior validated output-item array exactly once at its transcript position, appends the correlated `function_call_output`, keeps `store: false`, and does not send `previous_response_id` or a summary-only reasoning item

#### Scenario: Stateless reasoning state is unavailable
- **WHEN** a Responses turn produced with enabled/required reasoning has a function call but lacks complete non-empty encrypted reasoning state, regardless of visible summary output, or has unsupported/malformed output items
- **THEN** the turn fails with a typed sanitized protocol error before executing the function or dispatching a continuation

#### Scenario: Text-only fallback lacks opaque reasoning
- **WHEN** a completed Responses turn has no function call but its reasoning item cannot be replayed statelessly
- **THEN** normalized visible assistant text may remain in history, prior reasoning summary is omitted from future Responses input, and no synthetic `reasoning` item is created

#### Scenario: Opaque continuation is persisted
- **WHEN** a repository-backed session checkpoints a completed Responses turn
- **THEN** its origin-bound output-item state including validated logprobs round-trips with the session record and is available after restore, while agent events, snapshots, hooks, mailbox values, errors, and diagnostics expose none of its encrypted payload, provider item ids, or logprobs

#### Scenario: Responses stream is malformed or fails
- **WHEN** OpenAI returns an HTTP, protocol, refusal, or stream-terminal failure
- **THEN** the adapter preserves prior normalized deltas where valid and terminates once with a typed sanitized result without exposing raw response bodies or authorization data
