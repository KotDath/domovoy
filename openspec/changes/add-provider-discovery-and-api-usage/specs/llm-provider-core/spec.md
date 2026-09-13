## MODIFIED Requirements

### Requirement: Provider registry, profiles, and curated model catalog
The system SHALL keep wire adapters, provider profiles, and model catalog entries as separate concepts. A provider profile SHALL identify its stable provider identity, wire family, trusted endpoint, credential reference, and compatibility behavior without containing an effective secret. The runtime registry SHALL resolve an exact registered provider/model pair against one immutable validated catalog generation and SHALL reject an absent pair or unsupported wire family before transport dispatch. Newly server-listed chat models without maintained metadata MAY use a conservative provider-protocol fallback with unknown bounds; unknown bounds SHALL not be represented as guessed numeric limits. A refreshed catalog generation SHALL be published atomically and SHALL not mutate an already admitted request or historical model reference.

#### Scenario: Registered provider and model are selected
- **WHEN** an agent definition selects a model present in its registered provider's current validated catalog
- **THEN** the registry dispatches through the wire adapter declared by that model and profile

#### Scenario: Model is registered under another provider
- **WHEN** a definition selects a provider/model pair but the model exists only under a different provider identifier
- **THEN** resolution fails with a typed configuration error before credential resolution or network dispatch

#### Scenario: Caller defines a compatible endpoint
- **WHEN** a caller registers a valid custom OpenAI-compatible Chat Completions profile, provider-scoped credential reference, and explicit model entries
- **THEN** those models are selectable through the common registry without adding vendor payload fields to an agent definition

#### Scenario: Catalog is queried
- **WHEN** a caller queries the built-in model catalog
- **THEN** it receives the currently published validated generation and source/freshness status, including models from successful discovery and the maintained fallback where needed; server-listed chat models lacking rich metadata carry explicit conservative capability/bound status

#### Scenario: Catalog changes during invocation
- **WHEN** a newer generation is published after request admission
- **THEN** the active invocation keeps its exact selected model and adapter, and later requests resolve against the new generation

### Requirement: OpenAI-compatible Chat Completions family
The Chat Completions adapter SHALL translate provider-neutral requests for registered built-in and caller-defined compatible profiles, including ordered messages, tool schemas, streaming usage options, optional valid temperature, output-token limit, and model-supported reasoning controls. It SHALL normalize compatible SSE reasoning, answer, tool-call, usage, finish, and error data into the provider contract. Provider-specific request fields, authentication style, and parsing aliases SHALL be selected by typed profile/model compatibility metadata rather than hard-coded by the agent loop. An API-key provider SHALL be registered on this family only when its documented request and streaming behavior can be mapped without misrepresenting capabilities.

#### Scenario: Existing one-shot request is translated
- **WHEN** the prompt workspace sends a fresh request using a currently listed DeepSeek default with reasoning enabled and no tools
- **THEN** the adapter sends the current prompt as the sole user message with streaming and usage enabled, DeepSeek thinking enabled, high reasoning effort, and no unspecified sampling controls

#### Scenario: Tool-capable request is translated
- **WHEN** a request contains tool declarations and prior tool-call/result messages
- **THEN** the adapter emits valid compatible tool schemas and correlated messages and normalizes streamed tool calls for the runtime loop

#### Scenario: Moonshot Kimi request is translated
- **WHEN** the selected model is a validated Moonshot AI Kimi model
- **THEN** the adapter uses the Moonshot profile endpoint and credential while applying only the reasoning and compatibility fields declared for that model

#### Scenario: DeepSeek reasoning effort is selected
- **WHEN** enabled DeepSeek reasoning uses canonical low, medium, high, max, or model-default effort
- **THEN** the dialect maps them respectively to provider low, high, high, max, or high while retaining the thinking-enabled control; disabled reasoning emits only the disabled control

#### Scenario: Kimi reasoning effort is selected
- **WHEN** a caller selects reasoning effort for a validated Kimi model
- **THEN** the model's declared canonical effort set is enforced before dispatch and only its declared wire values are sent

#### Scenario: Custom endpoint emits compatible chunks
- **WHEN** a custom profile returns valid Chat Completions SSE chunks with text, tool calls, usage, and a terminal marker
- **THEN** the adapter produces the same normalized event grammar as a built-in profile

#### Scenario: Built-in compatible provider differs in optional fields
- **WHEN** a built-in compatible provider rejects a feature its model metadata does not declare
- **THEN** the adapter omits that feature's field rather than send OpenAI-specific options indiscriminately

### Requirement: Curated initial provider and model set
The built-in production set SHALL include API-key profiles for DeepSeek, Moonshot AI, OpenAI, Anthropic, Google Gemini, Groq, Cerebras, xAI, Mistral, OpenRouter, Together AI, Fireworks AI, Perplexity, MiniMax, Z.AI, and Hugging Face when their documented hosted API-key path is supported by a validated adapter. Regional variants SHALL use distinct provider identities and credential/endpoint profiles when present in the maintained Pi catalog. The bundled fallback SHALL contain validated model entries; live provider listing and refreshed maintained metadata SHALL determine the current selectable set under `provider-model-discovery`. Rich metadata SHALL identify model name, provider, wire family, supported input/tools, `unsupported | optional | required` reasoning capability, selectable canonical efforts, context bound, and output bound. A server-listed chat model without rich metadata SHALL use conservative text-chat capabilities with context/output bounds explicitly unknown. Existing OpenAI reasoning mappings SHALL remain valid. OAuth and cloud-account credential flows SHALL not be advertised as API-key profiles; unsupported account-based providers SHALL remain excluded until their distinct authentication contract exists.

