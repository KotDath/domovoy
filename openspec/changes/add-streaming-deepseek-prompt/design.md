## Context

See `proposal.md` for motivation and the three capability specs for observable behavior. The repository is the generated Flutter counter application with no networking, persistence, dependency injection, or state-management layer. Linux desktop is the primary runtime and required build target. The change must work without an LLM SDK or agent framework, keep every request stateless, and preserve compilation across Android, iOS, web, Linux, macOS, and Windows.

DeepSeek exposes `deepseek-v4-flash` through an OpenAI-compatible Chat Completions endpoint. In thinking mode its streaming delta extends the usual schema with `reasoning_content`, while final text remains in `content`. This extension needs normalization before presentation code sees it.

## Goals / Non-Goals

**Goals:**

- Establish a small domain contract that future provider adapters, including a Kimi adapter, can implement without changing the prompt UI.
- Stream reasoning and answer text incrementally and independently.
- Keep HTTP, SSE, credential storage, environment access, and widgets independently testable through constructor injection.
- Protect stored credentials at rest as far as each client platform permits and never expose them through presentation or errors.

**Non-Goals:**

- Multi-turn messages, history persistence, system prompts, tools, attachments, model selection, usage/cost reporting, Markdown rendering, or response regeneration.
- A generic agent orchestration runtime, OpenAI/DeepSeek SDK, backend proxy, account sync, or remote secret vault.
- Guaranteeing that a key embedded in a client process—especially a browser—cannot be extracted at runtime.

## Decisions

### 1. Domain API is a typed event stream

Define an `Agent` interface with a shape equivalent to `Stream<AgentEvent> prompt(AgentInput input)`. `AgentEvent` is a sealed family with reasoning delta, answer delta, completed, and failed variants. Failure is an explicit terminal event carrying a sanitized domain error rather than a provider exception or raw JSON.

This preserves the input/output vocabulary requested for the agent layer while representing progressive output naturally. It also gives the controller a deterministic rule: exactly one completed or failed terminal event ends an invocation. Returning one final DTO was rejected because it would hide streaming; exposing raw SSE or DeepSeek chunks was rejected because it couples the UI to one provider.

### 2. Use OpenAI-compatible Chat Completions, not Responses API

Implement an `OpenAiCompatibleChatAgent` using a small injected provider profile containing endpoint, model, request extensions, and delta-field mapping. The initial DeepSeek profile uses:

```json
{
  "model": "deepseek-v4-flash",
  "messages": [{"role": "user", "content": "<prompt>"}],
  "stream": true,
  "thinking": {"type": "enabled"},
  "reasoning_effort": "high"
}
```

The request is sent to `https://api.deepseek.com/chat/completions` with JSON content type, SSE accept type, and `Authorization: Bearer <resolved key>`. No sampling parameters are sent because DeepSeek ignores them in thinking mode.

Chat Completions was chosen over the Responses API because it is the broader compatibility surface for providers such as Kimi. The domain stream remains provider-neutral; a future provider profile or adapter can map a different reasoning extension without changing presentation. A DeepSeek SDK was rejected because it adds provider coupling without helping the small required surface.

### 3. Parse SSE framing separately from provider JSON

Use a general HTTP client capable of streamed responses and implement a small SSE decoder over the response byte stream. The decoder buffers arbitrary byte boundaries, recognizes blank-line event termination, joins multiple `data:` lines, ignores comments and unused SSE fields, and yields complete data payloads. A second parser handles Chat Completions JSON and maps non-empty `choices[0].delta.reasoning_content` and `choices[0].delta.content` independently. `[DONE]` produces successful completion.

Non-2xx responses are read as bounded error bodies and sanitized. Invalid text-bearing chunks, provider error payloads, network exceptions, and EOF before `[DONE]` become typed failures. Already-emitted deltas are not rolled back. Separating framing from JSON enables focused tests for split UTF-8 bytes, split lines, multiline data, empty/metadata chunks, malformed payloads, and interrupted streams.

