# OpenAI-Compatible Provider Configuration Specification

## Purpose

Defines reusable and credential-safe configuration for direct OpenAI-compatible Chat Completions providers, including local unauthenticated endpoints and paid remote models.

## Requirements

### Requirement: Editable provider profiles
The application SHALL represent each comparison model with an editable profile containing a stable lane id, display label, comparison tier, Chat Completions endpoint, model id, authentication mode, provider/model source link, and optional pricing metadata.

#### Scenario: Day 5 defaults are loaded
- **WHEN** no Day 5 profile settings have been saved
- **THEN** the three profiles are local Ollama `qwen3.5:2b` at `http://localhost:11434/v1/chat/completions`, DeepSeek `deepseek-v4-flash`, and DeepSeek `deepseek-v4-pro` at `https://api.deepseek.com/chat/completions`

#### Scenario: Profile is edited
- **WHEN** the user saves valid endpoint, model, authentication, link, or pricing changes
- **THEN** later Day 5 runs use the saved profile while the other profiles remain unchanged

#### Scenario: Defaults are restored
- **WHEN** the user explicitly resets Day 5 profiles
- **THEN** the three documented presets are restored without revealing or deleting saved credentials

### Requirement: Safe endpoint and metadata validation
The application SHALL reject a profile before execution unless its endpoint is an absolute HTTP(S) URI without embedded credentials, query, or fragment, its model id and label are non-empty, and every supplied source link and price is valid.

#### Scenario: Authenticated transport is insecure
- **WHEN** a bearer-authenticated profile uses plain HTTP
- **THEN** the profile is rejected before a credential or provider request is sent

#### Scenario: Local unauthenticated transport is configured
- **WHEN** an unauthenticated HTTP profile targets a loopback host
- **THEN** the profile is accepted for local OpenAI-compatible execution

#### Scenario: Non-loopback plain HTTP is configured
- **WHEN** an HTTP profile targets a non-loopback host
- **THEN** the profile is rejected and the UI explains that HTTPS is required outside the local machine

### Requirement: Optional bearer credential resolution
For a bearer-authenticated profile, the application SHALL resolve a profile-scoped saved override first and its configured environment variable second; an explicitly unauthenticated profile SHALL execute without an Authorization header.

#### Scenario: Saved override and environment key both exist
- **WHEN** a bearer profile has both credential sources
- **THEN** the saved application override is used and the UI identifies only that source

#### Scenario: Only environment key exists
- **WHEN** no saved override exists and the configured environment variable is non-empty
- **THEN** the environment key is used and the UI identifies the variable name without its value

#### Scenario: Bearer key is unavailable
- **WHEN** neither credential source contains a key for a bearer profile
- **THEN** that lane fails locally with an actionable sanitized error and no HTTP request begins

#### Scenario: Authentication is disabled
- **WHEN** an unauthenticated profile runs
- **THEN** no key is required and no Authorization header is emitted

### Requirement: Direct generic Chat Completions execution
Configured profiles SHALL execute through direct streamed OpenAI-compatible `/chat/completions` HTTP and SHALL normalize answer deltas, completion metadata, usage, failures, and arbitrary network chunk boundaries without an SDK or agent framework.

#### Scenario: Generic profile request is built
- **WHEN** a valid custom profile runs
- **THEN** the request contains its model id, one current user message, streaming enabled, and usage-streaming options without DeepSeek-only fields

#### Scenario: DeepSeek preset request is built
- **WHEN** a DeepSeek Day 5 preset runs
- **THEN** the request additionally sets `thinking.type` to `disabled` and omits `reasoning_effort`, conversation history, and response controls

#### Scenario: Endpoint rejects usage streaming options
- **WHEN** a custom profile cannot provide token usage in its stream
- **THEN** its answer can still complete and missing usage-dependent evidence is shown as unavailable rather than fabricated

### Requirement: Profile and credential persistence
The application SHALL persist non-secret Day 5 profile data and profile-scoped key overrides separately, SHALL store overrides using secure platform storage, and SHALL never display, log, export, or commit credential contents.

#### Scenario: Settings reopen
- **WHEN** saved profile settings are loaded later
- **THEN** endpoint, model, labels, links, and pricing are restored while key inputs remain blank and only credential sources are described

#### Scenario: Saved key is removed
- **WHEN** the user removes a profile-scoped override
- **THEN** the next resolution falls back to the configured environment variable or reports the key missing

### Requirement: Auditable pricing and source metadata
Pricing metadata SHALL identify its currency, per-million input/output rates, optional cache-hit rate, effective date, and authoritative source link, and SHALL be snapshotted with a comparison run.

#### Scenario: Pricing is omitted
- **WHEN** a profile has no provider-billing rates
- **THEN** the application labels provider cost as unavailable or zero only when the profile explicitly declares no provider fee

#### Scenario: Pricing is stale or user-edited
- **WHEN** pricing metadata is displayed
- **THEN** its effective date and source link remain visible so the estimate is not presented as a live billing statement
