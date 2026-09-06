## Context

See `proposal.md` for motivation and the three delta specs for observable behavior. Domovoy currently constructs one `OpenAiCompatibleChatAgent` around a fixed DeepSeek profile and a DeepSeek-specific required-key resolver. The stream normalizer already handles arbitrary SSE chunking, answer/reasoning deltas, finish reasons, and basic usage, while Days 3–4 provide the sequential-controller and comparison-card patterns.

Official sources checked 2026-09-07:

- DeepSeek lists `deepseek-v4-flash` and `deepseek-v4-pro` on the same OpenAI-compatible base URL and publishes current per-token pricing: https://api-docs.deepseek.com/quick_start/pricing
- DeepSeek's model-list example returns both model ids: https://api-docs.deepseek.com/api/list-models/
- Ollama documents streamed `/v1/chat/completions`, `stream_options.include_usage`, optional reasoning control, and ignored authentication for local use: https://docs.ollama.com/api/openai-compatibility
- The installed weak preset `qwen3.5:2b` is documented as a 2B family member with a 2.7 GB default artifact and 256K context: https://ollama.com/library/qwen3.5/tags

The target demonstration platform is Linux desktop. Existing Flutter targets must continue compiling, but live Ollama execution is Linux-only and optional outside the Day 5 demo environment.

## Goals / Non-Goals

**Goals:**

- Make provider identity, authentication, request dialect, pricing, and source evidence explicit immutable inputs to a run.
- Compare one already-installed local model against current DeepSeek Flash and Pro ids without introducing an SDK or server component.
- Separate raw measurements, deterministic text evidence, and human quality judgments.
- Keep all secrets out of profile JSON, UI values, test logs, and repository content.

**Non-Goals:**

- Automatically download/start Ollama, benchmark GPU/CPU/RAM/energy, fetch live prices, or guarantee statistical significance from one run.
- Automatically compile arbitrary model-generated Dart code or execute it on the user's machine.
- Use an LLM judge, infer missing token counts, compare conversation memory, or add Responses API support.
- Replace the existing shared DeepSeek configuration used by Days 1–4.

## Decisions

### 1. Introduce immutable profile snapshots and a per-run agent factory

Add a `ChatModelProfile` value containing stable id, label, tier, endpoint URI, model id, dialect, authentication policy, source URL, resource note, and optional token pricing. The Day 5 controller receives an `AgentFactory` and creates an agent from each validated snapshot while sharing the application's single HTTP client.

Three preset snapshots are ordered weak/medium/strong:

1. Ollama `qwen3.5:2b`, `http://localhost:11434/v1/chat/completions`, no bearer key, source metadata `2B / 2.7 GB`.
2. DeepSeek `deepseek-v4-flash`, `https://api.deepseek.com/chat/completions`, shared DeepSeek credential.
3. DeepSeek `deepseek-v4-pro`, the same endpoint and credential scope.

Tier is a UI label, not a semantic assertion. Profiles remain editable so another OpenAI-compatible service or model can replace any preset.

Passing three prebuilt `Agent` instances was rejected because settings changes could silently diverge from displayed metadata. Mutating the production agent was rejected because Days 1–4 need stable behavior.

### 2. Make request dialect explicit and keep generic requests portable

Use a small dialect enum:

- `generic`: standard model/messages/stream/stream-options only;
- `ollama`: standard fields plus `reasoning_effort: none` for the installed thinking-capable preset;
- `deepSeek`: standard fields plus `thinking.type: disabled` and no `reasoning_effort`.

All Day 5 inputs set provider-neutral thinking disabled and have no response-control or temperature override. The profile generates only its dialect's fields. The existing DeepSeek factory retains its current thinking-enabled default for Days 1–4.

Arbitrary user-authored JSON extensions were rejected because they are hard to validate, can alter the experiment, and could accidentally persist sensitive values. Treating every compatible endpoint as DeepSeek was rejected because generic servers may reject `thinking`.

