## Purpose

Defines the provider-neutral Dart contract through which agent runtimes select registered provider/model pairs, describe model context, resolve provider-scoped credentials, and consume normalized streaming output without depending on one vendor's payloads.

## ADDED Requirements

### Requirement: Portable model request values
The system SHALL represent provider and model identifiers, wire-family identity, model-specific `unsupported | optional | required` reasoning capability, a closed provider-neutral reasoning effort of `modelDefault | low | medium | high | max`, system prompt, ordered messages, generation settings, declared tools, message content parts, and message-indexed provider continuation entries as immutable provider-neutral values. `modelDefault` SHALL delegate to typed model/profile metadata rather than become a wire string. Supported message content SHALL include text, reasoning summaries, tool calls, and tool results with stable call identifiers. A continuation entry SHALL contain exact origin model/wire identity, a closed versioned format identifier, and defensively copied JSON payload; it SHALL correlate to one assistant message and SHALL NOT be accepted in agent-definition seed messages. These values SHALL validate required identifiers, role/content combinations, capability/mode/effort compatibility, continuation origin/format/correlation, and normalized-content consistency before network execution and SHALL support JSON-compatible session serialization without credentials or executable callbacks.

#### Scenario: Mixed context is prepared
- **WHEN** a caller constructs a request containing prior user text, assistant text, an assistant tool call, and the corresponding tool result
- **THEN** the request preserves message and content-part order, call correlation, selected provider/model, system prompt, tool declarations, and generation settings without a provider response type

#### Scenario: Portable value is serialized
- **WHEN** model metadata, messages, content parts, continuation entries, usage, errors, or a request snapshot are converted to JSON and restored
- **THEN** all public non-secret fields, confidential replay payload, and stable type discriminators round-trip without adding credentials or runtime objects

#### Scenario: Invalid request value is rejected
- **WHEN** an identifier is blank, a tool result lacks a call identifier, or a message contains parts forbidden for its role
- **THEN** validation rejects the value before a provider transport starts

#### Scenario: Reasoning effort round-trips
- **WHEN** a generation config with enabled reasoning and a canonical explicit effort is serialized and restored
- **THEN** its mode and effort round-trip without provider field names or vendor-specific string values

#### Scenario: Earlier generation JSON has no effort
- **WHEN** a valid generation-config payload containing the existing enabled/disabled mode has no reasoning-effort field
- **THEN** it decodes as `modelDefault`, preserving the prior mode and its model/profile-defined effective behavior

#### Scenario: Mode and effort conflict
- **WHEN** disabled reasoning carries an explicit effort, required reasoning is disabled, unsupported reasoning is enabled, or an enabled explicit effort is absent from the selected model's declared canonical set
- **THEN** validation rejects the request before credential resolution or transport dispatch

#### Scenario: Continuation state does not match the request
- **WHEN** continuation metadata has an unknown format, points to a non-assistant message, duplicates an index, conflicts with normalized content, or names another provider, model, or wire family
- **THEN** validation fails locally and no opaque payload is sent to either provider

### Requirement: Provider registry, profiles, and curated model catalog
The system SHALL keep wire adapters, provider profiles, and model catalog entries as separate concepts. A provider profile SHALL identify its provider, wire family, endpoint, credential reference, and compatibility behavior without containing an effective secret. The runtime registry SHALL resolve an exact registered provider/model pair and SHALL reject an absent pair or a model whose declared wire family is unsupported before transport dispatch. The built-in catalog for this change SHALL be finite and curated rather than a generated copy of Pi's full catalog.

#### Scenario: Registered provider and model are selected
- **WHEN** an agent definition selects a model present in its registered provider's catalog
- **THEN** the registry dispatches through the wire adapter declared by that model and profile

#### Scenario: Model is registered under another provider
- **WHEN** a definition selects a provider/model pair but the model exists only under a different provider identifier
- **THEN** resolution fails with a typed configuration error before credential resolution or network dispatch

