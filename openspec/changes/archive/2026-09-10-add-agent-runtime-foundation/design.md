## Context

See `proposal.md` for motivation and the four delta specs for behavior. Domovoy is currently a single Flutter package with feature/domain/data/presentation folders rather than separate Dart packages. The app manually composes one `http.Client`, a secure DeepSeek-only credential resolver, and `OpenAiCompatibleChatAgent` in `lib/app.dart`; `PromptController` directly consumes that object's stream. The current transport owns credential resolution, request construction, SSE normalization, usage/error mapping, and the application-facing `Agent` abstraction. Secure storage and environment lookup use fixed DeepSeek keys rather than provider identity.

The retained baseline is intentionally one-shot: each call sends one user message and `PromptController` discards prior output. Secure application overrides use `flutter_secure_storage`; environment access has an IO/stub split; there is no general DI, state-management, persistence, database, background-service, or isolate framework. The project targets Android, iOS, web, Linux, macOS, and Windows with Dart 3.10 and depends only on Flutter, `http`, and `flutter_secure_storage`. The main `llm-prompt-streaming` spec still requires optional validated temperature, but the cleanup-era `AgentInput` no longer carries it; the new typed generation config and adapter must restore that already-specified behavior rather than preserve the implementation drift.

Relevant patterns were independently checked against current sources, but are adapted rather than copied: OpenCode keeps a schema-first LLM core separate from session orchestration; Pi separates shared wire families from provider-owned profiles, authentication, and model catalogs; OpenClaw routes communication through addressed sessions; Hermes isolates delegated child context and treats background completion separately. The attached Pi checkout identifies DeepSeek and Moonshot AI as `openai-completions`, OpenAI as `openai-responses`, and Kimi For Coding as `anthropic-messages`. Domovoy will not import their TypeScript, vendor SDK, Node daemon, worker, thread, terminal, or generated 500-plus-model catalog assumptions.

## Goals / Non-Goals

**Goals:**

- Establish pure-Dart LLM and agent-runtime boundaries that can be unit-tested without Flutter bindings or network access.
- Keep provider transport, immutable agent configuration, mutable session state, tools/policies, and Flutter projection independently replaceable.
- Make every loop safely interruptible and observable without imposing a short productive-work quota, and make cancellation, terminal events, liveness, no-progress detection, tool errors, and usage uncertainty explicit.
- Provide ergonomic one-call execution and first-class sessions whose identity, records, lifecycle, and repository boundary permit later durable storage without a breaking public lifecycle redesign.
- Prove provider neutrality with both Chat Completions and OpenAI Responses while keeping profiles, credentials, and a curated catalog independently replaceable.
- Deliver a minimal in-process broker seam that proves two sessions can exchange queued correlated messages without direct references.
- Migrate the current prompt surface through the new runtime without changing its one-shot product behavior.

**Non-Goals:**

- No database/file/cloud session repository, replay log, operation/turn/invocation recovery frames, active-run replay, exact-once tool recovery, or durable mailbox guarantee. Versioned records, codec/repository ports, and an in-memory repository are included.
- No child-agent spawn/delegate/yield/announce APIs, completion collector, synchronous send-and-wait, in-flight steering, remote broker, or cross-device delivery.
- No background Flutter service, wake lock, notification integration, unrestricted work after suspension, worker isolate, or parallel tool scheduler.
- No generated/full Pi catalog, dynamic model discovery, provider fallback/routing, retry policy, pricing/cost ledger, embeddings, image/audio support, caller-supplied provider extension JSON, or general provider-management UI. The adapter-produced continuation envelope below is a closed replay contract, not an option escape hatch.
- No Anthropic Messages adapter, Kimi For Coding subscription profile, Anthropic profile, Gemini/Google adapter, Mistral Conversations, Bedrock, Vertex, Azure, or Codex OAuth in this change. Anthropic Messages plus Kimi For Coding is a required follow-up change.
- No approval UI in this change. `ask` is supported as a runtime contract; production composition without a handler denies safely.
- No promise that the new internal Dart APIs are stable for external package consumers; `domovoy` is not published.

## Decisions

### 1. Keep one Flutter package with enforced source-layer boundaries

Add these source boundaries rather than creating publishable packages now:

- `lib/core/llm/`: Dart-only immutable values, validation/serialization helpers, cancellation contract, provider/profile/model-registry interfaces, and event/error/usage vocabulary. It imports only `dart:*`.
- `lib/core/agents/`: Dart-only agent facade/definition, session records/snapshots/codec/repository port, runtime/session/run state machine, tool contracts/registries/policies/hooks, guards, and session-routing contracts/in-memory implementations. It depends on `core/llm`, never Flutter, HTTP, secure storage, or feature presentation.
- `lib/infrastructure/llm/openai_compatible/`: shared HTTP/SSE utilities, Chat Completions adapter, and typed DeepSeek/Moonshot/custom-compatible profiles.
- `lib/infrastructure/llm/openai_responses/`: HTTP/SSE OpenAI Responses adapter and OpenAI profile. Both infrastructure adapters depend on `core/llm`, `http`, and provider-scoped credential resolution; credentials are resolved only immediately before dispatch.
- `lib/infrastructure/credentials/`: secure provider-key storage plus secure-override-before-environment resolution. It preserves access to the legacy DeepSeek override key while namespacing new provider values.
- `lib/features/prompt/`: Flutter controller/page projection. It depends on the agent runtime public API, not infrastructure/provider types.
- `lib/app.dart`: the composition root. It owns concrete clients, registries, runtime, definitions, stores, and disposal; no service-locator package is added.

