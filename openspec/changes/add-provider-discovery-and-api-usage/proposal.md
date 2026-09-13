## Why

Domovoy's production chat offers only a fixed three-provider, eight-model catalog; a stale model identifier already prevents the configured DeepSeek key from reaching a currently listed model. Its token screen also foregrounds an estimated retained-context value and exclusive input/output components where users need the inclusive usage totals returned by the selected provider. Broader API-key provider support and refreshed model discovery make the agent usable without manual catalog edits and make reported token consumption clear.

## What Changes

- Add built-in API-key profiles for mainstream Pi-catalog provider families and their protocol adapters, preserving exact provider/model identity and provider-scoped credentials. Preserve existing DeepSeek, Moonshot AI, and OpenAI sessions and stored keys.
- Build a refreshable model catalog: query a provider's authenticated models endpoint when it has one; enrich discovered IDs with maintained Pi-style model capability metadata and use conservative text-chat metadata with unknown bounds for newly listed chat models; use a versioned maintained catalog for providers without a usable list endpoint. Refresh at startup and on explicit user action, with a safe last-known-good/fallback state and visible freshness/errors.
- Replace the stale DeepSeek Flash default with a presently listed model. Treat a previously saved but unavailable model selection as a recoverable selection issue, never silently rewrite historical attribution or dispatch a different model.
- Let settings manage API keys per provider, show credential availability without revealing values, and let the model picker reflect discovered models and provider status on desktop and narrow layouts.
- Make the visible token summary and details use provider-reported or exactly provider-derived inclusive request, response, and total counts. Show cache-read, cache-write, and reasoning separately when reported, with unknown/partial states; remove estimator values and estimated context-limit progress from the displayed accounting surface. Retain internal estimation where runtime context guards require it.
- Add fixture-backed protocol, discovery, credential, migration, UI, and accounting tests, plus a live DeepSeek key/model-list/request smoke test when a key is available.

## Capabilities

### New Capabilities

- `provider-model-discovery`: Refresh lifecycle, model-source provenance, capability reconciliation, fallback, and selection availability for API-key providers.

### Modified Capabilities

- `llm-provider-core`: Expand built-in protocol/provider coverage beyond the initial curated set and support a refreshable, immutable registry catalog with validated dispatch metadata.
- `llm-credentials`: Manage secure overrides and effective-source status for every built-in API-key provider while retaining DeepSeek's legacy override.
- `chat-workspace-ui`: Expose provider/model refresh and unavailable-selection recovery, provider-specific settings, and provider-only inclusive token accounting.

## Impact

- Core registry/catalog and provider-neutral model metadata; Chat Completions, OpenAI Responses, and native Anthropic/Gemini transport boundaries; production composition and provider credentials; chat workspace model picker/settings/token presentation; related tests and OpenSpec.
- Existing JSONL session records and per-attempt ledger remain readable. Catalog refresh does not rewrite persisted model references. No key, authorization header, raw discovery payload, or opaque continuation content enters UI, session JSON, or logs.
- Provider charges may result from live smoke requests. No pricing/cost display, OAuth account flow, model auto-routing, or UI token estimate is introduced.
- Recommended execution mode: **Heavy**. Risk is **T2** for new provider protocols, secret handling, model-selection persistence, and usage semantics; work spans core, infrastructure, and UI. Verification needs fixture and live provider evidence. The repository's named DeepSeek verifier is not available in the built-in collaboration tool set for this run; coordination must record a transparent alternative rather than claim that check occurred.