#### Scenario: Caller defines a compatible endpoint
- **WHEN** a caller registers a valid custom OpenAI-compatible Chat Completions profile, provider-scoped credential reference, and explicit model entries
- **THEN** those models are selectable through the common registry without adding vendor payload fields to an agent definition

#### Scenario: Catalog is queried
- **WHEN** a caller queries the built-in model catalog delivered by this change
- **THEN** it contains only the declared DeepSeek, Moonshot AI/Kimi, and OpenAI entries with validated capabilities and wire-family metadata and does not claim dynamic discovery or Pi catalog parity

### Requirement: Provider-scoped credentials
Credential overrides and environment fallbacks SHALL be resolved by provider identifier immediately before dispatch. Each built-in profile SHALL declare its accepted environment source, stored overrides SHALL be isolated by provider, and an explicit stored override SHALL take precedence over that provider's environment value. Effective keys and authorization headers SHALL NOT appear in model metadata, definitions, requests, session records, events, errors, logs, or serialization. The existing DeepSeek secure override SHALL remain readable after migration to provider-scoped storage.

#### Scenario: Two providers have stored credentials
- **WHEN** secure overrides exist for both DeepSeek and OpenAI
- **THEN** a request for either provider receives only that provider's credential

#### Scenario: Stored credential is absent
- **WHEN** a built-in provider has no stored override but its declared environment variable contains a non-empty key
- **THEN** dispatch uses that environment key without exposing it to provider-neutral values

#### Scenario: Legacy DeepSeek override exists
- **WHEN** the pre-change DeepSeek secure-storage key contains a valid override and no provider-scoped DeepSeek override exists
- **THEN** DeepSeek credential resolution continues to use the legacy value without requiring the user to re-enter it

#### Scenario: Selected provider has no credential
- **WHEN** neither provider-scoped storage nor the selected profile's environment source supplies a key
- **THEN** dispatch is skipped and the stream emits a typed sanitized configuration failure naming the provider but no secret source value

### Requirement: Normalized provider stream
An LLM provider SHALL accept one validated model request plus cancellation and return a single-subscription ordered stream of typed reasoning deltas, answer-text deltas, incremental tool-call data, usage updates, and exactly one terminal completion or sanitized failure. A successful completion MAY carry one origin-bound `LlmProviderTurnState` for replay, but raw response roots, headers, authorization values, and unscoped vendor payloads SHALL NOT cross this boundary. Opaque continuation payload SHALL NOT be projected into agent/UI events, snapshots, hooks, errors, logs, or diagnostics. An accepted request SHALL report operational failures as typed terminal events rather than uncaught stream errors.

#### Scenario: Provider streams text and a terminal result
- **WHEN** a provider produces reasoning, answer text, usage, and a finish reason
- **THEN** consumers receive normalized events in source order followed by exactly one successful terminal event and no later events

#### Scenario: Provider streams fragmented tool arguments
- **WHEN** one or more tool calls arrive with names and JSON arguments split across provider chunks
- **THEN** the provider stream identifies each call stably and emits ordered fragments that can be assembled without exposing the vendor chunk schema

#### Scenario: Provider operation fails
- **WHEN** credentials, transport, rate limiting, provider processing, or protocol decoding fails before normal completion
- **THEN** the stream retains already emitted deltas, emits exactly one typed sanitized failure, and exposes neither credentials nor raw sensitive response content

### Requirement: Typed usage and completion metadata
The provider contract SHALL represent input, output, total, cache-hit, and cache-miss token counts as independently optional non-negative fields, preserve an explicit unknown finish reason, and distinguish normal stop, output limit, content filter, and tool-call completion when reported by a provider.

#### Scenario: Provider reports partial usage
- **WHEN** a provider reports only a subset of supported token counters
- **THEN** reported counters are preserved and unavailable counters remain unknown rather than being estimated