Each boundary gets one barrel exposing its intended public surface; implementation helpers remain library-private where practical. This retains repository conventions and avoids premature package-management overhead. A multi-package workspace was rejected because the current codebase is small and the same import-direction guarantees can be reviewed and analyzer-tested inside one package.

### 2. Use immutable serializable values but keep capabilities/resources runtime-only

Every serialized object uses a required `type`/`version` discriminator where variants or future evolution require it, validates on construction and `fromJson`, defensively deep-copies JSON maps/lists, and returns unmodifiable collections. Unknown variant types and malformed numbers fail as typed configuration/protocol errors; no permissive partially initialized object is produced.

Serializable value objects:

- `ProviderId`, `ModelId`, `ModelRef`, `ModelCapabilities`, `LlmModel`;
- `LlmWireFamily`, non-secret provider-profile snapshots, and curated catalog metadata;
- `LlmMessage` plus `TextPart`, `ReasoningPart`, `ToolCallPart`, and `ToolResultPart`;
- `LlmProviderTurnState` and message-indexed `LlmContinuationEntry`, whose versioned opaque payload is created and consumed only by its declared provider/wire adapter;
- `LlmGenerationConfig`, `LlmToolDescriptor`, `LlmRequestSnapshot`;
- `LlmUsage`, normalized finish/stop reasons, sanitized `LlmError`, and stream/runtime event payloads;
- `AgentId`, `AgentDefinition`, nullable `AgentRunLimits`, `AgentLivenessPolicy`, `AgentNoProgressPolicy`, and `AgentTokenBudget`;
- `AgentSessionId`, `SessionRevision`, `RunId`, `TurnId`, `ToolCallId`, immutable `AgentTranscript`, `AgentSessionSnapshot`, and versioned `AgentSessionRecord`;
- `SessionEnvelope` and `DeliveryReceipt` including message/correlation/reply-to identifiers.

Runtime-only objects:

- `LlmProvider`, provider registry implementation, `http.Client`, credential resolver/effective value, response subscription;
- cancellation source/timers, `AgentRuntime`, mutable `AgentSession`, `AgentRun`, stream controllers and active accumulators;
- tool registry/executors, permission policies, approval handler, lifecycle hooks, clock/ID factory;
- session repository implementation, router registration/mailbox queues (their records/envelopes remain serializable).

`AgentDefinition` stores tool identifiers and a policy identifier, not executors or callbacks, and rejects provider continuation state in its seed messages. Creating or restoring a session resolves every referenced provider/model/tool/policy eagerly and fails before work if any reference is unavailable. `AgentSessionRecord` stores the complete serializable definition snapshot, committed transcript/counter state, and committed provider continuation entries correlated to assistant-message indexes; it does not store an active run, mailbox, credential, provider instance, policy, executor, timer, stream, or partial accumulator. This allows definitions and quiescent sessions to be persisted while secrets and executable authority remain explicitly injected. Serializing callbacks, effective credentials, or active operation frames was rejected as unsafe and falsely suggestive of crash recovery.

### 3. Define a narrow provider contract and typed event grammar

The main boundary is conceptually:

```dart
abstract interface class LlmProvider {
  ProviderId get id;
  LlmWireFamily get wireFamily;
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  });
}

enum ModelReasoningCapability { unsupported, optional, required }

enum ReasoningEffort { modelDefault, low, medium, high, max }

final class AgentReasoningOverride {
  final ReasoningMode mode;
  final ReasoningEffort effort;
}

final class LlmProviderTurnState {
  final ModelRef origin;
  final LlmWireFamily wireFamily;
  final String format; // Closed, versioned adapter format identifier.
  final Object payload; // Defensively copied/deep-frozen JSON.
}

final class LlmContinuationEntry {
  final int assistantMessageIndex;
  final LlmProviderTurnState state;
}
```

`LlmProviderRegistry` separately owns provider instances and a finite model catalog. Resolution uses the exact `(ProviderId, ModelId)` pair, verifies that the model and provider declare the same wire family, then dispatches through that provider instance. A provider profile owns a typed endpoint, credential reference/environment source, and protocol-compatibility dialect; a catalog entry owns model identity, wire family, capabilities, context bound, and output bound. This mirrors Pi's useful adapter/profile/catalog split without porting its generated catalog or auth SDKs.

`LlmRequest` contains a selected `ModelRef`, `LlmContext(systemPrompt, messages, tools, continuationEntries)`, and typed `LlmGenerationConfig` (`reasoningMode`, `reasoningEffort`, optional finite `temperature`, optional positive `maxOutputTokens`). `ReasoningEffort` is the closed provider-neutral set `modelDefault | low | medium | high | max`; it is not a vendor string. `modelDefault` means the selected model/profile mapping decides the effective wire value and is the backwards-compatible default. It contains no key, endpoint, transport, callback, or raw provider-options map. Each continuation entry must point to an assistant message, declare the exact selected provider/model/wire family, use a registered closed format, and pass that adapter's strict structural validation. A mismatched, duplicate, unknown-format, malformed, or normalized-content-inconsistent entry fails locally; adapters never guess or pass it to another provider. A raw caller extension map was rejected because it defeats provider neutrality, validation, and secret review. Custom compatible endpoints are registered as typed runtime profiles and explicit models rather than embedded in an agent definition.

Provider events form this grammar:

1. optional start/metadata and zero or more `LlmReasoningDelta`, `LlmTextDelta`, `LlmToolCallDelta`, and `LlmUsageUpdate` events in source order;
2. exactly one of `LlmCompleted` (optionally carrying one validated `LlmProviderTurnState`), `LlmFailed`, or `LlmCancelled`;
3. stream close with no events afterward.