### 3. Generalize credentials without weakening existing precedence

Define authentication as `none`, `sharedDeepSeek`, or `profileBearer`:

- `none` never resolves a key and emits no Authorization header;
- `sharedDeepSeek` reuses the current secure application override before `DEEPSEEK_API_KEY`;
- `profileBearer` reads a secure override under the stable profile id before the configured environment variable.

The settings dialog never pre-populates a key. It exposes only source status and explicit save/remove actions. Profile ids and environment-variable names are validated before they become storage lookup keys. The generic agent accepts an optional credential resolver and provider label so failures do not falsely name DeepSeek.

A dummy Ollama bearer token was rejected even though some clients require one: direct HTTP does not need it, and omitting the header is clearer evidence. Putting keys inside serialized profile objects was rejected as an avoidable leak.

### 4. Validate transport before resolving credentials

Accept only absolute HTTP(S) endpoints with a host and without URI user-info, query, or fragment. HTTPS is required for all bearer-authenticated profiles. Plain HTTP is allowed only for unauthenticated loopback hosts (`localhost`, `127.0.0.0/8`, and `::1`). Model ids, labels, source URLs, environment variable names, finite non-negative pricing, and stable ids receive domain validation before persistence or execution.

This ordering ensures an invalid insecure endpoint cannot cause a secret lookup or request. Supporting authenticated arbitrary LAN HTTP was rejected because it sends bearer credentials in clear text.

### 5. Persist settings and keys separately using existing platform storage

Add a versioned JSON document for non-secret comparison profiles and a scoped secure-key store backed by the existing `FlutterSecureStorage` instance. DeepSeek presets point at the existing DeepSeek override rather than duplicating it. Saving is serialized by a controller; the dialog cannot dismiss while writes are active. Invalid/corrupt persisted JSON falls back to presets with a sanitized warning instead of partially constructing a profile.

Adding SharedPreferences was rejected because secure storage already exists and avoids a new dependency. Storing results long-term is out of scope; only profile configuration persists.

### 6. Extend usage losslessly and preserve unavailable values

Extend `AgentTokenUsage` source-compatibly with optional cache-hit and cache-miss prompt-token fields, and parse DeepSeek's reported cache counters when present. Existing prompt/completion/total fields remain unchanged. Ollama or custom endpoints may omit some or all usage; no character-to-token approximation is introduced.

This avoids comparing provider tokenizers using an application estimate and enables pricing that reflects cache status when available.

### 7. Use a monotonic timing abstraction with strict terminal guards

Each lane starts an injected elapsed timer immediately before invoking the agent. The first non-empty answer delta freezes TTFT; the first completed, failed, thrown, or silently-ended terminal condition freezes total duration. A lane-local terminal flag plus controller generation id ignores every later event, matching the hardened Day 4 pattern. Requests run sequentially in visible lane order.

`DateTime.now()` was rejected because wall-clock adjustments can corrupt durations. Parallel execution was rejected because it introduces avoidable local and network contention and obscures video progress. The UI explicitly discloses that order, cold starts, network, and caches still make a single run non-scientific.

### 8. Calculate cost from frozen pricing with honest bounds

`TokenPricing` stores currency, cache-hit input, cache-miss input, output price per million tokens, effective date, and source URL. The 2026-09-07 presets use the current official USD table:

- Flash: cache-hit input `$0.0028`, cache-miss input `$0.14`, output `$0.28` per 1M tokens.
- Pro: cache-hit input `$0.003625`, cache-miss input `$0.435`, output `$0.87` per 1M tokens.

When cache counters are present, calculate their matching input costs plus completion cost. When only aggregate prompt tokens exist and hit/miss rates differ, show an all-hit to all-miss range. Missing usage/rates stays unavailable. Ollama explicitly declares zero provider billing while displaying that hardware and energy remain unmeasured. Every result keeps the pricing snapshot, date, currency, and link used.

Fetching or scraping current pricing at runtime was rejected because it adds fragility and makes a recorded result irreproducible. Showing a single cache-miss number as exact was rejected because it can overstate actual billing.