#### Scenario: Provider reports an unfamiliar finish reason
- **WHEN** the adapter receives a finish reason it does not recognize
- **THEN** completion is preserved with an unknown normalized finish reason rather than treated as a protocol failure

### Requirement: Provider cancellation
The provider boundary SHALL observe cooperative cancellation before request dispatch and during streaming, stop forwarding non-terminal events after cancellation, release the active response subscription, and terminate once with a cancellation result. Cancellation SHALL be idempotent and SHALL NOT be reported as an unknown provider failure. The shared cancellation token SHALL support detachable callback registration: a callback runs at most once if cancellation wins before disposal, registration and disposal are race-safe, and disposal is idempotent and prevents a not-yet-started callback. The existing one-shot cancellation future MAY remain for compatibility, but repeated operations SHALL be able to avoid retaining one future continuation per completed operation.

#### Scenario: Cancellation precedes dispatch
- **WHEN** cancellation is requested before credentials are resolved or transport dispatch begins
- **THEN** no network request is sent and the provider stream terminates as cancelled

#### Scenario: Cancellation interrupts streaming
- **WHEN** cancellation is requested after one or more deltas
- **THEN** the underlying response subscription is released, partial output remains observable, and exactly one cancellation terminal event follows

#### Scenario: A completed operation detaches cancellation observation
- **WHEN** an operation finishes before its token is cancelled and disposes its registration
- **THEN** a later cancellation does not invoke that operation's callback or retain it as a live listener

### Requirement: OpenAI-compatible Chat Completions family
The Chat Completions adapter SHALL translate provider-neutral requests for registered DeepSeek, Moonshot AI/Kimi, and caller-defined compatible profiles, including ordered messages, tool schemas, streaming usage options, optional valid temperature, output-token limit, and model-supported reasoning controls. It SHALL normalize compatible SSE reasoning, answer, tool-call, usage, finish, and error data into the provider contract. Provider-specific request fields and parsing aliases SHALL be selected by typed profile/model compatibility metadata rather than hard-coded by the agent loop.

#### Scenario: Existing one-shot request is translated
- **WHEN** the prompt workspace sends a fresh request using `deepseek-v4-flash` with reasoning enabled and no tools
- **THEN** the adapter sends the current prompt as the sole user message with streaming and usage enabled, DeepSeek thinking enabled, high reasoning effort, and no unspecified sampling controls

#### Scenario: Tool-capable request is translated
- **WHEN** a request contains tool declarations and prior tool-call/result messages
- **THEN** the adapter emits valid OpenAI-compatible tool schemas and correlated messages and normalizes streamed tool calls for the runtime loop

#### Scenario: Moonshot Kimi request is translated
- **WHEN** the selected model is a curated Moonshot AI Kimi model
- **THEN** the adapter uses the Moonshot profile endpoint and credential while applying only the reasoning and compatibility fields declared for that model

#### Scenario: DeepSeek reasoning effort is selected
- **WHEN** enabled DeepSeek V4 reasoning uses canonical low, medium, high, max, or model-default effort
- **THEN** the dialect maps them respectively to provider low, high, high, max, or high while retaining the thinking-enabled control; disabled reasoning emits only the disabled control

#### Scenario: Kimi reasoning effort is selected
- **WHEN** a caller selects reasoning effort for a curated Kimi model
- **THEN** Kimi K3 accepts low/high/max and defaults to the profile's backwards-compatible high, while K2.6 and K2.7 Code reject every explicit effort and K3 rejects medium before dispatch

#### Scenario: Custom endpoint emits compatible chunks
- **WHEN** a custom profile returns valid Chat Completions SSE chunks with text, tool calls, usage, and a terminal marker
- **THEN** the adapter produces the same normalized event grammar as a built-in profile

