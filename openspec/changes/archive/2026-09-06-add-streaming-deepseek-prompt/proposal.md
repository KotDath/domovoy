## Why

Domovoy currently contains only the generated Flutter counter and cannot send a user prompt to an LLM. The first product-facing slice should establish a small provider-independent agent boundary and a one-shot streaming experience that can later grow without introducing an agent framework or conversation history prematurely.

## What Changes

- Replace the counter home screen with a one-shot prompt workspace containing separate input and output areas.
- Introduce an abstract agent interface that accepts one prompt and streams typed reasoning, answer, completion, and failure events.
- Add a direct OpenAI-compatible Chat Completions adapter configured for the official DeepSeek `deepseek-v4-flash` model, with thinking enabled and separate streaming of `reasoning_content` and final-answer text.
- Add application settings for a persistent, masked DeepSeek API-key override.
- Resolve credentials in this order: non-empty application override, then `DEEPSEEK_API_KEY` from the process environment; reject prompt execution with a user-visible configuration error when neither exists.
- Render reasoning in a visually muted, expandable/collapsible section while keeping the final answer plainly visible.
- Keep every submission independent: no message history, conversation persistence, tools, or agent-framework integration is added in this change.

## Capabilities

### New Capabilities

- `llm-prompt-streaming`: Provider-independent one-shot prompt execution and typed streaming output, backed initially by DeepSeek through its OpenAI-compatible Chat Completions API.
- `llm-credentials`: Secure application API-key override, environment fallback, precedence, clearing, and missing-key behavior.
- `prompt-workspace`: Prompt input, progressive reasoning and answer presentation, settings access, loading state, and user-facing errors.

### Modified Capabilities

None.

## Impact

- Replaces the generated UI in `lib/main.dart` and introduces domain, data/infrastructure, settings, and presentation modules under `lib/`.
- Adds a general HTTP dependency for direct HTTPS/SSE communication and secure-storage support for the in-app key override; no DeepSeek SDK or agent framework is introduced.
- Calls the official OpenAI-compatible DeepSeek API at `https://api.deepseek.com/chat/completions` with model `deepseek-v4-flash` and sends the resolved API key as a bearer token.
- Adds unit and widget coverage for stream parsing, credential precedence, request/error mapping, and progressive UI behavior.
- Targets Linux desktop as the primary runtime and required end-to-end build target.
- Keeps all configured Flutter targets buildable; runtime process-environment availability and secure-storage guarantees remain platform-dependent, and browser clients cannot keep a direct-provider API key secret.