The adapter catches expected and unexpected operational exceptions and converts them to a sanitized terminal. Constructor/request validation may fail synchronously before a stream is accepted. A provider stream that closes without a terminal is converted by the runtime to an interrupted protocol failure. This dual check prevents a broken adapter from leaving the UI loading forever.

Tool-call deltas carry stable call id/index, optional name fragment, and ordered argument fragments. The runtime owns normalized assembly and semantic validation; the adapter owns strict validation of its opaque completed turn state. Usage fields are optional and never estimated. `unknown` preserves unfamiliar finish reasons while malformed text/tool event shapes remain protocol failures. Agent events, lifecycle hooks, snapshots, errors, and diagnostics project only normalized data and never expose an opaque continuation payload.

### 4. Deliver two wire families with curated profiles rather than one provider-shaped adapter

Replace the provider role of `OpenAiCompatibleChatAgent` with two infrastructure adapters that share only HTTP/SSE framing, sanitization, and cancellation utilities:

1. `OpenAiChatCompletionsLlmProvider` maps provider-neutral context to Chat Completions, including assistant tool calls and role `tool` results. Typed dialect metadata handles request/reasoning/output-token fields and response aliases without branching in the agent loop.
2. `OpenAiResponsesLlmProvider` maps instructions, ordered input items, function tools/calls/outputs, output text, reasoning, usage, refusal/error, and terminal events to/from the Responses API.

Built-in production profiles and their curated entries are exactly:

| Profile | Wire family | Endpoint/base | Models |
|---|---|---|---|
| `deepseek` | Chat Completions | `https://api.deepseek.com/chat/completions` | `deepseek-v4-flash`, `deepseek-v4-pro` |
| `moonshotai` | Chat Completions | `https://api.moonshot.ai/v1/chat/completions` | `kimi-k2.6`, `kimi-k2.7-code`, `kimi-k3` |
| `openai` | Responses | `https://api.openai.com/v1/responses` | `gpt-4o-mini`, `gpt-5-mini`, `gpt-5.4` |

Reasoning capability is a three-state model property rather than two interacting booleans:

| Model(s) | `ModelReasoningCapability` | Valid `ReasoningMode` |
|---|---|---|
| `deepseek-v4-flash`, `deepseek-v4-pro`, `kimi-k2.6` | `optional` | `enabled`, `disabled` |
| `kimi-k2.7-code`, `kimi-k3`, `gpt-5-mini` | `required` | `enabled` only |
| `gpt-4o-mini` | `unsupported` | `disabled` only |
| `gpt-5.4` | `optional` | `enabled`, `disabled` |

`unsupported` means the adapter emits no reasoning control and accepts no reasoning content. `optional` means both modes are valid and the adapter must send the protocol's explicit disabled value when omission would leave reasoning enabled; for OpenAI Responses, `gpt-5.4` maps disabled to `reasoning.effort: none`. `required` rejects disabled locally. Model metadata additionally publishes the selectable canonical efforts (excluding `modelDefault`); an explicit effort outside that set is rejected before credentials/network. Disabled mode permits only `modelDefault`, since an effort on disabled reasoning is contradictory. A custom Chat Completions model must declare both capability and accepted canonical efforts in its typed profile mapping; unsupported/generic profiles reject enabled reasoning and explicit effort instead of forwarding unknown strings. This leaves the user-selected/global unlimited guard policy unchanged.

Effort mapping is deliberately data-driven because vendor tiers are not equivalent:

| Model(s) | Explicit canonical efforts | `enabled + modelDefault` | Wire mapping |
|---|---|---|---|
| `deepseek-v4-flash`, `deepseek-v4-pro` | `low`, `medium`, `high`, `max` | `high` | low→`low`; medium→`high` (documented provider clamp); high→`high`; max→`max` |
| `kimi-k2.6` | none | provider thinking default | toggle only; any explicit effort is rejected |
| `kimi-k2.7-code` | none | fixed provider reasoning | always enabled; any explicit effort is rejected |
| `kimi-k3` | `low`, `high`, `max` | `high` for backwards compatibility | exact top-level `reasoning_effort`; `medium` is rejected |
| `gpt-4o-mini` | none | not applicable | disabled emits no reasoning field; enabled/explicit effort is rejected |
| `gpt-5-mini` | `low`, `medium`, `high` | `high` for backwards compatibility | exact Responses `reasoning.effort`; `max` is rejected |
| `gpt-5.4` | `low`, `medium`, `high`, `max` | `high` for backwards compatibility | low/medium/high exact; canonical max→provider `xhigh`; disabled→provider `none` |

`AgentDefinition.generation.reasoningEffort` is serialized. `AgentRunOptions.reasoning` is an optional runtime-only `AgentReasoningOverride` that replaces mode and effort as one pair, preventing a run-level disabled mode from accidentally inheriting a non-default effort. Resolution is one immutable snapshot per run: explicit run override, otherwise definition mode/effort, then—when effort is `modelDefault`—the model/profile mapping above. No global `AgentRuntimeProfile` reasoning override is added. A run cannot change effort between tool continuations.

A caller may register an additional Chat Completions profile with a validated HTTPS endpoint, provider ID, credential reference/environment source, dialect, and explicit model entries. It gets no implicit built-in models or arbitrary headers. Local HTTP endpoints may be allowed only by an explicit development/test policy; definitions still select only provider/model IDs.

`ProviderCredentialStore` is keyed by `ProviderId`; the secure adapter namespaces new values and supports an explicit read-through/migration path for the existing `deepseek_api_key_override`. Each profile declares its environment variable (`DEEPSEEK_API_KEY`, `MOONSHOT_API_KEY`, or `OPENAI_API_KEY`). Stored provider override wins over that provider's environment value. General credential/provider settings UI is not included; the current DeepSeek UI remains functional, and other profiles can use environment or injected credentials until a later UI change.