#### Scenario: Initial catalog is enumerated
- **WHEN** the built-in registry is composed with no network access or cached generation
- **THEN** it exposes the validated multi-provider fallback with at least one selectable currently supported DeepSeek model and source status rather than the former exact three-provider/eight-model list

#### Scenario: Undeclared provider model is requested
- **WHEN** a caller requests a model neither present in the current server-confirmed chat list nor explicitly available from a maintained source for a listing-free provider
- **THEN** resolution fails locally instead of guessing that the model is offered

#### Scenario: Non-reasoning OpenAI model is selected
- **WHEN** `gpt-4o-mini` is requested with disabled reasoning while it remains in the published catalog
- **THEN** request validation succeeds and the Responses body contains no `reasoning` field; enabled reasoning is rejected before dispatch

#### Scenario: Required and optional OpenAI reasoning are selected
- **WHEN** `gpt-5-mini` or `gpt-5.4` remains listed and is requested with its declared reasoning controls
- **THEN** `gpt-5-mini` disabled/max is rejected locally; its low/medium/high map exactly; and `gpt-5.4` low/medium/high map exactly, canonical max maps to `xhigh`, model-default enabled maps to high, and disabled maps explicitly to `none`

#### Scenario: Provider requires account credentials
- **WHEN** a Pi catalog entry needs OAuth, workload identity, cloud account signing, or another non-API-key flow
- **THEN** it is not presented as a working API-key provider or routed using an unrelated provider's key

### Requirement: UI-safe deterministic catalog enumeration
The provider registry SHALL expose immutable credential-free provider groups from one published catalog generation suitable for selection surfaces. Each group SHALL carry stable provider identity, a non-blank display name supplied by profile/catalog metadata, its selectable models with display names/capabilities, and source/freshness/availability status. Groups and models SHALL preserve explicit provider and catalog order rather than depend on map hash order, feature-local identifiers, or a hard-coded count. Enumeration SHALL expose no provider clients, credential references, effective secrets, untrusted discovery payloads, or compatibility payloads.

#### Scenario: Built-in catalog is enumerated for UI
- **WHEN** a caller requests selectable groups from the built-in registry
- **THEN** it receives the current provider groups and validated models in deterministic order with status and no credential data

#### Scenario: Custom provider is registered
- **WHEN** a conforming custom profile with a display name and models is registered
- **THEN** enumeration includes that provider and its models using supplied metadata without a feature code change or provider-identifier branch

#### Scenario: Enumerated collections escape the registry
- **WHEN** a caller attempts to mutate an obtained provider group or model list
- **THEN** the registry contents and later enumerations remain unchanged

## ADDED Requirements

### Requirement: Native Anthropic and Gemini API-key families
The system SHALL support documented Anthropic Messages and Google Gemini generate-content text streaming over their distinct API-key transports where a model's validated metadata declares compatibility. Each adapter SHALL translate provider-neutral text/history, usage snapshots, finish/error outcomes, and cancellation into the common provider contract. Native tool turns and explicit reasoning controls SHALL remain unavailable until provider-specific continuation signatures and request mappings are verified. Unsupported content or controls SHALL be rejected before dispatch, not silently dropped. Usage normalization SHALL retain provider-reported inclusive parents, cache and reasoning details only where explicitly reported, with unknown fields remaining unknown.

#### Scenario: Anthropic text turn streams
- **WHEN** an Anthropic model emits text followed by input/output/cache/thinking usage
- **THEN** the stream yields ordered text/usage events and one terminal result with exactly the reported provider facts

#### Scenario: Gemini text turn streams
- **WHEN** a Gemini model emits text parts and usage metadata
- **THEN** the adapter returns text and provider-reported request/response/total metrics with documented inclusion semantics

#### Scenario: Unsupported model feature is requested
- **WHEN** a native-family model lacks support for a requested tool or reasoning control
- **THEN** validation fails locally before credential resolution or transport dispatch

### Requirement: Plain provider error message with credential redaction
A failed provider invocation SHALL retain the provider's human-readable API error message for user presentation when available. The displayed message SHALL preserve the error's meaning and original wording except for redaction of credentials, authorization material, and other secrets; raw headers or response objects SHALL not be exposed. Typed error kind and provider/model attribution SHALL remain available independently of the text. If no safe message can be extracted, the system SHALL show a sanitized fallback.

#### Scenario: Provider reports context overflow
- **WHEN** a provider returns a context-limit error containing a safe message and no recovery succeeds
- **THEN** the user sees that provider message in plain text with its provider/model identity and no fabricated token count

#### Scenario: Provider error echoes authorization
- **WHEN** an upstream error message contains an effective API key or authorization header value
- **THEN** those secret substrings are redacted while safe explanation text remains visible
