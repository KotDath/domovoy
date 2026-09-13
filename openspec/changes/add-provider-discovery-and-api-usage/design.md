## Context

See `proposal.md`. Production composition in `lib/app.dart` currently registers three synchronous profiles and eight static models. `LlmProviderRegistry` is mutable at construction but has no atomic catalog replacement. The chat controller snapshots provider groups only when created. Settings are still a DeepSeek-specific dialog, though provider-scoped secure storage and environment resolution already exist. `LlmUsage` and `AgentUsageAggregate` already calculate inclusive request-context, response-generated, and overall values; the token presenter currently chooses exclusive `input`/`output` components and displays the retained-context estimator. The session ledger and JSONL persistence already preserve exact historical model references.

The existing DeepSeek key was tested against its authenticated list endpoint: it currently lists `deepseek-flash` and `deepseek-v4-pro`, not the bundled `deepseek-v4-flash`. A real reasoning-enabled DeepSeek call reported input 40, output 17, total 57, reasoning 15, cache hit 0, cache miss 40; cache and reasoning are children of inclusive parents. A real oversized `deepseek-flash` request returned HTTP 400 with a human-readable context-limit message and generic `invalid_request_error` code, so error classification cannot depend only on a dedicated overflow code.

## Goals / Non-Goals

**Goals:**

- Keep exact provider/model identity and a safe immutable generation from discovery through request admission, UI, and restored sessions.
- Offer API-key hosted providers supported by validated Pi metadata, using the correct transport family and provider-specific optional fields.
- Show actual provider usage and error messages with correct inclusive semantics and credential redaction.
- Keep existing production context management while giving Day 8 a reproducible over-limit diagnostic path.

**Non-Goals:**

- Sending arbitrary remote catalog entries without validated capability and transport metadata; dynamic endpoint or secret-source changes from a catalog feed.
- OAuth, AWS signing, Azure/Vertex account credentials, or other cloud-account authentication disguised as a single API key.
- A tokenizer or any displayed estimate, cost calculation, price source, automatic model routing, or migration of the JSONL storage envelope.

## Decisions

### 1. Use a trusted provider manifest plus validated Pi model metadata

Maintain a small typed manifest for each built-in API-key provider: stable id/name, trusted fixed API origin/path, credential environment name, authentication style, wire family, listing capability, and dialect behavior. Use the machine-readable `models.dev/api.json` feed for refreshed rich model metadata aligned to Pi's provider/model naming, plus a bundled versioned fallback; Pi's generated TypeScript catalog is not executed at runtime. The remote feed may add/update model identifiers and model capability/bound metadata but cannot set endpoint, credential source, or authentication style. Model-list endpoints, where documented, determine current availability. For a provider with no usable listing endpoint, the maintained metadata snapshot itself is the source of the selectable model set. A newly server-listed chat model without rich metadata is selectable through the verified provider chat protocol with conservative text-only/no-tools/model-default reasoning capability and unknown context/output bounds. A listing row explicitly marked non-chat is filtered out. This gives real refresh without fabricating authoritative limits or optional controls.

The initial manifest targets DeepSeek, OpenAI, Anthropic, Google Gemini, Moonshot AI, Groq, Cerebras, xAI, Mistral, OpenRouter, Together AI, Fireworks AI, Perplexity, MiniMax, Z.AI, and Hugging Face, plus Pi-listed API-key regional variants with separately verified endpoints and credentials. A concrete provider is enabled only after its endpoint/auth/listing/streaming fixture is verified; if one entry cannot meet this bar, show it as unsupported research status rather than register a broken selectable profile. Keep OAuth and cloud-account entries out of the API-key set. The provider manifest/fixture matrix is the implementation gate, not an unverified count promise.

Alternative rejected: trust every `/models` response and infer tools, reasoning, or numeric bounds. Listing endpoints provide IDs, not rich capabilities. Alternative rejected: require a Pi entry for every server-listed chat model; it would hide newly released IDs and recreate the stale DeepSeek failure.

### 2. Publish one immutable catalog generation atomically

Introduce a catalog service with `refresh`, `snapshot`, and change notifications. It obtains remote metadata and per-provider availability with bounded requests, cancellation, status, and independent provider failures. It validates all rows, deduplicates exact provider/model keys, preserves a deterministic manifest/model order, then atomically publishes a new generation to registry selection and UI observers. One run holds the resolved model/profile snapshot admitted before transport; a refresh cannot change that request. Successful last-known-good metadata is cached separately from session records without secrets; failure uses the prior generation or bundled fallback and exposes stale/partial/retry status. Production initialization need not await a slow network call to render the workspace.

DeepSeek startup/default selection changes to `deepseek-flash` if verified in the current/fallback generation. An old `deepseek-v4-flash` session remains readable with its exact selected id; sends reject as unavailable until an explicit user selection is acknowledged. Historical ledger attribution is never rewritten. Adapt restore validation so syntax and history are accepted without requiring current catalog membership; dispatch and selection change still validate current membership.

Alternative rejected: mutate registry maps one provider at a time. Intermediate groups could pair a new model with an old dialect or change a running request.

### 3. Extend the existing wire boundary by protocol family