Reasoning summary text remains a distinct normalized content part/event because the existing UI displays it. It is never answer text and is never synthesized into a provider-native reasoning input item. Opaque reasoning continuity is represented separately by `LlmProviderTurnState`.

The OpenAI Responses profile is deliberately stateless: every request sets `store: false` and does not use `previous_response_id`; every reasoning-capable request explicitly requests `include: ["reasoning.encrypted_content"]` even where the service currently supplies it by default. During streaming the adapter collects complete `response.output_item.done` items in provider index order; it never uses the potentially incomplete reasoning item from `response.output_item.added`. At successful completion it validates and deep-freezes the complete output items of the currently supported types (`reasoning`, assistant `message` with output text/phase, and `function_call`) as format `openai.responses.output_items.v1`. Known item fields, including item `id`, `status`, `summary`, `content`, assistant `phase`, function `call_id`/name/arguments, and reasoning `encrypted_content`, are preserved unchanged; unsupported output-item types fail as protocol errors rather than becoming arbitrary payload support.

The runtime commits that turn state atomically with its normalized complete assistant message and records its assistant-message index. On the next request to the same exact OpenAI model/wire adapter with reasoning still enabled, the encoder inserts the validated stored output-item array at that transcript position exactly once and skips synthetic encoding of the corresponding assistant message; following normalized tool results become `function_call_output` items. This preserves reasoning, function-call IDs, item IDs, and ordering across any number of local tool continuations while `store: false`. A later run that explicitly disables optional reasoning uses normalized visible history and does not replay earlier opaque reasoning state. If no matching turn state exists, normalized assistant text and non-reasoning function calls may use the documented synthetic input forms, but `LlmReasoningPart` is omitted rather than fabricated as `{type: reasoning, summary: ...}`. Any function-call turn produced with enabled/required reasoning but lacking replayable state fails locally before tool execution/continuation, whether or not a visible reasoning summary delta was emitted. A stateless reasoning output item without non-empty `encrypted_content` may fall back to visible text-only history only when that response has no function call; with a function call it is a protocol failure before the tool side effect.

The encrypted blob and provider item IDs are not API credentials and are intentionally serializable in `AgentSessionRecord`; they are confidential model-generated conversation metadata with the same lifetime as the correlated transcript turn. They are retained verbatim because redaction would invalidate stateless replay, removed when the record is deleted, and released with a transient session. They must never appear in agent/UI events, snapshots, lifecycle hooks, mailbox envelopes, logs, exceptions, or diagnostic `toString`; those surfaces may report only format/origin/item count. Raw response roots, headers, authorization values, and unrelated provider fields are never retained. A future durable repository must protect this metadata under the same at-rest/access policy as transcript content; this change still supplies only the in-memory repository.

Both adapters validate provider/model ownership, wire family, and capabilities before dispatch. Unsupported tools/reasoning/options produce configuration errors rather than silent behavior changes. The current `http.Client` remains shared and is closed by the composition root. Cancellation cancels response subscriptions and uses the most direct abort mechanism supported by `package:http`; the runtime still suppresses late events because not every platform can immediately abort DNS/TLS work. No Dart vendor SDK is added.

Kimi For Coding is not the Moonshot Chat Completions profile: the attached Pi implementation routes its subscription endpoint through Anthropic Messages and optional OAuth. A required follow-up change must add the Anthropic Messages adapter and Kimi For Coding profile/catalog (`kimi-for-coding`, `kimi-for-coding-highspeed`, `k3`) with its own fixtures and auth decision. This change must not expose Kimi Coding as supported before that follow-up is implemented and verified.

### 5. Put an ergonomic agent facade over first-class persistent-ready sessions

The public shape is conceptually:

```dart
final class AgentDefinition {
  final AgentId id;
  final String name;
  final String systemPrompt;
  final List<LlmMessage> initialMessages;
  final ModelRef model;
  final LlmGenerationConfig generation;
  final List<ToolId> enabledTools;
  final PolicyId policy;
  final AgentRunLimits limits;
  final AgentLivenessPolicy liveness;
  final AgentNoProgressPolicy noProgress;
  final AgentTokenBudget budget;
}

final class LlmGenerationConfig {
  final ReasoningMode reasoningMode; // Existing enabled/disabled API.
  final ReasoningEffort reasoningEffort; // Defaults to modelDefault.
  final double? temperature;
  final int? maxOutputTokens;
}

abstract interface class AgentRuntime {
  Agent agent(AgentDefinition definition);
  Future<void> close();
}

abstract interface class Agent {
  AgentDefinition get definition;
  AgentRun run(String input, {AgentRunOptions? options});
  Future<AgentSession> createSession({
    AgentSessionId? id,
    SessionPersistence persistence = SessionPersistence.transient,
  });
  Future<AgentSession> restoreSession(AgentSessionId id);
}

abstract interface class AgentSession {
  AgentSessionId get id;
  AgentSessionSnapshot get snapshot;
  AgentRun run(String input, {AgentRunOptions? options});
  Future<void> close();
}

abstract interface class AgentRun {
  RunId get id;
  Stream<AgentRunEvent> get events;
  Future<void> cancel();
}

abstract interface class CancellationRegistration {
  void dispose();
}

abstract interface class CancellationToken {
  bool get isCancelled;
  Future<void> get whenCancelled; // Compatibility/one-shot observation.
  CancellationRegistration register(void Function() callback);
}

abstract interface class AgentSessionRepository {
  Future<AgentSessionRecord?> load(AgentSessionId id);
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
  Future<void> delete(AgentSessionId id);
}

final class AgentPersistencePolicy {
  static const Duration defaultCancellationGracePeriod = Duration(seconds: 5);
  const AgentPersistencePolicy({
    this.cancellationGracePeriod = defaultCancellationGracePeriod,
  });
  final Duration cancellationGracePeriod; // Validated as strictly positive.
}
```

