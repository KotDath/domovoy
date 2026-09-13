## Purpose

Defines how Domovoy obtains, validates, refreshes, and presents selectable API-key provider models while preserving safe dispatch and durable historical model identity.

## ADDED Requirements

### Requirement: Refreshable API-key model catalog
The system SHALL offer a built-in set of hosted API-key providers aligned with the maintained Pi model catalog. It SHALL refresh model metadata from a versioned Pi-compatible catalog source when network access is available, and SHALL query each provider's authenticated model-list endpoint when that provider exposes a documented compatible listing API. Provider listing SHALL determine currently offered model identifiers; the maintained catalog SHALL enrich known models with capabilities, reasoning controls, and bounds. A newly server-listed text-chat model without Pi metadata SHALL remain selectable through its provider's verified chat protocol using a conservative text-only, no-tools, model-default reasoning profile with no explicit effort and explicitly unknown bounds; it SHALL NOT claim an invented context or output limit. Non-chat modalities SHALL not appear as selectable chat models. A provider with no usable listing endpoint SHALL use the maintained catalog's explicit model entries and SHALL identify that source in status. Refresh SHALL be available at application start and by explicit user action without requiring restart.

#### Scenario: Provider returns a new supported model
- **WHEN** a provider list contains a new model whose complete compatible metadata is present in the refreshed maintained catalog
- **THEN** the model appears under that provider with its exact provider/model identity and validated capabilities after refresh

#### Scenario: Provider has no model-list API
- **WHEN** a supported provider has no documented compatible listing endpoint
- **THEN** its selectable models come from the maintained catalog, and the UI identifies the catalog source and refresh time

#### Scenario: Provider list includes a newly released chat model
- **WHEN** an authenticated chat-model list contains an identifier absent from the Pi metadata but the provider's existing chat protocol is verified
- **THEN** the model is selectable for a conservative text-only request, its reasoning/tools and bounds are shown as unknown or unavailable, and no invented limit is used to block dispatch

#### Scenario: Provider list includes a non-chat model
- **WHEN** provider listing metadata identifies an embedding, image, audio, or other non-chat model
- **THEN** that model is excluded from the chat selector and is not sent to the chat endpoint

### Requirement: Safe, resilient catalog refresh
The system SHALL validate catalog source identity, schema, model identifiers, provider identity, endpoint constraints, capability fields, and bounds before publishing an immutable catalog generation. Remote model metadata SHALL NOT change credential destinations or provider transport endpoints. A failed, malformed, unauthenticated, timed-out, or cancelled refresh SHALL preserve a last-known-good catalog generation; if none is stored, a bundled validated fallback SHALL remain available. Refresh SHALL expose source, freshness, partial failure, and a retry action without revealing keys, request headers, raw response bodies, or untrusted error text. Concurrent refreshes SHALL not publish out of order or interrupt a running request's frozen selection.

#### Scenario: Remote catalog is unavailable
- **WHEN** network access fails during refresh after a valid catalog was previously published
- **THEN** the previous catalog stays selectable, its stale status is visible, and the user can retry

#### Scenario: One provider rejects its key
- **WHEN** a model-list request returns an authentication failure for one provider
- **THEN** that provider shows a sanitized credential/discovery status, other provider groups remain usable, and no key value enters catalog state

#### Scenario: Refresh races with a live run
- **WHEN** a newer catalog generation is published while a model invocation is active
- **THEN** that invocation retains its admitted provider, model, protocol, and generation metadata; later selections use the new generation

### Requirement: Historical selection and unavailable-model recovery
The system SHALL preserve exact provider/model references in persisted sessions and per-attempt usage even when a refreshed catalog no longer lists them. A restored unavailable selection SHALL be shown with its original identifier and an actionable replacement choice. The application SHALL NOT auto-replace, rewrite, or dispatch it as a different model. A user-selected supported replacement SHALL affect future turns only under the existing idle model-switch rules.

#### Scenario: Previously selected model disappears
- **WHEN** a session saved with a model absent from the current validated catalog is restored
- **THEN** its transcript and historical attribution remain readable, the model is marked unavailable, and sending waits for an explicit valid replacement

#### Scenario: Current DeepSeek default is refreshed
- **WHEN** the configured DeepSeek key lists `deepseek-flash` and `deepseek-v4-pro` but not the former `deepseek-v4-flash`
- **THEN** a new session selects a currently listed compatible default, while an old session retaining `deepseek-v4-flash` follows the unavailable-selection recovery flow