### 9. Use one code prompt, objective heuristics, and human quality ratings

The built-in prompt asks in Russian for a sufficiently complete Dart ECS based on sparse sets, including structure/invariants and create/remove/add/get/query operations, complexity, and swap-remove behavior. It remains editable and is frozen for all lanes.

For each completed answer, deterministic case-insensitive text checks report visible evidence for Dart code fences, sparse/dense mapping, swap-remove, O(1) complexity, component storage, and querying. They are labeled structural/lexical heuristics and never become a quality score. Terminal cards enable optional 1–5 correctness, completeness, and practical-usefulness ratings plus a note. The summary may identify the measured fastest lane but never invents a quality winner. An editable conclusion field lets the user record the assignment's short conclusion.

Executing generated code was rejected for safety. Automatic semantic scoring and keyword-derived winners were rejected as misleading.

### 10. Add a fifth persistent responsive laboratory

Keep all five pages in the existing `IndexedStack` and add compact navigation labels. Day 5 contains a profile-settings action, same-prompt input, run disclosure/progress, three streamed cards, timing/token/cost/resource/link evidence, checklist/ratings, and a final conclusion. Wide Linux windows use three columns; narrower layouts stack cards within one scroll view.

Profile editing is separated into a dialog so the primary recorded screen remains readable. Saved settings refresh when Day 5 becomes active without clearing prior run results unless the user starts a new comparison.

### 11. Test portable HTTP behavior and opt-in real providers

Unit tests cover profile validation, serialization, credential precedence, pricing bounds, timing, token parsing, quality heuristics, failure continuation, cancellation, and stale events. Widget tests cover settings, secret-safe fields, navigation retention, three lanes, measurement display, ratings/conclusion reset, links, and responsive layouts.

A loopback fake SSE server verifies custom unauthenticated OpenAI-compatible execution without external dependencies. Separate opt-in Linux smokes cover installed Ollama `qwen3.5:2b` and the two DeepSeek model ids. They assert non-empty answers and aggregate metadata only. The DeepSeek key is injected at process runtime; no smoke prints prompts, response bodies, request headers, or secrets.

## Risks / Trade-offs

- **A single sequential run favors whichever model is warm or sees better network conditions** → Show order and cold-start/cache limitations, preserve exact measurements, and avoid general speed claims.
- **The local model may expose reasoning differently or ignore a control** → Use Ollama's documented standard reasoning control, display answer content only, and keep the dialect editable.
- **Provider pricing changes after the preset date** → Freeze rates with date/link, allow editing, and label every result an estimate rather than billing truth.
- **Some compatible servers omit usage or reject `stream_options`** → Keep successful answer streaming independent from optional usage evidence and show unavailable values honestly.
- **Custom endpoints expand the trust boundary** → Validate transport before credential resolution, prohibit embedded credentials, and warn that configured providers receive the prompt.
- **Generated code can look plausible while being wrong** → Never execute it automatically, use manual quality ratings, and label checklist matching as non-semantic.
- **Five navigation destinations can become crowded** → Keep labels compact and rely on full page titles/tooltips for context.

## Migration Plan

1. Generalize profile, credential, and generic-agent boundaries with compatibility adapters so Days 1–4 and existing tests retain current behavior.
2. Add source-compatible cache usage parsing, immutable profiles/settings persistence, validation, and unit tests.
3. Add Day 5 controller, measurements, pricing, heuristics, and deterministic tests.
4. Add profile settings and the fifth responsive destination with widget coverage.
5. Add fake-server and opt-in Ollama/DeepSeek smokes plus the video/code checklist; run the complete Flutter/Linux verification suite.
6. Verify, sync all delta specs, archive, retain `feature/day-05`, and merge it into `main` locally and remotely.

Rollback removes the Day 5 screen, stores, factory, and optional cache fields; the existing DeepSeek profile and callers continue using their prior defaults.