The facade also exposes a typed user-message form for callers that need provider-neutral content parts; the string form is the convenience path, not a dynamic union. `Agent.run` synchronously returns a run handle, creates a fresh transient session internally, and surfaces asynchronous startup/resource failures through that run's typed event terminal. This preserves the ergonomic call while repository-backed create/restore remains asynchronous.

`AgentRuntime.close()` is an idempotent ownership barrier with `open -> closing -> closed` state and one shared future. The runtime owns every one-call/caller-owned session and every accepted session-opening operation from acceptance until closure, including an ephemeral run whose session has not registered yet. Starting close atomically rejects new agent binding, run, create, restore, and routing registration; pending opens must observe closing and clean up instead of registering late. It snapshots accepted/opening/live sessions, requests their closure concurrently, and gives all persistence finalization one shared absolute `AgentPersistencePolicy` deadline rather than one deadline per session. It waits until every accepted run has emitted/suppressed its sole terminal and every session has closed or been deterministically abandoned/quarantined. It then reaches closed even if one child close failed, and only after all cleanup attempts completes its shared future with the first sanitized failure, if any. The runtime closes no injected repository, router, provider, credential store, or HTTP client; their ownership stays with composition.

`AgentSession.run` accepts valid user content, permits one active run, and returns a single-subscription `AgentRun`; stream cancellation invokes run cancellation. Session states are `idle`, `running`, `closing`, and `closed`. `close` is idempotent, cancels active work, flushes a committed repository-backed checkpoint, unregisters the in-process mailbox, and releases controllers. It never deletes a repository record. A successful close means the final committed snapshot was acknowledged by the repository. If the close flush fails or exceeds the persistence cancellation grace period, the session still reaches `closed` and releases runtime resources within the bound, but the shared idempotent close future completes with a sanitized persistence error. Run failure returns a still-open caller-owned session to idle when safe so callers can retry; a session infrastructure failure that makes state unreliable closes it.

`AgentSessionId` is the sole public identity for lifecycle, repository, and messaging. `AgentSessionRecord` is versioned and revisioned and contains the serializable definition snapshot, committed `AgentTranscript`, cumulative reported usage/counters, and timestamps. `AgentSessionCodec` strictly maps records to deep-frozen JSON. `AgentSessionRepository` provides `load`, cancellation-aware optimistic `save(expectedRevision, cancellation)`, and `delete`; this change includes an in-memory repository and contract suite. A save future completes successfully only after its revision is committed. A conforming repository that observes cancellation before its commit point completes with the typed cancelled error and guarantees that operation cannot mutate storage later; if the commit point already passed, it completes successfully instead. Conflict and other failures likewise guarantee no later mutation by that operation. These semantics can be implemented by an in-memory map or a Drift/SQLite/file transaction without requiring completion in the same event-loop turn. `createSession(persistence: repository)` saves an initial record, while `restoreSession` loads/decodes, validates resources, acquires one live session for that ID in a runtime, and starts idle. Unknown versions, conflicts, malformed history, and unavailable resources are typed failures before dispatch.

Session checkpoints occur only after atomic committed boundaries: accepted run input/inbound messages, a complete assistant message, each complete tool result, and terminal usage/counter state. Partial deltas, in-flight tool state, approval waits, cancellation objects, mailbox queues, and transport frames are not records. Checkpoints are serialized, each save captures an immutable record, and the runtime advances the acknowledged revision only on successful completion. A normally productive checkpoint has no microtask, event-loop-turn, or persistence-grace timeout: a legitimate delayed save is awaited until it settles or run/session cancellation begins. A checkpoint failure stops continuation; it cannot promise rollback or exact-once recovery for an external side effect that completed before its result checkpoint. Restoring never resumes an active run automatically.

Cancellation is observable without retaining one `Future.then` callback per operation. `CancellationToken.register` invokes a callback exactly once if cancellation wins before disposal; registration on an already-cancelled token invokes the callback before `register` returns and yields an inert registration. The returned registration has idempotent `dispose` that prevents a not-yet-started callback. Runtime and repository wait races dispose their registrations in `finally` on success, error, cancellation, or abandonment. `whenCancelled` remains for one-shot compatibility but is not used by repeated checkpoint loops.

Run-work cancellation and persistence-operation cancellation use separate sources. On ordinary completion or a non-cancellation stop/failure, the terminal guard freezes state and awaits the serialized final checkpoint before emitting the one terminal event. A save error at that barrier replaces a provisional completion/non-cancellation stop with a typed sanitized persistence/conflict failure and closes the unreliable session. Cancelling the run, cancelling its subscription, closing its session, or firing the idle/total-duration guard instead starts one absolute persistence-shutdown budget from the runtime-only `AgentPersistencePolicy`; this budget is independent of productive `maxDuration` and the idle watchdog and is never reset by progress.

Within that one shutdown budget the runtime cancels an active save, waits for its success or typed cancellation, and, when its revision outcome is known and time remains, attempts at most one final save of the frozen committed snapshot using a fresh operation token tied to the same absolute deadline. It emits/completes the selected cancellation-family terminal only after the final save is acknowledged or the single deadline is reached; once the deadline callback fires, deadline abandonment wins over any save observation delivered later. Thus a delayed conforming save can finish normally, while cancellation and close remain bounded even if a repository ignores its token. Explicit caller/subscription cancellation and idle/duration stop keep their already-selected terminal if this shutdown flush fails; there is no competing persistence terminal. `AgentRun.cancel()` completes after that barrier and remains idempotent. A caller-owned session returns to idle after a cancelled/stopped terminal only when it is transient or its final record was acknowledged; otherwise it closes as unreliable. A close caller instead receives the sanitized persistence error described above.

