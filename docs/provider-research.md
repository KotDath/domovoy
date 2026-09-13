# Pi providers and Domovoy transport research

Researched 2026-09-13 from the [current Pi source](https://github.com/earendil-works/pi/tree/main/packages/ai/src/providers). The former badlogic/pi-mono repository redirects there. Pi distinguishes provider identity from wire API, model metadata, credentials, and streaming implementation. Several providers share an API; that does not make their optional reasoning fields interchangeable.

## Provider matrix

Base URLs below are research findings, not arbitrary user-supplied destinations. Runtime integration status is tracked separately in Domovoy's provider manifest and tests.

| Pi provider | API / base | API-key environment |
|---|---|---|
| anthropic | Anthropic Messages; `https://api.anthropic.com` | `ANTHROPIC_API_KEY` |
| google | Gemini generate-content; `https://generativelanguage.googleapis.com/v1beta` | `GEMINI_API_KEY` |
| openai | Responses; `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| xai | Responses; `https://api.x.ai/v1` | `XAI_API_KEY` |
| mistral | Mistral Chat Completions; `https://api.mistral.ai/v1` | `MISTRAL_API_KEY` |
| deepseek | Chat Completions; `https://api.deepseek.com` | `DEEPSEEK_API_KEY` |
| ant-ling | Chat Completions; `https://api.ant-ling.com/v1` | `ANT_LING_API_KEY` |
| baseten | Chat Completions; `https://inference.baseten.co/v1` | `BASETEN_API_KEY` |
| cerebras | Chat Completions; `https://api.cerebras.ai/v1` | `CEREBRAS_API_KEY` |
| groq | Chat Completions; `https://api.groq.com/openai/v1` | `GROQ_API_KEY` |
| huggingface | Chat Completions router; `https://router.huggingface.co/v1` | `HF_TOKEN` |
| moonshotai | Chat Completions; `https://api.moonshot.ai/v1` | `MOONSHOT_API_KEY` |
| moonshotai-cn | Chat Completions; `https://api.moonshot.cn/v1` | `MOONSHOT_API_KEY` |
| nvidia | Chat Completions; `https://integrate.api.nvidia.com/v1` | `NVIDIA_API_KEY` |
| together | Chat Completions; `https://api.together.ai/v1` | `TOGETHER_API_KEY` |
| fireworks | Chat Completions and Anthropic model routes; `https://api.fireworks.ai/inference` | `FIREWORKS_API_KEY` |
| openrouter | Chat Completions and Anthropic model routes; `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` |
| minimax | Anthropic Messages; `https://api.minimax.io/anthropic` | `MINIMAX_API_KEY` |
| minimax-cn | Anthropic Messages; `https://api.minimaxi.com/anthropic` | `MINIMAX_CN_API_KEY` |
| kimi-coding | Anthropic Messages; `https://api.kimi.com/coding` | `KIMI_API_KEY` |
| vercel-ai-gateway | Anthropic Messages; `https://ai-gateway.vercel.sh` | `AI_GATEWAY_API_KEY` |
| opencode | Mixed model routes; `https://opencode.ai/zen/v1` | `OPENCODE_API_KEY` |
| opencode-go | Mixed model routes; `https://opencode.ai/zen/go/v1` | `OPENCODE_API_KEY` |
| xiaomi | Chat Completions; `https://api.xiaomimimo.com/v1` | `XIAOMI_API_KEY` |
| xiaomi-token-plan-ams | Chat Completions; `https://token-plan-ams.xiaomimimo.com/v1` | `XIAOMI_TOKEN_PLAN_AMS_API_KEY` |
| xiaomi-token-plan-cn | Chat Completions; `https://token-plan-cn.xiaomimimo.com/v1` | `XIAOMI_TOKEN_PLAN_CN_API_KEY` |
| xiaomi-token-plan-sgp | Chat Completions; `https://token-plan-sgp.xiaomimimo.com/v1` | `XIAOMI_TOKEN_PLAN_SGP_API_KEY` |
| zai | Chat Completions coding plan; `https://api.z.ai/api/coding/paas/v4` | `ZAI_API_KEY` |
| zai-coding-cn | Chat Completions coding plan; `https://open.bigmodel.cn/api/coding/paas/v4` | `ZAI_CODING_CN_API_KEY` |
| qwen-token-plan | Chat Completions; `https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` | `QWEN_TOKEN_PLAN_API_KEY` |
| qwen-token-plan-cn | Chat Completions; `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` | `QWEN_TOKEN_PLAN_CN_API_KEY` |
| qwen-token-plan-individual | Same international Qwen endpoint, different plan catalog | `QWEN_TOKEN_PLAN_API_KEY` |
| google-vertex | Vertex generate-content; project/location-dependent endpoint | API key or ADC plus project/location |
| amazon-bedrock | Bedrock Converse binary event stream; regional AWS endpoint | AWS credentials, profile, or Bedrock bearer token |
| azure-openai-responses | Azure Responses; resource/deployment endpoint | `AZURE_OPENAI_API_KEY` plus resource configuration |
| cloudflare-workers-ai | Account-specific Workers AI endpoint | `CLOUDFLARE_API_KEY` + account ID |
| cloudflare-ai-gateway | Account/gateway-specific routing | `CLOUDFLARE_API_KEY` + account/gateway IDs |
| github-copilot | Subscription/token exchange, mixed routes | Copilot token / OAuth |
| openai-codex | ChatGPT Codex Responses; `https://chatgpt.com/backend-api` | OAuth |
| radius | Pi Messages gateway, dynamic catalog | Radius key or OAuth plus gateway configuration |

OAuth, subscription token exchanges, cloud-account configuration/signing, and the separate Pi Messages protocol are outside the initial simple API-key scope. These providers were researched; their presence in this table does not claim an enabled or live-tested Domovoy adapter. Perplexity is an additional popular API-key service, rather than a member of this Pi built-in list.

OpenCode Zen and Go remain research-only: Pi routes their models through mixed per-model APIs, while Domovoy currently has no verified per-model route dispatcher. Their public catalogs are therefore intentionally excluded from the enabled picker.

Mistral's Pi API label is `mistral-conversations`, but the source uses Mistral Chat Completions: the label must not be converted into an invented `/conversations` endpoint. Likewise, provider IDs in models.dev differ in places (`fireworks-ai`, `togetherai`). Remote metadata's API URL or env names must never overwrite an app-owned credential destination.

## Models

Pi provides provider-owned catalogs and a model store; most built-in model arrays are generated/static, while some provider factories can supply dynamic catalogs. This is not a universal authenticated `/models` poll. For Domovoy, query documented provider listing endpoints where available; use [models.dev JSON](https://models.dev/api.json) for current metadata and listing-free providers. Cache the last successful result and expose its source/freshness. Do not execute downloaded TypeScript.

Provider listings are authoritative for exact offered IDs but do not prove that an account has quota or model entitlement. Models.dev is community metadata, not account availability. New listed chat IDs should remain selectable with unknown limits and no inferred optional controls when metadata is absent. Known non-chat entries must be filtered.

Live DeepSeek discovery returned `deepseek-flash` and `deepseek-v4-pro`; the former hardcoded `deepseek-v4-flash` was absent. This is why a fixed finite picker is insufficient.

## API usage semantics

| Family | Full input | Full generated output | Cache / reasoning |
|---|---|---|---|
| OpenAI Chat / DeepSeek | `prompt_tokens` | `completion_tokens` | Cached input is included in input; `completion_tokens_details.reasoning_tokens` is included in output |
| OpenAI Responses | `input_tokens` | `output_tokens` | `input_tokens_details.cached_tokens`; `output_tokens_details.reasoning_tokens` |
| Anthropic | `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` | `output_tokens` | Native input excludes caches; optional `output_tokens_details.thinking_tokens` is part of output |
| Gemini | `promptTokenCount` (includes cache) | `candidatesTokenCount + thoughtsTokenCount` when both reported | `cachedContentTokenCount`, `thoughtsTokenCount`; keep provider `totalTokenCount` |
| Mistral | `prompt_tokens` | `completion_tokens` | Optional cached-input details; do not estimate missing reasoning |
| Bedrock (research only) | API-specific input/cache counters | `outputTokens` | `cacheReadInputTokens`, `cacheWriteInputTokens`, `totalTokens` |

Use provider overall totals where available. Exact derived totals require documented inclusion semantics and sufficient counters. Missing is unknown, never fabricated zero; streamed cumulative snapshots replace/reconcile a physical invocation, rather than being added as separate calls. Aggregate cache hit is sum(cache read)/sum(full input), not an average of per-request percentages. Reasoning and caches are breakdowns, not extra tokens to add to inclusive totals.

Observed DeepSeek fixtures: thinking input 40/output 17/reasoning 15/overall 57; visible output derives as 2. Repeated cached request input 3471/cache read 3328/cache miss 143/output 2/overall 3473, hit ~95.9%. Error requests may report no usage at all.

## Branching

Pi's coding-agent session tree supports branch/fork-style history navigation; this is distinct from cross-provider message conversion in pi-ai. For a modest Domovoy demo, create an acknowledged checkpoint and independent durable child sessions. Copying a checkpoint must not count inherited provider requests as newly incurred usage. Switch branches only after in-flight work finishes; preserve original provider/model attribution.

## Primary references

- [Pi provider registrations](https://github.com/earendil-works/pi/blob/main/packages/ai/src/providers/all.ts), [types](https://github.com/earendil-works/pi/blob/main/packages/ai/src/types.ts), [models](https://github.com/earendil-works/pi/blob/main/packages/ai/src/models.ts), [model store](https://github.com/earendil-works/pi/blob/main/packages/ai/src/models-store.ts), [auth](https://github.com/earendil-works/pi/blob/main/packages/ai/src/auth/resolve.ts).
- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/), [context caching](https://api-docs.deepseek.com/guides/kv_cache/).
- [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming), [input/cache usage](https://platform.claude.com/docs/en/api/typescript/messages), [thinking usage](https://platform.claude.com/docs/en/build-with-claude/thinking-steering-and-cost).
- [Gemini generate-content](https://ai.google.dev/api/generate-content), [tokens](https://ai.google.dev/gemini-api/docs/generate-content/tokens).
- [Mistral models](https://docs.mistral.ai/api/endpoint/models), [Mistral API](https://docs.mistral.ai/api).

### Verified Pi branch implementation

At source revision `71dca871bc80b6bc97be37f0ca3189399d651fff` (2026-09-11), [SessionManager](https://github.com/badlogic/pi-mono/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/session-manager.ts) distinguishes three operations:

- `branch(id)` moves the current leaf cursor in the same append-only JSONL tree. Future entries become children at that position; old siblings remain in the file.
- `createBranchedSession(leafId)` copies the root-to-target path into a new session/file and records parent-session lineage. Entry payloads, provider/model attribution and usage are retained; copying does not generate tokens.
- `forkFrom(sourcePath, targetCwd, ...)` copies the source's whole tree under a new header, rather than only a selected path.

[Runtime fork](https://github.com/badlogic/pi-mono/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/agent-session-runtime.ts) defaults to before a selected user message, with an `at` option for the selected entry. It settles active generation before replacing the runtime context. Optional tree-navigation branch summaries are separate paid LLM calls with their own usage. The session manager itself does not aggregate copied usage; Domovoy demo totals must explicitly distinguish inherited path usage from new branch expenditure.