### Requirement: OpenAI Responses family
The OpenAI Responses adapter SHALL translate provider-neutral requests for the registered OpenAI profile into the Responses API, including instructions and ordered conversation items, function tools and correlated function-call outputs, optional valid temperature where supported, output-token limits, model-valid reasoning controls, streaming usage, and cancellation. Every request SHALL use `store: false` and omit `previous_response_id`; every reasoning-capable request SHALL request `reasoning.encrypted_content`. It SHALL normalize Responses SSE output text, reasoning, function-call arguments, usage, completion, refusal, and sanitized error events into the common provider grammar. It SHALL also collect complete supported `response.output_item.done` items in provider order and return them as `openai.responses.output_items.v1` turn state only after successful completion; potentially incomplete `output_item.added` reasoning content SHALL NOT be retained for replay.

#### Scenario: OpenAI text response is streamed
- **WHEN** a reasoning-capable curated OpenAI model streams reasoning and output text through the Responses API
- **THEN** the adapter emits normalized reasoning and answer deltas followed by exactly one completed terminal with reported usage

#### Scenario: OpenAI requests a function tool
- **WHEN** the Responses stream produces a function call whose arguments arrive incrementally
- **THEN** the adapter emits stable ordered tool-call fragments, retains complete reasoning/message/function-call output items including ids, status, phase, call correlation, summaries, and encrypted reasoning, and the runtime can correlate a later function-call output without synthesizing provider reasoning

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
- **THEN** its origin-bound output-item state round-trips with the session record and is available after restore, while agent events, snapshots, hooks, mailbox values, errors, and diagnostics expose none of its encrypted payload or provider item ids

#### Scenario: Responses stream is malformed or fails
- **WHEN** OpenAI returns an HTTP, protocol, refusal, or stream-terminal failure
- **THEN** the adapter preserves prior normalized deltas where valid and terminates once with a typed sanitized result without exposing raw response bodies or authorization data

### Requirement: Curated initial provider and model set
The built-in production profiles in this change SHALL be DeepSeek over Chat Completions, Moonshot AI global over Chat Completions, and OpenAI over Responses. The built-in catalog SHALL contain DeepSeek `deepseek-v4-flash` and `deepseek-v4-pro`; Moonshot AI `kimi-k2.6`, `kimi-k2.7-code`, and `kimi-k3`; and OpenAI `gpt-4o-mini`, `gpt-5-mini`, and `gpt-5.4`. Catalog metadata SHALL identify model name, provider, wire family, supported input/tools, `unsupported | optional | required` reasoning capability, selectable canonical efforts, context bound, and output bound. `gpt-4o-mini` SHALL be non-reasoning and accept only disabled mode; `gpt-5-mini` SHALL require enabled reasoning and accept low/medium/high; `gpt-5.4` SHALL support enabled low/medium/high/max, map canonical max to provider `xhigh`, and map disabled mode to provider effort `none`. Pricing, automatic catalog refresh, China-region profiles, OAuth providers, and undeclared models SHALL NOT be implied.

#### Scenario: Initial catalog is enumerated
- **WHEN** the built-in registry is composed
- **THEN** it exposes exactly the three built-in profiles and eight declared model entries through provider-neutral metadata

#### Scenario: Undeclared provider model is requested
- **WHEN** a caller requests an otherwise real provider model that is not in the curated catalog and has not been explicitly registered through a custom profile
- **THEN** resolution fails locally instead of guessing capabilities or silently sending the request

#### Scenario: Non-reasoning OpenAI model is selected
- **WHEN** `gpt-4o-mini` is requested with disabled reasoning
- **THEN** request validation succeeds and the Responses body contains no `reasoning` field; enabled reasoning is rejected before dispatch

#### Scenario: Required and optional OpenAI reasoning are selected
- **WHEN** `gpt-5-mini` is requested with disabled/max reasoning or `gpt-5.4` is requested with either mode and a valid canonical effort
- **THEN** `gpt-5-mini` disabled/max is rejected locally; its low/medium/high map exactly; and `gpt-5.4` low/medium/high map exactly, canonical max maps to `xhigh`, model-default enabled maps to backwards-compatible high, and disabled maps explicitly to `none`