If a save is still pending at the deadline, or reports cancellation/failure without the repository guarantee that no later write can occur, the session becomes persistence-unreliable: it closes, starts no more provider/tool/repository work, and only the last acknowledged checkpoint is promised restorable. A timed-out operation is observed only to absorb its late completion/error; it cannot emit another event or update the closed session revision. Its `AgentSessionId` remains quarantined from same-runtime restore while the abandoned future is pending, preventing a late write from racing a new live session. An adapter that writes after completing with cancellation/failure violates the repository contract; correctness across a second runtime sharing such a nonconforming adapter cannot be guaranteed.

The prompt workspace receives an `Agent` facade based on its copied reasoning definition. On submit it calls the one-call run operation and maps runtime events into its existing `PromptState`; the run owns and closes its ephemeral session on terminal/dispose. Its feature policy explicitly sets one model turn and zero tool calls even though global runtime productive quotas default to unlimited. This preserves the `No conversation history` requirement while proving the new runtime in production. Reusing one long-lived session in the current UI was rejected because it would silently change product behavior.

### 6. Implement one deterministic guarded state machine

Per run control flow:

1. reject if the session is closed/busy or values/resources are invalid;
2. atomically drain envelopes already queued for this session, append their user-role payloads in FIFO order, then append the explicit run input; checkpoint this committed input when repository-backed;
3. emit run start and check cancellation, configured productive quotas, idle liveness, model/provider context/output bounds, and known token budgets;
4. snapshot context and call the selected provider;
5. forward reasoning/text/usage events while accumulating one candidate assistant message and tool-call fragments;
6. on provider completion, validate/commit and checkpoint the complete assistant message; incomplete output is never committed after cancellation/failure;
7. if there are no tool calls, emit successful completion;
8. otherwise process calls sequentially in provider order under the tool and guard rules below and commit/checkpoint one tool result per processed call;
9. fingerprint the completed continuation cycle, emit the no-progress warning at five identical cycles, and stop after ten before another continuation; reset the counter on defined progress;
10. immediately before a continuation, atomically drain newly queued envelopes, append them in FIFO order, re-check cancellation, quotas, liveness, bounds, and budgets, and return to step 4;
11. pass terminal counters through the persistence terminal barrier for a repository-backed session, emit exactly one agent terminal after acknowledgement or deterministic shutdown abandonment, and close the event stream.

One run-work cancellation source fans out to provider, approval, and executor work; operation-scoped persistence sources implement the separate terminal barrier above. Terminal transition uses a single guarded state so idle/total timeout, loop stop, caller cancellation, subscription cancellation, repository failure, and provider completion cannot emit competing terminals. Standard Dart `Future`, `Stream`, `StreamSubscription`, `Timer`, and `Stopwatch` are sufficient. Tools may internally use `Isolate.run` for CPU-heavy work, but the runtime neither requires nor serializes isolates.

No automatic retries are included: retries can duplicate side-effecting tools and complicate usage accounting. Parallel tool execution was rejected for MVP because provider order, approval, cancellation, and mobile resource bounds are easier to audit sequentially.

### 7. Tool contract, schema subset, policy, and failure semantics

An `AgentTool` pairs a serializable `LlmToolDescriptor` with a runtime executor:

```dart
abstract interface class AgentToolExecutor {
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  });
}
```

The descriptor uses a documented JSON-Schema subset sufficient for OpenAI function tools: object root, `type`, `properties`, `required`, nested object/array `items`, primitive types, `enum`, and `additionalProperties`. Unsupported schema keywords or a non-object root fail tool registration. Arguments are assembled, JSON-decoded to an object, and recursively validated before policy. This avoids claiming complete JSON Schema compliance and avoids a new package dependency. Both schema and arguments are deep-frozen.

`ToolExecutionLiveness.reportProgress()` is a cheap runtime-only signal that resets the idle watchdog and may publish a sanitized progress event; it never mutates or persists transcript content. Long-running executors are responsible for cancellation and periodic liveness. Each attempted call increments the tool-call count before lookup/validation when a finite quota is configured so malformed calls cannot bypass it. Outcomes:

- unknown/disabled tool, malformed JSON, schema failure: no policy/executor; append sanitized error result;
- `deny`: no executor; append denial result;
- `ask`: call injected `ToolApprovalHandler`; missing handler is deny; handler's exact allow executes;
- `allow`: execute once;
- executor failure/throw: catch and append sanitized tool failure;
- cancellation/timeout: do not synthesize a normal tool result; terminate the run.

Denied and failed tool results are shown to the model on a continuation, rather than failing the whole run, so it can recover or answer without the tool. Policy/hook infrastructure failure is different: it makes authorization/auditing unreliable and therefore terminates with typed runtime failure.

Policies and hooks are runtime-only registries. `ToolPermissionPolicy.decide` returns `allow | deny | ask`; hooks observe immutable before/after model/tool contexts in registration order and cannot mutate messages or override decisions. A future change may add broader model/message policies without changing provider adapters.

### 8. Default productive work to unlimited and enforce independent safety guards

`AgentRunLimits` has nullable positive `maxModelTurns`, nullable non-negative `maxToolCalls`, nullable positive `maxDuration`, and optional positive `maxOutputTokensPerTurn`. `AgentTokenBudget` has nullable non-negative cumulative input, output, and total token ceilings. `null` means unlimited/unenforced for that dimension; it is serialized as absence/null rather than a numeric sentinel. Global runtime defaults for turns, tool calls, total duration, and cumulative tokens are all unlimited. A finite zero tool allowance is valid and disables tools, as required by the current prompt feature.