Using a general SSE package was considered, but the protocol subset is small and a package would not remove the provider-specific normalization work. The HTTP client and parser remain replaceable and injected.

### 4. Resolve secrets through isolated sources

Split credential handling into three roles:

- an application override store backed by platform credential storage;
- an environment reader that returns `DEEPSEEK_API_KEY` on `dart:io` platforms and returns absent through a conditional web implementation;
- a resolver that selects the non-empty application override before the environment value and otherwise returns a typed missing-key failure.

Use a secure-storage Flutter plugin rather than preferences or a plain file. The settings screen never reads the stored secret back into a text field: it accepts a replacement value, reports only whether an override exists and which source is active, and exposes a separate remove action. Whitespace-only input is invalid; surrounding accidental whitespace is removed before storage and use.

On web, platform environment fallback is unavailable and any directly used provider key is observable by the browser runtime. The UI will display that limitation. The app remains buildable and can use an override on web where provider CORS permits it, but a backend proxy is the appropriate future production design.

### 5. Use a lightweight controller and explicit composition root

Create a `PromptController` using Flutter listenable primitives rather than adding a state-management framework. Its immutable state contains the accumulated reasoning, accumulated answer, request status, sanitized error, and reasoning expansion state. It subscribes to one agent stream, appends deltas, disables concurrent submission, retains partial content on failure, and disposes its subscription with the view.

`main.dart` remains a thin entry point. An application composition root constructs storage, environment reader, resolver, streamed HTTP client, DeepSeek provider profile, agent, and controller through constructors. Tests inject fakes at each boundary.

### 6. Use a responsive two-area workspace

The home page replaces the counter. A layout breakpoint presents input and output side by side on wide screens and stacked on narrow screens. The reasoning section uses a theme-derived muted surface/text treatment and an accessible disclosure header; it starts expanded when reasoning first appears and remains entirely user-controlled afterward. The final answer is never collapsed.

Each submission clears the prior result and does not send it to the provider. The submit action is disabled while active and for empty input. Settings are reachable from the app bar and directly from a missing-key error.

## Risks / Trade-offs

- **Client-held API keys can be extracted from a running app** → Store overrides in platform credential storage, avoid logs and UI disclosure, warn on web, and reserve a backend proxy for a later production-hardening change.
- **Direct browser calls may be blocked by provider CORS** → Keep web compilation and UI intact, surface a sanitized transport error, and document the proxy path rather than weakening browser security.
- **`DEEPSEEK_API_KEY` is not practically injectable into normally launched mobile apps** → Treat environment access as an optional fallback; the in-app override remains the supported path on those platforms.
- **OpenAI-compatible providers differ in reasoning extensions and terminal behavior** → Normalize behind the `Agent` contract and keep provider profiles/adapters responsible for their delta schema.
- **Hand-written SSE parsing can fail on chunk boundaries** → Isolate it as a byte-stream transformer and cover UTF-8 fragmentation, CRLF/LF framing, multiline data, terminal markers, and premature EOF with unit tests.
- **Secure-storage plugins add native platform configuration** → Follow each platform's documented setup, keep access behind an interface, and verify analysis/tests plus representative builds during implementation.

## Migration Plan

1. Add HTTP and secure-storage dependencies and any required native configuration.
2. Add the domain event contract, credentials abstractions, environment implementations, and secure override store.
3. Add and test the SSE decoder and OpenAI-compatible Chat Completions adapter with the DeepSeek profile.
4. Replace the counter screen with the injected controller, responsive prompt workspace, reasoning disclosure, errors, and settings.
5. Replace the generated widget test and add domain, data, controller, and widget tests.
6. Run formatting, static analysis, tests, and a Linux desktop build check. Rollback consists of reverting the new modules/dependencies and restoring the generated counter entry point; the only persisted state to remove is the optional application key override.
