## Why

Day 5 needs an auditable comparison of a weak local model, a mid-tier paid model, and a stronger paid model under one identical coding prompt. Domovoy currently owns one fixed DeepSeek profile, so it cannot run that comparison or safely target a user-configured OpenAI-compatible Chat Completions endpoint such as Ollama.

## What Changes

- Add reusable, validated OpenAI-compatible provider profiles with configurable endpoint, model id, optional bearer credential, source link, and optional pricing metadata.
- Ship three editable Day 5 presets: locally available Ollama `qwen3.5:2b`, DeepSeek `deepseek-v4-flash`, and DeepSeek `deepseek-v4-pro`.
- Resolve bearer credentials without exposing them, using a profile's saved application override before its configured environment variable; allow explicitly unauthenticated local profiles.
- Add a Day 5 laboratory that snapshots one shared ECS/sparse-set Dart prompt and runs the three profiles sequentially with reasoning disabled.
- Record time to first answer token, total duration, provider-reported token usage, estimated API cost when enough pricing data is available, and explicit unavailable states otherwise.
- Keep quality comparison human-controlled with structured ratings, a deterministic implementation-checklist heuristic, task-fit notes, provider/model links, and limitations that avoid claiming a universal winner from one response.
- Add opt-in live smoke coverage for DeepSeek Flash/Pro and documented manual Ollama preparation without putting credentials or response bodies in logs.
- Extend persistent application navigation with a compact Day 5 destination while preserving Days 1–4 state.

## Capabilities

### New Capabilities

- `openai-compatible-provider-configuration`: Validated custom Chat Completions profiles, optional authentication, safe credential precedence, and pricing/source metadata.
- `model-version-comparison`: Same-prompt three-model execution, timing/token/cost evidence, transparent quality evaluation, links, and Linux demonstration behavior.

### Modified Capabilities

- `prompt-workspace`: Add a persistent Day 5 model-comparison destination without coupling its state to Days 1–4.

## Impact

- Extends the provider construction boundary, credential storage, streaming usage normalization, dependency wiring, and settings UI while preserving the existing DeepSeek defaults.
- Adds a fifth Linux desktop screen, comparison controller/domain models, timing and cost calculations, widget/unit/integration tests, and a credential-safe video checklist.
- Uses direct OpenAI-compatible `/chat/completions` HTTP only; no LLM SDK, Responses API, agent framework, or automatic video generation is introduced.
- Local Ollama remains a user-started external dependency; cloud pricing is displayed as dated estimate metadata and never treated as a billing statement.