Resolution precedence is run override, then `AgentDefinition`, then runtime profile. Because Dart needs to distinguish "no run override" from "explicitly override to unlimited", `AgentRunOptions` uses an explicit override wrapper/sentinel rather than relying on nullable named parameters. Resolved values are immutable for the run. The prompt workspace definition resolves to one model turn and zero tools; this is feature policy, not the runtime default.

Usage aggregates only provider-reported counters. Configured token checks occur before work and after each usage event/terminal. A provider response can exceed a ceiling because usage may be known only after generation; once observed, no tool or continuation starts. If a configured dimension remains unknown when continuation would otherwise occur, the run fails `budgetUnverifiable` instead of proceeding unmetered. Final output already emitted remains visible. Per-turn output remains both a request setting and a model-capability clamp, not a cumulative run quota.

`AgentLivenessPolicy` defaults to a ten-minute idle timeout. A monotonic idle clock resets on provider reasoning/text/tool-call/usage events, consumed inbound messages, approval resolution, tool start/progress/completion, and committed transcript checkpoints. A tool receives `ToolExecutionLiveness` so legitimately long work can report heartbeats without manufacturing transcript content. An explicit override may disable the idle timeout; total elapsed duration remains independent and unlimited by default.

`AgentNoProgressPolicy` fingerprints consecutive completed tool-continuation cycles from ordered tool IDs, canonical validated arguments, normalized outcomes, committed answer content, and inbound progress. Identical cycles with no new answer/inbound/progress increment one counter. The fifth emits one warning; the tenth emits a typed stop before an eleventh continuation. Changed arguments, changed normalized results, new answer content, consumed inbound content, or an explicit progress marker reset the counter. Warning and stop thresholds are positive, `warning < stop`, and follow the same precedence. This avoids treating legitimate polling with changing results as stuck.

Cancellation, one guarded terminal, provider model/context/output bounds, the liveness watchdog, and no-progress detection remain active independently from productive quotas. This is the chosen "let it work" policy: useful varied work may continue until completion or caller cancellation rather than being forced to summarize at an arbitrary small turn count.

Monetary budgets are deferred because the repository has no authoritative model-price/version source; importing Pi pricing would become stale and misleading. Duration uses monotonic timers, not wall-clock timestamps.

### 9. Route session messages through bounded in-memory mailboxes

The messaging API is conceptually:

```dart
abstract interface class SessionMessageRouter {
  Future<DeliveryReceipt> send(
    SessionEnvelope envelope, {
    DeliveryPreference preference = DeliveryPreference.queuedOnly,
  });
}
```

The runtime registers an in-memory mailbox for each live `AgentSessionId`; duplicate live registration fails. `SessionEnvelope` contains message id, source/target session IDs, a user-role `LlmMessage` payload, accepted timestamp, optional correlation id, and optional reply-to id. Restricting payload to user-role content prevents a sender from injecting fake assistant/tool authority into the target history. The envelope's source/correlation metadata is emitted on `AgentInboundMessageConsumed`; it is not trusted as provider authorization.

`send` synchronously validates/copies an envelope and atomically enqueues it in the target mailbox before completing `queued`. Unknown, closed, or full targets return typed `rejected`; no exception or false delivery status. Capacity is finite per runtime (default 100). FIFO is acceptance order in this process. Draining removes envelopes only when the session commits them immediately before a model request; an envelope arriving after the final drain remains queued for the next run. Mailboxes are not part of `AgentSessionRecord`, so restoring a record creates a new empty in-process mailbox.

`DeliveryPreference.preferSteer` exists so callers need not change shape later, but MVP always degrades it to `queued`. `DeliveryStatus.steered` is reserved and never emitted. Correlation/reply-to are inert routing metadata: they enable a future spawned task to send a late completion, but MVP creates no child, waiter, collector, or automatic run. This is deliberately broker/session-mediated rather than direct P2P.

### 10. Flutter/mobile lifecycle and security ownership

The UI subscribes only to `AgentRun.events`. For the prompt facade path its controller stores the active run, marks itself disposed and detaches UI delivery synchronously, then requests idempotent run/subscription cancellation; it does not own the runtime or transport. The existing generation guard prevents late microtasks from mutating disposed state. Synchronous Flutter `State.dispose` cannot await cleanup, so the runtime's live/opening-session registry is the authoritative async barrier rather than the controller's unawaited cancellation future.

`ProductionAgentStack`/`DomovoyDependencies` exposes one idempotent `Future<void> close()` and owns the concrete runtime, repository/router resources, providers, and shared `http.Client`. Its fixed order is: (1) await `runtime.close()`; (2) in cleanup/finally, close owned repository/router resources when they are closeable; (3) only then call `http.Client.close()`. It attempts every later cleanup step even if an earlier one fails, then reports only a sanitized first failure. Flutter `dispose` may launch this future unawaited only with an error handler, but must call this ordered close method and must never invoke `client.close` directly; tests and non-Flutter hosts await it. Consequently provider cancellation/session checkpoint cleanup always gets access to the client until the runtime barrier has finished. Transient `inactive`/`paused` states do not claim background execution and do not automatically restart work; OS process death may preempt async cleanup and loses in-memory repository/mailbox state. A future durable/background change must specify platform policy, storage adapter, recovery, notifications, and resource policy explicitly.

API keys remain in provider-scoped secure storage/environment adapters and are resolved at dispatch; the legacy DeepSeek secure key remains readable. Definitions, catalog metadata, messages, records, snapshots, envelopes, tool arguments/results, hooks, and errors never contain the effective credential. Sanitizers must not include raw provider response bodies, request headers, stack traces, repository exception text, or executor exception text in user-facing events. The existing web warning remains because browser runtime secrets cannot be made confidential by this architecture.