Use the current Chat Completions adapter for providers with documented compatible payloads, driven by typed profile/dialect flags for authentication, system/tool representation, streaming usage request options, and reasoning controls. Keep OpenAI on Responses. Add Anthropic Messages and Gemini generate-content text streaming adapters because their request and stream grammars differ materially. Native tool turns and explicit reasoning controls are not advertised until opaque continuation signatures and model-specific request mappings are verified. Retain unsupported-feature validation before dispatch, cancellation, single terminal result, and secret-free errors. Map each provider's usage parents and children using documented inclusion semantics; unknown counters stay unavailable. Do not claim generic compatibility merely because a provider advertises OpenAI-shaped chat.

For provider error text, extract the human-readable message from documented error envelopes and retain it through the typed failure. Redact the effective key, bearer/header material, and known secret-bearing substrings before logging or presentation. Preserve HTTP status, normalized error kind, and safe provider wording separately. Match DeepSeek's observed context-limit structure as an overflow classification even when `code=invalid_request_error`; generic invalid requests remain distinct.

Alternative rejected: catch all errors and show response bodies. Raw bodies can contain echoed prompts or credentials. Alternative rejected: always replace a provider message with a generic sanitized phrase; that hides the requested overflow evidence.

### 4. Make settings and model selection data-driven

Rework the DeepSeek-only dialog/controller into a selected-provider credential editor backed by the existing namespaced credential store/resolver. The UI lists built-in API-key providers, shows configured source only, and supports save/remove per provider. Preserve the legacy DeepSeek key path and existing web warning. Refresh after a key change updates only the relevant provider's discovery state and never reveals the key in a catalog object. The chat controller subscribes to catalog generations, reprojects model groups, and marks a saved-but-missing selection unavailable without changing session persistence. The existing idle model-switch operation handles explicit replacement. Replace the current flat model menu with a searchable, bounded/virtualized picker so OpenRouter and Hugging Face sized catalogs remain usable; search normalized provider/name/id text and keep keyboard and semantics support.

Alternative rejected: infer configured keys from model-list success alone. Offline or listing-free providers would appear unconfigured despite a valid key.

### 5. Present inclusive provider usage and isolate the Day 8 diagnostic

Switch the existing pure `ChatTokenPresenter` to `LlmUsage.requestContext`, `responseGenerated`, `overall` and the corresponding aggregate dimensions as leading input/output/overall values. Keep exclusive components only under explicit breakdown names, and display optional cache/reasoning as unavailable if absent. Remove retained-context estimate, bound ratio/progress, and any `estimated` label from the visible summary/detail projection; leave `AgentRetainedContextMeasurement` and estimator-driven internal fit/safety policies unchanged. A provider's parent totals have priority over a complete exact child derivation, and aggregate partiality remains explicit.

For the Day 8 learning scenario, provide a separately launched diagnostic entry or tool with short/long/oversize actions against the real configured DeepSeek path. The oversize action generates its payload locally, turns off proactive compaction and the single overflow retry for that diagnostic run, and does not reject on a heuristic preflight estimate. It presents the actual terminal API message and provider counters that exist; unknown failure usage remains unknown. A browser-only smoke harness may route requests through a local loopback proxy that reads the key from the host environment, never embeds it into compiled web assets, and uses the production stack/HTTP contract. Normal chat keeps its existing automatic compaction behavior.

Alternative rejected: simulate overflow using a fake provider or show a predicted number. The user requested the actual API limit error.

## Risks / Trade-offs

- [Remote metadata becomes stale or malformed] → Validate schema/identity/bounds; publish atomically; retain prior generation and visible stale status; maintain bundled fallback.
- [Provider advertises an ID but not its capabilities] → Offer conservative text-only chat through the verified provider protocol, mark bounds unknown, and omit unsupported optional controls.
- [Many hosted providers diverge subtly from Chat Completions] → Provider fixture matrix and typed dialect flags; reject unsupported controls before transport; do not enable unverified profiles.
- [Keys leak through discovery/error text or web bundles] → Provider-scoped resolver at dispatch, secret redaction, no raw response roots in public state, browser proxy for live UI smoke.
- [Refresh invalidates a saved model] → Preserve exact selection/history and block only future sends until explicit replacement.
- [Displayed totals double count cache/reasoning] → Test inclusive parents and child breakdown with observed DeepSeek 40/17/57/15 fixture and malformed/partial variants.
- [Oversize diagnostic incurs a large request or provider charge] → Explicit diagnostic action, bounded generated payload, one provider attempt, no automatic retry; keep it out of normal chat.

## Migration Plan

1. Add manifest, validated catalog source/cache, atomic registry publication, and discovery tests while retaining the current providers as fallback.
2. Add provider protocol adapters and per-provider fixtures; enable only verified hosted API-key profiles. Replace DeepSeek default with listed `deepseek-flash`, preserving old selection references.
3. Make settings and picker consume catalog/credential state; add unavailable-selection and refresh/offline/restart tests.
4. Change token presenter and provider error visibility, add the Day 8 diagnostic and real DeepSeek smoke evidence, then run formatting, analysis, full tests, Linux/web build where supported, and strict OpenSpec validation.

Rollback to an older binary may read the existing session/ledger JSON, but a session whose selected model is new or only remotely discovered cannot be dispatched there. Keep JSONL records and keys unchanged; do not rewrite historical selection on rollback.
