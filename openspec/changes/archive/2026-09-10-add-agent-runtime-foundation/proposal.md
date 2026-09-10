## Why

Domovoy's current `OpenAiCompatibleChatAgent` combines DeepSeek request construction, transport parsing, credentials, and the application-facing agent contract, so it cannot support reusable tools, multi-turn execution, multiple wire protocols, persistent-ready sessions, or communication between sessions without becoming a god object. The product needs a pure-Dart foundation that separates provider profiles and transports from agent orchestration while preserving the current one-shot Flutter experience.

## What Changes

- Introduce provider-neutral model metadata, messages/content parts, generation requests, typed stream events, usage, finish reasons, sanitized errors, and a narrowly scoped versioned envelope for provider-owned continuation state, with two production wire adapters: OpenAI-compatible Chat Completions and OpenAI Responses.
- Add a provider/model registry, provider-scoped credential resolution, and a small curated catalog for DeepSeek, Moonshot AI/Kimi, and OpenAI plus a caller-defined OpenAI-compatible endpoint. The change does not copy Pi's full generated catalog or add dynamic model discovery.
- Introduce a serializable `AgentDefinition` for system prompt, initial messages, provider/model selection, generation settings including provider-neutral reasoning mode/effort, enabled tool identifiers, policy references, and nullable run guards/budgets. Productive turn, tool, duration, and cumulative-token quotas are unlimited unless a runtime profile, definition, or run override sets them.
- Add an ergonomic reusable agent facade: `runtime.agent(definition)`, one-call `agent.run(...)` backed by an owned ephemeral session, first-class caller-owned sessions created or restored by stable identity, and idempotent bounded `runtime.close()` for all accepted/opening/live sessions.
- Add versioned session records, transcript/snapshot boundaries, serializable provider continuation metadata, a cancellation-aware optimistic repository port, and an in-memory repository implementation so later Drift/SQLite/file storage can be attached without changing the public create/run/restore lifecycle. Checkpoint shutdown uses a deterministic bounded policy rather than scheduler timing; durable adapters and recovery of active work are not implemented here.
- Add an in-memory agent loop that streams model output, assembles and validates tool calls, applies `allow | deny | ask` permission policy, executes approved Dart tools with cancellation/liveness reporting, appends tool results, repeats model turns, and stops with a typed reason.
- Add lifecycle hooks, a single-subscription run event stream, a ten-minute idle watchdog, and repeated no-progress detection that warns after five identical cycles and stops after ten while resetting on observable progress.
- Add a broker-style session messaging seam and in-memory FIFO router. MVP delivery is queued and consumed only at safe model-turn boundaries; identifiers and correlation fields leave room for later steering and asynchronous completion without implementing child-agent orchestration.
- Migrate the existing prompt workspace to create an ephemeral session per submission, preserving its no-history UX, progressive reasoning/answer output, DeepSeek settings, and sanitized failures, while composition shutdown awaits the runtime before closing repository/router resources and the shared HTTP client.
- Explicitly defer a durable repository adapter, active-run/tool/stream recovery, background execution, steering an in-flight model stream, child spawning/delegation, async completion collectors, parallel tool execution, remote brokers, dynamic provider/model discovery, and a general provider-management UI.
- Require a subsequent independently verifiable change for the Anthropic Messages wire adapter and Kimi For Coding subscription profile; this follow-up is not silently treated as delivered by ordinary Moonshot/Kimi support in this change.

## Capabilities

### New Capabilities

- `llm-provider-core`: Provider-neutral Dart values, registry/catalog and credential boundaries, normalized streaming contract, and the Chat Completions plus OpenAI Responses production families and profiles.
- `agent-runtime`: Agent facade, definition/session/run separation, persistence-ready session records and ports, guarded tool loop, policies, hooks, cancellation, liveness/no-progress protection, event projection, and ephemeral/caller-owned session semantics.
- `agent-session-messaging`: Addressed in-memory queued delivery between registered agent sessions with ordering and correlation semantics.

### Modified Capabilities

- `llm-prompt-streaming`: Replace the provider-coupled one-shot agent boundary with an ephemeral agent-runtime session while preserving the existing workspace's observable stream behavior.

## Impact

- Affects `lib/features/prompt/domain`, `lib/features/prompt/data`, `lib/features/settings`, dependency composition in `lib/app.dart`, and their tests.
- Adds pure-Dart core boundaries under `lib/core/llm` and `lib/core/agents`; Flutter, secure-storage, and HTTP concerns remain adapters/composition concerns outside domain values and the loop.
- Keeps the package as one Flutter package (`domovoy`) and keeps Android, iOS, web, Linux, macOS, and Windows support. No Node/Python daemon, isolate worker, database, code generator, or agent SDK is introduced.
- Existing DeepSeek API-key overrides remain readable while credential storage becomes provider-scoped in `flutter_secure_storage`; credentials and executable callbacks are runtime-only and are never serialized into definitions, session records, messages, events, or failures. OpenAI encrypted reasoning state is not a credential: it is retained only as confidential transcript metadata required for `store: false` replay and is excluded from UI events, hooks, logs, errors, and diagnostic rendering.

## Deferred backlog clarification

This change already models reasoning capability per curated model: each `LlmModel`
owns `unsupported | optional | required` capability metadata and its selectable
canonical efforts, while typed profile/adapter mappings define that model's
default and wire values. The exact eight-model matrix in this change is the
accepted finite, hand-curated foundation; it is not a shared provider-wide
reasoning flag.

A separate independently proposed change may evolve this foundation into a
richer model-specific reasoning catalog and maintenance mechanism. That work
should evaluate a single per-model source of truth for supported modes,
selectable efforts, effective defaults, provider wire mappings/clamps, and
metadata provenance/freshness, reducing duplicated model-id branching in
adapters. It must decide explicitly whether catalog updates stay curated or use
validated dynamic discovery; dynamic refresh and undeclared models remain out
of scope here. This backlog item does not reopen this change or make its
implemented reasoning matrix incomplete against the approved specification.