All core execution stays platform-neutral Dart. No `dart:io` import enters web-reachable core code; the existing conditional environment adapter and `package:http` preserve platform compatibility. Native identifiers remain `ru.kotdath.domovoy`.

## Risks / Trade-offs

- [The foundation introduces many public concepts at once] → Keep one narrow public barrel per layer, no provider-option escape hatch, and require contract tests against fakes plus both production wire adapters.
- [Two protocols and eight curated models increase the first change] → Share only framing/sanitization utilities, keep each adapter independently fixture-tested, omit SDKs/discovery/full catalogs, and make provider/model enumeration an explicit acceptance boundary.
- [Curated model metadata becomes stale] → Treat entries as a reviewed versioned snapshot, reject unknown models, omit pricing, and update catalogs through later reviewed changes rather than runtime guessing.
- [Binary reasoning booleans misrepresent non-reasoning or always-reasoning models] → Use `unsupported | optional | required`, validate `ReasoningMode` locally, and keep wire-specific disabled values in typed adapter metadata.
- [A custom compatible endpoint is not actually compatible] → Require explicit dialect/model capability metadata and convert malformed or unsupported behavior to typed protocol/configuration failures.
- [Custom schema validation could be mistaken for full JSON Schema] → Name and document the exact subset, reject unsupported constructs at registration, and add positive/negative recursive tests.
- [Cooperative cancellation cannot force arbitrary tool Futures to stop] → Pass a cancellation token, ignore late completion after terminal, document executor obligations, and never start subsequent work.
- [A durable repository can ignore cancellation or settle after shutdown] → Require cancellation-aware atomic save semantics, use one configurable positive five-second-default shutdown budget, close and quarantine an unreliable session after abandonment, and never infer a hang from microtask/event-loop scheduling.
- [Unlimited productive quotas can consume resources indefinitely] → Keep caller cancellation, a default idle watchdog, deterministic no-progress detection, model/context/output bounds, and opt-in per-run/definition quotas with explicit precedence.
- [Liveness or loop detection can stop legitimate long work] → Give tools a heartbeat channel, reset repetition on changed results/content/inbound progress, emit a warning five cycles before the ten-cycle stop, and make policies overridable/disableable.
- [A session record may imply stronger crash recovery than exists] → Persist only versioned committed checkpoints, never active frames/mailboxes, use optimistic revisions, and explicitly disclaim exact-once recovery of external tool side effects.
- [Some HTTP phases cannot be aborted uniformly on all Flutter targets] → Cancel subscriptions/use supported abort primitives and guard terminal/event delivery independently.
- [Provider usage can be absent or arrive after budget overshoot] → Never estimate; fail before continuation when configured budgets are unverifiable and state that one turn can overshoot.
- [In-memory queue can lose messages and create false durability expectations] → Use explicit `queued`, bounded capacity, documented process scope, and no `delivered` status.
- [Reasoning content in a session record may be sensitive] → Keep the supplied repository in-memory, never place reasoning in logs/events beyond its typed stream, and require an explicit retention/redaction decision before attaching a durable adapter.
- [Stateless Responses continuation needs provider-owned opaque state] → Retain only validated completed output items in a versioned origin-bound envelope, request encrypted reasoning, replay it verbatim, prohibit synthetic reasoning items, and classify the payload as confidential transcript metadata rather than a credential.
- [Flutter disposal cannot await async session cleanup] → Make runtime and composition close futures idempotent and bounded, keep the controller non-owning, and enforce runtime/repository-router/client order inside the launched future.
- [A tool can leak data or mutate external state] → Tools are opt-in by ID, schema-validated, policy-gated, sequential, and absent from the production prompt definition until explicitly enabled.
- [Legacy UI migration could accidentally introduce history] → Open and close a fresh session per submit and retain existing controller/widget regression tests.

## Migration Plan

1. Add and test provider-neutral values, curated registry/catalog, provider-scoped credential contracts, deep JSON validation/serialization, cancellation, event grammar, and fake-provider contract.
2. Move existing HTTP/SSE behavior behind the Chat Completions adapter; add DeepSeek, Moonshot AI/Kimi, and custom-compatible profiles and migrate legacy DeepSeek credential access.
3. Add and fixture-test the OpenAI Responses adapter/profile and exact curated OpenAI models without a vendor SDK or live network calls.
4. Add the agent facade, definition/resource resolution, versioned transcript/session records, codec/repository ports and in-memory repository, create/restore lifecycle, run state machine, unlimited-default quota resolution, watchdog/no-progress guards, tools, policy/approval, hooks, and cancellation races using deterministic fakes.
5. Add and test bounded in-memory session routing with two real runtime sessions and fake providers, keeping mailboxes outside session records.
6. Replace the legacy prompt dependency with the agent one-call facade and its one-turn/zero-tool feature policy; remove superseded provider-as-agent code only after behavior tests pass.
7. Run formatting, analyzer, full tests, and OpenSpec validation; inspect the full diff, credential migration, catalog contents, and all configured platform identifiers.

Rollback restores the previous `Agent`/`OpenAiCompatibleChatAgent` composition and removes the new core/infrastructure trees. No durable session migration is needed because the included repository is in-memory. The legacy DeepSeek credential key remains untouched/readable, so rollback does not lose the existing override.

## Open Questions

None block this change. Production tools, a general provider/settings UI, durable storage adapters, and the exact scope of the required Anthropic Messages/Kimi For Coding follow-up are intentionally deferred to separately proposed changes; they do not alter the contracts selected here.
